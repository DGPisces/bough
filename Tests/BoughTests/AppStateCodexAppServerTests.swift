import XCTest
@testable import Bough
@testable import BoughCore

@MainActor
final class AppStateCodexAppServerTests: XCTestCase {

    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToRunningAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdle() {
        var s1 = SessionSnapshot()
        s1.status = .running
        AppState.applyCodexThreadStatus(&s1, status: ["type": .string("notLoaded")])
        XCTAssertEqual(s1.status, .idle)

        var s2 = SessionSnapshot()
        s2.status = .running
        AppState.applyCodexThreadStatus(&s2, status: ["type": .string("systemError")])
        XCTAssertEqual(s2.status, .idle)
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        AppState.applyCodexThreadStatus(&snapshot, status: nil)
        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        // Codex can theoretically emit both flags at once; approval is strictly
        // more actionable, so we should route to .waitingApproval.
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testUsageNotificationRoutesToUsageStore() async throws {
        let state = AppState()
        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        let service = try! XCTUnwrap(state.codexAppServerService)
        XCTAssertNotNil(service.onRateLimitsUpdated)
        let notificationExpectation = expectation(description: "usage notification callback receives route")
        var observedMessage = false
        let priorRateLimitHandler = service.onRateLimitsUpdated
        service.onRateLimitsUpdated = { message in
            observedMessage = true
            priorRateLimitHandler?(message)
            notificationExpectation.fulfill()
        }

        let message = try parse(
            #"{"method":"account/rateLimits/updated","params":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000000},"planType":"prolite"}}}}"#
        )
        XCTAssertNotNil(CodexRateLimitParser.parse(message: message, receivedAt: Date()))

        transport.deliver(message)
        await Task.yield()
        await Task.yield()
        await fulfillment(of: [notificationExpectation], timeout: 1)
        await Task.yield()
        for _ in 0..<10 {
            if observedMessage { break }
            await Task.yield()
        }

        XCTAssertTrue(observedMessage)

        let snapshot = state.usageStore.snapshot(for: .codex)
        XCTAssertEqual(snapshot.fiveHour.availableOrStaleSnapshot?.usedPercent, 10)
        XCTAssertEqual(snapshot.weekly.availableOrStaleSnapshot?.usedPercent, 20)
        XCTAssertEqual(snapshot.availability, .available)

        state.stopCodexAppServerClientForTesting()
    }

    func testServiceExitRemovesCodexAppServerSessionsAndStopsUsageLoop() async {
        let state = AppState()
        var codexSession = SessionSnapshot(startTime: Date())
        codexSession.source = AppState.codexAppBundleId
        state.sessions["codexapp:thread-1"] = codexSession
        state.sessions["other:thread"] = SessionSnapshot(startTime: Date())

        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()
        let service = try! XCTUnwrap(state.codexAppServerService)
        let exitExpectation = expectation(description: "service exit callback invoked")
        let priorOnExit = service.onExit
        var callbackCount = 0
        service.onExit = {
            callbackCount += 1
            exitExpectation.fulfill()
            priorOnExit?()
        }

        transport.exit(status: 0)
        await fulfillment(of: [exitExpectation], timeout: 1)

        XCTAssertNil(state.codexAppServerService)
        XCTAssertNil(state.sessions["codexapp:thread-1"])
        XCTAssertNotNil(state.sessions["other:thread"])
        XCTAssertEqual(state.usageStore.snapshot(for: .codex).availability, .unavailable(reason: "Codex app-server unavailable"))
        XCTAssertEqual(callbackCount, 1)

        state.stopCodexAppServerClientForTesting()
        XCTAssertNil(state.codexAppServerService)
        XCTAssertEqual(state.usageStore.snapshot(for: .codex).availability, .unavailable(reason: "Codex app-server unavailable"))
        XCTAssertNotNil(state.sessions["other:thread"])
    }

    func testServiceReleaseAfterExit() async {
        let state = AppState()
        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        weak var weakService: CodexAppServerService?
        weakService = state.codexAppServerService
        XCTAssertNotNil(weakService)

        transport.exit(status: 0)
        await Task.yield()
        for _ in 0..<20 {
            if weakService == nil { break }
            await Task.yield()
        }

        XCTAssertNil(weakService)
    }

    func testOldServiceExitCannotClearNewService() async {
        let state = AppState()
        let firstTransport = FakeCodexAppServerTransport(fireExitOnStop: false)
        let secondTransport = FakeCodexAppServerTransport()
        var transportCallIndex = 0
        state.codexAppServerTransportFactory = { _ in
            defer { transportCallIndex += 1 }
            return transportCallIndex == 0 ? firstTransport : secondTransport
        }
        state.codexAppServerExecutablePath = "/bin/echo"

        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()
        _ = try! XCTUnwrap(state.codexAppServerService)

        // Force a realistic restart after the first service has become stale.
        state.codexAppServerService = nil
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        let secondService = try! XCTUnwrap(state.codexAppServerService)
        firstTransport.exit(status: 0)
        await Task.yield()

        XCTAssert(state.codexAppServerService === secondService)
    }

    func testThreadStartedSelectsActiveCodexSessionAndRefreshesCounts() async throws {
        let state = AppState()
        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        transport.deliver(CodexJSONRPCMessage(
            raw: [
                "params": .object([
                    "thread": .object([
                        "id": .string("thread-active"),
                        "cwd": .string("/tmp/bough-active"),
                        "status": .object([
                            "type": .string("active"),
                            "activeFlags": .array([])
                        ])
                    ])
                ])
            ],
            kind: .notification(method: "thread/started")
        ))
        for _ in 0..<20 {
            if state.activeSessionId == "codexapp:thread-active" {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(state.activeSessionId, "codexapp:thread-active")
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.totalSessionCount, 1)
    }

    func testThreadStatusChangedMovesActiveSelectionAwayFromIdleThread() async throws {
        let state = AppState()
        var other = SessionSnapshot(startTime: Date())
        other.status = .running
        other.lastActivity = Date(timeIntervalSinceNow: -10)
        state.sessions["local:running"] = other

        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        transport.deliver(CodexJSONRPCMessage(
            raw: [
                "params": .object([
                    "thread": .object([
                        "id": .string("thread-idle"),
                        "status": .object([
                            "type": .string("active"),
                            "activeFlags": .array([])
                        ])
                    ])
                ])
            ],
            kind: .notification(method: "thread/started")
        ))
        for _ in 0..<20 {
            if state.activeSessionId == "codexapp:thread-idle" {
                break
            }
            await Task.yield()
        }

        transport.deliver(CodexJSONRPCMessage(
            raw: [
                "params": .object([
                    "threadId": .string("thread-idle"),
                    "status": .object([
                        "type": .string("idle")
                    ])
                ])
            ],
            kind: .notification(method: "thread/status/changed")
        ))
        for _ in 0..<20 {
            if state.activeSessionId == "local:running" {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(state.activeSessionId, "local:running")
        XCTAssertEqual(state.sessions["codexapp:thread-idle"]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.totalSessionCount, 2)
    }

    func testCodexSessionCleanupUsesSessionTeardown() async throws {
        let state = AppState()
        state.sessions["local:1"] = {
            var snapshot = SessionSnapshot(startTime: Date())
            snapshot.status = .running
            snapshot.lastActivity = Date(timeIntervalSinceNow: -60)
            return snapshot
        }()
        state.activeSessionId = "codexapp:thread-removed"

        let transport = FakeCodexAppServerTransport()
        state.codexAppServerTransportFactory = { _ in transport }
        state.codexAppServerExecutablePath = "/bin/echo"
        state.startCodexAppServerClientIfPossibleForTesting()
        await Task.yield()

        let message = CodexJSONRPCMessage(
            raw: [
                "params": .object([
                    "thread": .object([
                        "id": .string("thread-removed"),
                        "path": .string("/tmp/codex-thread.json"),
                        "status": .object([
                            "type": .string("active"),
                            "activeFlags": .array([])
                        ])
                    ])
                ])
            ],
            kind: .notification(method: "thread/started")
        )
        transport.deliver(message)
        for _ in 0..<20 {
            if state.sessions["codexapp:thread-removed"] != nil {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(state.sessions["codexapp:thread-removed"]?.transcriptPath, "/tmp/codex-thread.json")
        XCTAssertEqual(state.attachedTranscriptPaths["codexapp:thread-removed"], "/tmp/codex-thread.json")
        XCTAssertEqual(state.activeSessionId, "codexapp:thread-removed")

        transport.exit(status: 0)
        await Task.yield()
        for _ in 0..<20 {
            if state.sessions["codexapp:thread-removed"] == nil {
                break
            }
            await Task.yield()
        }

        XCTAssertNil(state.sessions["codexapp:thread-removed"])
        XCTAssertNil(state.attachedTranscriptPaths["codexapp:thread-removed"])
        XCTAssertEqual(state.activeSessionId, "local:1")
    }

    func testMissingExecutableStartsUsageRefreshLoopWithNilReader() {
        let state = AppState()
        state.codexAppServerExecutablePath = "/tmp/\(UUID().uuidString)"
        state.startCodexAppServerClientIfPossibleForTesting()

        XCTAssertNil(state.codexAppServerService)
        XCTAssertEqual(state.usageStore.snapshot(for: .codex).availability, .unavailable(reason: "Codex app-server unavailable"))
    }

    func testWatcherMarksCodexUnavailableWhenCodexIsNotRunningAtStartup() {
        let state = AppState()
        state.codexAppServerRunningApplicationProvider = { false }
        state.startCodexAppServerWatcher()

        XCTAssertNil(state.codexAppServerService)
        XCTAssertEqual(state.usageStore.snapshot(for: .codex).availability, .unavailable(reason: "Codex app-server unavailable"))

        state.stopCodexAppServerWatcher()
    }

    func testWatcherDoesNotStartWhenCodingSessionsDisabled() {
        let state = AppState()
        state.codingSessionsEnabledProvider = { false }
        state.codexAppServerRunningApplicationProvider = { true }
        state.codexAppServerExecutablePath = "/bin/echo"

        state.startCodexAppServerWatcher()

        XCTAssertNil(state.codexAppServerObservers)
        XCTAssertNil(state.codexAppServerService)
        XCTAssertNil(state.usageStore.snapshots[.codex])
    }

    private func parse(_ json: String) throws -> CodexJSONRPCMessage {
        try XCTUnwrap(CodexAppServerClient.parseMessage(Data(json.utf8)))
    }
}

private final class FakeCodexAppServerTransport: CodexAppServerTransport {
    var onMessage: (@Sendable (CodexJSONRPCMessage) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    let fireExitOnStop: Bool
    private var nextId: Int64 = 1
    private(set) var stopCallCount = 0

    init(fireExitOnStop: Bool = true) {
        self.fireExitOnStop = fireExitOnStop
    }

    func start() throws {}
    func stop() {
        stopCallCount += 1
        if fireExitOnStop {
            onExit?(0)
        }
    }
    func initializeHandshake(clientName: String, clientVersion: String) throws -> CodexRequestID { .int(0) }
    func sendRequest(method: String, params: Any?) throws -> CodexRequestID {
        defer { nextId += 1 }
        return .int(nextId)
    }
    func deliver(_ message: CodexJSONRPCMessage) { onMessage?(message) }
    func exit(status: Int32) { onExit?(status) }
}

private extension UsageWindowSlot {
    var availableOrStaleSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        default:
            return nil
        }
    }
}
