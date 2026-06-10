import XCTest

final class PiExtensionSecurityTests: XCTestCase {
    func testDangerousBashPermissionPathFailsClosedAndStripsShellQuotes() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-pi.ts")

        XCTAssertTrue(source.contains("function stripShellQuotes"))
        XCTAssertTrue(source.contains(".map(stripShellQuotes)"))
        XCTAssertTrue(source.contains(#"behavior?.behavior !== "allow""#))
        XCTAssertTrue(source.contains("Bough is unavailable for permission review"))
    }

    func testPiExtensionWaitsForAckAndLongBlockingApproval() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-pi.ts")

        XCTAssertTrue(source.contains(#"sock.on("end", () => finish(true))"#))
        XCTAssertTrue(source.contains("timeoutMs = 86_400_000"))
    }

    func testOpenCodePluginWaitsForAckAndLongBlockingApproval() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-opencode.js")

        XCTAssertTrue(source.contains(#"sock.on("end", () => finish(true))"#))
        XCTAssertTrue(source.contains("timeoutMs = 86400000"))
    }

    func testOpenCodePluginRestoresMultiSelectAnswerArrays() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-opencode.js")

        XCTAssertTrue(source.contains("questionMeta[index]?.multiSelect"))
        XCTAssertTrue(source.contains("answerKey: q.answerKey || q.header"))
        XCTAssertFalse(source.contains(#"split(/\s*,\s*/)"#))
        XCTAssertTrue(source.contains("decision?.updatedInput?.answerValues"))
        XCTAssertFalse(source.contains("Object.values(answers)"))
    }

    func testOpenCodePermissionRepliesCarryToolUseIdForQueueCleanup() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-opencode.js")

        XCTAssertTrue(source.contains("tool_use_id: p.id, _opencode_request_id: p.id"))
        XCTAssertTrue(source.contains(#"t === "permission.replied" && p.id && p.sessionID"#))
        XCTAssertTrue(source.contains(#"t === "question.replied" || t === "question.rejected") && p.id && p.sessionID"#))
    }

    func testOpenCodePluginMapsFailedToolsAndFailsClosedWhenBoughUnavailable() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-opencode.js")

        XCTAssertTrue(source.contains(#"if (st === "error")"#))
        XCTAssertTrue(source.contains(#"hook_event_name: "PostToolUseFailure""#))
        XCTAssertTrue(source.contains(#"await replyPermission(requestId, "reject", "Bough is unavailable for permission review")"#))
        XCTAssertTrue(source.contains("await rejectQuestion(requestId);"))
    }

    func testOpenCodeAndPiUseSessionTitleField() throws {
        let opencode = try readRepoFile("Sources/Bough/Resources/bough-opencode.js")
        let pi = try readRepoFile("Sources/Bough/Resources/bough-pi.ts")

        XCTAssertTrue(opencode.contains("extra.session_title = s.pendingTitle"))
        XCTAssertTrue(pi.contains("{ session_title: sessionName }"))
        XCTAssertFalse(opencode.contains("extra.codex_title = s.pendingTitle"))
        XCTAssertFalse(pi.contains("{ codex_title: sessionName }"))
    }

    func testPiToolEventsCarryStandardToolUseId() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-pi.ts")

        XCTAssertTrue(source.contains("const toolUseId = event.toolCallId"))
        XCTAssertTrue(source.contains("tool_use_id: toolUseId"))
        XCTAssertTrue(source.contains("tool_use_id: event.toolCallId"))
    }

    private func readRepoFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: TestHelpers.repoRoot(from: #filePath)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
