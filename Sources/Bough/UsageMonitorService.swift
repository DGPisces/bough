import Foundation
import Darwin
import ServiceManagement
import BoughCore

enum UsageMonitorLifecycleState: String, CaseIterable, Equatable {
    case installed
    case running
    case stopped
    case error
    case needsApproval
    case needsRepair
}

enum UsageMonitorLifecycleAction: String, CaseIterable, Equatable {
    case enable
    case disable
    case repair
    case uninstall
}

struct UsageMonitorLifecycleStatus: Equatable {
    let state: UsageMonitorLifecycleState
    let writerOwner: UsageContinuityWriterOwner
    let message: String?

    var isHelperWriter: Bool {
        writerOwner == .helper
    }
}

struct UsageMonitorLifecycleModel: Equatable {
    let stateLabel: String
    let message: String?
    let availableActions: [UsageMonitorLifecycleAction]
    let uninstallConfirmation: String

    init(
        status: UsageMonitorLifecycleStatus,
        availableActions: [UsageMonitorLifecycleAction],
        localized: (String) -> String
    ) {
        self.stateLabel = localized(Self.stateLabelKey(for: status.state))
        self.message = status.message.map(localized)
        self.availableActions = availableActions
        self.uninstallConfirmation = localized("usage_monitor_uninstall_confirmation")
    }

    static func stateLabelKey(for state: UsageMonitorLifecycleState) -> String {
        switch state {
        case .installed: return "usage_monitor_state_installed"
        case .running: return "usage_monitor_state_running"
        case .stopped: return "usage_monitor_state_stopped"
        case .error: return "usage_monitor_state_error"
        case .needsApproval: return "usage_monitor_state_needs_approval"
        case .needsRepair: return "usage_monitor_state_needs_repair"
        }
    }

    static func actionLabelKey(for action: UsageMonitorLifecycleAction) -> String {
        switch action {
        case .enable: return "usage_monitor_action_enable"
        case .disable: return "usage_monitor_action_disable"
        case .repair: return "usage_monitor_action_repair"
        case .uninstall: return "usage_monitor_action_uninstall"
        }
    }
}

protocol UsageMonitorAppServiceClient {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

protocol UsageMonitorProcessTerminating {
    func terminateProcesses(named executableName: String)
}

struct SMUsageMonitorAppServiceClient: UsageMonitorAppServiceClient {
    private let service: SMAppService

