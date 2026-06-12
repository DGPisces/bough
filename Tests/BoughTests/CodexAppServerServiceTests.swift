import Foundation
import XCTest
@testable import Bough
@testable import BoughCore

@MainActor
final class CodexAppServerServiceTests: XCTestCase {
    func testRateLimitReadCoalescesOverlappingRefreshes() async throws {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())

        async let first = service.readRateLimits()
        async let second = service.readRateLimits()
        await Task.yield()

        XCTAssertEqual(transport.sentRequests.map(\.method), ["account/rateLimits/read"])
        transport.deliver(responseId: .int(1), result: ["ok": .bool(true)])
        let firstResult = try await first["ok"]?.asBool
        let secondResult = try await second["ok"]?.asBool
        XCTAssertEqual(firstResult, true)
        XCTAssertEqual(secondResult, true)
    }

    func testRateLimitReadHandlesResponseDeliveredDuringSend() async throws {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        transport.onSendRequest = { transport, requestID in
            transport.deliver(responseId: requestID, result: ["ok": .bool(true)])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        let result = try await service.readRateLimits()

        XCTAssertEqual(result["ok"]?.asBool, true)
    }

    func testRateLimitReadIgnoresStaleResponseOutsideSendWindow() async throws {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())

        transport.deliver(responseId: .int(1), result: ["ok": .bool(true)])
        await Task.yield()
        let task = Task { try await service.readRateLimits() }
        await Task.yield()
        transport.deliver(responseId: .int(1), result: ["ok": .bool(false)])
        let result = try await task.value

        XCTAssertEqual(transport.sentRequests.map(\.method), ["account/rateLimits/read"])
        XCTAssertEqual(result["ok"]?.asBool, false)
    }

    func testRateLimitReadTimesOutAfterTenSeconds() async {
        let sleeper = ManualSleeper()
        let service = CodexAppServerService(transport: FakeCodexTransport(), timeoutSeconds: 10, sleeper: sleeper)
        let task = Task { try await service.readRateLimits() }
        await Task.yield()
        sleeper.complete()

        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch CodexAppServerService.Error.requestTimedOut {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
    }

    func testPendingRateLimitReadFailsOnExit() async {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        let task = Task { try await service.readRateLimits() }
        await Task.yield()
        transport.exit(status: 9)

        do {
            _ = try await task.value
            XCTFail("Expected service stop")
        } catch CodexAppServerService.Error.serviceStopped {
            XCTAssertEqual(transport.sentRequests.count, 1)
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
    }

    func testResponseFromStoppedGenerationIsIgnored() async {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        let task = Task { try await service.readRateLimits() }
        await Task.yield()
        let oldId = transport.sentRequests[0].id

        service.stop()
        transport.deliver(responseId: oldId, result: ["ok": .bool(true)])

        do {
            _ = try await task.value
            XCTFail("Expected service stop")
        } catch CodexAppServerService.Error.serviceStopped {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
    }

    func testRoutesThreadAndRateLimitNotifications() async throws {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        var threadMethods: [String] = []
        var usageMethods: [String] = []
        service.onThreadNotification = { message in
            if case .notification(let method) = message.kind {
                threadMethods.append(method)
            }
        }
        service.onRateLimitsUpdated = { message in
            if case .notification(let method) = message.kind {
                usageMethods.append(method)
            }
        }

        transport.deliver(try parse(#"{"method":"thread/status/changed","params":{}}"#))
        transport.deliver(try parse(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"#))
        await Task.yield()

        XCTAssertEqual(threadMethods, ["thread/status/changed"])
        XCTAssertEqual(usageMethods, ["account/rateLimits/updated"])
    }

    func testStoppedServiceDoesNotRouteNotifications() async throws {
        let transport = FakeCodexTransport()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        var threadMethods: [String] = []
        var usageMethods: [String] = []
        service.onThreadNotification = { message in
            if case .notification(let method) = message.kind {
                threadMethods.append(method)
            }
        }
        service.onRateLimitsUpdated = { message in
            if case .notification(let method) = message.kind {
                usageMethods.append(method)
            }
        }

        service.stop()
        transport.deliver(try parse(#"{"method":"thread/status/changed","params":{}}"#))
        transport.deliver(try parse(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"#))
        await Task.yield()

        XCTAssertEqual(threadMethods, [])
        XCTAssertEqual(usageMethods, [])
    }

    func testStartDoesNotRouteNotificationsBeforeInitializeCompletes() async throws {
        let transport = FakeCodexTransport()
        let sleeper = ManualSleeper()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: sleeper)
        var threadMethods: [String] = []
        service.onThreadNotification = { message in
            if case .notification(let method) = message.kind {
                threadMethods.append(method)
            }
        }

        try service.start(clientVersion: "dev")
        transport.deliver(try parse(#"{"method":"thread/status/changed","params":{}}"#))
        await Task.yield()
        XCTAssertEqual(threadMethods, [])

        transport.deliver(responseId: .int(0), result: [:])
        for _ in 0..<3 { await Task.yield() }
        sleeper.complete()
        transport.deliver(try parse(#"{"method":"thread/status/changed","params":{}}"#))
        await Task.yield()

        XCTAssertEqual(threadMethods, ["thread/status/changed"])
        service.stop()
    }

    func testRateLimitReadWaitsForInitializeResponse() async throws {
        let transport = FakeCodexTransport()
        let sleeper = ManualSleeper()
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: sleeper)

        try service.start(clientVersion: "dev")
        let task = Task { try await service.readRateLimits() }
        await Task.yield()
        XCTAssertEqual(transport.sentRequests.map(\.method), [])

        transport.deliver(responseId: .int(0), result: [:])
        // Deadline-based wait instead of a fixed yield count: under machine
        // load ten bare yields can elapse before the cooperative pool runs
        // the awaiting task, flaking this test (same class of fix as commit
        // 6c22513 "Make timing-sensitive tests deterministic").
        let requestDeadline = Date().addingTimeInterval(5)
        while transport.sentRequests.isEmpty && Date() < requestDeadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.sentRequests.map(\.method), ["account/rateLimits/read"])

        transport.deliver(responseId: .int(1), result: ["ok": .bool(true)])
        let result = try await task.value
        XCTAssertEqual(result["ok"]?.asBool, true)
        // Release the parked timeout sleep only AFTER the read resolved:
        // completing earlier turns the request-timeout sleep into an immediate
        // return that races the response delivery on the main actor and flakes
        // this test as requestTimedOut under load. A late wake is harmless —
        // the timeout task re-checks cancellation and the pending request.
        sleeper.complete()
        service.stop()
    }

    func testStartStopsTransportOnHandshakeFailure() {
        let transport = FakeCodexTransport()
        transport.initializeHandshakeResult = .failure(CodexAppServerServiceTestsError.handshakeFailed)
        let service = CodexAppServerService(transport: transport, timeoutSeconds: 10, sleeper: ManualSleeper())
        var didCallServiceExit = false
        service.onExit = {
            didCallServiceExit = true
        }

        do {
            try service.start(clientVersion: "dev")
            XCTFail("Expected start failure")
        } catch {
            // expected
        }

        XCTAssertEqual(transport.startCallCount, 1)
        XCTAssertEqual(transport.stopCallCount, 1)
        XCTAssertFalse(didCallServiceExit)
    }

    private func parse(_ json: String) throws -> CodexJSONRPCMessage {
        try XCTUnwrap(CodexAppServerClient.parseMessage(Data(json.utf8)))
    }
}

private final class FakeCodexTransport: CodexAppServerTransport {
    struct SentRequest { let id: CodexRequestID; let method: String }
    var onMessage: (@Sendable (CodexJSONRPCMessage) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var nextId: Int64 = 1
    private(set) var sentRequests: [SentRequest] = []
    var initializeHandshakeResult: Result<CodexRequestID, Swift.Error> = .success(.int(0))
    var onSendRequest: ((FakeCodexTransport, CodexRequestID) -> Void)?

    func start() throws {
        startCallCount += 1
    }
    func initializeHandshake(clientName: String, clientVersion: String) throws -> CodexRequestID {
        try initializeHandshakeResult.get()
    }
    func stop() {
        stopCallCount += 1
        onExit?(0)
    }
    func sendRequest(method: String, params: Any?) throws -> CodexRequestID {
        let id = CodexRequestID.int(nextId)
        nextId += 1
        sentRequests.append(SentRequest(id: id, method: method))
        onSendRequest?(self, id)
        return id
    }
    func deliver(_ message: CodexJSONRPCMessage) { onMessage?(message) }
    func deliver(responseId: CodexRequestID, result: [String: AnyCodableLike]) {
        onMessage?(CodexJSONRPCMessage(raw: ["id": responseId.anyCodable, "result": .object(result)], kind: .response(id: responseId)))
    }
    func exit(status: Int32) { onExit?(status) }
}

private enum CodexAppServerServiceTestsError: Error {
    case handshakeFailed
}

/// Parks every sleep until `complete()` is called. Stores ALL parked
/// continuations: a single-continuation version dropped the first parked
/// sleep when a second one arrived (e.g. the initialization-timeout sleep
/// and a request-timeout sleep parked at once), leaking a CheckedContinuation
/// ("SWIFT TASK CONTINUATION MISUSE" warnings, observed pointer-auth crash).
private final class ManualSleeper: CodexAppServerSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isComplete = false

    func sleep(seconds: TimeInterval) async {
        _ = seconds
        let shouldPark: Bool = {
            lock.lock(); defer { lock.unlock() }
            return !isComplete
        }()
        guard shouldPark else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func complete() {
        lock.lock()
        isComplete = true
        let parked = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in parked { continuation.resume() }
    }
}

private extension CodexRequestID {
    var anyCodable: AnyCodableLike {
        switch self {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }
}
