import Foundation
import BoughCore

extension AppState {
    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.saveSessions()
            }
        }
    }

    func saveSessions() {
        SessionPersistence.save(sessions)
    }

    func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted where p.lastActivity > cutoff {
            guard sessions[p.sessionId] == nil else { continue }
            guard let source = SessionSnapshot.normalizedSupportedSource(p.source) else { continue }
            var snapshot = SessionSnapshot(startTime: p.startTime)
            snapshot.cwd = p.cwd
            snapshot.source = source
            snapshot.model = p.model
            snapshot.sessionTitle = p.sessionTitle
            snapshot.sessionTitleSource = p.sessionTitleSource
            snapshot.providerSessionId = p.providerSessionId
            snapshot.lastUserPrompt = p.lastUserPrompt
            snapshot.lastAssistantMessage = p.lastAssistantMessage
            if let prompt = p.lastUserPrompt {
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            if let reply = p.lastAssistantMessage {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            snapshot.termApp = p.termApp
            snapshot.itermSessionId = p.itermSessionId
            snapshot.ttyPath = p.ttyPath
            snapshot.kittyWindowId = p.kittyWindowId
            snapshot.tmuxPane = p.tmuxPane
            snapshot.tmuxClientTty = p.tmuxClientTty
            snapshot.tmuxEnv = p.tmuxEnv
            snapshot.termBundleId = p.termBundleId
            snapshot.lastActivity = p.lastActivity
            // Restore persisted cliPid only if the process is still alive — avoids
            // stale sessions reappearing briefly after the app or IDE restarts (#46).
            if let pid = p.cliPid, pid > 0 {
                let identity = ProcessIdentity(pid: pid, startTime: p.cliStartTime)
                if Self.isLiveProcess(identity) {
                    snapshot.cliPid = pid
                    snapshot.cliStartTime = p.cliStartTime
                }
            }
            // Skip sessions whose process is dead and status was idle — nothing to show.
            if snapshot.cliPid == nil && snapshot.status == .idle && snapshot.lastUserPrompt == nil {
                continue
            }
            sessions[p.sessionId] = snapshot
            refreshProviderTitle(for: p.sessionId)
            // Reattach exit monitoring without changing the restored idle/running snapshot.
            tryMonitorSession(p.sessionId)
        }
        SessionPersistence.clear()
        if activeSessionId == nil {
            activeSessionId = sessions.first(where: { $0.value.status != .idle })?.key
                ?? sessions.keys.sorted().first
        }
        refreshDerivedState()
    }
}
