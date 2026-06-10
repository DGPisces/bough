import XCTest
@testable import Bough
import BoughCore

final class TerminalVisibilityDetectorTests: XCTestCase {
    func testKittyFocusedWindowMatchesByWindowId() {
        var session = SessionSnapshot()
        session.kittyWindowId = "42"
        session.cwd = "/work/project"

        XCTAssertTrue(TerminalVisibilityDetector.kittyFocusedWindowMatchesSession(
            session,
            window: ["id": 42, "cwd": "/different"]
        ))
        XCTAssertFalse(TerminalVisibilityDetector.kittyFocusedWindowMatchesSession(
            session,
            window: ["id": 7, "cwd": "/work/project"]
        ))
    }

    func testKittyFocusedWindowFallsBackToCwdWhenWindowIdMissing() {
        var session = SessionSnapshot()
        session.cwd = "/work/project/"

        XCTAssertTrue(TerminalVisibilityDetector.kittyFocusedWindowMatchesSession(
            session,
            window: ["cwd": "file:///work/project"]
        ))
        XCTAssertFalse(TerminalVisibilityDetector.kittyFocusedWindowMatchesSession(
            session,
            window: ["cwd": "/work/other"]
        ))
    }

    func testKittyFocusedWindowDecodesFileURLCwd() {
        var session = SessionSnapshot()
        session.cwd = "/work/My Project"

        XCTAssertTrue(TerminalVisibilityDetector.kittyFocusedWindowMatchesSession(
            session,
            window: ["cwd": "file:///work/My%20Project"]
        ))
    }

    func testTmuxVisibilityCommandsUseSessionTmuxEnvironment() throws {
        let source = try sourceFile("Sources/Bough/TerminalVisibilityDetector.swift")

        XCTAssertTrue(source.contains("isTmuxPaneActive(pane, tmuxEnv: session.tmuxEnv)"))
        XCTAssertTrue(source.contains("private static func tmuxProcessEnv(_ tmuxEnv:"))
        XCTAssertTrue(source.contains("runProcess(bin, args: [\"display-message\""))
        XCTAssertTrue(source.contains("runProcess(bin, args: [\"list-panes\""))
        XCTAssertTrue(source.contains("env: env"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
