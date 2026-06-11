import SwiftUI
import CoreServices
import os.log
import SQLite3
import CryptoKit
import BoughCore

private let log = Logger(subsystem: "com.dgpisces.bough", category: "AppState")

struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startTime: Date?
}

@MainActor
@Observable
final class AppState {
    nonisolated static let disabledModePermissionResponse =
        Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)

    /// Snapshot of a hook event accepted by HookServer, kept for diagnostics
    /// export (#103). Stored in a fixed-size ring so we can attach the recent
    /// hook stream to bug reports without pulling in full payloads.
    ///
    /// `payloadKeys` lists the top-level JSON field names the hook arrived
    /// with (sorted, no values), and `promptPreview` is a 80-char prefix of
    /// any extracted user prompt. Together those let us tell at a glance
    /// whether a hook fired with an empty / missing prompt vs. fired with a
    /// prompt that the UI then dropped.
    struct DiagnosticHookEvent: Sendable {
        let timestamp: Date
        let source: String?
        let sessionId: String?
        let eventName: String
        let toolName: String?
        let viaPlugin: Bool
        let payloadKeys: [String]
        let promptPreview: String?
    }

    struct DiscoveredSession {
        let sessionId: String
        let cwd: String
        let tty: String?
        let model: String?
        let pid: pid_t?
        let modifiedAt: Date
        let recentMessages: [ChatMessage]
        var source: String = "claude"
        /// Absolute path to the JSONL transcript this session was discovered from.
        /// When non-nil and the session is still live, AppState registers a JSONLTailer
        /// so incremental assistant appends reach the UI without another full scan.
        var transcriptPath: String? = nil
    }

    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var permissionQueue: [PermissionRequest] = []
    var questionQueue: [QuestionRequest] = []

    @ObservationIgnored
    private(set) var recentHookEvents: [DiagnosticHookEvent] = []
    @ObservationIgnored
    private let maxRecentHookEvents = 100

    func recordHookEvent(
        source: String?,
        sessionId: String?,
        eventName: String,
        toolName: String?,
        viaPlugin: Bool,
        payloadKeys: [String],
        promptPreview: String?
    ) {
        recentHookEvents.append(DiagnosticHookEvent(
            timestamp: Date(),
            source: source,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            viaPlugin: viaPlugin,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        ))
        if recentHookEvents.count > maxRecentHookEvents {
            recentHookEvents.removeFirst(recentHookEvents.count - maxRecentHookEvents)
        }
    }
    /// Cache of in-flight PreToolUse records keyed by session/source/tool_use_id. Used to
    /// correlate permission requests back to their originating tool call. See AppState+ToolUseCache.
    @ObservationIgnored
    var pendingToolUses: [ToolUseKey: PreToolUseRecord] = [:]
    /// Records the transcript path currently watched for each session so we only
    /// reattach when the path actually changes. See AppState+TranscriptTailer.
    @ObservationIgnored
    var attachedTranscriptPaths: [String: String] = [:]
    /// Watches active session transcripts for appended assistant lines. Lazily
    /// constructed so the delta handler can safely capture `self`.
    @ObservationIgnored
    lazy var transcriptTailer: JSONLTailer = JSONLTailer { [weak self] delta in
        guard let self else { return }
        Task { @MainActor [self] in
            self.applyTranscriptDelta(delta)
        }
    }
    /// Active JSON-RPC client connected to `codex app-server`, or nil when
    /// Codex Desktop isn't running. See AppState+CodexAppServer.
    @ObservationIgnored
    var codexAppServerService: CodexAppServerService?
    /// NSWorkspace launch/terminate observers tracking Codex Desktop.
    @ObservationIgnored
    var codexAppServerObservers: [NSObjectProtocol]?
    @ObservationIgnored
    var codexAppServerExecutablePath = CodexAppServerClient.defaultExecutablePath
    @ObservationIgnored
    var codexAppServerTransportFactory: (URL) -> CodexAppServerTransport = {
        CodexAppServerClient(executableURL: $0)
    }
    @ObservationIgnored
    var codexAppServerRunningApplicationProvider: () -> Bool = {
        NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == AppState.codexAppBundleId })
    }
    /// Single-assignment: set at init and never replaced. @ObservationIgnored is intentional —
    /// AppState does not need to emit observation changes when usageStore is assigned (it isn't,
    /// after init). UsageStore is @Observable itself, so its fields emit changes independently.
    /// If usageStore is ever replaced (e.g. in a future refactor), remove @ObservationIgnored so
    /// the observation graph re-connects and views see the new instance (WR-04).
    @ObservationIgnored
    var usageStore = UsageStore()
    @ObservationIgnored
    var musicStore = MusicNowPlayingStore.live()
    @ObservationIgnored
    var defaultSourceProvider: () -> String = { SettingsManager.shared.defaultSource }
    @ObservationIgnored
    var codingSessionsEnabledProvider: () -> Bool = { CodingSessionsSettings.isEnabled() }
    @ObservationIgnored
    var airDropEnabledProvider: () -> Bool = { AirDropSettings.isEnabled() }

    /// Wires the direct-OAuth usage channels (spec §9): Claude via the
    /// credentials file/Keychain, Codex via ~/.codex/auth.json, with the
    /// spawn-once app-server reader as Codex's auth-failure fallback.
    func startUsageChannels() {
        guard codingSessionsEnabledProvider() else { return }
        let mirrorWriter: (ClaudeOAuthCredentials) -> Void = { credentials in
            guard UsageStore.shouldMirrorClaudeToken() else { return }
            try? ClaudeOAuthTokenMirror.write(credentials)
        }
        let claude = ClaudeOAuthUsageClient(
            credentialsReader: ClaudeOAuthCredentialsReader(
                keychainRead: ClaudeKeychainReader.readCredentialsData
            ),
            tokenMirrorWriter: mirrorWriter
        )
        let codex = CodexOAuthUsageClient()
        let fallback = CodexAppServerRateLimitMonitorReader(
            executableURL: URL(fileURLWithPath: codexAppServerExecutablePath)
        )
        usageStore.startUsageChannels(claude: claude, codex: codex, codexFallback: fallback)
    }

    func refreshUsageManually() {
        guard codingSessionsEnabledProvider() else { return }
        Task { @MainActor in
            await usageStore.refreshAllOAuth(force: true)
        }
    }

    func refreshUsageForPanelOpen() {
        guard codingSessionsEnabledProvider() else { return }
        usageStore.refreshForPanelOpenIfNeeded()
    }

    func setUsageRefreshActivity(_ activity: UsageRefreshActivity) {
        usageStore.setRefreshActivity(activity)
    }

    /// Computed: first item in permission queue (backward compat for UI reads)
    var pendingPermission: PermissionRequest? {
        guard let idx = nextVisiblePermissionIndex() else { return nil }
        return permissionQueue[idx]
    }
    /// Computed: first item in question queue
    var pendingQuestion: QuestionRequest? { questionQueue.first }
    /// Preview-only: mock question payload for DebugHarness (no continuation needed)
    var previewQuestionPayload: QuestionPayload?
    /// Preview-only: mock approval payload for DebugHarness (no continuation needed)
    var previewPermissionEvent: HookEvent?
    var surface: IslandSurface = .collapsed
    var airDropState: AirDropFlowState = .idle
    var airDropIncludeText = false
    var airDropReturnSurface: AirDropReturnSurface = .collapsed
    var airDropPreviewOverlayPhase: AirDropDragOverlayPhase?
    var airDropPreviewScenarioName: String?
    var airDropMagnetPreheating = false
    var airDropDropZoneHighlighted = false
    @ObservationIgnored
    var airDropFlowController = AirDropFlowController()
    @ObservationIgnored
    var airDropFlowConfigured = false
    @ObservationIgnored
    var airDropReturnTask: Task<Void, Never>?
    @ObservationIgnored
    var airDropEmptyDragDismissTask: Task<Void, Never>?
    @ObservationIgnored
    var airDropEmptyDragDismissDelay: TimeInterval = 2.0
    @ObservationIgnored
    var airDropOpenPanel: NSOpenPanel?
    @ObservationIgnored
    var airDropExplicitDismissInFlight = false
    @ObservationIgnored
    var airDropDuplicateDragSuppressionInterval: TimeInterval = 0.75
    @ObservationIgnored
    var airDropDateProvider: () -> Date = Date.init
    @ObservationIgnored
    var airDropLastDragPayloadSignature: String?
    @ObservationIgnored
    var airDropLastDragPayloadAcceptedAt: Date?

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    private var maxHistory: Int { SettingsManager.shared.maxToolHistory }
    private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    private var completionQueue: [String] = []
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false
    /// Auto-collapse timer fired but mouse is inside panel — defer collapse until mouse leaves
    var deferCollapseOnMouseLeave = false
    private var processMonitors: [String: (source: DispatchSourceProcess, process: ProcessIdentity)] = [:]
    private var exitingSessions: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    private var runningApplicationBundleIds: Set<String>?
    @ObservationIgnored
    private var runningApplicationObservers: [NSObjectProtocol] = []
    var saveTimer: Timer?
    var fsEventStream: FSEventStreamRef?
    var lastFSScanTime: Date = .distantPast
    var discoveryScanTask: Task<Void, Never>?
    var pendingDiscoveryRescan = false
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }
    /// True when an interactive card (approval or question) is visible — completions must queue.
    private var isShowingInteractive: Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }
    private var modelReadRetryAt: [String: Date] = [:]

    private var dismissedPermissionRequestIds: Set<String> = []
    private static func normalizedSessionId(for event: HookEvent) -> String {
        event.sessionId ?? "default"
    }
    func clearDismissedPermissionRequestId(_ id: String) {
        dismissedPermissionRequestIds.remove(id)
    }
    private func nextVisiblePermissionIndex() -> Int? {
        permissionQueue.firstIndex { request in
            !dismissedPermissionRequestIds.contains(request.dismissalId)
        }
    }

    var activePermissionQueueIndex: Int? {
        nextVisiblePermissionIndex()
    }

    func visiblePermissionQueueIndex(forSession sessionId: String) -> Int? {
        permissionQueue.firstIndex { request in
            Self.normalizedSessionId(for: request.event) == sessionId
                && !dismissedPermissionRequestIds.contains(request.dismissalId)
        }
    }

    var rotatingSessionId: String?
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }
    private var rotationTimer: Timer?

    func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.cleanupIdleSessions()
            }
        }
    }

    private func cleanupIdleSessions() {
        guard hasIdleCleanupWork else { return }

        // 1. Verify monitored PIDs are still alive (DispatchSource can silently miss exits).
        var deadMonitors: [(String, ProcessIdentity)] = []
        for (sessionId, monitor) in processMonitors {
            let process = monitor.process
            // Check if the monitored process is still the same live process.
            if !Self.isLiveProcess(process) {
                deadMonitors.append((sessionId, process))
                continue
            }
        }
        for (sessionId, process) in deadMonitors {
            // PID gone but monitor didn't fire — treat as process exit so session is removed
            // promptly (after 5s grace) instead of lingering for 10 minutes.
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }

        // 2. Reset likely-stuck sessions only when we have no process monitor.
        //    If the process is still monitored/alive, trust explicit Stop/SessionEnd or
        //    process exit instead of synthesizing idle and risking false-idle mid-thought.
        //    - No tool + no monitor: 300s (agents can think for several minutes)
        //    - Has tool + no monitor: 180s (long build / deep thinking with missed exit)
        //    - waitingApproval/Question + no monitor: 300s (connection likely dropped)
        //
        //    Skip remote sessions: they NEVER have a local process monitor (the CLI runs
        //    on the remote host), and a long-running remote task that doesn't fire hook
        //    events for >180s shouldn't be force-flipped to idle here — it'll then be
        //    swept by Section 4. Remote session lifecycle is driven by remote-end hooks
        //    and SSH connection state in RemoteManager, not by local timeouts. (#121)
        for (key, session) in sessions
            where processMonitors[key] == nil
            && session.status != .idle
            && !session.isRemote {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            let threshold: TimeInterval
            switch session.status {
            case .waitingApproval, .waitingQuestion: threshold = 300
            default: threshold = session.currentTool != nil ? 180 : 300
            }
            if elapsed > threshold {
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }

        // 2b. Some CLIs keep their parent process alive across requests, so a missed Stop hook
        // can leave the UI stuck in bare "thinking" forever after an interrupt. If we've had no
        // follow-up hook activity for a long time and there isn't even a live tool/description,
        // reset that silent processing state back to idle.
        let monitoredThinkingTimeout: TimeInterval = 300
        let nativeAppThinkingTimeout: TimeInterval = 30
        let codexTerminalTurnSettleTime: TimeInterval = 3
        for (key, session) in sessions
            where processMonitors[key] != nil
            && session.status == .processing
            && session.currentTool == nil
            && session.toolDescription == nil {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            if session.isNativeAppMode,
               elapsed >= codexTerminalTurnSettleTime,
               let finishedAt = Self.nativeAppFinishedTurnTimestamp(sessionId: key, session: session),
               finishedAt >= session.lastActivity.addingTimeInterval(-1) {
                sessions[key]?.status = .idle
                continue
            }
            // Native apps write transcripts synchronously — if the transcript check above
            // didn't find a stop marker after 30s, the session is almost certainly idle.
            if session.isNativeAppMode, elapsed > nativeAppThinkingTimeout {
                sessions[key]?.status = .idle
                continue
            }
            if elapsed > monitoredThinkingTimeout {
                sessions[key]?.status = .idle
            }
        }

        // 3. Verify PID liveness for sessions without monitors but with a known PID.
        //    If the process died: idle sessions are removed directly (no grace needed),
        //    non-idle sessions go through handleProcessExit for the 5s grace period.
        for (key, session) in sessions where processMonitors[key] == nil {
            guard let process = resolvedSessionProcessIdentity(for: key) else { continue }
            if !Self.isLiveProcess(process) {
                if exitingSessions[key] == process { continue }
                if session.status == .idle {
                    removeSession(key)
                } else {
                    handleProcessExit(sessionId: key, exitedProcess: process)
                }
            }
        }

        // 3b. Native app sessions (OpenCode desktop, Codex app, etc.) whose app is no longer
        //     running should be cleaned up — these apps can't send SessionEnd when force-quit.
        //     Don't check PID liveness here: the dedup in integrateDiscovered may have
        //     reattached a CLI PID to the old native app session, keeping it alive incorrectly.
        let nativeAppBundleIds = Self.nativeAppBundleIdsPendingCleanup(sessions: sessions)
        if !nativeAppBundleIds.isEmpty {
            let runningBundleIds = currentRunningApplicationBundleIds()
            for (key, session) in sessions {
                guard session.isNativeAppMode,
                      let bundleId = session.termBundleId,
                      !runningBundleIds.contains(bundleId) else { continue }
                removeSession(key)
            }
        }

        // 4. Remove idle sessions past timeout (user setting, or 10 min default for no-monitor sessions)
        let userTimeout = SettingsManager.shared.sessionTimeout
        let defaultStaleMinutes = 10  // for sessions without process monitor
        for (key, session) in sessions where session.status == .idle {
            let idleMinutes = Int(-session.lastActivity.timeIntervalSinceNow / 60)
            let hasMonitor = processMonitors[key] != nil
            if userTimeout > 0 && idleMinutes >= userTimeout {
                // User-configured timeout applies to all sessions
                removeSession(key)
            } else if !hasMonitor && idleMinutes >= defaultStaleMinutes {
                // No process monitor (hook-only sessions): clean up after 10 min idle
                removeSession(key)
            }
        }

        // 5. Reclaim memory for abandoned tool_use_id cache entries.
        prunePendingToolUses()

        refreshDerivedState()
    }

    private var hasIdleCleanupWork: Bool {
        !sessions.isEmpty
            || activeSessionId != nil
            || rotatingSessionId != nil
            || surface != .collapsed
            || !processMonitors.isEmpty
            || !exitingSessions.isEmpty
            || !permissionQueue.isEmpty
            || !questionQueue.isEmpty
            || !pendingToolUses.isEmpty
            || !completionQueue.isEmpty
    }

    nonisolated static func nativeAppBundleIdsPendingCleanup(sessions: [String: SessionSnapshot]) -> Set<String> {
        Set(sessions.values.compactMap { session in
            guard session.isNativeAppMode else { return nil }
            return session.termBundleId
        })
    }

    private func currentRunningApplicationBundleIds() -> Set<String> {
        if let runningApplicationBundleIds {
            return runningApplicationBundleIds
        }

        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        runningApplicationBundleIds = ids
        installRunningApplicationObserversIfNeeded()
        return ids
    }

    func isRunningApplicationBundleId(_ bundleId: String) -> Bool {
        currentRunningApplicationBundleIds().contains(bundleId)
    }

    private func installRunningApplicationObserversIfNeeded() {
        guard runningApplicationObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.runningApplicationBundleIds?.insert(bundleId)
            }
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.runningApplicationBundleIds?.remove(bundleId)
            }
        }

        runningApplicationObservers = [launchObserver, terminateObserver]
    }

    // MARK: - Process Monitoring (DispatchSource)

    private func currentSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let pid = sessions[sessionId]?.cliPid, pid > 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: sessions[sessionId]?.cliStartTime)
    }

    func resolvedSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let process = currentSessionProcessIdentity(for: sessionId) else { return nil }
        if let resolved = Self.trackedProcessIdentity(for: process.pid, source: sessions[sessionId]?.source) {
            if resolved != process {
                setSessionProcessIdentity(resolved, for: sessionId)
            }
            return resolved
        }
        if process.startTime != nil { return process }
        guard let refreshed = Self.liveProcessIdentity(for: process.pid) else { return process }
        setSessionProcessIdentity(refreshed, for: sessionId)
        return refreshed
    }

    func setSessionProcessIdentity(_ process: ProcessIdentity, for sessionId: String) {
        sessions[sessionId]?.cliPid = process.pid
        sessions[sessionId]?.cliStartTime = process.startTime
    }

    nonisolated static func liveProcessIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: getProcessStartTime(pid))
    }

    nonisolated static func isLiveProcess(_ process: ProcessIdentity) -> Bool {
        guard process.pid > 0, kill(process.pid, 0) == 0 else { return false }
        guard let expectedStart = process.startTime else { return true }
        return getProcessStartTime(process.pid) == expectedStart
    }

    private nonisolated static func trackedProcessIdentity(for pid: pid_t, source: String?) -> ProcessIdentity? {
        guard pid > 0 else { return nil }

        var currentPid: pid_t? = pid
        var visited = Set<pid_t>()
        var firstLiveProcess: ProcessIdentity?

        for _ in 0..<6 {
            guard let candidatePid = currentPid,
                  candidatePid > 0,
                  !visited.contains(candidatePid),
                  let process = liveProcessIdentity(for: candidatePid) else {
                break
            }

            visited.insert(candidatePid)
            if firstLiveProcess == nil {
                firstLiveProcess = process
            }
            if let path = executablePath(for: candidatePid),
               CLIProcessResolver.sourceMatchesExecutablePath(path, source: source) {
                return process
            }
            currentPid = parentPID(for: candidatePid)
        }

        return firstLiveProcess
    }

    private nonisolated static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func isNativeAppProcess(_ pid: pid_t, source: String) -> Bool {
        guard let path = executablePath(for: pid)?.lowercased() else { return false }
        switch source {
        case "cursor":     return path.contains("/cursor.app/contents/")
        case "trae":       return path.contains("/trae.app/contents/")
        case "traecn":     return path.contains("/trae.app/contents/") || path.contains("/traecn.app/contents/")
        case "qoder":      return path.contains("/qoder.app/contents/")
        case "droid":      return path.contains("/factory.app/contents/")
        case "codebuddy":  return path.contains("/codebuddy.app/contents/")
        case "codybuddycn": return path.contains("/codebuddycn.app/contents/") || path.contains("/codebuddy.app/contents/")
        case "stepfun":    return path.contains("/stepfun.app/contents/")
        case "codex":      return path.contains("/codex.app/contents/")
        case "opencode":   return path.contains("/opencode.app/contents/")
        case "antigravity": return path.contains("/antigravity.app/contents/")
        case "workbuddy":   return path.contains("/workbuddy.app/contents/")
        case "hermes":      return path.contains("/hermes.app/contents/")
        default:           return false
        }
    }

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard let process = Self.liveProcessIdentity(for: pid) else {
            handleProcessExit(sessionId: sessionId, exitedProcess: ProcessIdentity(pid: pid, startTime: nil))
            return
        }
        monitorProcess(sessionId: sessionId, process: process)
    }

    private func monitorProcess(sessionId: String, process: ProcessIdentity) {
        guard processMonitors[sessionId] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self, self.sessions[sessionId] != nil else { return }
                self.handleProcessExit(sessionId: sessionId, exitedProcess: process)
            }
        }
        source.resume()
        processMonitors[sessionId] = (source: source, process: process)
        exitingSessions.removeValue(forKey: sessionId)

        // Keep cliPid aligned with the monitored process unless we already have a different
        // live PID from a stronger source (hooks beat heuristic discovery).
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId) {
            if !Self.isLiveProcess(currentProcess) || currentProcess.pid == process.pid {
                setSessionProcessIdentity(process, for: sessionId)
            }
        } else {
            setSessionProcessIdentity(process, for: sessionId)
        }

        // Safety: if process already exited before monitor started
        if !Self.isLiveProcess(process) {
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
    }

    /// Grace period after process exit — gives 5s for a replacement process or fresh hook event
    /// to claim the session before removal. Prevents flicker during agent restarts.
    private func handleProcessExit(sessionId: String, exitedProcess: ProcessIdentity) {
        // Tear down the dead monitor immediately
        stopMonitor(sessionId)

        // If the session already moved to a replacement live PID, reattach immediately and
        // avoid flashing idle because a stale/wrong monitor exited.
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId),
           currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
            monitorProcess(sessionId: sessionId, process: currentProcess)
            return
        }

        if exitingSessions[sessionId] == exitedProcess {
            return
        }
        exitingSessions[sessionId] = exitedProcess

        // If session was actively doing something, reset state right away so the UI
        // doesn't show a stale "running Edit" while we wait through the grace period.
        if let status = sessions[sessionId]?.status, status != .idle {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            // Drain any pending permissions/questions — the process is gone
            drainPermissions(forSession: sessionId, reason: "process-exited")
            drainQuestions(forSession: sessionId, reason: "process-exited")
            refreshDerivedState()
        }

        let exitTime = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.sessions[sessionId] != nil else { return }
            guard self.exitingSessions[sessionId] == exitedProcess else { return }

            // A new monitor was attached during the grace period (new process took over)
            if self.processMonitors[sessionId] != nil { return }

            // Session was taken over by a different process (e.g. auto-update/restart):
            // cliPid changed to a new PID that's still alive → attach monitor, don't remove.
            if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
               currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
                self.monitorProcess(sessionId: sessionId, process: currentProcess)
                return
            }

            // Original process confirmed dead — remove regardless of lastActivity.
            // This prevents a race where an in-flight hook event (e.g. "Stop") updates
            // lastActivity after exitTime, causing the session to linger for 10+ minutes.
            if !Self.isLiveProcess(exitedProcess) {
                self.removeSession(sessionId)
                return
            }

            // Session received fresh activity during the grace period and the original PID is
            // still alive — the exit signal was stale/spurious, so restore monitoring.
            if let lastActivity = self.sessions[sessionId]?.lastActivity,
               lastActivity > exitTime {
                self.monitorProcess(sessionId: sessionId, process: exitedProcess)
                return
            }

            self.removeSession(sessionId)
        }
    }

    private func stopMonitor(_ sessionId: String) {
        processMonitors[sessionId]?.source.cancel()
        processMonitors.removeValue(forKey: sessionId)
    }

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible.
    private func removeSession(_ sessionId: String) {
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId, reason: "removeSession")
        drainQuestions(forSession: sessionId, reason: "removeSession")

        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                if !showNextPending() {
                    showNextCompletionOrCollapse()
                }
            } else {
                _ = showNextPending()
            }
        }
        sessions.removeValue(forKey: sessionId)
        stopMonitor(sessionId)
        detachTranscriptTailer(sessionId: sessionId)
        exitingSessions.removeValue(forKey: sessionId)
        modelReadRetryAt.removeValue(forKey: sessionId)
        completionQueue.removeAll { $0 == sessionId }
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
        refreshDerivedState()
        scheduleSave()
    }

    func removeSessionWithCleanup(_ sessionId: String) {
        removeSession(sessionId)
    }

    func suspendCodingSessionsForDisabledMode() {
        stopCodexAppServerWatcher()
        stopSessionDiscovery()
        usageStore.pauseCodingSessionCollectionForDisabledMode()

        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        rotationTimer?.invalidate()
        rotationTimer = nil

        for sessionId in Array(sessions.keys) {
            stopMonitor(sessionId)
            detachTranscriptTailer(sessionId: sessionId)
        }
        transcriptTailer.detachAll()
        attachedTranscriptPaths.removeAll()
        pendingToolUses.removeAll()
        exitingSessions.removeAll()
        modelReadRetryAt.removeAll()
        completionQueue.removeAll()
        dismissedPermissionRequestIds.removeAll()

        drainAllPermissions(reason: "coding-sessions-disabled")
        drainAllQuestions(reason: "coding-sessions-disabled")

        sessions.removeAll()
        activeSessionId = nil
        rotatingSessionId = nil
        completionHasBeenEntered = false
        deferCollapseOnMouseLeave = false
        surface = .collapsed

        refreshDerivedState()
    }

    func resumeCodingSessionsForEnabledMode() {
        usageStore.resumeCodingSessionCollectionForEnabledMode()
    }

    // MARK: - Compact bar mascot rotation

    /// Cached sorted active session IDs — refreshed by refreshActiveIds()
    private var cachedActiveIds: [String] = []

    private func refreshActiveIds() {
        cachedActiveIds = sessions
            .filter { $0.value.status != .idle }
            .sorted { a, b in
                let pa = statusPriority(a.value.status)
                let pb = statusPriority(b.value.status)
                if pa != pb { return pa > pb }
                // Same priority — most recently active first
                return a.value.lastActivity > b.value.lastActivity
            }
            .map(\.key)
    }

    /// Higher = more urgent, shown first in rotation
    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingApproval: return 5
        case .waitingQuestion: return 4
        case .running:         return 3
        case .processing:      return 2
        case .idle:            return 0
        }
    }

    private func startRotationIfNeeded() {
        refreshActiveIds()
        if cachedActiveIds.count > 1 {
            // If the most urgent session changed, snap to it immediately
            if let top = cachedActiveIds.first, top != rotatingSessionId {
                let topStatus = sessions[top]?.status ?? .idle
                let currentStatus = rotatingSessionId.flatMap { sessions[$0]?.status } ?? .idle
                if statusPriority(topStatus) > statusPriority(currentStatus) {
                    rotatingSessionId = top
                }
            }
            if rotatingSessionId.map({ !cachedActiveIds.contains($0) }) ?? true {
                rotatingSessionId = cachedActiveIds.first
            }
            if rotationTimer == nil {
                let interval = TimeInterval(max(1, SettingsManager.shared.rotationInterval))
                rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor [self] in
                        self.rotateToNextSession()
                    }
                }
            }
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            rotatingSessionId = nil
            // When rotation stops, ensure activeSessionId points to the remaining
            // active session (if any) so the collapsed bar doesn't stick on an idle one.
            if let active = cachedActiveIds.first,
               activeSessionId != active {
                activeSessionId = active
            }
        }
    }

    private func rotateToNextSession() {
        guard cachedActiveIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = cachedActiveIds.firstIndex(of: current) {
            rotatingSessionId = cachedActiveIds[(idx + 1) % cachedActiveIds.count]
        } else {
            rotatingSessionId = cachedActiveIds.first
        }
    }

    /// Start monitoring the CLI process for a session.
    /// Prefers the PID captured by the bridge (_ppid), falls back to source-aware process scans by CWD.
    func tryMonitorSession(_ sessionId: String) {
        guard codingSessionsEnabledProvider() else { return }
        guard sessions[sessionId]?.isRemote != true else { return }
        let currentMonitor = processMonitors[sessionId]?.process

        // Primary: use PID from bridge (works for any CLI)
        if let sessionProcess = resolvedSessionProcessIdentity(for: sessionId),
           Self.isLiveProcess(sessionProcess) {
            if currentMonitor == sessionProcess { return }
            if currentMonitor != nil {
                stopMonitor(sessionId)
            }
            monitorProcess(sessionId: sessionId, process: sessionProcess)
            return
        }

        if let currentMonitor, Self.isLiveProcess(currentMonitor) {
            setSessionProcessIdentity(currentMonitor, for: sessionId)
            return
        }

        // Fallback: scan for matching processes by CWD (source-aware)
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let source = sessions[sessionId]?.source
        Task.detached {
            let pid = Self.findPidForCwd(cwd, source: source)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                guard self.codingSessionsEnabledProvider() else { return }
                guard let discoveredProcess = Self.liveProcessIdentity(for: pid) else { return }

                let preferredProcess: ProcessIdentity
                if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
                   Self.isLiveProcess(currentProcess) {
                    preferredProcess = currentProcess
                } else {
                    preferredProcess = discoveredProcess
                    self.setSessionProcessIdentity(discoveredProcess, for: sessionId)
                }

                if let monitorProcess = self.processMonitors[sessionId]?.process,
                   monitorProcess == preferredProcess, Self.isLiveProcess(monitorProcess) {
                    return
                }

                if self.processMonitors[sessionId] != nil {
                    self.stopMonitor(sessionId)
                }
                self.monitorProcess(sessionId: sessionId, process: preferredProcess)
            }
        }
    }

    /// Find a CLI process PID by matching CWD, scoped to the correct source.
    /// Never guesses across sources: a missing/unknown source returns no PID instead of
    /// accidentally binding a session to the wrong process family.
    private nonisolated static func findPidForCwd(_ cwd: String, source: String? = nil) -> pid_t? {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source) else { return nil }
        let pids = findPids(forSource: normalizedSource)
        for pid in pids {
            if getCwd(for: pid) == cwd { return pid }
        }
        return nil
    }

    private nonisolated static func findPids(forSource source: String, candidatePids: [pid_t]? = nil) -> [pid_t] {
        switch source {
        case "claude":     return findClaudePids(candidatePids: candidatePids)
        case "codex":      return findCodexPids(candidatePids: candidatePids)
        case "gemini":     return findGeminiPids(candidatePids: candidatePids)
        case "cursor":     return findCursorPids(candidatePids: candidatePids)
        case "cursor-cli": return findCursorPids(candidatePids: candidatePids)
        case "trae":       return findTraePids(candidatePids: candidatePids)
        case "traecn":     return findTraeCNPids(candidatePids: candidatePids)
        case "traecli":    return findTraeCliPids(candidatePids: candidatePids)
        case "copilot":    return findCopilotPids(candidatePids: candidatePids)
        case "qoder":      return findQoderPids(candidatePids: candidatePids)
        case "qoder-cli":  return findQoderPids(candidatePids: candidatePids)
        case "droid":      return findFactoryPids(candidatePids: candidatePids)
        case "codebuddy":  return findCodeBuddyPids(candidatePids: candidatePids)
        case "codybuddycn": return findCodyBuddyCNPids(candidatePids: candidatePids)
        case "stepfun":    return findStepFunPids(candidatePids: candidatePids)
        case "opencode":   return findOpenCodePids(candidatePids: candidatePids)
        case "antigravity": return findAntiGravityPids(candidatePids: candidatePids)
        case "workbuddy":  return findWorkBuddyPids(candidatePids: candidatePids)
        case "hermes":     return findHermesPids(candidatePids: candidatePids)
        case "qwen":       return findQwenPids(candidatePids: candidatePids)
        case "kimi":       return findKimiPids(candidatePids: candidatePids)
        case "pi":         return findPiPids(candidatePids: candidatePids)
        case "kiro":       return findKiroPids(candidatePids: candidatePids)
        default:           return []
        }
    }

    private func enqueueCompletion(_ sessionId: String) {
        // Behavior setting (#146): respect "Auto-expand on agent completion".
        // When disabled the panel stays compact — status indicators still
        // update, but no completion card pops down.
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoExpandOnCompletion) else { return }

        // Don't queue duplicates
        if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

        if isShowingCompletion || isShowingInteractive {
            // Already showing one — queue this for later
            completionQueue.append(sessionId)
        } else {
            // Show immediately
            showCompletion(sessionId)
        }
    }

    private func showCompletion(_ sessionId: String) {
        doShowCompletion(sessionId)
    }

    private func doShowCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false
        deferCollapseOnMouseLeave = false

        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
        deferCollapseOnMouseLeave = false
    }

    private func showNextCompletionOrCollapse() {
        // Once the mouse has entered the completion card, defer collapse until it leaves
        if completionHasBeenEntered {
            deferCollapseOnMouseLeave = true
            return
        }
        // showNextPending handles: interactive items first, then completionQueue, then collapse
        if showNextPending() { return }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // Cached derived state (refreshed by refreshDerivedState after session mutations)
    private(set) var status: AgentStatus = .idle
    private(set) var primarySource: String = "claude"
    private(set) var activeSessionCount: Int = 0
    private(set) var totalSessionCount: Int = 0

    var currentTool: String? {
        // When approvals/questions are pending, always reflect the *front of the queue*.
        // Otherwise a second incoming request can overwrite session.currentTool and make
        // the first pending item appear to “disappear” in compact UI.
        if let pending = pendingPermission {
            return pending.event.toolName
        }
        if pendingQuestion != nil {
            // AskUserQuestion arrives via PermissionRequest tool.
            return "AskUserQuestion"
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        if let pending = pendingPermission {
            let sessionId = Self.normalizedSessionId(for: pending.event)
            return pending.event.toolDescription ?? sessions[sessionId]?.toolDescription
        }
        if let q = pendingQuestion {
            return q.question.question
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        let displaySessionId = s.displaySessionId(sessionId: id)
        return s.displayTitle(sessionId: displaySessionId)
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    /// Recompute cached status/source/counts from sessions in a single O(n) pass.
    /// Call after any mutation to `sessions` or session status.
    func refreshDerivedState() {
        let summary = deriveSessionSummary(from: sessions)
        // Whenever no session is actively working, honor the user-configured
        // default mascot. Covers both "no sessions at all" (#102) and "all
        // sessions idle" (#149) — without this, a user who sets the default
        // to Codex still sees Claude every time their last session goes idle
        // because deriveSessionSummary echoes the most recently active source.
        // Active work always wins (running / processing / waiting* status).
        let effectiveSource: String
        if summary.status == .idle {
            effectiveSource = defaultSourceProvider()
        } else {
            effectiveSource = summary.primarySource
        }
        // Only assign when changed (avoids unnecessary @Observable notifications)
        if status != summary.status { status = summary.status }
        if primarySource != effectiveSource { primarySource = effectiveSource }
        if activeSessionCount != summary.activeSessionCount { activeSessionCount = summary.activeSessionCount }
        if totalSessionCount != summary.totalSessionCount { totalSessionCount = summary.totalSessionCount }
    }

    func refreshProviderTitle(for trackedSessionId: String, providerSessionId: String? = nil) {
        guard let session = sessions[trackedSessionId] else { return }
        guard !session.isRemote else { return }

        let lookupSessionId = providerSessionId ?? session.providerSessionId ?? trackedSessionId
        if let providerSessionId {
            sessions[trackedSessionId]?.providerSessionId = providerSessionId
        } else if SessionTitleStore.supports(provider: session.source) {
            sessions[trackedSessionId]?.providerSessionId = lookupSessionId
        }

        guard SessionTitleStore.supports(provider: session.source) else { return }

        if let resolved = SessionTitleStore.title(for: lookupSessionId, provider: session.source, cwd: session.cwd) {
            sessions[trackedSessionId]?.sessionTitle = resolved.title
            sessions[trackedSessionId]?.sessionTitleSource = resolved.source
        } else {
            sessions[trackedSessionId]?.sessionTitle = nil
            sessions[trackedSessionId]?.sessionTitleSource = nil
        }
    }

    func handleEvent(_ event: HookEvent) {
        guard codingSessionsEnabledProvider() else { return }

        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let sessionId = Self.normalizedSessionId(for: event)

        // Skip Codex APP internal sessions (title generation, etc.) — they have no transcript
        if (event.rawJSON["_source"] as? String) == "codex"
            && sessions[sessionId] == nil
            && event.rawJSON["transcript_path"] is NSNull {
            return
        }

        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }

        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        let prevStatus = sessions[sessionId]?.status
        let wasWaiting = prevStatus == .waitingApproval || prevStatus == .waitingQuestion

        // Cache PreToolUse payloads so downstream events sharing tool_use_id can be
        // correlated, and drain queue entries whose agent already moved on.
        cachePreToolUseIfApplicable(event)
        resolveToolUseIfCompleted(event)

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: maxHistory)

        // Backfill model after metadata extraction. Hooks are inconsistent across providers,
        // so retry with a cooldown instead of giving up permanently on the first miss.
        if sessions[sessionId]?.isRemote != true {
            maybeBackfillModel(for: sessionId)
        }

        // Session was waiting and got an activity event. Historically we'd
        // blanket-drain the whole queue here, assuming the user answered in the
        // terminal. That heuristic misfires for parallel MCP / plugin tool calls:
        // an unrelated PostToolUse / Stop / etc. would deny pending permissions
        // for *other* in-flight tools (#147).
        //
        // The right signal that a specific permission is moot is its tool_use_id
        // showing up in PostToolUse / PostToolUseFailure / PermissionDenied —
        // resolveToolUseIfCompleted already does that surgically above. We keep
        // the question-queue drain (questions don't carry tool_use_id reliably
        // and are rare enough that a blanket sweep is acceptable) and refresh
        // session status, but never drain unrelated permission requests.
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedEventName) {
                drainQuestions(forSession: sessionId, reason: "wasWaiting-blanket-drain-event=\(normalizedEventName)")
                let stillHasPermission = permissionQueue.contains { Self.normalizedSessionId(for: $0.event) == sessionId }
                let stillHasQuestion = questionQueue.contains { Self.normalizedSessionId(for: $0.event) == sessionId }
                if !stillHasPermission && !stillHasQuestion,
                   (sessions[sessionId]?.status == .waitingApproval
                    || sessions[sessionId]?.status == .waitingQuestion) {
                    sessions[sessionId]?.status = (normalizedEventName == "Stop") ? .idle : .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                }
                showNextPending()
            }
        }

        // Detect Cursor YOLO mode once per session (nil = unchecked)
        if event.rawJSON["_source"] as? String == "cursor",
           sessions[sessionId]?.isYoloMode == nil {
            sessions[sessionId]?.isYoloMode = Self.detectCursorYoloMode()
        }

        for effect in effects {
            executeEffect(effect, sessionId: sessionId)
        }

        // QUOTA-01: emit Claude Code quota payload for Stop and PostToolUse events.
        // Serializes rawJSON back to Data so applyClaudeCodePayload receives the full payload.
        if (event.rawJSON["_source"] as? String) == "claude",
           normalizedEventName == "Stop" || normalizedEventName == "PostToolUse",
           let payloadData = try? JSONSerialization.data(withJSONObject: event.rawJSON) {
            executeEffect(.claudeCodeUsagePayload(payloadData, Date()), sessionId: sessionId)
        }

        if let provider = sessions[sessionId]?.source,
           sessions[sessionId]?.isRemote != true,
           SessionTitleStore.supports(provider: provider) {
            refreshProviderTitle(for: sessionId)
        }

        // If a hook just supplied (or changed) this session's transcript path, attach
        // the tailer so the next assistant append shows up in the panel immediately.
        if sessions[sessionId]?.isRemote != true {
            attachTranscriptTailerIfNeeded(sessionId: sessionId)
        }

        // Handle the "else if activeSessionId == sessionId → mostActive" edge case
        // (reducer can't check activeSessionId since it's AppState-local)
        if sessions[sessionId]?.status == .idle && activeSessionId == sessionId {
            if normalizedEventName != "Stop" {
                activeSessionId = mostActiveSessionId()
            }
        }

        scheduleSave()
        startRotationIfNeeded()
        refreshDerivedState()
    }

    func removeRemoteSessions(hostId: String) {
        let ids = sessions.compactMap { key, session in
            session.remoteHostId == hostId ? key : nil
        }
        for id in ids {
            removeSession(id)
        }
        refreshDerivedState()
    }

    private func executeEffect(_ effect: SideEffect, sessionId: String) {
        switch effect {
        case .playSound(let eventName):
            SoundManager.shared.handleEvent(eventName)
        case .tryMonitorSession(let sid):
            tryMonitorSession(sid)
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .enqueueCompletion(let sid):
            enqueueCompletion(sid)
        case .setActiveSession(let sid):
            activeSessionId = sid
        case .claudeCodeUsagePayload(let data, let receivedAt):
            usageStore.applyClaudeCodePayload(data, receivedAt: receivedAt)
        }
    }

    private func maybeBackfillModel(for sessionId: String) {
        guard let session = sessions[sessionId], session.model == nil else { return }
        let now = Date()
        if let retryAt = modelReadRetryAt[sessionId], retryAt > now {
            return
        }

        if let model = Self.readModelForSession(sessionId: sessionId, session: session) {
            sessions[sessionId]?.model = model
            modelReadRetryAt.removeValue(forKey: sessionId)
        } else {
            modelReadRetryAt[sessionId] = now.addingTimeInterval(5)
        }
    }

    func handlePermissionRequest(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        guard codingSessionsEnabledProvider() else {
            continuation.resume(returning: Self.disabledModePermissionResponse)
            return
        }

        let sessionId = Self.normalizedSessionId(for: event)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        // Extract metadata so blocking-first sessions have cwd, source, cliPid, terminal info
        extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        tryMonitorSession(sessionId)
        let permissionEvent = permissionEventByEnrichingFromCache(event)

        // Clear any pending questions for THIS session (mutually exclusive within a session)
        drainQuestions(forSession: sessionId, reason: "newPermissionRequest")

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = permissionEvent.toolName
        sessions[sessionId]?.toolDescription = permissionEvent.toolDescription
        sessions[sessionId]?.lastActivity = Date()

        let request = PermissionRequest(event: permissionEvent, continuation: continuation)
        let hadVisiblePermission = nextVisiblePermissionIndex() != nil
        // New incoming permission request means this request needs user decision again.
        dismissedPermissionRequestIds.remove(request.dismissalId)

        // Replay deduplication: if the same tool_use_id is already queued, swap the
        // continuation in place and deny the previous waiter. Preserves card order.
        if mergeDuplicatePermissionRequest(request) {
            if !hadVisiblePermission, showNextPending() {
                SoundManager.shared.handleEvent("PermissionRequest")
            }
            refreshDerivedState()
            return
        }

        permissionQueue.append(request)

        // Show UI when the queue previously had no visible approval. This covers
        // dismissed requests that remain queued for an external terminal answer.
        if !hadVisiblePermission, showNextPending() {
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    func approvePermission(always: Bool = false) {
        guard let idx = nextVisiblePermissionIndex() else { return }
        let pending = permissionQueue.remove(at: idx)
        let sessionId = Self.normalizedSessionId(for: pending.event)
        dismissedPermissionRequestIds.remove(pending.dismissalId)
        let responseData: Data
        if always,
           let toolName = pending.event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [["toolName": toolName, "ruleContent": "*"]],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        }
        pending.continuation.resume(returning: responseData)
        sessions[sessionId]?.status = .running

        showNextPending()
        refreshDerivedState()
    }

    /// Find an existing session whose source matches and whose CLI PID equals
    /// the supplied ppid. Used by HookServer to merge plugin-proxied events
    /// (e.g. omo) into their main session when pluginSessionMode == "merge". (#123)
    ///
    /// We additionally require the candidate session to have been active in
    /// the last 5 minutes. This guards against macOS PID reuse — a stale
    /// session whose CLI long since exited could otherwise still match the
    /// plugin event's `_ppid` if the OS recycled that PID for an unrelated
    /// process. Live sessions update `lastActivity` on every event so the
    /// window is generous; stale ones get skipped. (#123 review)
    func findSessionId(forSource source: String, ppid: Int) -> String? {
        let normalized = SessionSnapshot.runtimeSourceGroup(source)
        let cutoff = Date().addingTimeInterval(-300)
        return sessions.first(where: { _, snap in
            let snapSource = SessionSnapshot.runtimeSourceGroup(snap.source)
            return snapSource == normalized
                && snap.cliPid == pid_t(ppid)
                && snap.lastActivity >= cutoff
        })?.key
    }

    func denyPermission() {
        guard let idx = nextVisiblePermissionIndex() else { return }
        let pending = permissionQueue.remove(at: idx)
        let sessionId = Self.normalizedSessionId(for: pending.event)
        dismissedPermissionRequestIds.remove(pending.dismissalId)
        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        pending.continuation.resume(returning: Data(response.utf8))
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
        refreshDerivedState()
    }

    func dismissPermissionPrompt() {
        guard let idx = nextVisiblePermissionIndex() else { return }
        let pending = permissionQueue[idx]

        dismissedPermissionRequestIds.insert(pending.dismissalId)

        if !showNextPending() {
            if case .approvalCard = surface {
                withAnimation(NotchAnimation.close) {
                    surface = .collapsed
                }
            }
        }
        refreshDerivedState()
    }

    func handleQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        guard codingSessionsEnabledProvider() else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        let sessionId = Self.normalizedSessionId(for: event)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        tryMonitorSession(sessionId)

        guard let question = QuestionPayload.from(event: event) else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        drainPermissions(forSession: sessionId, reason: "handleQuestion(Notification)")

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()

        let request = QuestionRequest(event: event, question: question, continuation: continuation)
        questionQueue.append(request)

        if showNextPending(),
           case .questionCard(let visibleSessionId) = surface,
           visibleSessionId == sessionId {
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    func handleAskUserQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        guard codingSessionsEnabledProvider() else {
            continuation.resume(returning: Self.disabledModePermissionResponse)
            return
        }

        let sessionId = Self.normalizedSessionId(for: event)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        tryMonitorSession(sessionId)

        var askItems: [AskUserQuestionItem] = []
        if let questions = event.toolInput?["questions"] as? [[String: Any]] {
            var usedAnswerKeys = Set<String>()
            askItems = questions.enumerated().compactMap { index, item in
                let questionText = item["question"] as? String ?? "Question"
                let header = item["header"] as? String
                let multiSelect = item["multiSelect"] as? Bool ?? false
                var optionLabels: [String]?
                var optionDescs: [String]?
                if let opts = item["options"] as? [[String: Any]] {
                    optionLabels = opts.compactMap { $0["label"] as? String }
                    optionDescs = opts.compactMap { $0["description"] as? String }
                }
                if optionLabels?.isEmpty == true { optionLabels = nil }
                if optionDescs?.isEmpty == true { optionDescs = nil }
                let payload = QuestionPayload(
                    question: questionText,
                    options: optionLabels,
                    descriptions: optionDescs,
                    header: header
                )
                let trimmedHeader = header?.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseKey = (trimmedHeader?.isEmpty == false ? trimmedHeader : nil) ?? "answer_\(index + 1)"
                var answerKey = baseKey
                if usedAnswerKeys.contains(answerKey) {
                    var suffix = 2
                    while usedAnswerKeys.contains("\(baseKey)_\(suffix)") {
                        suffix += 1
                    }
                    answerKey = "\(baseKey)_\(suffix)"
                }
                usedAnswerKeys.insert(answerKey)
                return AskUserQuestionItem(payload: payload, answerKey: answerKey, multiSelect: multiSelect)
            }
        }

        if askItems.isEmpty {
            let questionText = event.toolInput?["question"] as? String ?? "Question"
            var options: [String]?
            if let stringOpts = event.toolInput?["options"] as? [String] {
                options = stringOpts
            } else if let dictOpts = event.toolInput?["options"] as? [[String: Any]] {
                options = dictOpts.compactMap { $0["label"] as? String }
            }
            if !questionText.isEmpty {
                let payload = QuestionPayload(question: questionText, options: options)
                askItems = [AskUserQuestionItem(payload: payload, answerKey: "answer", multiSelect: false)]
            }
        }

        guard !askItems.isEmpty else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": ["answers": [:] as [String: String]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            let responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            continuation.resume(returning: responseData)
            sessions[sessionId]?.status = .processing
            refreshDerivedState()
            return
        }

        drainPermissions(forSession: sessionId, reason: "handleAskUserQuestion")
        drainQuestions(forSession: sessionId, reason: "handleAskUserQuestion")

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()

        let askState = AskUserQuestionState(items: askItems, answers: [:])
        let request = QuestionRequest(
            event: event,
            question: askItems[0].payload,
            continuation: continuation,
            isFromPermission: true,
            askUserQuestionState: askState
        )
        questionQueue.append(request)

        if showNextPending(),
           case .questionCard(let visibleSessionId) = surface,
           visibleSessionId == sessionId {
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    func answerQuestion(_ answer: String) {
        guard !questionQueue.isEmpty else { return }
        // AskUserQuestion uses batch wizard — direct single answers are not processed
        if questionQueue[0].isFromPermission, questionQueue[0].askUserQuestionState != nil {
            return
        }
        let pending = questionQueue.removeFirst()
        let responseData: Data
        if pending.isFromPermission {
            let answerKey = pending.question.header ?? "answer"
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": [
                            "answers": [answerKey: answer]
                        ]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answer
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = Self.normalizedSessionId(for: pending.event)
        sessions[sessionId]?.status = .processing

        showNextPending()
        refreshDerivedState()
    }

    func answerQuestionMulti(_ answers: [(question: String, answer: String)]) {
        answerQuestionMulti(answers.map { (question: $0.question, answer: AskUserQuestionAnswerValue.single($0.answer)) })
    }

    func answerQuestionMulti(_ answers: [(question: String, answer: AskUserQuestionAnswerValue)]) {
        guard !questionQueue.isEmpty else { return }
        let pending = questionQueue.removeFirst()
        let responseData: Data
        if pending.isFromPermission {
            var answersDict: [String: Any] = [:]
            var answerValues: [Any] = []
            if let askState = pending.askUserQuestionState {
                // Match by position — wizard collects answers in the same order as items
                for (index, item) in askState.items.enumerated() {
                    if index < answers.count {
                        let answer = answers[index].answer.jsonValue
                        answersDict[item.answerKey] = answer
                        answerValues.append(answer)
                    }
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                let answer = answers.first?.answer.jsonValue ?? ""
                answersDict[answerKey] = answer
                answerValues.append(answer)
            }
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": [
                            "answers": answersDict,
                            "answerValues": answerValues
                        ]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answers.first?.answer.jsonValue ?? ""
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = Self.normalizedSessionId(for: pending.event)
        sessions[sessionId]?.status = .processing

        showNextPending()
        refreshDerivedState()
    }

    func skipQuestion() {
        guard !questionQueue.isEmpty else { return }
        let pending = questionQueue.removeFirst()
        let responseData: Data
        if pending.isFromPermission {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        } else {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = Self.normalizedSessionId(for: pending.event)
        sessions[sessionId]?.status = .processing

        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued permissions for a specific session, resuming their continuations with deny
    private func drainPermissions(forSession sessionId: String, reason: String = "unknown") {
        let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        permissionQueue.removeAll { item in
            guard Self.normalizedSessionId(for: item.event) == sessionId else { return false }
            dismissedPermissionRequestIds.remove(item.dismissalId)
            log.notice("⚠️ permission deny reason=drainPermissions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: denyResponse)
            return true
        }
    }

    private func drainAllPermissions(reason: String) {
        guard !permissionQueue.isEmpty else { return }
        let denyResponse = Self.disabledModePermissionResponse
        for item in permissionQueue {
            log.notice("⚠️ permission deny reason=drainAllPermissions(\(reason, privacy: .public)) session=\(item.event.sessionId ?? "nil", privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: denyResponse)
        }
        permissionQueue.removeAll()
        dismissedPermissionRequestIds.removeAll()
    }

    /// Called when the bridge socket disconnects — the question/permission was answered externally (e.g. user replied in terminal)
    func handlePeerDisconnect(sessionId: String) {
        let hadPending = questionQueue.contains(where: { Self.normalizedSessionId(for: $0.event) == sessionId })
            || permissionQueue.contains(where: { Self.normalizedSessionId(for: $0.event) == sessionId })
        guard hadPending else { return }

        drainQuestions(forSession: sessionId, reason: "peer-disconnect")
        drainPermissions(forSession: sessionId, reason: "peer-disconnect")
        let currentStatus = sessions[sessionId]?.status
        if currentStatus == .waitingApproval || currentStatus == .waitingQuestion {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued questions for a specific session.
    /// AskUserQuestion-derived requests are denied; notification questions return empty.
    private func drainQuestions(forSession sessionId: String, reason: String = "unknown") {
        questionQueue.removeAll { item in
            guard Self.normalizedSessionId(for: item.event) == sessionId else { return false }
            if item.isFromPermission {
                log.notice("⚠️ permission deny reason=drainQuestions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                let denyData = Data(
                    #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                item.continuation.resume(returning: denyData)
            } else {
                item.continuation.resume(returning: Data("{}".utf8))
            }
            return true
        }
    }

    private func drainAllQuestions(reason: String) {
        guard !questionQueue.isEmpty else { return }
        for item in questionQueue {
            if item.isFromPermission {
                log.notice("⚠️ permission deny reason=drainAllQuestions(\(reason, privacy: .public)) session=\(item.event.sessionId ?? "nil", privacy: .public) tool=AskUserQuestion")
                item.continuation.resume(returning: Self.disabledModePermissionResponse)
            } else {
                item.continuation.resume(returning: Data("{}".utf8))
            }
        }
        questionQueue.removeAll()
    }

    /// After dequeuing, show next pending item or collapse
    @discardableResult
    func showNextPending() -> Bool {
        if let idx = nextVisiblePermissionIndex() {
            let next = permissionQueue.remove(at: idx)
            permissionQueue.insert(next, at: 0)
            let sid = Self.normalizedSessionId(for: next.event)
            activeSessionId = sid
            // When the session list is open, keep it open; approvals can be handled inline.
            if surface != .sessionList {
                surface = .approvalCard(sessionId: sid)
            }
            return true
        } else if let next = questionQueue.first {
            let sid = Self.normalizedSessionId(for: next.event)
            activeSessionId = sid
            surface = .questionCard(sessionId: sid)
            return true
        } else if !completionQueue.isEmpty {
            while let next = completionQueue.first {
                completionQueue.removeFirst()
                if sessions[next] != nil {
                    withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                    return true
                }
            }
            return false
        } else if case .approvalCard = surface {
            surface = .collapsed
        } else if case .questionCard = surface {
            surface = .collapsed
        }
        return false
    }

    /// Find the most recently active non-idle session
    func mostActiveSessionId() -> String? {
        // Pick the most urgent session: highest status priority, then most recent activity
        sessions.max { a, b in
            let pa = statusPriority(a.value.status)
            let pb = statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
    }

    /// Check if Cursor is in YOLO mode by reading its settings
    private static func detectCursorYoloMode() -> Bool {
        let settingsPath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              let str = String(data: data, encoding: .utf8) else { return false }
        let stripped = ConfigInstaller.stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return false }
        if json["cursor.general.yoloMode"] as? Bool == true { return true }
        if json["cursor.agent.enableYoloMode"] as? Bool == true { return true }
        return false
    }

    /// Read Claude model from a session transcript file.
    private nonisolated static func readModelFromTranscript(sessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/projects/\(projectDir)/\(sessionId).jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let chunk = handle.readData(ofLength: 32768)
        let text = UTF8FileChunkReader.decode(chunk)
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return nil
    }

    private nonisolated static func readModelForSession(sessionId: String, session: SessionSnapshot) -> String? {
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return nil }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        switch source {
        case "claude":
            return readModelFromTranscript(sessionId: sessionId, cwd: session.cwd)
        case "qoder":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.qoder/projects",
                projectEncoder: { $0.claudeProjectDirEncoded() },
                reader: readRecentFromTranscript(path:)
            )
        case "droid":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.factory/sessions",
                projectEncoder: { $0.claudeProjectDirEncoded() },
                reader: readRecentFromFactoryTranscript(path:)
            )
        case "codebuddy":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.codebuddy/projects",
                projectEncoder: { $0.appProjectDirEncoded() },
                reader: readRecentFromCodeBuddyTranscript(path:)
            )
        case "codex":
            return readModelFromCodexStore(cwd: session.cwd, processStart: processStart)
        case "gemini":
            return readModelFromGeminiStore(cwd: session.cwd, processStart: processStart)
        case "cursor":
            return readModelFromCursorStore(cwd: session.cwd, processStart: processStart)
        case "copilot":
            return readModelFromCopilotStore(cwd: session.cwd, processStart: processStart)
        case "opencode":
            return readModelFromOpenCodeStore(cwd: session.cwd, processStart: processStart)
        default:
            return nil
        }
    }

    private nonisolated static func readModelFromProjectTranscript(
        sessionId: String,
        cwd: String?,
        basePath: String,
        projectEncoder: (String) -> String,
        reader: (String) -> (String?, [ChatMessage])
    ) -> String? {
        guard let cwd else { return nil }
        let path = "\(basePath)/\(projectEncoder(cwd))/\(sessionId).jsonl"
        return reader(path).0
    }

    private nonisolated static func readModelFromCodexStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let base = ConfigInstaller.codexHome() + "/sessions"
        let fm = FileManager.default
        guard let path = findRecentCodexSession(base: base, cwd: cwd, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCodexTranscript(path: path).0
    }

    private nonisolated static func codexLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        let effectiveSessionId: String
        if let providerSessionId = session.providerSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerSessionId.isEmpty {
            effectiveSessionId = providerSessionId
        } else {
            effectiveSessionId = sessionId
        }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        guard let transcriptPath = codexTranscriptPath(
            sessionId: effectiveSessionId,
            cwd: session.cwd,
            processStart: processStart
        ),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }

        return codexLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func qoderLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = qoderTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return qoderLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func codeBuddyLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = codeBuddyTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return codeBuddyLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func nativeAppFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        switch session.source {
        case "codex":
            return codexLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "qoder":
            return qoderLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "codebuddy":
            return codeBuddyLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        default:
            return nil
        }
    }

    private nonisolated static func codexTranscriptPath(
        sessionId: String,
        cwd: String?,
        processStart: Date?
    ) -> String? {
        let codexHome = ConfigInstaller.codexHome()
        let statePath = codexHome + "/state_5.sqlite"

        if let path: String = withSQLiteDatabase(at: statePath, body: { db in
            guard let statement = prepareSQLiteStatement(
                db: db,
                sql: """
                    SELECT rollout_path
                    FROM threads
                    WHERE id = ?
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            bindSQLiteText(sessionId, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqliteColumnString(statement, index: 0)
        }),
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard let cwd else { return nil }
        let base = codexHome + "/sessions"
        return findRecentCodexSession(base: base, cwd: cwd, after: processStart, fm: .default)
    }

    private nonisolated static func qoderTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let projectPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/projects/\(cwd.claudeProjectDirEncoded())")
        let candidates = [
            projectPath.appendingPathComponent("\(sessionId).jsonl").path,
            projectPath.appendingPathComponent("transcript/\(sessionId).jsonl").path
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private nonisolated static func codeBuddyTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/projects/\(cwd.appProjectDirEncoded())/\(sessionId).jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private nonisolated static func readModelFromGeminiStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard let projectDir = findGeminiProjectDirectory(
            for: cwd,
            tmpBase: tmpBase,
            projects: readGeminiProjectsMap(path: "\(home)/.gemini/projects.json"),
            fm: fm
        ) else {
            return nil
        }
        let chatsBase = "\(tmpBase)/\(projectDir)/chats"
        guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromGeminiTranscript(path: best.path).1
    }

    private nonisolated static func readModelFromCursorStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let transcriptBase = "\(home)/.cursor/projects/\(cwd.appProjectDirEncoded())/agent-transcripts"
        guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCursorTranscript(path: best.path).0
    }

    private nonisolated static func readModelFromCopilotStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCopilotTranscript(path: best.path).0
    }

    private nonisolated static func readModelFromOpenCodeStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        return withSQLiteDatabase(at: dbPath) { db in
            guard let session = findRecentOpenCodeSession(in: db, cwd: cwd, after: processStart) else {
                return nil
            }
            return readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId).0
        }
    }

    // MARK: - Session Persistence

    // See AppState+Persistence.swift.

    // MARK: - Session Discovery (FSEventStream + process scan)

    // See AppState+SessionDiscovery.swift.

    func stopSessionDiscovery() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        discoveryScanTask?.cancel()
        discoveryScanTask = nil
        pendingDiscoveryRescan = false
        for key in Array(processMonitors.keys) { stopMonitor(key) }
        let center = NSWorkspace.shared.notificationCenter
        for observer in runningApplicationObservers {
            center.removeObserver(observer)
        }
        runningApplicationObservers.removeAll()
        runningApplicationBundleIds = nil
    }

    deinit {
        // The last reference can be dropped from a background task (tests do
        // this), so deinit may run off the main thread. `DispatchQueue.main.sync`
        // keeps self's storage valid for the duration of the teardown; the
        // closure is non-escaping, so capturing self in deinit is safe.
        let teardown = {
            MainActor.assumeIsolated {
                self.rotationTimer?.invalidate()
                self.cleanupTimer?.invalidate()
                self.saveTimer?.invalidate()
                if let stream = self.fsEventStream {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                }
                self.discoveryScanTask?.cancel()
                for (_, m) in self.processMonitors { m.source.cancel() }
                let center = NSWorkspace.shared.notificationCenter
                for observer in self.runningApplicationObservers {
                    center.removeObserver(observer)
                }
            }
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    /// Find running `claude` processes, match to transcript files, extract recent messages
    nonisolated static func findActiveClaudeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        // Step 1: find running claude processes using native APIs
        let claudePids = findClaudePids(candidatePids: candidatePids)
        guard !claudePids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        // Each claude process → its CWD → the single most recent .jsonl
        for pid in claudePids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty else { continue }

            // Skip subagent worktrees — they are child tasks, not independent sessions
            if cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
                continue
            }

            // Get process start time to filter stale transcript files
            let processStart = getProcessStartTime(pid)

            let projectDir = cwd.claudeProjectDirEncoded()
            let projectPath = "\(home)/.claude/projects/\(projectDir)"
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            // Find the most recently modified .jsonl that was written AFTER this process started
            var bestFile: String?
            var bestDate = Date.distantPast
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = "\(projectPath)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified > bestDate {
                    // Skip files from old sessions: must be modified after process started
                    if let start = processStart, modified < start.addingTimeInterval(-10) {
                        continue
                    }
                    bestDate = modified
                    bestFile = file
                }
            }

            guard let file = bestFile else { continue }

            // Skip stale transcripts: only show sessions active within last 5 minutes.
            // When processStart is unknown (proc_pidinfo failed), use a tighter 30s window
            // to avoid resurrecting zombie sessions from stale transcript files.
            let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

            let sessionId = String(file.dropLast(6))
            guard !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let fullPath = "\(projectPath)/\(file)"
            let (model, messages) = readRecentFromTranscript(path: fullPath)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: bestDate,
                recentMessages: messages,
                transcriptPath: fullPath
            ))
        }
        return results
    }

    nonisolated static func allProcessIds() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private nonisolated static func findPids(
        matchingPathSubstrings pathSubstrings: [String],
        argSubstrings: [String] = [],
        candidatePids: [pid_t]? = nil
    ) -> [pid_t] {
        let loweredPaths = pathSubstrings.map { $0.lowercased() }
        let loweredArgs = argSubstrings.map { $0.lowercased() }
        guard !loweredPaths.isEmpty || !loweredArgs.isEmpty else { return [] }

        var matched: [pid_t] = []
        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid)?.lowercased() else { continue }
            if loweredPaths.contains(where: { path.contains($0) }) {
                matched.append(pid)
                continue
            }
            guard !loweredArgs.isEmpty,
                  let args = getProcessArgs(pid)?.map({ $0.lowercased() }) else { continue }
            if args.contains(where: { arg in loweredArgs.contains(where: { arg.contains($0) }) }) {
                matched.append(pid)
            }
        }
        return matched
    }

    /// Get PIDs of running Claude Code processes
    /// Claude's binary is named by version (e.g. "2.1.91") under ~/.local/share/claude/versions/
    private nonisolated static func findClaudePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        let claudeVersionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path

        var claudePids: [pid_t] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            // Match processes whose executable is under claude's versions directory
            if path.hasPrefix(claudeVersionsDir) {
                claudePids.append(pid)
            }
        }
        return claudePids
    }

    private nonisolated static func findGeminiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/gemini-cli/bundle/gemini.js",
                "/opt/homebrew/bin/gemini",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCursorPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/cursor.app/contents/macos/cursor",
                "/cursor.app/contents/frameworks/cursor helper",
                "/.local/share/cursor-agent/versions/",
            ],
            argSubstrings: ["/cursor-agent/index.js"],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func sourceForCursorPid(_ pid: pid_t) -> String {
        if let path = executablePath(for: pid),
           CLIProcessResolver.sourceMatchesExecutablePath(path, source: "cursor-cli") {
            return "cursor-cli"
        }
        if let args = getProcessArgs(pid),
           args.contains(where: { CLIProcessResolver.sourceMatchesExecutablePath($0, source: "cursor-cli") }) {
            return "cursor-cli"
        }
        return "cursor"
    }

    private nonisolated static func findQoderPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/qoder.app/contents/macos/electron",
                "/qoder.app/contents/frameworks/qoder helper",
                "/.qoder/bin/qodercli/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func sourceForQoderPid(_ pid: pid_t) -> String {
        if let path = executablePath(for: pid),
           CLIProcessResolver.sourceMatchesExecutablePath(path, source: "qoder-cli") {
            return "qoder-cli"
        }
        if let args = getProcessArgs(pid),
           args.contains(where: { CLIProcessResolver.sourceMatchesExecutablePath($0, source: "qoder-cli") }) {
            return "qoder-cli"
        }
        return "qoder"
    }

    private nonisolated static func findFactoryPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/factory.app/contents/macos/electron",
                "/factory.app/contents/frameworks/factory helper",
                "/.local/bin/droid",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCodeBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddy.app/contents/macos/electron",
                "/codebuddy.app/contents/frameworks/codebuddy helper",
            ],
            argSubstrings: [
                "/@tencent-ai/codebuddy-code/bin/codebuddy",
                "/opt/homebrew/bin/codebuddy",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCodyBuddyCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddycn.app/contents/macos/electron",
                "/codebuddycn.app/contents/frameworks/codebuddycn helper",
                "/.codybuddycn/",
                "/.codebuddycn/",
            ],
            argSubstrings: [
                "/.codybuddycn/",
                "/.codebuddycn/",
                "/opt/homebrew/bin/codybuddycn",
                "/opt/homebrew/bin/codebuddycn",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findStepFunPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/stepfun.app/contents/macos/stepfun",
                "/.stepfun/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/stepfun",
                "/.stepfun/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/trae.app/contents/macos/trae",
                "/trae.app/contents/frameworks/trae helper",
                "/.trae/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/trae",
                "/.trae/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraeCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/traecn.app/contents/macos/trae",
                "/trae-cn.app/contents/macos/trae",
                "/.traecn/",
                "/.trae-cn/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/traecn",
                "/opt/homebrew/bin/trae-cn",
                "/.traecn/",
                "/.trae-cn/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraeCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findAntiGravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
                "/antigravity.app/contents/macos/antigravity",
            ],
            argSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findWorkBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/workbuddy.app/contents/macos/workbuddy",
                "/.workbuddy/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/workbuddy",
                "/.workbuddy/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findHermesPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/hermes",
                "/hermes.app/contents/macos/hermes",
                "/.hermes/hermes-agent/",
            ],
            argSubstrings: [
                "/.local/bin/hermes",
                "/.hermes/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findQwenPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/qwen",
                "/.bun/bin/qwen",
            ],
            argSubstrings: [
                "/@qwen-code/qwen-code/",
                "/.qwen/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findKimiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/kimi",
                "/.local/share/uv/tools/kimi-cli/",
            ],
            argSubstrings: [
                "/kimi-cli/",
                "kimi_cli",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findKiroPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/kiro.app/contents/macos/kiro",
                "/.kiro/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/kiro",
                "/usr/local/bin/kiro",
                "/.local/bin/kiro",
                "kiro --agent",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findPiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/pi-coding-agent/",
                "/bin/pi",
            ],
            argSubstrings: [
                "pi-coding-agent",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func md5Hash(of string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func findActiveKimiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let kimiPids = findKimiPids(candidatePids: candidatePids)
        guard !kimiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.kimi/sessions"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in kimiPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let workdirHash = md5Hash(of: cwd)
            let workdirPath = "\(sessionsBase)/\(workdirHash)"
            guard fm.fileExists(atPath: workdirPath),
                  let sessionDirs = try? fm.contentsOfDirectory(atPath: workdirPath) else { continue }

            var bestPath: String?
            var bestDate = Date.distantPast
            var bestSessionId: String?

            for sessionId in sessionDirs {
                let wirePath = "\(workdirPath)/\(sessionId)/wire.jsonl"
                guard fm.fileExists(atPath: wirePath),
                      let attrs = try? fm.attributesOfItem(atPath: wirePath),
                      let modified = attrs[.modificationDate] as? Date,
                      modified > bestDate else { continue }
                if let start = processStart, modified < start.addingTimeInterval(-10) {
                    continue
                }
                bestPath = wirePath
                bestDate = modified
                bestSessionId = sessionId
            }

            guard let path = bestPath, let sessionId = bestSessionId else { continue }
            let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

            let (_, messages) = readRecentFromKimiTranscript(path: path)
            guard !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: nil,
                pid: pid,
                modifiedAt: bestDate,
                recentMessages: messages,
                source: "kimi"
            ))
        }

        return results
    }

    private nonisolated static func readRecentFromKimiTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path, maxBytes: 262_144) else { return (nil, []) }

        var messages: [ChatMessage] = []
        var previousUserText: String?
        var previousAssistantText: String = ""

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let type = message["type"] as? String
            else { continue }

            switch type {
            case "TurnBegin":
                if let userText = previousUserText, !userText.isEmpty {
                    messages.append(ChatMessage(isUser: true, text: userText))
                    if !previousAssistantText.isEmpty {
                        messages.append(ChatMessage(isUser: false, text: previousAssistantText))
                    }
                }
                previousUserText = nil
                previousAssistantText = ""
                if let payload = message["payload"] as? [String: Any],
                   let userInput = payload["user_input"] as? [[String: Any]] {
                    let texts = userInput.compactMap { part -> String? in
                        guard part["type"] as? String == "text" else { return nil }
                        return part["text"] as? String
                    }
                    previousUserText = texts.joined()
                }
            case "ContentPart":
                if let payload = message["payload"] as? [String: Any],
                   payload["type"] as? String == "text",
                   let textContent = payload["text"] as? String {
                    previousAssistantText += textContent
                }
            case "TurnEnd":
                if let userText = previousUserText, !userText.isEmpty {
                    messages.append(ChatMessage(isUser: true, text: userText))
                    if !previousAssistantText.isEmpty {
                        messages.append(ChatMessage(isUser: false, text: previousAssistantText))
                    }
                }
                previousUserText = nil
                previousAssistantText = ""
            default:
                break
            }
        }

        // flush final turn
        if let userText = previousUserText, !userText.isEmpty {
            messages.append(ChatMessage(isUser: true, text: userText))
            if !previousAssistantText.isEmpty {
                messages.append(ChatMessage(isUser: false, text: previousAssistantText))
            }
        }

        return (nil, Array(messages.suffix(3)))
    }

    private nonisolated static func findCopilotPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/@github/copilot/npm-loader.js",
                "/opt/homebrew/bin/copilot",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findOpenCodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opencode.app/contents/macos/opencode",
                "/opencode.app/contents/macos/opencode-cli",
                "/.opencode/bin/opencode",
            ],
            candidatePids: candidatePids
        )
    }

    /// Get the current working directory of a process using proc_pidinfo
    private nonisolated static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Get the start time of a process using proc_pidinfo
    private nonisolated static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private nonisolated static func isSubagentWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-")
    }

    private nonisolated static func findMostRecentJSONLFile(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    private nonisolated static func findFlatStoreSessions(
        pids: [pid_t],
        basePath: String,
        source: String,
        sourceResolver: ((pid_t) -> String)? = nil,
        projectEncoder: (String) -> String,
        transcriptReader: (String) -> (String?, [ChatMessage])
    ) -> [DiscoveredSession] {
        guard !pids.isEmpty else { return [] }

        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in pids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let projectPath = "\(basePath)/\(projectEncoder(cwd))"
            guard let best = findMostRecentJSONLFile(in: projectPath, after: processStart, fm: fm) else { continue }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = transcriptReader(best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: sourceResolver?(pid) ?? source
            ))
        }

        return results
    }

    nonisolated static func findActiveGeminiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let geminiPids = findGeminiPids(candidatePids: candidatePids)
        guard !geminiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard fm.fileExists(atPath: tmpBase) else { return [] }

        let projects = readGeminiProjectsMap(path: "\(home)/.gemini/projects.json")
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in geminiPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            guard let projectDir = findGeminiProjectDirectory(for: cwd, tmpBase: tmpBase, projects: projects, fm: fm) else {
                continue
            }

            let processStart = getProcessStartTime(pid)
            let chatsBase = "\(tmpBase)/\(projectDir)/chats"
            guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else { continue }
            let geminiFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < geminiFreshnessLimit { continue }

            let (sessionId, model, messages) = readRecentFromGeminiTranscript(path: best.path)
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "gemini"
            ))
        }

        return results
    }

    private nonisolated static func readGeminiProjectsMap(path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return [:]
        }
        return projects
    }

    private nonisolated static func findGeminiProjectDirectory(
        for cwd: String,
        tmpBase: String,
        projects: [String: String],
        fm: FileManager
    ) -> String? {
        if let mapped = projects[cwd], fm.fileExists(atPath: "\(tmpBase)/\(mapped)") {
            return mapped
        }

        guard let dirs = try? fm.contentsOfDirectory(atPath: tmpBase) else { return nil }
        for dir in dirs {
            let projectRootPath = "\(tmpBase)/\(dir)/.project_root"
            guard let data = fm.contents(atPath: projectRootPath),
                  let root = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  root == cwd else { continue }
            return dir
        }
        return nil
    }

    private nonisolated static func findMostRecentGeminiSession(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasPrefix("session-") && file.hasSuffix(".json") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    private nonisolated static func readRecentFromGeminiTranscript(path: String) -> (String, String?, [ChatMessage]) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (((path as NSString).lastPathComponent as NSString).deletingPathExtension, nil, [])
        }

        let sessionId = (json["sessionId"] as? String)
            ?? (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let model = json["model"] as? String
        let messages = (json["messages"] as? [[String: Any]]) ?? []

        var combined: [(Int, ChatMessage)] = []
        for (index, message) in messages.enumerated() {
            let type = (message["type"] as? String)?.lowercased() ?? ""
            let text = extractTextContent(from: message["content"])
                ?? (message["content"] as? String)
            guard let text, !text.isEmpty else { continue }

            if type == "user" {
                combined.append((index, ChatMessage(isUser: true, text: text)))
            } else {
                combined.append((index, ChatMessage(isUser: false, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (sessionId, model, Array(combined.suffix(3).map { $0.1 }))
    }

    nonisolated static func findActiveQoderSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findQoderPids(candidatePids: candidatePids),
            basePath: "\(home)/.qoder/projects",
            source: "qoder",
            sourceResolver: sourceForQoderPid,
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { readRecentFromTranscript(path: $0) }
        )
    }

    nonisolated static func findActiveCodeBuddySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findCodeBuddyPids(candidatePids: candidatePids),
            basePath: "\(home)/.codebuddy/projects",
            source: "codebuddy",
            projectEncoder: { $0.appProjectDirEncoded() },
            transcriptReader: { readRecentFromCodeBuddyTranscript(path: $0) }
        )
    }

    nonisolated static func findActiveFactorySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findFactoryPids(candidatePids: candidatePids),
            basePath: "\(home)/.factory/sessions",
            source: "droid",
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { readRecentFromFactoryTranscript(path: $0) }
        )
    }

    nonisolated static func findActiveCursorSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let cursorPids = findCursorPids(candidatePids: candidatePids)
        guard !cursorPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let projectsBase = "\(home)/.cursor/projects"
        guard fm.fileExists(atPath: projectsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in cursorPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let transcriptBase = "\(projectsBase)/\(cwd.appProjectDirEncoded())/agent-transcripts"
            guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else { continue }
            let cursorFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < cursorFreshnessLimit { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCursorTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: sourceForCursorPid(pid)
            ))
        }

        return results
    }

    private nonisolated static func findMostRecentCursorTranscript(
        in transcriptsBase: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: transcriptsBase) else { return nil }

        var best: (path: String, modified: Date)?
        for sessionDir in sessionDirs {
            let dirPath = "\(transcriptsBase)/\(sessionDir)"
            guard let candidate = findMostRecentJSONLFile(in: dirPath, after: processStart, fm: fm) else { continue }
            if best.map({ candidate.modified > $0.modified }) ?? true {
                best = candidate
            }
        }
        return best
    }

    nonisolated static func findActiveCopilotSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let copilotPids = findCopilotPids(candidatePids: candidatePids)
        guard !copilotPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in copilotPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
                continue
            }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionDir = (best.path as NSString).deletingLastPathComponent
            let sessionId = (sessionDir as NSString).lastPathComponent
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCopilotTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "copilot"
            ))
        }

        return results
    }

    private nonisolated static func findRecentCopilotSession(
        base: String,
        cwd: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }

        let candidates = dirs.compactMap { dir -> (path: String, modified: Date)? in
            let fullPath = "\(base)/\(dir)/events.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (fullPath, modified)
        }.sorted { $0.modified > $1.modified }

        for candidate in candidates.prefix(50) {
            if let start = processStart, candidate.modified < start.addingTimeInterval(-10) {
                continue
            }
            if copilotSessionMatchesCwd(path: candidate.path, cwd: cwd) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func copilotSessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 32768)
        let text = UTF8FileChunkReader.decode(data)

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any] else { continue }

            if type == "session.start",
               let context = payload["context"] as? [String: Any],
               let sessionCwd = context["cwd"] as? String, sessionCwd == cwd {
                return true
            }

            if type == "hook.start",
               let input = payload["input"] as? [String: Any],
               let sessionCwd = input["cwd"] as? String, sessionCwd == cwd {
                return true
            }
        }
        return false
    }

    nonisolated static func findActiveOpenCodeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let openCodePids = findOpenCodePids(candidatePids: candidatePids)
        guard !openCodePids.isEmpty else { return [] }

        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        return withSQLiteDatabase(at: dbPath) { db in
            var results: [DiscoveredSession] = []
            var seenSessionIds: Set<String> = []

            for pid in openCodePids {
                guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
                let processStart = getProcessStartTime(pid)
                guard let session = findRecentOpenCodeSession(in: db, cwd: cwd, after: processStart) else { continue }
                guard !seenSessionIds.contains(session.sessionId) else { continue }
                seenSessionIds.insert(session.sessionId)

                let (model, messages) = readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId)
                results.append(DiscoveredSession(
                    sessionId: session.sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: model,
                    pid: pid,
                    modifiedAt: session.modifiedAt,
                    recentMessages: messages,
                    source: "opencode"
                ))
            }

            return results
        } ?? []
    }

    private nonisolated static func withSQLiteDatabase<T>(
        at path: String,
        body: (OpaquePointer) -> T?
    ) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    private nonisolated static func prepareSQLiteStatement(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private nonisolated static func bindSQLiteText(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    private nonisolated static func sqliteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    private nonisolated static func findRecentOpenCodeSession(
        in db: OpaquePointer,
        cwd: String,
        after processStart: Date?
    ) -> (sessionId: String, modifiedAt: Date)? {
        let sql = """
            SELECT id, time_updated
            FROM session
            WHERE time_archived IS NULL
              AND (
                directory = ?
                OR EXISTS (
                    SELECT 1
                    FROM message m
                    WHERE m.session_id = session.id
                      AND json_extract(m.data, '$.path.cwd') = ?
                )
              )
            ORDER BY time_updated DESC
            LIMIT 20;
            """
        guard let statement = prepareSQLiteStatement(db: db, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindSQLiteText(cwd, to: statement, index: 1)
        bindSQLiteText(cwd, to: statement, index: 2)

        let minUpdatedAtMs = processStart.map { Int64($0.timeIntervalSince1970 * 1000) - 10_000 }
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            if let sessionId = sqliteColumnString(statement, index: 0) {
                let updatedAtMs = sqlite3_column_int64(statement, 1)
                if minUpdatedAtMs.map({ updatedAtMs >= $0 }) ?? true {
                    let modifiedAt = Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000)
                    return (sessionId, modifiedAt)
                }
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else { return nil }
        return nil
    }

    private nonisolated static func readRecentFromOpenCodeSession(
        db: OpaquePointer,
        sessionId: String
    ) -> (String?, [ChatMessage]) {
        var model: String?

        if let messageStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT data
                FROM message
                WHERE session_id = ?
                ORDER BY time_updated DESC
                LIMIT 12;
                """
        ) {
            defer { sqlite3_finalize(messageStatement) }
            bindSQLiteText(sessionId, to: messageStatement, index: 1)
            while sqlite3_step(messageStatement) == SQLITE_ROW {
                guard model == nil,
                      let data = sqliteColumnString(messageStatement, index: 0),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                model = json["modelID"] as? String
                if model == nil,
                   let modelInfo = json["model"] as? [String: Any] {
                    model = modelInfo["modelID"] as? String
                }
            }
        }

        var seenMessageIds: Set<String> = []
        var combined: [(Int64, ChatMessage)] = []
        if let partStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT p.message_id, json_extract(m.data, '$.role'), p.time_created, p.data
                FROM part p
                JOIN message m ON m.id = p.message_id
                WHERE p.session_id = ?
                ORDER BY p.time_created DESC
                LIMIT 80;
                """
        ) {
            defer { sqlite3_finalize(partStatement) }
            bindSQLiteText(sessionId, to: partStatement, index: 1)
            while sqlite3_step(partStatement) == SQLITE_ROW {
                guard let messageId = sqliteColumnString(partStatement, index: 0),
                      !seenMessageIds.contains(messageId),
                      let role = sqliteColumnString(partStatement, index: 1),
                      let data = sqliteColumnString(partStatement, index: 3),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      json["type"] as? String == "text",
                      let text = json["text"] as? String, !text.isEmpty else { continue }

                let isUser = role == "user"
                guard isUser || role == "assistant" else { continue }

                seenMessageIds.insert(messageId)
                combined.append((sqlite3_column_int64(partStatement, 2), ChatMessage(isUser: isUser, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    // MARK: - Codex Session Discovery

    /// Find running Codex processes.
    /// Checks both executable path (Desktop app) and command-line args (npm/Homebrew: node script).
    private nonisolated static func findCodexPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        var codexPids: [pid_t] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            let pathLower = path.lowercased()

            // Match 1: Codex Desktop app (native binary)
            if pathLower.contains("codex.app/contents/") && pathLower.hasSuffix("/codex") {
                codexPids.append(pid)
                continue
            }

            // Match 2: npm/Homebrew install — node running @openai/codex script.
            // proc_pidpath returns the node binary, so check command-line args instead.
            if pathLower.hasSuffix("/node") {
                if let args = getProcessArgs(pid),
                   args.contains(where: { $0.contains("@openai/codex") || $0.contains("openai-codex") }) {
                    codexPids.append(pid)
                }
            }
        }
        return codexPids
    }

    /// Get command-line arguments for a process via sysctl KERN_PROCARGS2.
    private nonisolated static func getProcessArgs(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // First 4 bytes = argc (as int32)
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 256 else { return nil }

        // Skip past argc + executable path + padding nulls to reach argv
        var offset = MemoryLayout<Int32>.size
        // Skip executable path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Parse null-terminated argv strings
        var args: [String] = []
        var argStart = offset
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > argStart {
                args.append(String(bytes: buffer[argStart..<offset], encoding: .utf8) ?? "")
            }
            offset += 1
            argStart = offset
        }
        return args
    }

    /// Find active Codex sessions by matching running processes to session files
    nonisolated static func findActiveCodexSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let codexPids = findCodexPids(candidatePids: candidatePids)
        guard !codexPids.isEmpty else { return [] }

        let fm = FileManager.default
        let sessionsBase = ConfigInstaller.codexHome() + "/sessions"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in codexPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else {
                // getCwd failed
                continue
            }
            // pid found
            let processStart = getProcessStartTime(pid)

            // Codex stores sessions in date-based dirs: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
            // Scan recent directories for matching session files
            guard let bestFile = findRecentCodexSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
                // no session file found
                continue
            }

            // Extract session ID from filename: rollout-{date}-{uuid}.jsonl
            let fileName = (bestFile as NSString).lastPathComponent
            let sessionId = extractCodexSessionId(from: fileName)
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let modifiedAt = (try? fm.attributesOfItem(atPath: bestFile))?[.modificationDate] as? Date ?? Date()

            // Skip stale transcripts: tighter window when processStart is unknown
            let codexFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if modifiedAt.timeIntervalSinceNow < codexFreshnessLimit { continue }

            let (model, messages) = readRecentFromCodexTranscript(path: bestFile)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: modifiedAt,
                recentMessages: messages,
                source: "codex"
            ))
        }
        return results
    }

    /// Find the most recent Codex session file matching a CWD
    /// Scans back up to 7 days to cover long-running sessions that span day boundaries
    private nonisolated static func findRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        let cal = Calendar.current
        let now = Date()
        var dirs: [String] = []
        for daysBack in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", cal.component(.year, from: date))
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dir = "\(base)/\(y)/\(m)/\(d)"
            if fm.fileExists(atPath: dir) {
                dirs.append(dir)
            }
        }
        guard !dirs.isEmpty else { return nil }
        return scanCodexDir(dirs: dirs, cwd: cwd, after: after, fm: fm)
    }

#if DEBUG
    nonisolated static func testFindRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        findRecentCodexSession(base: base, cwd: cwd, after: after, fm: fm)
    }
#endif

    private nonisolated static func scanCodexDir(dirs: [String], cwd: String, after: Date?, fm: FileManager) -> String? {
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let threshold = after?.addingTimeInterval(-10)
            let candidates = files.compactMap { file -> (path: String, modified: Date)? in
                guard file.hasSuffix(".jsonl") else { return nil }
                let fullPath = "\(dir)/\(file)"
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let modified = attrs?[.modificationDate] as? Date ?? .distantPast
                if let threshold, modified < threshold {
                    return nil
                }
                return (fullPath, modified)
            }
            .sorted { $0.modified > $1.modified }

            for candidate in candidates.prefix(20) {
                if codexSessionMatchesCwd(path: candidate.path, cwd: cwd) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    /// Check if a Codex session file's CWD matches the target
    private nonisolated static func codexSessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 4096) // First line is enough
        let text = UTF8FileChunkReader.decode(data)
        guard let firstLine = text.components(separatedBy: "\n").first,
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return false }
        return sessionCwd == cwd
    }

    /// Extract session ID from Codex filename: rollout-2026-04-04T20-54-48-{uuid}.jsonl
    private nonisolated static func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        // The UUID is the last 36 chars (8-4-4-4-12)
        // Pattern: after the datetime portion, everything from the 4th dash group onwards is the UUID
        let parts = name.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}
        // That's: [rollout, YYYY, MM, DDThh, mm, ss, uuid1, uuid2, uuid3, uuid4, uuid5]
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    private nonisolated static func extractTextContent(from rawContent: Any?) -> String? {
        if let text = rawContent as? String, !text.isEmpty {
            return text
        }
        if let items = rawContent as? [[String: Any]] {
            for item in items {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                if let output = item["output"] as? [String: Any],
                   let text = output["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private nonisolated static func readRecentFromCursorTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let role = json["role"] as? String,
                  let message = json["message"] as? [String: Any],
                  let textContent = extractTextContent(from: message["content"])
            else { continue }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (nil, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readRecentFromCodeBuddyTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "message",
                  let role = json["role"] as? String,
                  let textContent = extractTextContent(from: json["content"])
            else { continue }

            if model == nil,
               let providerData = json["providerData"] as? [String: Any],
               let messageModel = providerData["model"] as? String, !messageModel.isEmpty {
                model = messageModel
            }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readRecentFromFactoryTranscript(path: String) -> (String?, [ChatMessage]) {
        let sidecarPath = path.replacingOccurrences(of: ".jsonl", with: ".settings.json")
        var model: String?
        if let data = FileManager.default.contents(atPath: sidecarPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let foundModel = json["model"] as? String, !foundModel.isEmpty {
            model = foundModel
        }
        let (_, messages) = readRecentFromTranscript(path: path)
        return (model, messages)
    }

    private nonisolated static func readRecentFromCopilotTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any]
            else { continue }

            if model == nil {
                if let currentModel = payload["currentModel"] as? String, !currentModel.isEmpty {
                    model = currentModel
                } else if let eventModel = payload["model"] as? String, !eventModel.isEmpty {
                    model = eventModel
                } else if let metrics = payload["modelMetrics"] as? [String: Any],
                          let metricModel = metrics.keys.sorted().last, !metricModel.isEmpty {
                    model = metricModel
                }
            }

            if type == "user.message",
               let textContent = payload["content"] as? String, !textContent.isEmpty {
                userMessages.append((index, textContent))
            } else if type == "assistant.message",
                      let textContent = payload["content"] as? String, !textContent.isEmpty {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readTranscriptTail(path: String, maxBytes: UInt64 = 65536) -> String? {
        UTF8FileChunkReader.tailText(path: path, maxBytes: maxBytes)
    }

    private nonisolated static func parseISO8601Timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    nonisolated static func codexLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        let terminalEventTypes: Set<String> = ["task_complete", "turn_aborted", "turn_failed"]
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String,
                  terminalEventTypes.contains(eventType),
                  let timestamp = json["timestamp"] as? String,
                  let date = parseISO8601Timestamp(timestamp) else { continue }

            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    nonisolated static func qoderLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = json["timestamp"] as? String,
                  let date = parseISO8601Timestamp(timestamp) else { continue }

            let type = json["type"] as? String ?? ""
            if type == "progress",
               let data = json["data"] as? [String: Any] {
                let hookEvent = (data["hookEvent"] as? String) ?? (data["hookName"] as? String) ?? ""
                if hookEvent == "Stop" || hookEvent == "SessionEnd" {
                    if latest == nil || date > latest! {
                        latest = date
                    }
                    continue
                }
            }

            if type == "assistant",
               let message = json["message"] as? [String: Any],
               (message["role"] as? String) == "assistant",
               extractTextContent(from: message["content"]) != nil {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }

        return latest
    }

    nonisolated static func codeBuddyLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "message",
                  (json["role"] as? String) == "assistant",
                  (json["status"] as? String) == "completed",
                  extractTextContent(from: json["content"]) != nil else { continue }

            let date: Date?
            if let rawTimestamp = json["timestamp"] as? NSNumber {
                date = Date(timeIntervalSince1970: rawTimestamp.doubleValue / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Double {
                date = Date(timeIntervalSince1970: rawTimestamp / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Int64 {
                date = Date(timeIntervalSince1970: TimeInterval(rawTimestamp) / 1000)
            } else {
                date = nil
            }

            guard let date else { continue }
            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    /// Read model and recent messages from a Codex transcript file
    private nonisolated static func readRecentFromCodexTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            // Extract model from session_meta
            if type == "session_meta", model == nil,
               let payload = json["payload"] as? [String: Any] {
                model = payload["model"] as? String
                    ?? payload["model_provider"] as? String
            }

            // Prefer event_msg (cleaner user/agent messages from Codex)
            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let msgType = payload["type"] as? String,
               let msg = payload["message"] as? String, !msg.isEmpty {
                if msgType == "user_message" {
                    userMessages.append((index, msg))
                } else if msgType == "agent_message" {
                    assistantMessages.append((index, msg))
                }
            }

            // Fallback: extract from response_item only if event_msg didn't provide the same content
            // (user messages come from event_msg which is cleaner — response_item user entries
            //  often contain injected system/tool context, not actual user input)
            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let role = payload["role"] as? String {

                if let content = payload["content"] as? [[String: Any]] {
                    for item in content {
                        let itemType = item["type"] as? String ?? ""
                        if let t = item["text"] as? String, !t.isEmpty {
                            if role == "user" && itemType == "input_text" && userMessages.isEmpty {
                                // Only use response_item for user messages if no event_msg was found
                                userMessages.append((index, t))
                            } else if role == "assistant" && itemType == "output_text" && assistantMessages.last?.1 != t {
                                // Only add if not a duplicate of the last event_msg entry
                                assistantMessages.append((index, t))
                            }
                            break
                        }
                    }
                }
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }

    /// Read model and last 3 user/assistant messages from a transcript file's tail
    private nonisolated static func readRecentFromTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { continue }

            if model == nil, let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            // Extract text content
            var textContent: String?
            if let content = message["content"] as? String, !content.isEmpty {
                textContent = content
            } else if let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "text",
                       let t = item["text"] as? String, !t.isEmpty {
                        textContent = t
                        break
                    }
                }
            }

            if let text = textContent {
                if role == "user" {
                    userMessages.append((index, text))
                } else if role == "assistant" {
                    assistantMessages.append((index, text))
                }
            }
            index += 1
        }

        // Build recent messages: take last few user+assistant, sorted by order, keep 3
        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }
}

/// Encode a path the same way Claude Code does for project directory names:
/// every non-alphanumeric character (/, space, ., _, ', non-ASCII, …) → "-"
extension String {
    func claudeProjectDirEncoded() -> String {
        var result = ""
        for c in self.unicodeScalars {
            switch c {
            case "a"..."z", "A"..."Z", "0"..."9":
                result.append(Character(c))
            default:
                result.append("-")
            }
        }
        return result
    }

    func appProjectDirEncoded() -> String {
        let encoded = claudeProjectDirEncoded()
        if encoded.hasPrefix("-") {
            return String(encoded.dropFirst())
        }
        return encoded
    }
}
