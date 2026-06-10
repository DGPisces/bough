import XCTest
@testable import Bough
import BoughCore

@MainActor
final class AppStateSessionDiscoveryTests: XCTestCase {
    func testDiscoveryDedupUsesRuntimeSourceGroupForCursorCLI() {
        let appState = AppState()
        appState.sessions["hook-session"] = snapshot(source: "cursor-cli", cwd: "/tmp/project")

        appState.integrateDiscovered([
            AppState.DiscoveredSession(
                sessionId: "file-session",
                cwd: "/tmp/project",
                tty: nil,
                model: nil,
                pid: nil,
                modifiedAt: Date(),
                recentMessages: [],
                source: "cursor"
            )
        ])

        XCTAssertNotNil(appState.sessions["hook-session"])
        XCTAssertNil(appState.sessions["file-session"])
    }

    func testFindSessionIdUsesRuntimeSourceGroupForQoderCLI() {
        let appState = AppState()
        var session = snapshot(source: "qoder-cli", cwd: "/tmp/project")
        session.cliPid = 12345
        session.lastActivity = Date()
        appState.sessions["hook-session"] = session

        XCTAssertEqual(appState.findSessionId(forSource: "qoder", ppid: 12345), "hook-session")
    }

    private func snapshot(source: String, cwd: String) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.source = source
        snapshot.cwd = cwd
        return snapshot
    }
}
