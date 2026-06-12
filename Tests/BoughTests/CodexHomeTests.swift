import XCTest
@testable import Bough

final class CodexHomeTests: XCTestCase {
    private var savedValue: String?

    override func setUp() {
        super.setUp()
        TestHelpers.processEnvironmentLock.lock()
        savedValue = ProcessInfo.processInfo.environment["CODEX_HOME"]
        unsetenv("CODEX_HOME")
    }

    override func tearDown() {
        if let savedValue {
            setenv("CODEX_HOME", savedValue, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        TestHelpers.processEnvironmentLock.unlock()
        super.tearDown()
    }

    func testCodexHomeDefaultsToDotCodexWhenUnset() {
        unsetenv("CODEX_HOME")
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testCodexHomeUsesAbsolutePath() {
        setenv("CODEX_HOME", "/abs/path", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), "/abs/path")
    }

    func testCodexHomeExpandsTilde() {
        setenv("CODEX_HOME", "~/foo", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/foo")
    }

    func testCodexHomeBareTildeBecomesHome() {
        setenv("CODEX_HOME", "~", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory())
    }

    func testCodexHomeEmptyStringFallsBack() {
        setenv("CODEX_HOME", "", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testCodexHomeWhitespaceFallsBack() {
        setenv("CODEX_HOME", "   ", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testDisplayCodexPathUsesEnvNameWhenSet() {
        setenv("CODEX_HOME", "/abs/path", 1)
        XCTAssertEqual(ConfigInstaller.displayCodexPath(filename: "hooks.json"), "$CODEX_HOME/hooks.json")
    }

    func testDisplayCodexPathFallsBackWhenUnset() {
        unsetenv("CODEX_HOME")
        XCTAssertEqual(ConfigInstaller.displayCodexPath(filename: "hooks.json"), "~/.codex/hooks.json")
    }

    func testSessionTitleStoreReadsCodexHomeSessionIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHomeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CODEX_HOME", root.path, 1)
        try """
        {"id":"session-1","thread_name":"Custom home title","updated_at":"2026-06-08T00:00:00Z"}
        """.write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionTitleStore.codexThreadName(sessionId: "session-1"), "Custom home title")
    }

    func testDiscoveryWatchRootsUsesCodexHomeSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHomeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        setenv("CODEX_HOME", root.path, 1)

        // Isolated suite: `.standard` is shared across `swift test --parallel`
        // worker processes via cfprefsd, so another worker writing
        // cli_enabled_codex would race this test.
        let suiteName = "CodexHomeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cli_enabled_codex")

        XCTAssertTrue(AppState.discoveryWatchRoots(defaults: defaults).contains(sessions.path))
    }

    func testDiscoveryWatchRootsSkipsCodexHomeWhenSessionsDirectoryIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHomeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CODEX_HOME", root.path, 1)

        let suiteName = "CodexHomeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cli_enabled_codex")

        XCTAssertFalse(AppState.discoveryWatchRoots(defaults: defaults).contains(root.path))
    }

    func testCodexTranscriptPathsUseCodexHomeHelper() throws {
        let source = try String(
            contentsOf: TestHelpers.repoRoot(from: #filePath).appendingPathComponent("Sources/Bough/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let codexHome = ConfigInstaller.codexHome()"))
        XCTAssertTrue(source.contains("let statePath = codexHome + \"/state_5.sqlite\""))
        XCTAssertTrue(source.contains("let base = codexHome + \"/sessions\""))
        XCTAssertTrue(source.contains("let sessionsBase = ConfigInstaller.codexHome() + \"/sessions\""))
    }
}
