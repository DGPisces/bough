import AppKit
import Foundation
import BoughCore

/// One-click diagnostics export for bug reports.
/// Collects app metadata, settings, session state, CLI configs, and recent logs into a zip.
struct DiagnosticsExporter {
    private struct StateSnapshot {
        let sessions: [[String: Any]]
        let hookEvents: [[String: Any]]
    }

    private final class CommandOutputBox: @unchecked Sendable {
        var data = Data()
    }

    @MainActor
    static func export(appState: AppState) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bough-Diagnostics-\(timestamp()).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let stateSnapshot = StateSnapshot(
            sessions: sessionSnapshots(from: appState),
            hookEvents: recentHookEvents(from: appState)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = try buildArchive(saveTo: url, stateSnapshot: stateSnapshot)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([zipURL])
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Archive Builder

    private static func buildArchive(saveTo destination: URL, stateSnapshot: StateSnapshot) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("Bough-Diag-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("Bough-Diagnostics-\(timestamp())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. Metadata
        writeJSON(metadata(), to: root.appendingPathComponent("metadata.json"))

        // 2. Session snapshots (from AppState)
        writeJSON(stateSnapshot.sessions, to: root.appendingPathComponent("state/sessions.json"))

        // 2b. Recent hook events ring buffer (#103). Helps reproduce
        // session-routing / source-inference issues that only show up at
        // runtime — bug reports can ship with the actual event stream.
        writeJSON(stateSnapshot.hookEvents, to: root.appendingPathComponent("state/hook-events.json"))

        // 3. CLI config files
        let home = fm.homeDirectoryForCurrentUser.path
        let configs: [(source: String, dest: String)] = [
            ("\(home)/.claude/settings.json", "configs/claude-settings.json"),
            ("\(home)/.codex/hooks.json", "configs/codex-hooks.json"),
            ("\(home)/.gemini/settings.json", "configs/gemini-settings.json"),
            ("\(home)/.cursor/hooks.json", "configs/cursor-hooks.json"),
            ("\(home)/.qoder/settings.json", "configs/qoder-settings.json"),
            ("\(home)/.factory/settings.json", "configs/factory-settings.json"),
            ("\(home)/.codebuddy/settings.json", "configs/codebuddy-settings.json"),
            ("\(home)/.bough/sessions.json", "configs/persisted-sessions.json"),
        ]
        for item in configs {
            copyIfExists(from: item.source, to: root.appendingPathComponent(item.dest))
        }

        // 3b. DIAG-04: Hook config snapshot, codex config, and migration log
        writeJSON(hookConfigSnapshot(), to: root.appendingPathComponent("configs/hook-config-snapshot.json"))
        copyIfExists(from: "\(home)/.codex/config.toml", to: root.appendingPathComponent("configs/codex-config.toml"))
        writeJSON(migrationLogEntry(), to: root.appendingPathComponent("configs/migration-log.json"))

        // 4. Socket status
        let socketPath = SocketPath.path
        let socketExists = fm.fileExists(atPath: socketPath)
        let socketInfo = "path: \(socketPath)\nexists: \(socketExists)\n"
        try? socketInfo.write(to: root.appendingPathComponent("state/socket.txt"), atomically: true, encoding: .utf8)

        let logsDir = root.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // 5. Unified system logs (last 2 hours)
        let logOutput = runCommand("/usr/bin/log", args: [
            "show", "--style", "compact", "--info", "--debug",
            "--last", "2h", "--predicate", "subsystem == \"com.dgpisces.bough\""
        ])
        try? logOutput.write(to: logsDir.appendingPathComponent("unified.log"), atomically: true, encoding: .utf8)

        // 6. sw_vers
        let swVers = runCommand("/usr/bin/sw_vers", args: [])
        try? swVers.write(to: logsDir.appendingPathComponent("sw_vers.txt"), atomically: true, encoding: .utf8)

        // 7. Recent crash reports
        copyCrashReports(to: logsDir.appendingPathComponent("crash-reports", isDirectory: true))

        // Zip
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", root.path, destination.path]
        try proc.run()
        let dittoExited = ProcessRunner.waitUntilExitOrTerminate(proc, timeout: 20)
        try? fm.removeItem(at: tmp)

        guard dittoExited else {
            throw NSError(domain: "DiagnosticsExporter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "ditto timed out"
            ])
        }

        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "DiagnosticsExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ditto failed with exit code \(proc.terminationStatus)"
            ])
        }
        return destination
    }

    // MARK: - Data Collectors

    private static func metadata() -> [String: Any] {
        [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": AppVersion.current,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier,
            "socketPath": SocketPath.path,
            "settings": [
                "hideInFullscreen": UserDefaults.standard.bool(forKey: SettingsKey.hideInFullscreen),
                "hideWhenNoSession": UserDefaults.standard.bool(forKey: SettingsKey.hideWhenNoSession),
                "collapseOnMouseLeave": UserDefaults.standard.bool(forKey: SettingsKey.collapseOnMouseLeave),
                "sessionTimeout": UserDefaults.standard.integer(forKey: SettingsKey.sessionTimeout),
                "maxVisibleSessions": UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions),
                "mascotSpeed": UserDefaults.standard.integer(forKey: SettingsKey.mascotSpeed),
                "displayChoice": UserDefaults.standard.string(forKey: SettingsKey.displayChoice) ?? "auto",
            ],
        ]
    }

    @MainActor
    static func recentHookEvents(from appState: AppState) -> [[String: Any]] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return appState.recentHookEvents.map { event in
            var dict: [String: Any] = [
                "timestamp": isoFormatter.string(from: event.timestamp),
                "eventName": event.eventName,
                "viaPlugin": event.viaPlugin,
                "payloadKeys": event.payloadKeys,
            ]
            if let source = event.source { dict["source"] = source }
            if let sessionId = event.sessionId { dict["sessionId"] = String(sessionId.prefix(12)) }
            if let toolName = event.toolName { dict["toolName"] = toolName }
            if let preview = event.promptPreview { dict["promptPreview"] = sanitizedDiagnosticsText(preview) }
            return dict
        }
    }

    @MainActor
    static func sessionSnapshots(from appState: AppState) -> [[String: Any]] {
        return appState.sessions.map { id, s in
            var dict: [String: Any] = [
                "id": String(id.prefix(8)),
                "status": "\(s.status)",
                "source": s.source,
                "lastActivity": ISO8601DateFormatter().string(from: s.lastActivity),
            ]
            if let cwd = s.cwd { dict["cwd"] = cwd }
            if let tool = s.currentTool { dict["currentTool"] = tool }
            if let model = s.model { dict["model"] = model }
            if let term = s.terminalName { dict["terminal"] = term }
            if let pid = s.cliPid { dict["pid"] = pid }
            dict["subagentCount"] = s.subagents.count
            dict["toolHistoryCount"] = s.toolHistory.count
            return dict
        }
    }

    // MARK: - DIAG-04 Helpers

    /// Builds the hook-config-snapshot payload. Internal for testability.
    /// - Parameter home: Root directory to resolve `.claude/` and `.codex/` against.
    ///   Defaults to the current user's home directory (production behavior).
    ///   Tests inject a temp directory to stay hermetic — see WR-02 fix.
    static func hookConfigSnapshot(home: String? = nil) -> [String: Any] {
        let fm = FileManager.default
        let home = home ?? fm.homeDirectoryForCurrentUser.path

        // claudeCodeStatusLine
        let settingsPath = home + "/.claude/settings.json"
        let statusLine: Any = ConfigInstaller.currentClaudeCodeStatusLineCommand(settingsPath: settingsPath)
            .map(sanitizedDiagnosticsText) ?? NSNull()

        // claudeCodeHooksBlock — parse ~/.claude/settings.json and extract top-level "hooks" key
        var claudeCodeHooksBlock: Any = NSNull()
        if let json = ConfigInstaller.parseJSONCFile(at: settingsPath, fm: fm),
           let hooks = json["hooks"] {
            claudeCodeHooksBlock = sanitizedJSONValue(hooks)
        }

        // codexHooksInstalled — ~/.codex/hooks.json exists and contains a managed Bough hook.
        let codexHooksPath = home + "/.codex/hooks.json"
        var codexHooksInstalled = false
        if fm.fileExists(atPath: codexHooksPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: codexHooksPath)),
           let content = String(data: data, encoding: .utf8) {
            codexHooksInstalled = containsManagedCodexHookMarker(content)
        }

        // codexFeaturesSection — lines under [features] table in ~/.codex/config.toml
        let codexConfigPath = home + "/.codex/config.toml"
        var codexFeaturesSection = ""
        if let data = try? Data(contentsOf: URL(fileURLWithPath: codexConfigPath)),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            var inFeatures = false
            var featureLines: [String] = []
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces) == "[features]" {
                    inFeatures = true
                    continue
                }
                if inFeatures {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") { break }
                    featureLines.append(line)
                }
            }
            codexFeaturesSection = sanitizedDiagnosticsText(featureLines.joined(separator: "\n"))
        }

        return [
            "claudeCodeStatusLine": statusLine,
            "claudeCodeHooksBlock": claudeCodeHooksBlock,
            "codexHooksInstalled": codexHooksInstalled,
            "codexFeaturesSection": codexFeaturesSection,
        ]
    }

    private static func containsManagedCodexHookMarker(_ content: String) -> Bool {
        let lower = content.lowercased()
        if lower.contains("bough-hook-v1-start") || lower.contains("bough-hook-v1-end") {
            return true
        }
        if lower.contains("bough_hook_v1") {
            return true
        }
        if lower.contains("~/.bough/bough-hook.sh") || lower.contains("/.bough/bough-hook.sh") {
            return true
        }
        if lower.contains("~/.claude/hooks/bough-hook.sh")
            || lower.contains("/.claude/hooks/bough-hook.sh") {
            return true
        }
        if ConfigInstaller.containsBoughBridgeCommand(content) {
            return true
        }
        if lower.range(of: #"(^|/)bough-opencode\.js($|[?#])"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Builds the migration-log payload. Internal for testability.
    /// - Parameter home: Root directory to resolve `.claude/` and `.codex/` against.
    ///   Defaults to the current user's home directory (production behavior).
    ///   Tests inject a temp directory to stay hermetic — see WR-02 fix.
    /// Note: `statusLinePresent` still reads the real `~/.claude/settings.json`
    /// via `ConfigInstaller.currentClaudeCodeStatusLineCommand()` — that field
    /// remains environment-dependent until ConfigInstaller surfaces an injectable
    /// path (out of scope for this fix).
    static func migrationLogEntry(
        home: String? = nil,
        codexAppServerProcessStarts: [ConfigInstaller.CodexAppServerProcessStart]? = nil
    ) -> [String: Any] {
        let fm = FileManager.default
        let home = home ?? fm.homeDirectoryForCurrentUser.path
        let codexConfigPath = home + "/.codex/config.toml"
        let restartStatus: ConfigInstaller.CodexAppServerRestartStatus
        if let codexAppServerProcessStarts {
            restartStatus = ConfigInstaller.codexAppServerRestartStatus(
                configPath: codexConfigPath,
                fm: fm,
                processStarts: codexAppServerProcessStarts
            )
        } else {
            restartStatus = ConfigInstaller.codexAppServerRestartStatus(
                configPath: codexConfigPath,
                fm: fm
            )
        }
        let configModifiedAt: Any = restartStatus.configModificationDate
            .map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        return [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "statusLinePresent": ConfigInstaller.currentClaudeCodeStatusLineCommand() != nil,
            "claudeSettingsExists": fm.fileExists(atPath: home + "/.claude/settings.json"),
            "codexHooksJsonExists": fm.fileExists(atPath: home + "/.codex/hooks.json"),
            "codexConfigModifiedAt": configModifiedAt,
            "codexDeprecatedHooksKeyPresent": ConfigInstaller.codexDeprecatedHooksKeyPresent(
                fm: fm,
                configPath: codexConfigPath
            ),
            "codexAppServerRunningPIDs": restartStatus.runningPIDs.map(Int.init),
            "codexAppServerStalePIDs": restartStatus.stalePIDs.map(Int.init),
            "codexAppServerNeedsRestart": restartStatus.needsRestart,
            "note": "Synthesized at export time — no persistent migration log. Status reflects current disk state.",
        ]
    }

    // MARK: - Helpers

    private static func writeJSON(_ obj: Any, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Copies `path` to `url` if the source file exists. Internal (not private)
    /// so `DiagnosticsExporterTests` can drive it directly with fixture paths
    /// and verify the wiring DIAG-04 uses for `~/.codex/config.toml` — see WR-01 fix.
    static func copyIfExists(from path: String, to url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            try? sanitizedDiagnosticsText(content).write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? fm.copyItem(atPath: path, toPath: url.path)
        }
    }

    static func sanitizedDiagnosticsText(_ content: String) -> String {
        var sanitized = content
        let tokenPatterns = [
            #"github_pat_[A-Za-z0-9_]+"#,
            #"gh[pousr]_[A-Za-z0-9_]+"#,
            #"sk-[A-Za-z0-9._\-]+"#,
            #"Bearer\s+[A-Za-z0-9._~+/\-]+=*"#,
        ]
        for pattern in tokenPatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        let sensitiveKeyPattern = #"(?i)(["']?)([A-Za-z0-9_.-]*(?:token|secret|password|authorization|bearer|api[_-]?key|private[_-]?key|pat)[A-Za-z0-9_.-]*)(["']?)(\s*[:=]\s*)(["']?)[^"'\n\r,}]+(["']?)"#
        sanitized = sanitized.replacingOccurrences(
            of: sensitiveKeyPattern,
            with: "$1$2$3$4$5<redacted>$6",
            options: .regularExpression
        )

        sanitized = sanitized.replacingOccurrences(
            of: ["bough", "internal"].joined(separator: "-"),
            with: "bough",
            options: .caseInsensitive
        )
        return sanitized
    }

    private static func sanitizedJSONValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return sanitizedDiagnosticsText(string)
        case let dict as [String: Any]:
            var sanitized: [String: Any] = [:]
            for (key, value) in dict {
                sanitized[key] = sanitizedJSONValue(value)
            }
            return sanitized
        case let array as [Any]:
            return array.map(sanitizedJSONValue)
        default:
            return value
        }
    }

    private static func runCommand(_ executable: String, args: [String]) -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let box = CommandOutputBox()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
            let exited = ProcessRunner.waitUntilExitOrTerminate(proc, timeout: 10)
            _ = drained.wait(timeout: .now() + 1)
            guard exited else {
                return "error: command timed out after 10s: \(executable)"
            }
            return String(data: box.data, encoding: .utf8) ?? ""
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    private static func copyCrashReports(to dir: URL) {
        let fm = FileManager.default
        let diagDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? fm.contentsOfDirectory(at: diagDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let recent = files
            .filter { $0.lastPathComponent.lowercased().contains("bough") }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .prefix(5)
        guard !recent.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in recent {
            try? fm.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
