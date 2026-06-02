import AppKit
import CoreServices
import Foundation
import os.log
import BoughCore

private let discoveryLog = Logger(subsystem: "com.dgpisces.bough", category: "AppState")

extension AppState {
    nonisolated static func findDiscoveredSessions() -> [DiscoveredSession] {
        let candidatePids = allProcessIds()
        var discovered: [DiscoveredSession] = []
        if ConfigInstaller.isEnabled(source: "claude") {
            discovered.append(contentsOf: findActiveClaudeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codex") {
            discovered.append(contentsOf: findActiveCodexSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "gemini") {
            discovered.append(contentsOf: findActiveGeminiSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "qoder") {
            discovered.append(contentsOf: findActiveQoderSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codebuddy") {
            discovered.append(contentsOf: findActiveCodeBuddySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "droid") {
            discovered.append(contentsOf: findActiveFactorySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "cursor") {
            discovered.append(contentsOf: findActiveCursorSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "copilot") {
            discovered.append(contentsOf: findActiveCopilotSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "opencode") {
            discovered.append(contentsOf: findActiveOpenCodeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "kimi") {
            discovered.append(contentsOf: findActiveKimiSessions(candidatePids: candidatePids))
        }
        return discovered
    }

    nonisolated static func discoveryWatchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String)] = [
            ("claude", "\(home)/.claude/projects"),
            ("codex", "\(home)/.codex/sessions"),
            ("gemini", "\(home)/.gemini/tmp"),
            ("qoder", "\(home)/.qoder/projects"),
            ("codebuddy", "\(home)/.codebuddy/projects"),
            ("droid", "\(home)/.factory/sessions"),
            ("cursor", "\(home)/.cursor/projects"),
            ("copilot", "\(home)/.copilot/session-state"),
            ("opencode", "\(home)/.local/share/opencode"),
            ("kimi", "\(home)/.kimi/sessions"),
        ]
        let fm = FileManager.default
        return candidates.compactMap { source, path in
            guard ConfigInstaller.isEnabled(source: source), fm.fileExists(atPath: path) else { return nil }
            return path
        }
    }

    func requestDiscoveryScan() {
        guard codingSessionsEnabledProvider() else {
            stopSessionDiscovery()
            return
        }

        if discoveryScanTask != nil {
            pendingDiscoveryRescan = true
            return
        }

        pendingDiscoveryRescan = false
        discoveryScanTask = Task.detached { [weak self] in
            let discovered = Self.findDiscoveredSessions()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.discoveryScanTask = nil
                    return
                }
                self.integrateDiscovered(discovered)
                self.discoveryScanTask = nil
                if self.pendingDiscoveryRescan {
                    self.pendingDiscoveryRescan = false
                    self.requestDiscoveryScan()
                }
            }
        }
    }

    func startSessionDiscovery() {
        guard codingSessionsEnabledProvider() else { return }
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions, respecting per-source toggles.
        requestDiscoveryScan()
        // Watch all known session-store roots so discovery keeps working when hooks are missed.
        startProjectsWatcher()
    }

    /// FSEventStream on known session-store roots — fires when transcript/event files change.
    func startProjectsWatcher() {
        guard codingSessionsEnabledProvider() else { return }
        guard fsEventStream == nil else { return }
        let watchRoots = Self.discoveryWatchRoots()
        guard !watchRoots.isEmpty else { return }

        var context = FSEventStreamContext()
        // passUnretained is safe here: the stream is dispatched on .main (same as
        // @MainActor), so callbacks cannot interleave with deinit. Both
        // stopSessionDiscovery() and deinit stop/invalidate the stream synchronously
        // on the main thread before self is deallocated.
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let appState = Unmanaged<AppState>.fromOpaque(info).takeUnretainedValue()
                appState.handleProjectsDirChange()
            },
            &context,
            watchRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // 2-second latency (coalesces rapid writes)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.fsEventStream = stream
        discoveryLog.info("Discovery watcher started on \(watchRoots.joined(separator: ", "))")
    }

    /// Called by FSEventStream when a known session-store directory changes.
    nonisolated func handleProjectsDirChange() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.codingSessionsEnabledProvider() else { return }
            // Debounce: skip if scanned within the last 3 seconds
            guard Date().timeIntervalSince(self.lastFSScanTime) > 3 else { return }
            self.lastFSScanTime = Date()
            self.requestDiscoveryScan()
        }
    }

    /// Update existing session's messages from discovered transcript data.
    private func backfillSessionMessages(sessionId: String, from info: DiscoveredSession) -> Bool {
        guard var session = sessions[sessionId], !info.recentMessages.isEmpty else { return false }
        var mutated = false
        let messagesChanged = session.recentMessages.count != info.recentMessages.count ||
            zip(session.recentMessages, info.recentMessages).contains { $0.isUser != $1.isUser || $0.text != $1.text }
        if messagesChanged {
            session.recentMessages = info.recentMessages
            mutated = true
        }
        if let lastUser = info.recentMessages.last(where: { $0.isUser }),
           session.lastUserPrompt != lastUser.text {
            session.lastUserPrompt = lastUser.text
            mutated = true
        }
        if let lastAssistant = info.recentMessages.last(where: { !$0.isUser }),
           session.lastAssistantMessage != lastAssistant.text {
            session.lastAssistantMessage = lastAssistant.text
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// Merge discovered sessions into current state (skip already-known ones)
    func integrateDiscovered(_ discovered: [DiscoveredSession]) {
        guard codingSessionsEnabledProvider() else { return }
        var didMutate = false
        for info in discovered {
            // Session already known — try to update PID and attach monitor.
            // Discovery PIDs are heuristic (matched by CWD), so when the session already
            // has a known-good alive PID that differs from discovery, we trust the existing
            // one for both cliPid and monitor to avoid cross-session contamination.
            if sessions[info.sessionId] != nil {
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[info.sessionId]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: info.sessionId)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                        // Existing PID is alive and different — discovery PID is unreliable.
                    } else {
                        // No existing PID, or it's dead, or it matches — safe to use discovery PID.
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: info.sessionId)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: info.sessionId, from: info) {
                    didMutate = true
                }
                if let path = info.transcriptPath, sessions[info.sessionId]?.transcriptPath != path {
                    sessions[info.sessionId]?.transcriptPath = path
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
                tryMonitorSession(info.sessionId)
                refreshProviderTitle(for: info.sessionId, providerSessionId: info.sessionId)
                continue
            }

            // Dedup: if a hook-created session already exists with same source + cwd + pid,
            // skip the discovered one to avoid duplicate entries (e.g. Codex hooks vs
            // file-based discovery produce different session IDs for the same process).
            // Only dedup when PID matches (or discovered has no PID), so concurrent
            // sessions in the same repo aren't incorrectly merged.
            // Never merge a discovery (CLI) session with an existing native app session —
            // they're fundamentally different even if they share source + cwd.
            let duplicateKey = sessions.first(where: { (_, existing) in
                guard existing.source == info.source,
                      existing.cwd != nil, existing.cwd == info.cwd else { return false }
                // Don't merge CLI discovery into a stale native app session whose app has quit —
                // the PID was likely reattached incorrectly. If the native app IS running, allow merge.
                if existing.isNativeAppMode,
                   let bid = existing.termBundleId,
                   !isRunningApplicationBundleId(bid) {
                    return false
                }
                // If we have PIDs for both and the existing one is still alive, they must match.
                // Dead persisted PIDs should not block dedup / reattachment.
                if let discoveredPid = info.pid, let existingPid = existing.cliPid,
                   discoveredPid != existingPid,
                   Self.isLiveProcess(ProcessIdentity(pid: existingPid, startTime: existing.cliStartTime)) { return false }
                return true
            })?.key

            if let existingKey = duplicateKey {
                // Same guard as above: don't let unreliable discovery PID contaminate
                // an existing session that has a known-good alive PID.
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[existingKey]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: existingKey)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                    } else {
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: existingKey)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: existingKey, from: info) {
                    didMutate = true
                }
                if let path = info.transcriptPath, sessions[existingKey]?.transcriptPath != path {
                    sessions[existingKey]?.transcriptPath = path
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: existingKey)
                tryMonitorSession(existingKey)
                refreshProviderTitle(for: existingKey, providerSessionId: info.sessionId)
                continue
            }

            var session = SessionSnapshot(startTime: info.modifiedAt)
            session.cwd = info.cwd
            session.model = info.model
            session.ttyPath = info.tty
            session.recentMessages = info.recentMessages
            session.source = info.source
            if let pid = info.pid, let process = Self.liveProcessIdentity(for: pid) {
                session.cliPid = process.pid
                session.cliStartTime = process.startTime
            } else {
                session.cliPid = info.pid
            }
            session.providerSessionId = SessionTitleStore.supports(provider: info.source) ? info.sessionId : nil
            if let last = info.recentMessages.last(where: { $0.isUser }) {
                session.lastUserPrompt = last.text
            }
            if let last = info.recentMessages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = last.text
            }
            session.transcriptPath = info.transcriptPath
            sessions[info.sessionId] = session
            refreshProviderTitle(for: info.sessionId, providerSessionId: info.sessionId)
            tryMonitorSession(info.sessionId)
            attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
            didMutate = true
        }
        if didMutate && activeSessionId == nil {
            activeSessionId = sessions.keys.sorted().first
        }
        if didMutate {
            scheduleSave()
        }
        refreshDerivedState()
    }
}
