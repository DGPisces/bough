import XCTest
@testable import Bough
import BoughCore

@MainActor
final class AppStateToolUseCacheTests: XCTestCase {

    // MARK: - Cache lifecycle

    func testPreToolUseCachesRecord() throws {
        let appState = AppState()
        let event = try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_1",
            toolInput: ["command": "ls"]
        )

        appState.handleEvent(event)

        let cached = try XCTUnwrap(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
        XCTAssertEqual(cached.sessionId, "s1")
        XCTAssertEqual(cached.toolName, "Bash")
    }

    func testPostToolUseClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))
        XCTAssertNotNil(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "toolu_1")])

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
    }

    func testPostToolUseFailureAlsoClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        appState.handleEvent(try makeHookEvent(name: "PostToolUseFailure", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "toolu_1")])
    }

    func testPruneRemovesExpiredRecords() throws {
        let appState = AppState()
        appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "ancient")] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date(timeIntervalSinceNow: -(AppState.pendingToolUseTTL + 60))
        )
        appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "fresh")] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        appState.prunePendingToolUses()

        XCTAssertNil(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "ancient")])
        XCTAssertNotNil(appState.pendingToolUses[toolUseKey(sessionId: "s1", toolUseId: "fresh")])
    }

    // MARK: - Duplicate PermissionRequest replay

    func testDuplicatePermissionRequestReplacesContinuationAndDeniesOld() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")
        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }

        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }

        // The old continuation should be denied immediately; queue length stays 1.
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Second (replacement) continuation still waits for user decision.
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    func testSameToolUseIdDifferentSessionDoesNotMergePermissionRequests() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "shared")
        let second = try makePermissionEvent(sessionId: "s2", toolName: "Bash", toolUseId: "shared")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 2 }
        await assertTaskNotResolved(firstTask)
        await assertTaskNotResolved(secondTask)

        appState.approvePermission()
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "allow")
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    // MARK: - Stale queue drain via PostToolUse

    func testPostToolUseDrainsQueuedPermissionForSameId() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_drain")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }

        // Agent moved on — emits PostToolUse for the same tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_drain"
        ))

        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPostToolUseDrainClearsDismissedPermissionId() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_redismiss")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }
        appState.dismissPermissionPrompt()
        XCTAssertNil(appState.activePermissionQueueIndex)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_redismiss"
        ))
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "deny")

        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_redismiss")
        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.activePermissionQueueIndex == 0 }
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    func testPostToolUseDoesNotAffectUnrelatedQueueEntries() async throws {
        let appState = AppState()
        let kept = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "keep_me")
        let drained = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "drop_me")

        let keptTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(kept, continuation: cont)
            }
        }
        let drainedTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(drained, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 2 }

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "drop_me"
        ))

        let drainedResponse = await drainedTask.value
        XCTAssertEqual(try behavior(drainedResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "keep_me")

        appState.approvePermission()
        let keptResponse = await keptTask.value
        XCTAssertEqual(try behavior(keptResponse), "allow")
    }

    func testPostToolUseDoesNotDrainSameToolUseIdFromDifferentSession() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s2", toolName: "Bash", toolUseId: "shared_drain")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "shared_drain"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1)
        await assertTaskNotResolved(responseTask)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
    }

    func testDismissedPermissionIdIsScopedBySession() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "shared_dismiss")
        let second = try makePermissionEvent(sessionId: "s2", toolName: "Bash", toolUseId: "shared_dismiss")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }
        appState.dismissPermissionPrompt()
        XCTAssertNil(appState.activePermissionQueueIndex)

        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.activePermissionQueueIndex == 0 }
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "shared_dismiss"
        ))
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "deny")
    }

    // MARK: - issue #147 regression: parallel/plugin tool calls must not deny pending permissions

    /// Repro for #147: a Stop (or any non-keepWaiting activity event) arriving
    /// while a PermissionRequest is pending used to trigger a wasWaiting blanket
    /// drain that denied the queued request before the user could react.
    /// After the fix, only surgical (tool_use_id) drains may remove a queued
    /// permission — unrelated activity events leave the queue alone.
    func testStopEventDoesNotDenyPendingPermission() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval)

        // Activity event for the same session that carries no tool_use_id.
        // Pre-fix this would blanket-drain the pending permission via the
        // wasWaiting branch in handleEvent.
        appState.handleEvent(try makeHookEvent(
            name: "Stop",
            sessionId: "s1",
            toolName: nil,
            toolUseId: nil
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1, "Stop must not deny a pending PermissionRequest with a different/absent tool_use_id (#147)")
        await assertTaskNotResolved(responseTask)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
    }

    /// Repro for #147 with parallel tools: Notion / MCP plugin invokes two
    /// fetches at once. The first PostToolUse arrives (its PreToolUse was never
    /// cached, so `resolveToolUseIfCompleted` finds nothing to drain) while the
    /// second tool's PermissionRequest is still pending. Pre-fix, the blanket
    /// drain would deny the pending second request; the UI flashed a card and
    /// users saw "denied by PermissionRequest hook" before they could react.
    func testParallelPostToolUseDoesNotDenyUnrelatedPendingPermission() async throws {
        let appState = AppState()
        let pendingForToolB = try makePermissionEvent(
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: "toolu_B"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pendingForToolB, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }

        // Tool A finishes — PostToolUse arrives with a tool_use_id that was
        // never in the queue (and never cached, since we skipped its PreToolUse
        // for this scenario). resolveToolUseIfCompleted removes nothing.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: "toolu_A"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Unrelated PostToolUse must not deny pending PermissionRequest for parallel tool (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_B")
        await assertTaskNotResolved(responseTask)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
    }

    func testTraePostToolUseKeepsQueuedPermissionUntilUserResponds() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_trae",
            source: "traecli"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_trae",
            source: "traecli"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1)
        await assertTaskNotResolved(responseTask)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
    }

    // MARK: - Backfill from cache

    func testEnrichBackfillsMissingToolNameFromCache() async throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_enrich",
            toolInput: ["command": "ls"]
        ))

        // PermissionRequest payload omits tool_name (simulates a thin third-party re-emit).
        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_enrich"
        ])

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(thin, continuation: cont)
            }
        }

        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }
        let session = appState.sessions["s1"]
        XCTAssertEqual(session?.currentTool, "Bash")
        appState.approvePermission()
        _ = await responseTask.value
    }

    func testAlwaysApprovalUsesEnrichedToolNameFromCache() async throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_always",
            toolInput: ["command": "ls"]
        ))

        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_always"
        ])

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(thin, continuation: cont)
            }
        }

        try await TestHelpers.waitUntil { appState.permissionQueue.count == 1 }
        appState.approvePermission(always: true)
        let response = await responseTask.value
        XCTAssertEqual(try alwaysRuleToolName(response), "Bash")
    }

    // MARK: - Helpers

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String?,
        toolUseId: String?,
        toolInput: [String: Any]? = nil,
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        if let source { payload["_source"] = source }
        return try makeRawHookEvent(payload)
    }

    private func makePermissionEvent(sessionId: String, toolName: String, toolUseId: String, source: String? = nil) throws -> HookEvent {
        try makeHookEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: ["command": "echo hi"],
            source: source
        )
    }

    private func makeRawHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "AppStateToolUseCacheTests", code: 1)
        }
        return event
    }

    private func toolUseKey(sessionId: String, toolUseId: String, source: String? = nil) -> ToolUseKey {
        var payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": sessionId,
            "tool_use_id": toolUseId
        ]
        if let source { payload["_source"] = source }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return ToolUseKey(event: HookEvent(from: data)!)!
    }

    private func behavior(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func alwaysRuleToolName(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        let updatedPermissions = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let firstUpdate = try XCTUnwrap(updatedPermissions.first)
        let rules = try XCTUnwrap(firstUpdate["rules"] as? [[String: Any]])
        let firstRule = try XCTUnwrap(rules.first)
        return try XCTUnwrap(firstRule["toolName"] as? String)
    }

    private func assertTaskNotResolved(_ task: Task<Data, Never>, timeout: TimeInterval = 0.05) async {
        let exp = expectation(description: "task should stay pending")
        exp.isInverted = true

        Task {
            _ = await task.value
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: timeout)
    }
}