    init(plistName: String = UsageMonitorService.plistName) {
        self.service = SMAppService.agent(plistName: plistName)
    }

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

struct SystemUsageMonitorProcessTerminator: UsageMonitorProcessTerminating {
    func terminateProcesses(named executableName: String) {
        let pids = Self.runningPIDs(named: executableName)
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if pids.allSatisfy({ !Self.isRunning(pid: $0) }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for pid in pids where Self.isRunning(pid: pid) {
            kill(pid, SIGKILL)
        }
    }

    private static func runningPIDs(named executableName: String) -> [pid_t] {
        guard let data = ProcessRunner.run(path: "/usr/bin/pgrep", args: ["-x", executableName], timeout: 2),
              let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private static func isRunning(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

struct UsageMonitorService {
    static let plistName = "dev.dgpisces.bough.usage-monitor.plist"
    static let helperExecutableName = "bough-usage-monitor"
    static let staleHeartbeatInterval: TimeInterval = UsageMonitorRunner.appClosedIdleInterval * 2 + 30

    private let client: UsageMonitorAppServiceClient
    private let processTerminator: UsageMonitorProcessTerminating
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date
    private let plistURL: URL
    private let helperExecutableURL: URL
    private let statusURL: URL
    private let commandURL: URL
    private let continuityStoreURL: URL

    init(
        client: UsageMonitorAppServiceClient = SMUsageMonitorAppServiceClient(),
        processTerminator: UsageMonitorProcessTerminating = SystemUsageMonitorProcessTerminator(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        bundleURL: URL = Bundle.main.bundleURL,
        statusURL: URL = URL(fileURLWithPath: UsageMonitorRunner.defaultStatusPath()),
        commandURL: URL = URL(fileURLWithPath: UsageMonitorRunner.defaultStatusPath())
            .deletingLastPathComponent()
            .appendingPathComponent("usage-monitor-command.json"),
        continuityStoreURL: URL = URL(fileURLWithPath: UsageContinuityStore.defaultPath())
    ) {
        self.client = client
        self.processTerminator = processTerminator
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
        self.plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(Self.plistName)
        self.helperExecutableURL = bundleURL
            .appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(Self.helperExecutableName)
        self.statusURL = statusURL
        self.commandURL = commandURL
        self.continuityStoreURL = continuityStoreURL
    }

    func observedStatus() -> UsageMonitorLifecycleStatus {
        status(updateWriterOwner: false)
    }

    func refreshStatus() -> UsageMonitorLifecycleStatus {
        status(updateWriterOwner: true)
    }

    private func status(updateWriterOwner: Bool) -> UsageMonitorLifecycleStatus {
        guard bundleArtifactsAreHealthy else {
            recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(
                state: .needsRepair,
                writerOwner: .app,
                message: "usage_monitor_message_bundle_repair"
            )
        }

        switch client.status {
        case .enabled:
            if let helperStatus = readHelperStatus() {
                switch helperStatus.state {
                case .running:
                    let heartbeatIsFresh = now().timeIntervalSince(helperStatus.lastHeartbeatAt) <= Self.staleHeartbeatInterval
                    let state: UsageMonitorLifecycleState = heartbeatIsFresh ? .running : .installed
                    recordWriterOwner(.helper, updateWriterOwner: updateWriterOwner)
                    return UsageMonitorLifecycleStatus(state: state, writerOwner: .helper, message: nil)
                case .stale:
                    recordWriterOwner(.helper, updateWriterOwner: updateWriterOwner)
                    return UsageMonitorLifecycleStatus(state: .installed, writerOwner: .helper, message: nil)
                case .failed:
                    recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
                    return UsageMonitorLifecycleStatus(
                        state: .error,
                        writerOwner: .app,
                        message: "usage_monitor_message_collection_failed"
                    )
                case .unavailable:
                    recordWriterOwner(.helper, updateWriterOwner: updateWriterOwner)
                    return UsageMonitorLifecycleStatus(state: .installed, writerOwner: .helper, message: nil)
                }
            }
            recordWriterOwner(.helper, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(state: .installed, writerOwner: .helper, message: nil)
        case .notRegistered:
            recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(state: .stopped, writerOwner: .app, message: nil)
        case .requiresApproval:
            recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(
                state: .needsApproval,
                writerOwner: .app,
                message: "usage_monitor_message_approval"
            )
        case .notFound:
            recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(
                state: .needsRepair,
                writerOwner: .app,
                message: "usage_monitor_message_launch_agent_missing"
            )
        @unknown default:
            recordWriterOwner(.app, updateWriterOwner: updateWriterOwner)
            return UsageMonitorLifecycleStatus(
                state: .error,
                writerOwner: .app,
                message: "usage_monitor_message_unknown_status"
            )
        }
    }

    @discardableResult
    func enable() throws -> UsageMonitorLifecycleStatus {
        try client.register()
        let status = refreshStatus()
        if status.state == .installed || status.state == .running {
            setWriterOwner(.helper)
        }
        return status
    }

    @discardableResult
    func disable() throws -> UsageMonitorLifecycleStatus {
        try? client.unregister()
        terminateHelperProcesses()
        setWriterOwner(.app)
        return UsageMonitorLifecycleStatus(state: .stopped, writerOwner: .app, message: nil)
    }

    @discardableResult
    func disableForCodingSessionsOff() -> UsageMonitorLifecycleStatus {
        let isCurrentlyRegistered = shouldRestoreWhenCodingSessionsReturn
        let shouldRestore = isCurrentlyRegistered || defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled)
        defaults.set(shouldRestore, forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled)
        if isCurrentlyRegistered {
            try? client.unregister()
        }
        terminateHelperProcesses()
        setWriterOwner(.app)
        return UsageMonitorLifecycleStatus(state: .stopped, writerOwner: .app, message: nil)
    }

    @discardableResult
    func restoreAfterCodingSessionsOnIfNeeded() throws -> UsageMonitorLifecycleStatus? {
        guard defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled) else {
            return nil
        }

        let status = try enable()
        defaults.set(false, forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled)
        return status
    }

    @discardableResult
    func repair() throws -> UsageMonitorLifecycleStatus {
        try? client.unregister()
        try client.register()
        return refreshStatus()
    }

    @discardableResult
    func uninstall() throws -> UsageMonitorLifecycleStatus {
        try? client.unregister()
        terminateHelperProcesses()
        removeManagedRuntimeArtifacts()
        setWriterOwner(.app)
        return UsageMonitorLifecycleStatus(state: .stopped, writerOwner: .app, message: nil)
    }

    func isActionAvailable(_ action: UsageMonitorLifecycleAction, for state: UsageMonitorLifecycleState) -> Bool {
        switch action {
        case .enable:
            return state == .stopped || state == .needsApproval || state == .needsRepair
        case .disable:
            return state == .installed || state == .running || state == .error || state == .needsApproval
        case .repair:
            return state == .error || state == .needsRepair || state == .installed
        case .uninstall:
            return state != .stopped
        }
    }

    private var bundleArtifactsAreHealthy: Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: plistURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        guard fileManager.fileExists(atPath: helperExecutableURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: helperExecutableURL.path)
    }

    private var shouldRestoreWhenCodingSessionsReturn: Bool {
        switch client.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    private func readHelperStatus() -> UsageMonitorStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageMonitorStatus.self, from: data)
    }

    private func removeManagedRuntimeArtifacts() {
        for url in [statusURL, commandURL] where url.path != continuityStoreURL.path {
            try? fileManager.removeItem(at: url)
        }
    }

    private func terminateHelperProcesses() {
        processTerminator.terminateProcesses(named: Self.helperExecutableName)
    }

    private func recordWriterOwner(_ owner: UsageContinuityWriterOwner, updateWriterOwner: Bool) {
        guard updateWriterOwner else { return }
        setWriterOwner(owner)
    }

    private func setWriterOwner(_ owner: UsageContinuityWriterOwner) {
        defaults.set(owner.rawValue, forKey: SettingsKey.usageContinuityWriterOwner)
    }
}
