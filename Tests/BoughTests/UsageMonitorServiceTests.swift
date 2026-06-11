import XCTest
import ServiceManagement
@testable import Bough
@testable import BoughCore

final class UsageMonitorServiceTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var fakeClient: FakeUsageMonitorAppServiceClient!
    private var fakeProcessTerminator: FakeUsageMonitorProcessTerminator!
    private let now = Date(timeIntervalSince1970: 1_779_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMonitorServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaultsSuiteName = "UsageMonitorServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        fakeClient = FakeUsageMonitorAppServiceClient()
        fakeProcessTerminator = FakeUsageMonitorProcessTerminator()
        try createBundleArtifacts()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testMapsServiceStatusesToLifecycleStates() throws {
        fakeClient.currentStatus = .notRegistered
        XCTAssertEqual(makeService().refreshStatus().state, .stopped)

        fakeClient.currentStatus = .requiresApproval
        XCTAssertEqual(makeService().refreshStatus().state, .needsApproval)

        fakeClient.currentStatus = .notFound
        XCTAssertEqual(makeService().refreshStatus().state, .needsRepair)

        fakeClient.currentStatus = .enabled
        XCTAssertEqual(makeService().refreshStatus().state, .installed)

        try writeStatus(.init(state: .running, lastHeartbeatAt: now))
        XCTAssertEqual(makeService().refreshStatus().state, .running)

        try writeStatus(.init(state: .failed, lastHeartbeatAt: now, reason: "read failed"))
        XCTAssertEqual(makeService().refreshStatus().state, .error)
    }

    func testEnableRegistersAndSwitchesToHelperWriterAfterHealthyStatus() throws {
        fakeClient.currentStatus = .notRegistered
        let status = try makeService().enable()

        XCTAssertEqual(fakeClient.calls, [.register])
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "helper")
    }

    func testObservedStatusDoesNotPersistWriterOwner() throws {
        fakeClient.currentStatus = .enabled
        try writeStatus(.init(state: .running, lastHeartbeatAt: now))

        let status = makeService().observedStatus()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.writerOwner, .helper)
        XCTAssertNil(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner))

        _ = makeService().refreshStatus()
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "helper")
    }

    func testDisableUnregistersAndPreservesContinuityDatabase() throws {
        try "db".write(to: continuityURL(), atomically: true, encoding: .utf8)

        let status = try makeService().disable()

        XCTAssertEqual(fakeClient.calls, [.unregister])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(fakeProcessTerminator.terminatedPaths, [helperURL().path])
        XCTAssertEqual(status.state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: continuityURL().path))
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "app")
    }

    func testCodingSessionsOffDisablesRegisteredMonitorKillsHelperAndMarksRestore() throws {
        fakeClient.currentStatus = .enabled

        let status = makeService().disableForCodingSessionsOff()

        XCTAssertEqual(fakeClient.calls, [.unregister])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled), true)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "app")
    }

    func testCodingSessionsOffKillsOrphanHelperWithoutMarkingRestoreWhenMonitorWasNotRegistered() throws {
        fakeClient.currentStatus = .notRegistered

        _ = makeService().disableForCodingSessionsOff()

        XCTAssertEqual(fakeClient.calls, [])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled), false)
    }

    func testCodingSessionsOffPreservesPendingRestoreWhenRelaunchedWhileAlreadyStopped() throws {
        fakeClient.currentStatus = .notRegistered
        defaults.set(true, forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled)

        _ = makeService().disableForCodingSessionsOff()

        XCTAssertEqual(fakeClient.calls, [])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled), true)
    }

    func testCodingSessionsOnRestoresPausedMonitorAndClearsRestoreFlag() throws {
        fakeClient.currentStatus = .notRegistered
        defaults.set(true, forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled)

        let status = try makeService().restoreAfterCodingSessionsOnIfNeeded()

        XCTAssertEqual(fakeClient.calls, [.register])
        XCTAssertEqual(status?.state, .installed)
        XCTAssertEqual(defaults.bool(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled), false)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "helper")
    }

    func testCodingSessionsOnDoesNothingWithoutRestoreFlag() throws {
        fakeClient.currentStatus = .notRegistered

        let status = try makeService().restoreAfterCodingSessionsOnIfNeeded()

        XCTAssertNil(status)
        XCTAssertEqual(fakeClient.calls, [])
    }

    func testRepairUnregistersRegistersVerifiesAndPreservesContinuityDatabase() throws {
        try "db".write(to: continuityURL(), atomically: true, encoding: .utf8)

        let status = try makeService().repair()

        XCTAssertEqual(fakeClient.calls, [.unregister, .register])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(fakeProcessTerminator.terminatedPaths, [helperURL().path])
        XCTAssertEqual(status.state, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: continuityURL().path))
    }

    func testUninstallRemovesManagedArtifactsButPreservesContinuityDatabase() throws {
        try writeStatus(.init(state: .running, lastHeartbeatAt: now))
        try "command".write(to: commandURL(), atomically: true, encoding: .utf8)
        try "db".write(to: continuityURL(), atomically: true, encoding: .utf8)

        let status = try makeService().uninstall()

        XCTAssertEqual(fakeClient.calls, [.unregister])
        XCTAssertEqual(fakeProcessTerminator.terminatedNames, [UsageMonitorService.helperExecutableName])
        XCTAssertEqual(status.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: continuityURL().path))
    }

    func testDisableDeletesClaudeTokenMirror() throws {
        TestHelpers.processEnvironmentLock.lock()
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMonitorServiceTests-HOME-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        setenv("HOME", fakeHome.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: fakeHome)
            TestHelpers.processEnvironmentLock.unlock()
        }

        try ClaudeOAuthTokenMirror.write(ClaudeOAuthCredentials(
            accessToken: "t", expiresAt: nil, scopes: [], subscriptionType: nil
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path))

        _ = try makeService().disable()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path),
            "disable() must delete the token mirror (spec §6.3)"
        )
    }

    func testUninstallDeletesClaudeTokenMirror() throws {
        TestHelpers.processEnvironmentLock.lock()
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMonitorServiceTests-HOME-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        setenv("HOME", fakeHome.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: fakeHome)
            TestHelpers.processEnvironmentLock.unlock()
        }

        try ClaudeOAuthTokenMirror.write(ClaudeOAuthCredentials(
            accessToken: "t", expiresAt: nil, scopes: [], subscriptionType: nil
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path))

        _ = try makeService().uninstall()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path),
            "uninstall() must delete the token mirror (spec §6.3)"
        )
    }

    func testMissingBundleArtifactNeedsRepair() throws {
        try FileManager.default.removeItem(at: helperURL())

        let status = makeService().refreshStatus()

        XCTAssertEqual(status.state, .needsRepair)
        XCTAssertEqual(status.message, "usage_monitor_message_bundle_repair")
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "app")
    }

    func testRunningHelperSuppressesLegacyRawReason() throws {
        try writeStatus(.init(
            state: .running,
            lastHeartbeatAt: now,
            reason: "Provider sample was not newer than the stored sample"
        ))

        let status = makeService().refreshStatus()

        XCTAssertEqual(status.state, .running)
        XCTAssertNil(status.message)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageContinuityWriterOwner), "helper")
    }

    func testStaleAndUnavailableHelperSuppressRawReason() throws {
        try writeStatus(.init(
            state: .stale,
            lastHeartbeatAt: now,
            reason: "Provider sample was not newer than the stored sample"
        ))

        var status = makeService().refreshStatus()

        XCTAssertEqual(status.state, .installed)
        XCTAssertNil(status.message)

        try writeStatus(.init(
            state: .unavailable,
            lastHeartbeatAt: now,
            reason: "Usage sources unavailable"
        ))

        status = makeService().refreshStatus()

        XCTAssertEqual(status.state, .installed)
        XCTAssertNil(status.message)
    }

    func testFailedHelperUsesLocalizedLifecycleMessage() throws {
        try writeStatus(.init(
            state: .failed,
            lastHeartbeatAt: now,
            reason: "Provider sample was not newer than the stored sample"
        ))

        let status = makeService().refreshStatus()

        XCTAssertEqual(status.state, .error)
        XCTAssertEqual(status.message, "usage_monitor_message_collection_failed")

        let model = UsageMonitorLifecycleModel(
            status: status,
            availableActions: [],
            localized: { key in
                key == "usage_monitor_message_collection_failed"
                    ? "后台监控无法刷新用量。如果持续出现，请尝试修复。"
                    : key
            }
        )
        XCTAssertEqual(model.message, "后台监控无法刷新用量。如果持续出现，请尝试修复。")
    }

    // MARK: - Helpers

    private func makeService() -> UsageMonitorService {
        UsageMonitorService(
            client: fakeClient,
            processTerminator: fakeProcessTerminator,
            defaults: defaults,
            now: { self.now },
            bundleURL: bundleURL(),
            statusURL: statusURL(),
            commandURL: commandURL(),
            continuityStoreURL: continuityURL()
        )
    }

    private func createBundleArtifacts() throws {
        try FileManager.default.createDirectory(
            at: plistURL().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helperURL().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "plist".write(to: plistURL(), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: helperURL(), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL().path)
    }

    private func writeStatus(_ status: UsageMonitorStatus) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try data.write(to: statusURL(), options: .atomic)
    }

    private func bundleURL() -> URL {
        tempDir.appendingPathComponent("Bough.app", isDirectory: true)
    }

    private func plistURL() -> URL {
        bundleURL()
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(UsageMonitorService.plistName)
    }

    private func helperURL() -> URL {
        bundleURL()
            .appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(UsageMonitorService.helperExecutableName)
    }

    private func statusURL() -> URL {
        tempDir.appendingPathComponent("usage-monitor-status.json")
    }

    private func commandURL() -> URL {
        tempDir.appendingPathComponent("usage-monitor-command.json")
    }

    private func continuityURL() -> URL {
        tempDir.appendingPathComponent("usage-continuity.sqlite")
    }
}

private final class FakeUsageMonitorAppServiceClient: UsageMonitorAppServiceClient {
    enum Call: Equatable {
        case register
        case unregister
    }

    var currentStatus: SMAppService.Status = .enabled
    var calls: [Call] = []

    var status: SMAppService.Status {
        currentStatus
    }

    func register() throws {
        calls.append(.register)
        currentStatus = .enabled
    }

    func unregister() throws {
        calls.append(.unregister)
        currentStatus = .notRegistered
    }
}

private final class FakeUsageMonitorProcessTerminator: UsageMonitorProcessTerminating {
    var terminatedNames: [String] = []
    var terminatedPaths: [String] = []

    func terminateProcesses(named executableName: String, matchingExecutablePath executablePath: String) {
        terminatedNames.append(executableName)
        terminatedPaths.append(executablePath)
    }
}
