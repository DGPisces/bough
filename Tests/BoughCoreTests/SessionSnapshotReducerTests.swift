import XCTest
@testable import BoughCore

final class SessionSnapshotReducerTests: XCTestCase {
    func testSessionStartActivatesVisibleSession() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "claude-session",
            "_source": "claude",
            "cwd": "/tmp/bough-session"
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["claude-session"]?.status, .idle)
        XCTAssertTrue(effects.contains(.setActiveSession(sessionId: "claude-session")))
    }

    private func makeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
