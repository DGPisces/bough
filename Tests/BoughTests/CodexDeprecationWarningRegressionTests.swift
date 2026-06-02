import XCTest

final class CodexDeprecationWarningRegressionTests: XCTestCase {
    func testCodexDoesNotWarnAboutDeprecatedCodexHooksKey() throws {
        let codexPath = try Self.codexExecutablePath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDeprecationWarningRegressionTests-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("[features]\nhooks = true\n".utf8)
            .write(to: codexHome.appendingPathComponent("config.toml"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["--version"]
        process.environment = [
            "HOME": root.path,
            "CODEX_HOME": codexHome.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(stderrText.contains("[features].codex_hooks is deprecated"))
        XCTAssertFalse(stderrText.contains("codex_hooks is deprecated"))
    }

    private static func codexExecutablePath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-lc", "command -v codex"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw XCTSkip("codex CLI not installed")
        }
        let path = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            throw XCTSkip("codex CLI not installed")
        }
        return path
    }
}
