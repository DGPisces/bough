import Foundation

/// Best-effort `claude --version` probe used only to build the OAuth
/// User-Agent (`claude-code/<version>`, spec §4.2). Cached per process.
public enum ClaudeCLIVersionProbe {
    public static let fallbackVersion = "2.1.0"
    private static let lock = NSLock()
    private static var cached: String?

    public static func cachedVersion() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let detected = detect() ?? fallbackVersion
        cached = detected
        return detected
    }

    /// internal for tests.
    static func detect(executableCandidates: [String]? = nil) -> String? {
        let home = NSHomeDirectory()
        let candidates = executableCandidates ?? [
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let version = runVersionProbe(path: path) { return version }
        }
        return nil
    }

    private static func runVersionProbe(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate(); return nil }
        guard let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) else { return nil }
        // Output shape: "2.1.173 (Claude Code)" — first semver-looking token wins.
        let pattern = #"\d+\.\d+\.\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }
}
