import Foundation
import Network
import os.log
import BoughCore

private let log = Logger(subsystem: "com.dgpisces.bough", category: "HookServer")

private final class UmaskRestorer: @unchecked Sendable {
    private let lock = NSLock()
    private let previousUmask: mode_t
    private var didRestore = false

    init(previousUmask: mode_t) {
        self.previousUmask = previousUmask
    }

    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRestore else { return }
        didRestore = true
        umask(previousUmask)
    }
}

@MainActor
class HookServer {
    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?
    private var ownedSocketPath: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        let path = HookServer.socketPath
        // Clean up stale default sockets without deleting arbitrary BOUGH_SOCKET_PATH targets.
        guard Self.prepareSocketPathForListen(path) else {
            log.error("Refusing to remove existing socket path at \(path)")
            return
        }
        ownedSocketPath = path

        // Set umask to 0o077 BEFORE the listener creates the socket file,
        // ensuring it is never world-readable even briefly (closes TOCTOU window).
        let umaskRestorer = UmaskRestorer(previousUmask: umask(0o077))

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)

        do {
            listener = try NWListener(using: params)
        } catch {
            umaskRestorer.restore()
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [umaskRestorer] state in
            switch state {
            case .ready:
                // Restore previous umask now that the socket file exists with safe permissions
                umaskRestorer.restore()
                // Belt-and-suspenders: explicitly set 0o700 in case umask didn't take effect
                chmod(path, 0o700)
                log.info("HookServer listening on \(path)")
            case .failed(let error):
                umaskRestorer.restore()
                log.error("HookServer failed: \(error.localizedDescription)")
            case .cancelled:
                umaskRestorer.restore()
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop(removeSocketAfterDelay: Bool = true) {
        listener?.cancel()
        listener = nil
        let path = ownedSocketPath ?? HookServer.socketPath
        let allowCustomPathRemoval = ownedSocketPath == path
        ownedSocketPath = nil
        guard removeSocketAfterDelay else {
            _ = Self.removeSocketIfPresent(path, allowCustomPath: allowCustomPathRemoval)
            return
        }
        // Delay socket removal so in-flight hooks can finish sending their payload
        // before the file disappears — prevents intermittent errors on session end (#45).
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            _ = Self.removeSocketIfPresent(path, allowCustomPath: allowCustomPathRemoval)
        }
    }

    nonisolated static func testRemoveSocketIfPresent(_ path: String) -> Bool {
        removeSocketIfPresent(path)
    }

    nonisolated private static func prepareSocketPathForListen(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        guard SocketPath.canAutoRemoveExistingSocket(at: path) else {
            return false
        }
        return unlink(path) == 0 || errno == ENOENT
    }

    nonisolated private static func removeSocketIfPresent(_ path: String, allowCustomPath: Bool = false) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        guard allowCustomPath || SocketPath.canAutoRemoveExistingSocket(at: path) else {
            return false
        }
        return unlink(path) == 0 || errno == ENOENT
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 1_048_576  // 1MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor [self] in

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    /// Read from user settings; defaults to all known internal tools.
    private static var autoApproveTools: Set<String> {
        SettingsManager.shared.autoApproveTools
    }

    /// User-configured cwd substring blocklist for plugin/background hooks (e.g. claude-mem).
    /// Empty default = no filtering. Trimmed, blank entries skipped.
    private static func eventMatchesExcludedCwd(_ cwd: String) -> Bool {
        cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings)
    }

    /// Pure substring blocklist match — returns true if `cwd` contains any
    /// non-empty trimmed entry of `patternsCSV`. Extracted for testability;
    /// `nonisolated` because it touches no actor state.
    nonisolated static func cwdMatchesAnyPattern(_ cwd: String, patternsCSV: String) -> Bool {
        guard !patternsCSV.isEmpty else { return false }
        for entry in patternsCSV.split(separator: ",", omittingEmptySubsequences: false) {
            let pattern = entry.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty, cwd.contains(pattern) { return true }
        }
        return false
    }

    /// Fire-and-forget POST of the hook event to a user-configured webhook URL.
    /// Wraps the raw event in a small envelope (event/source/session/cwd/tool/raw)
    /// so users on the receiving side don't need to dig through bridge-internal
    /// fields. Optional event-name allow-list filters noisy event types. (#115)
    private static func forwardEventToWebhook(_ event: HookEvent) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.webhookEnabled) else { return }
        // Trim whitespace — users routinely paste URLs with leading/trailing space
        // and URL(string:) silently rejects those (RFC 3986 forbids whitespace).
        let urlString = (defaults.string(forKey: SettingsKey.webhookURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty,
              let endpoint = URL(string: urlString) else { return }

        let normalizedName = EventNormalizer.normalize(event.eventName)

        // Event filter: comma-separated allow-list. Empty = forward all.
        // Match on either the normalized name (PreToolUse) or raw name (pre_tool_use).
        if let filter = defaults.string(forKey: SettingsKey.webhookEventFilter),
           !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            let allowed = filter.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard allowed.contains(normalizedName) || allowed.contains(event.eventName) else { return }
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let envelope: [String: Any] = [
            "event": normalizedName,
            "raw_event": event.eventName,
            "session_id": event.sessionId ?? "",
            "source": event.rawJSON["_source"] as? String ?? "",
            "cwd": event.rawJSON["cwd"] as? String ?? "",
            "tool_name": event.toolName ?? "",
            "timestamp": isoFormatter.string(from: Date()),
            "raw": event.rawJSON,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bough-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Fire-and-forget. Failures are intentionally swallowed: a flaky
            // webhook should never break the hook event pipeline.
        }.resume()
    }

    private static func hiddenPluginResponse(for _: [String: Any]) -> Data {
        return Data("{}".utf8)
    }

    private static func pluginPpid(from raw: [String: Any]) -> Int? {
        if let p = raw["_ppid"] as? Int { return p }
        if let p = raw["_ppid"] as? Int32 { return Int(p) }
        if let p = raw["_ppid"] as? NSNumber { return p.intValue }
        return nil
    }

    static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        if normalizedEventName == "PermissionRequest" {
            return .permission
        }
        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    static func shouldDeferCodexPermissionToAutoReview(
        _ event: HookEvent,
        fm: FileManager = .default,
        allowTranscriptScan: Bool = false
    ) -> Bool {
        guard EventNormalizer.normalize(event.eventName) == "PermissionRequest",
              event.toolName != "AskUserQuestion",
              let rawSource = event.rawJSON["_source"] as? String,
              SessionSnapshot.normalizedSupportedSource(rawSource) == "codex"
        else { return false }

        if codexRuntimeApprovalPolicyIsNever(event.rawJSON) {
            return false
        }
        if codexAutoReviewEnabled(fromRuntimePayload: event.rawJSON) {
            return true
        }
        if allowTranscriptScan,
           codexAutoReviewEnabledFromTranscript(event: event, fm: fm) {
            return true
        }
        return ConfigInstaller.codexAutoReviewEnabled(fm: fm)
    }

    private static func codexRuntimeApprovalPolicyIsNever(_ raw: [String: Any]) -> Bool {
        let containers = [
            raw,
            raw["config"] as? [String: Any],
            raw["runtime"] as? [String: Any],
            raw["approval"] as? [String: Any],
            raw["approval_context"] as? [String: Any],
            raw["approvalContext"] as? [String: Any],
        ].compactMap { $0 }

        return containers.contains { container in
            firstString(
                in: container,
                keys: ["approval_policy", "approvalPolicy", "_approval_policy"]
            ) == "never"
        }
    }

    private static func codexAutoReviewEnabled(fromRuntimePayload raw: [String: Any]) -> Bool {
        let containers = [
            raw,
            raw["config"] as? [String: Any],
            raw["runtime"] as? [String: Any],
            raw["approval"] as? [String: Any],
            raw["approval_context"] as? [String: Any],
            raw["approvalContext"] as? [String: Any],
        ].compactMap { $0 }

        for container in containers {
            let approvalPolicy = firstString(
                in: container,
                keys: ["approval_policy", "approvalPolicy", "_approval_policy"]
            )
            guard approvalPolicy != "never" else { continue }

            if firstString(
                in: container,
                keys: [
                    "approvals_reviewer",
                    "approvalsReviewer",
                    "approval_reviewer",
                    "approvalReviewer",
                    "_approvals_reviewer",
                    "_codex_approvals_reviewer",
                ]
            ) == "auto_review" {
                return true
            }
        }
        return false
    }

    private static func codexAutoReviewEnabledFromTranscript(event: HookEvent, fm: FileManager) -> Bool {
        for path in codexTranscriptCandidatePaths(event: event, fm: fm) {
            if codexTranscriptIndicatesAutoReview(path: path, fm: fm) {
                return true
            }
        }
        return false
    }

    private static func codexTranscriptCandidatePaths(event: HookEvent, fm: FileManager) -> [String] {
        var candidates: [String] = []
        let raw = event.rawJSON

        if let transcriptPath = firstString(
            in: raw,
            keys: ["transcript_path", "transcriptPath", "_codex_transcript_path"]
        ), fm.fileExists(atPath: transcriptPath) {
            candidates.append(transcriptPath)
        }

        let threadIds = [
            firstString(in: raw, keys: ["_codex_thread_id", "codex_thread_id", "thread_id", "threadId"]),
            event.sessionId,
        ]
        for threadId in threadIds.compactMap({ $0 }) {
            if let path = codexSessionPath(forThreadId: threadId, raw: raw, fm: fm),
               !candidates.contains(path) {
                candidates.append(path)
            }
        }

        return candidates
    }

    private static func codexSessionPath(forThreadId threadId: String, raw: [String: Any], fm: FileManager) -> String? {
        let safeThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeThreadId.count >= 8,
              safeThreadId.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else { return nil }

        let codexHome = firstString(in: raw, keys: ["_codex_home", "codex_home", "codexHome"])
            ?? ConfigInstaller.codexHome()
        let sessionsBase = "\(codexHome)/sessions"
        guard fm.fileExists(atPath: sessionsBase) else { return nil }

        let calendar = Calendar.current
        let now = Date()
        for daysBack in 0..<14 {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", calendar.component(.year, from: date))
            let m = String(format: "%02d", calendar.component(.month, from: date))
            let d = String(format: "%02d", calendar.component(.day, from: date))
            let dir = "\(sessionsBase)/\(y)/\(m)/\(d)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted(by: >) where file.hasSuffix(".jsonl") && file.contains(safeThreadId) {
                return "\(dir)/\(file)"
            }
        }
        return nil
    }

    private static func codexTranscriptIndicatesAutoReview(path: String, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: path),
              let text = readFileProbe(path: path, maxBytes: 16_777_216) else { return false }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = item["payload"] as? [String: Any] else { continue }

            if item["type"] as? String == "turn_context",
               firstString(in: payload, keys: ["model"]) == "codex-auto-review" {
                return true
            }

            guard item["type"] as? String == "response_item",
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "developer" else { continue }

            if developerPayloadMentionsCodexAutoReview(payload) {
                return true
            }
        }
        return false
    }

    private static func developerPayloadMentionsCodexAutoReview(_ payload: [String: Any]) -> Bool {
        let text = messageText(from: payload).lowercased()
        return text.contains("approvals_reviewer") && text.contains("auto_review")
    }

    private static func messageText(from payload: [String: Any]) -> String {
        if let text = payload["content"] as? String { return text }
        guard let parts = payload["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func readFileProbe(path: String, maxBytes: UInt64) -> String? {
        UTF8FileChunkReader.headAndTailText(path: path, maxBytes: maxBytes)
    }

    private static func firstString(in raw: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = raw[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func disabledModeResponse(for event: HookEvent) -> Data {
        switch routeKind(for: event) {
        case .permission:
            return AppState.disabledModePermissionResponse
        case .question, .event:
            return Data("{}".utf8)
        }
    }

    private static let pluginMarkerBytes = Data("_via_plugin".utf8)

    @discardableResult
    func handleQuotaEvent(payload: Data) -> Bool {
        guard CodingSessionsSettings.isEnabled() else { return false }
        return appState.usageStore.applyClaudeCodePayload(payload)
    }

    private func processRequest(data: Data, connection: NWConnection) {
        // Plugin session mode pre-filter (#123): events that arrived through a
        // plugin proxy (bridge marks them with `_via_plugin`) can be merged
        // into the matching main session, hidden, or kept separate per the
        // user's setting. "separate" preserves prior behavior.
        //
        // Cheap byte probe first — most events don't carry `_via_plugin`,
        // and JSONSerialization on every PostToolUse on the main thread is
        // not free.
        var processedData = data
        if data.range(of: Self.pluginMarkerBytes) != nil,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (raw["_via_plugin"] as? Bool) == true {
            let mode = UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
                ?? SettingsDefaults.pluginSessionMode
            switch mode {
            case "hide":
                sendResponse(connection: connection, data: Self.hiddenPluginResponse(for: raw))
                return
            case "merge":
                if let source = raw["_source"] as? String,
                   let ppid = Self.pluginPpid(from: raw),
                   let mainSessionId = appState.findSessionId(forSource: source, ppid: ppid) {
                    var rewritten = raw
                    rewritten["session_id"] = mainSessionId
                    if let newData = try? JSONSerialization.data(withJSONObject: rewritten) {
                        processedData = newData
                    }
                }
                // No matching main session → fall through with original data
                // (acts like "separate" in that case).
            default:
                break // "separate": no-op
            }
        }

        guard let event = HookEvent(from: processedData) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        guard CodingSessionsSettings.isEnabled() else {
            sendResponse(connection: connection, data: Self.disabledModeResponse(for: event))
            return
        }

        // Diagnostics ring buffer (#103): record the post-merge view of the
        // event so the export reflects what was actually dispatched. Also
        // capture the field names the hook arrived with and a prompt preview
        // so future "prompt not showing" reports can be diagnosed without
        // round-tripping for more data.
        let payloadKeys = event.rawJSON.keys
            .filter { !$0.hasPrefix("_") }  // drop bridge-injected metadata fields
            .sorted()
        let promptPreview: String? = {
            let candidates = ["prompt", "user_prompt", "userPrompt", "message", "input", "content", "text"]
            for key in candidates {
                if let s = event.rawJSON[key] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(80))
                    }
                }
            }
            return nil
        }()
        appState.recordHookEvent(
            source: event.rawJSON["_source"] as? String,
            sessionId: event.sessionId,
            eventName: event.eventName,
            toolName: event.toolName,
            viaPlugin: (event.rawJSON["_via_plugin"] as? Bool) == true,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        )

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured cwd exclusion: drop hooks fired by background plugins
        // (e.g. claude-mem, agent loops) whose cwd matches any user-provided
        // substring. Default empty list = no filtering, matches existing behavior. (#125)
        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           Self.eventMatchesExcludedCwd(cwd) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured webhook forwarding: fire-and-forget POST to an external URL.
        // Runs *before* the route handlers so it doesn't add latency to user-facing
        // permission/question UI. Disabled by default. (#115)
        Self.forwardEventToWebhook(event)

        switch Self.routeKind(for: event) {
        case .permission:
            let sessionId = event.sessionId ?? "default"

            // Codex's built-in auto-review replaces the manual sandbox approval
            // prompt with its own reviewer. Do not convert that into a Bough
            // human approval; return no decision so Codex can continue its
            // native approval path.
            if Self.shouldDeferCodexPermissionToAutoReview(event) {
                sendResponse(connection: connection, data: Data("{}".utf8))
                return
            }

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                monitorPeerDisconnect(connection: connection, sessionId: sessionId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }
            monitorPeerDisconnect(connection: connection, sessionId: sessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .question:
            let questionSessionId = event.sessionId ?? "default"
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .event:
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// BoughBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String) {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                    self.connectionContexts.removeValue(forKey: connId)
                default:
                    break
                }
            }
        }

        // Safety net: keep this aligned with installed blocking hook timeouts
        // (24h) so a valid long-running approval/question is not cancelled
        // before the client gives up.
        // (e.g. stuck continuation, NWConnection never transitions), clean it up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 86_400_000_000_000)
            guard let self = self else { return }
            if self.connectionContexts.removeValue(forKey: connId) != nil {
                log.warning("Connection context for session \(sessionId) timed out — cleaning up")
                if !context.responded {
                    connection.cancel()
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
