import Foundation
import BoughCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let sessionTitle: String?
    let sessionTitleSource: SessionTitleSource?
    let providerSessionId: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let termApp: String?
    let itermSessionId: String?
    let ttyPath: String?
    let kittyWindowId: String?
    let tmuxPane: String?
    let tmuxClientTty: String?
    let tmuxEnv: String?
    let termBundleId: String?
    let cliPid: Int32?
    let cliStartTime: Date?
    let startTime: Date
    let lastActivity: Date
}

enum SessionPersistence {
    private static let relativePath = "sessions.json"

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.compactMap { (id, s) in
            guard !s.isRemote else { return nil }
            return PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                sessionTitle: s.sessionTitle,
                sessionTitleSource: s.sessionTitleSource,
                providerSessionId: s.providerSessionId,
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                termApp: s.termApp,
                itermSessionId: s.itermSessionId,
                ttyPath: s.ttyPath,
                kittyWindowId: s.kittyWindowId,
                tmuxPane: s.tmuxPane,
                tmuxClientTty: s.tmuxClientTty,
                tmuxEnv: s.tmuxEnv,
                termBundleId: s.termBundleId,
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity
            )
        }
        // Preserve the pre-existing silent-on-error save semantics: AtomicJSONStore.write
        // throws, but session persistence is best-effort and must never crash the app.
        do {
            try AtomicJSONStore.write(persisted, to: Self.relativePath)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        AtomicJSONStore.read([PersistedSession].self, from: Self.relativePath) ?? []
    }

    static func clear() {
        let fileURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".bough", isDirectory: true)
            .appendingPathComponent(Self.relativePath)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
