import Foundation
import AppKit
import BoughCore

extension AppState {
    /// Session ID prefix applied to Codex threads surfaced via the app-server.
    /// The rollout-file discovery path uses the raw UUID; the `codexapp:` prefix
    /// keeps the two channels' session namespaces disjoint so a user running
    /// Codex Desktop AND Codex CLI simultaneously doesn't see them collapse.
    static let codexAppSessionPrefix = "codexapp:"
    // Plain `let` constants — nonisolated so NSWorkspace notification
    // handlers on background queues can read them without Swift 6
    // Sendable warnings.
    nonisolated static let codexAppBundleId = "com.openai.codex"

    // MARK: - Public lifecycle

    /// Start watching `com.openai.codex` in NSWorkspace and, whenever it's
    /// running, maintain a JSON-RPC client connected to `codex app-server`.
    /// Idempotent — safe to call multiple times.
    func startCodexAppServerWatcher() {
        guard codingSessionsEnabledProvider() else {
            usageStore.pauseCodingSessionCollectionForDisabledMode()
            return
        }
        if codexAppServerObservers != nil { return }

        var observers: [NSObjectProtocol] = []
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppState.codexAppBundleId else { return }
            Task { @MainActor in self?.startCodexAppServerClientIfPossible() }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppState.codexAppBundleId else { return }
            Task { @MainActor in self?.stopCodexAppServerClient() }
        })

        codexAppServerObservers = observers

        // Catch up with whatever state we booted into.
        if codexAppServerRunningApplicationProvider() {
            startCodexAppServerClientIfPossible()
        } else {
            usageStore.startCodexRefreshLoop(using: nil)
        }
    }

    func stopCodexAppServerWatcher() {
        if let observers = codexAppServerObservers {
            let center = NSWorkspace.shared.notificationCenter
            for observer in observers { center.removeObserver(observer) }
            codexAppServerObservers = nil
        }
        stopCodexAppServerClient()
    }

    // MARK: - Client lifecycle

    private func startCodexAppServerClientIfPossible() {
        guard codingSessionsEnabledProvider() else {
            usageStore.pauseCodingSessionCollectionForDisabledMode()
            return
        }
        guard codexAppServerService == nil else { return }
        let executableURL = URL(fileURLWithPath: codexAppServerExecutablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            usageStore.startCodexRefreshLoop(using: nil)
            return
        }

        let client = codexAppServerTransportFactory(executableURL)
        let service = CodexAppServerService(transport: client)
        service.onThreadNotification = { [weak self] message in
            Task { @MainActor in self?.handleCodexAppServerMessage(message) }
        }
        service.onRateLimitsUpdated = { [weak self] message in
            Task { @MainActor in
                guard let self, self.codingSessionsEnabledProvider() else { return }
                self.usageStore.applyCodexRateLimitMessage(message)
            }
        }
        service.onExit = { [weak self, weak service] in
            Task { @MainActor [weak self, weak service] in
                guard let self, let service else { return }
                guard self.codexAppServerService === service else { return }
                self.codexAppServerService = nil
                self.usageStore.stopCodexRefreshLoop()
                self.removeCodexAppServerSessions()
            }
        }

        do {
            try service.start(
                clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            )
            codexAppServerService = service
            usageStore.startCodexRefreshLoop(using: service)
        } catch {
            service.stop()
            usageStore.startCodexRefreshLoop(using: nil)
            return
        }
    }

    private func stopCodexAppServerClient() {
        guard let service = codexAppServerService else {
            usageStore.stopCodexRefreshLoop()
            removeCodexAppServerSessions()
            return
        }
        service.stop()
        codexAppServerService = nil
        usageStore.stopCodexRefreshLoop()
        removeCodexAppServerSessions()
    }

    private func removeCodexAppServerSessions() {
        let stale = sessions.keys.filter { $0.hasPrefix(AppState.codexAppSessionPrefix) }
        for id in stale {
            removeSessionWithCleanup(id)
        }
    }

    func startCodexAppServerClientIfPossibleForTesting() {
        startCodexAppServerClientIfPossible()
    }

    func stopCodexAppServerClientForTesting() {
        stopCodexAppServerClient()
    }

    // MARK: - Notification dispatch

    private func handleCodexAppServerMessage(_ message: CodexJSONRPCMessage) {
        guard codingSessionsEnabledProvider() else { return }
        guard case .notification(let method) = message.kind else { return }
        let params = message.raw["params"]?.asObject ?? [:]

        switch method {
        case "thread/started":
            applyCodexThreadStartedNotification(params: params)
        case "thread/status/changed":
            applyCodexThreadStatusNotification(params: params)
        case "thread/closed":
            applyCodexThreadClosedNotification(params: params)
        default:
            break
        }
    }

    private func applyCodexThreadStartedNotification(params: [String: AnyCodableLike]) {
        guard let thread = params["thread"]?.asObject else { return }
        guard let threadId = thread["id"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId

        var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
        snapshot.source = "codex"
        snapshot.termBundleId = AppState.codexAppBundleId
        snapshot.providerSessionId = threadId
        if let cwd = thread["cwd"]?.asString, !cwd.isEmpty {
            snapshot.cwd = cwd
        }
        if let preview = thread["preview"]?.asString, !preview.isEmpty {
            snapshot.lastUserPrompt = preview
        }
        if let name = thread["name"]?.asString, !name.isEmpty {
            snapshot.sessionTitle = name
        }
        if let path = thread["path"]?.asString, !path.isEmpty {
            snapshot.transcriptPath = path
        }

        applyCodexThreadStatus(&snapshot, status: thread["status"]?.asObject)
        snapshot.lastActivity = Date()
        sessions[sessionId] = snapshot
        if snapshot.status != .idle || activeSessionId == nil {
            activeSessionId = sessionId
        }
        attachTranscriptTailerIfNeeded(sessionId: sessionId)
        refreshDerivedState()
    }

    private func applyCodexThreadStatusNotification(params: [String: AnyCodableLike]) {
        guard let threadId = params["threadId"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId
        guard var snapshot = sessions[sessionId] else { return }

        applyCodexThreadStatus(&snapshot, status: params["status"]?.asObject)
        snapshot.lastActivity = Date()
        sessions[sessionId] = snapshot
        if snapshot.status != .idle {
            activeSessionId = sessionId
        } else if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        refreshDerivedState()
    }

    private func applyCodexThreadClosedNotification(params: [String: AnyCodableLike]) {
        guard let threadId = params["threadId"]?.asString else { return }
        let sessionId = AppState.codexAppSessionPrefix + threadId
        removeSessionWithCleanup(sessionId)
    }

    /// Map a ThreadStatus union onto our flat AgentStatus enum. Shared between the
    /// initial `thread/started` payload (which embeds the status) and the incremental
    /// `thread/status/changed` notification.
    static func applyCodexThreadStatus(
        _ snapshot: inout SessionSnapshot,
        status: [String: AnyCodableLike]?
    ) {
        CodexThreadStatusMapper.apply(&snapshot, status: status)
    }

    // Instance method kept for convenience on call sites that already have `self`.
    fileprivate func applyCodexThreadStatus(
        _ snapshot: inout SessionSnapshot,
        status: [String: AnyCodableLike]?
    ) {
        AppState.applyCodexThreadStatus(&snapshot, status: status)
    }
}
