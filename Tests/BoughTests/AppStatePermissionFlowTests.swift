import XCTest
@testable import Bough
import BoughCore

@MainActor
final class AppStatePermissionFlowTests: XCTestCase {

    func testDismissPermissionSkipsAlreadyDismissedSessions() async throws {
        let appState = AppState()

        let eventA = try makePermissionRequestEvent(sessionId: "s1", toolName: "Bash")
        let eventB = try makePermissionRequestEvent(sessionId: "s2", toolName: "Read")

        let responseTaskA = await startPermissionRequest(eventA, in: appState)
        let responseTaskB = await startPermissionRequest(eventB, in: appState)

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s1"))

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s2"))
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 2)

        await assertTaskNotResolved(responseTaskA)
        await assertTaskNotResolved(responseTaskB)

        appState.handlePeerDisconnect(sessionId: "s1")
        appState.handlePeerDisconnect(sessionId: "s2")

        let responseA = await responseTaskA.value
        let responseB = await responseTaskB.value

        XCTAssertEqual(try extractPermissionBehavior(from: responseA), "deny")
        XCTAssertEqual(try extractPermissionBehavior(from: responseB), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testDismissSinglePermissionCollapsesAndKeepsPending() async throws {
        let appState = AppState()
        let sessionId = "s-single"
        let event = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Bash")

        let responseTask = await startPermissionRequest(event, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertNil(appState.pendingPermission)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        await assertTaskNotResolved(responseTask)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
    }

    func testNewPermissionAfterDismissedPermissionBecomesCurrentApprovalTarget() async throws {
        let appState = AppState()
        let firstEvent = try makePermissionRequestEvent(
            sessionId: "s-hidden",
            toolName: "Bash",
            toolUseId: "toolu_hidden"
        )

        let firstTask = await startPermissionRequest(firstEvent, in: appState)
        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertNil(appState.pendingPermission)

        let secondEvent = try makePermissionRequestEvent(
            sessionId: "s-visible",
            toolName: "Read",
            toolUseId: "toolu_visible"
        )
        let secondTask = await startPermissionRequest(secondEvent, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-visible"))
        XCTAssertEqual(appState.pendingPermission?.toolUseId, "toolu_visible")

        appState.approvePermission()

        let secondResponse = await secondTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: secondResponse), "allow")
        await assertTaskNotResolved(firstTask)

        appState.handlePeerDisconnect(sessionId: "s-hidden")
        let firstResponse = await firstTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: firstResponse), "deny")
    }

    func testDismissPermissionShowsNextRequestFromSameSession() async throws {
        let appState = AppState()
        let sessionId = "s-same"
        let firstEvent = try makePermissionRequestEvent(
            sessionId: sessionId,
            toolName: "Bash",
            toolUseId: "toolu_first"
        )
        let secondEvent = try makePermissionRequestEvent(
            sessionId: sessionId,
            toolName: "Read",
            toolUseId: "toolu_second"
        )

        let firstTask = await startPermissionRequest(firstEvent, in: appState)
        let secondTask = await startPermissionRequest(secondEvent, in: appState)

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_first")

        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_second")
        XCTAssertEqual(appState.pendingPermission?.toolUseId, "toolu_second")
        await assertTaskNotResolved(firstTask)
        await assertTaskNotResolved(secondTask)

        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: secondResponse), "allow")

        appState.handlePeerDisconnect(sessionId: sessionId)
        let firstResponse = await firstTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: firstResponse), "deny")
    }

    func testPeerDisconnectDrainsNilSessionPermissionAsDefaultSession() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: nil, toolName: "Bash")

        let responseTask = await startPermissionRequest(event, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "default"))
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: "default")

        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPeerDisconnectDrainsNilSessionQuestionAsDefaultSession() async throws {
        let appState = AppState()
        let event = try makeQuestionEvent(sessionId: nil)

        let responseTask = await startQueuedQuestionRequest(event, in: appState)

        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: "default")

        _ = await responseTask.value
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testDismissLastPermissionShowsQueuedQuestion() async throws {
        let appState = AppState()
        let permissionSession = "s-permission"
        let questionSession = "s-question"
        let permissionEvent = try makePermissionRequestEvent(sessionId: permissionSession, toolName: "Bash")
        let questionEvent = try makeQuestionEvent(sessionId: questionSession)

        let permissionTask = await startPermissionRequest(permissionEvent, in: appState)
        let questionTask = await startQueuedQuestionRequest(questionEvent, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: permissionSession))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .questionCard(sessionId: questionSession))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue.count, 1)
        await assertTaskNotResolved(permissionTask)

        appState.skipQuestion()
        _ = await questionTask.value

        appState.handlePeerDisconnect(sessionId: permissionSession)
        let permissionResponse = await permissionTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: permissionResponse), "deny")
    }

    func testQuestionHandlerDoesNotStealVisibleApprovalCard() async throws {
        let appState = AppState()
        let permissionSession = "s-visible-approval"
        let questionSession = "s-new-question"
        let permissionEvent = try makePermissionRequestEvent(sessionId: permissionSession, toolName: "Bash")
        let questionEvent = try makeQuestionEvent(sessionId: questionSession)

        let permissionTask = await startPermissionRequest(permissionEvent, in: appState)
        let questionTask = await startQuestionRequest(questionEvent, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: permissionSession))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.denyPermission()
        let permissionResponse = await permissionTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: permissionResponse), "deny")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: questionSession))

        appState.skipQuestion()
        _ = await questionTask.value
    }

    func testWaitingQuestionStatusStaysWhileSameSessionPermissionIsPending() async throws {
        let appState = AppState()
        let sessionId = "s-waiting-question-with-permission"
        let permissionEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Bash")
        let permissionTask = await startPermissionRequest(permissionEvent, in: appState)
        appState.sessions[sessionId]?.status = .waitingQuestion

        appState.handleEvent(try makeGenericEvent(sessionId: sessionId, eventName: "PostToolUse"))

        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingQuestion)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let response = await permissionTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
    }

    func testDismissedSessionGetsShownAgainWhenNewPermissionArrivesAfterDrain() async throws {
        let appState = AppState()
        let sessionId = "s-reappear"

        let firstEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Edit")
        let firstResponseTask = await startPermissionRequest(firstEvent, in: appState)
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let firstResponse = await firstResponseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)

        let secondEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Write")
        let secondResponseTask = await startPermissionRequest(secondEvent, in: appState)

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()

        let secondResponse = await secondResponseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: secondResponse), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    // MARK: - Helpers

    private func makePermissionRequestEvent(
        sessionId: String?,
        toolName: String,
        toolUseId: String? = nil,
        toolInput: [String: Any] = ["command": "echo test"]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "tool_name": toolName,
            "tool_input": toolInput
        ]
        if let sessionId { payload["session_id"] = sessionId }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 1)
        }
        return event
    }

    private func makeQuestionEvent(sessionId: String?) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "Notification",
            "question": "Continue?",
            "options": ["Yes", "No"]
        ]
        if let sessionId { payload["session_id"] = sessionId }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 2)
        }
        return event
    }

    private func makeGenericEvent(sessionId: String, eventName: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": eventName,
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": "echo done"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 3)
        }
        return event
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func startPermissionRequest(_ event: HookEvent, in appState: AppState) async -> Task<Data, Never> {
        let exp = expectation(description: "permission request should be enqueued")
        let task = Task<Data, Never> { @MainActor in
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
                exp.fulfill()
            }
        }

        await fulfillment(of: [exp], timeout: 1.0)
        return task
    }

    private func startQueuedQuestionRequest(_ event: HookEvent, in appState: AppState) async -> Task<Data, Never> {
        let exp = expectation(description: "question request should be enqueued")
        let task = Task<Data, Never> { @MainActor in
            await withCheckedContinuation { continuation in
                appState.questionQueue.append(QuestionRequest(
                    event: event,
                    question: QuestionPayload(question: "Continue?", options: ["Yes", "No"]),
                    continuation: continuation
                ))
                exp.fulfill()
            }
        }

        await fulfillment(of: [exp], timeout: 1.0)
        return task
    }

    private func startQuestionRequest(_ event: HookEvent, in appState: AppState) async -> Task<Data, Never> {
        let exp = expectation(description: "question request should be handled")
        let task = Task<Data, Never> { @MainActor in
            await withCheckedContinuation { continuation in
                appState.handleQuestion(event, continuation: continuation)
                exp.fulfill()
            }
        }

        await fulfillment(of: [exp], timeout: 1.0)
        return task
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
