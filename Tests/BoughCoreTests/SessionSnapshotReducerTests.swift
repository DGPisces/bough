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

    func testSessionStartKeepsTranscriptAndEnvironmentMetadataAfterReset() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "opencode-session",
            "_source": "opencode",
            "transcript_path": "/Users/example/.opencode/project/session.jsonl",
            "_env": [
                "TERM_PROGRAM": "iTerm.app",
                "ITERM_SESSION_ID": "w0t0p0:ABC-123",
                "TMUX_PANE": "%4"
            ]
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        let session = try XCTUnwrap(sessions["opencode-session"])
        XCTAssertEqual(session.transcriptPath, "/Users/example/.opencode/project/session.jsonl")
        XCTAssertEqual(session.termApp, "iTerm.app")
        XCTAssertEqual(session.itermSessionId, "ABC-123")
        XCTAssertEqual(session.tmuxPane, "%4")
    }

    func testRemoteSessionStartDoesNotReturnLocalMonitorEffectAfterReset() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-session",
            "_source": "codex",
            "cwd": "/home/user/project",
            "_remote_host_id": "remote-1",
            "_remote_host_name": "devbox"
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
        let sessionId = try XCTUnwrap(event.sessionId)

        XCTAssertEqual(sessions[sessionId]?.remoteHostId, "remote-1")
        XCTAssertFalse(effects.contains(.tryMonitorSession(sessionId: sessionId)))
    }

    func testPermissionRequestEntersWaitingApprovalForNormalizedNames() throws {
        for eventName in ["PermissionRequest", "permission_request"] {
            var sessions: [String: SessionSnapshot] = [:]
            let event = try makeHookEvent([
                "hook_event_name": eventName,
                "session_id": "approval-session",
                "tool_name": "Bash",
                "tool_input": [
                    "description": "Remove build output",
                    "command": "rm -rf .build"
                ]
            ])

            _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

            let session = try XCTUnwrap(sessions["approval-session"])
            XCTAssertEqual(session.status, .waitingApproval)
            XCTAssertEqual(session.currentTool, "Bash")
            XCTAssertEqual(session.toolDescription, "Remove build output\nCommand:\nrm -rf .build")
        }
    }

    func testPermissionDeniedClearsWaitingApprovalState() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let request = try makeHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "approval-session",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf .build"]
        ])
        _ = reduceEvent(sessions: &sessions, event: request, maxHistory: 10)

        let denied = try makeHookEvent([
            "hook_event_name": "PermissionDenied",
            "session_id": "approval-session"
        ])
        _ = reduceEvent(sessions: &sessions, event: denied, maxHistory: 10)

        let session = try XCTUnwrap(sessions["approval-session"])
        XCTAssertEqual(session.status, .processing)
        XCTAssertNil(session.currentTool)
        XCTAssertNil(session.toolDescription)
    }

    func testUserPromptSubmitReadsPromptFromParamsContainer() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "prompt-session",
            "params": [
                "prompt": "prompt nested in params"
            ]
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        let session = try XCTUnwrap(sessions["prompt-session"])
        XCTAssertEqual(session.lastUserPrompt, "prompt nested in params")
        XCTAssertEqual(session.recentMessages.last?.text, "prompt nested in params")
    }

    func testUserPromptSubmitReadsPromptFromInputContainer() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "input-prompt-session",
            "input": [
                "prompt": "prompt nested in input"
            ]
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        let session = try XCTUnwrap(sessions["input-prompt-session"])
        XCTAssertEqual(session.lastUserPrompt, "prompt nested in input")
        XCTAssertEqual(session.recentMessages.last?.text, "prompt nested in input")
    }

    func testPostCompactClearsCompactingDescription() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let preCompact = try makeHookEvent([
            "hook_event_name": "PreCompact",
            "session_id": "compact-session"
        ])
        _ = reduceEvent(sessions: &sessions, event: preCompact, maxHistory: 10)

        XCTAssertEqual(sessions["compact-session"]?.toolDescription, "Compacting context\u{2026}")

        let postCompact = try makeHookEvent([
            "hook_event_name": "PostCompact",
            "session_id": "compact-session"
        ])
        _ = reduceEvent(sessions: &sessions, event: postCompact, maxHistory: 10)

        let session = try XCTUnwrap(sessions["compact-session"])
        XCTAssertEqual(session.status, .processing)
        XCTAssertNil(session.currentTool)
        XCTAssertNil(session.toolDescription)
    }

    func testStopReadsLegacyCodexTitleAliasAsSessionTitle() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let event = try makeHookEvent([
            "hook_event_name": "Stop",
            "session_id": "title-session",
            "codex_title": "Investigate release gate"
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["title-session"]?.sessionTitle, "Investigate release gate")
    }

    private func makeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
