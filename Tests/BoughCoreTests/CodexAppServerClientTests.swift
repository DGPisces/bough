import XCTest
@testable import BoughCore

final class CodexAppServerClientTests: XCTestCase {

    // MARK: - lifecycle cleanup

    func testRepeatedStopDoesNotLeakFileDescriptors() throws {
        let baseline = try openFileDescriptorCount()

        for index in 0..<25 {
            let client = CodexAppServerClient(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                callbackQueue: DispatchQueue(label: "dev.dgpisces.bough.codex-client-test-stop-loop-\(index)")
            )

            try client.start()
            client.stop()
        }

        try assertOpenFileDescriptorCountSettles(atMost: baseline + 8)
    }

    func testRepeatedProcessExitDoesNotLeakFileDescriptors() throws {
        let baseline = try openFileDescriptorCount()

        for index in 0..<25 {
            let exitExpectation = expectation(description: "process \(index) exits")
            let client = CodexAppServerClient(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                callbackQueue: DispatchQueue(label: "dev.dgpisces.bough.codex-client-test-exit-loop-\(index)")
            )
            client.onExit = { _ in exitExpectation.fulfill() }

            try client.start()
            wait(for: [exitExpectation], timeout: 2)
        }

        try assertOpenFileDescriptorCountSettles(atMost: baseline + 8)
    }

    func testStopDoesNotCallExitHandler() throws {
        let exitExpectation = expectation(description: "explicit stop suppresses exit callback")
        exitExpectation.isInverted = true
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            callbackQueue: DispatchQueue(label: "dev.dgpisces.bough.codex-client-test-stop-exit")
        )
        client.onExit = { _ in exitExpectation.fulfill() }

        try client.start()
        client.stop()

        wait(for: [exitExpectation], timeout: 0.2)
    }

    func testStopClearsOutputReadabilityHandlers() throws {
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            callbackQueue: DispatchQueue(label: "dev.dgpisces.bough.codex-client-test-stop")
        )

        try client.start()
        XCTAssertEqual(client.activeReadabilityHandlerCountForTesting, 2)

        client.stop()

        XCTAssertEqual(client.activeReadabilityHandlerCountForTesting, 0)
        XCTAssertFalse(client.isRunning)
    }

    func testProcessExitClearsOutputReadabilityHandlers() throws {
        let exitExpectation = expectation(description: "process exits")
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            callbackQueue: DispatchQueue(label: "dev.dgpisces.bough.codex-client-test-exit")
        )
        client.onExit = { _ in exitExpectation.fulfill() }

        try client.start()
        wait(for: [exitExpectation], timeout: 2)

        XCTAssertEqual(client.activeReadabilityHandlerCountForTesting, 0)
        XCTAssertFalse(client.isRunning)
    }

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default
            .contentsOfDirectory(atPath: "/dev/fd")
            .compactMap(Int.init)
            .count
    }

    private func assertOpenFileDescriptorCountSettles(
        atMost maxCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(1)
        var count = try openFileDescriptorCount()
        while count > maxCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            count = try openFileDescriptorCount()
        }
        XCTAssertLessThanOrEqual(count, maxCount, file: file, line: line)
    }

    // MARK: - drainMessages

    func testDrainMessagesEmptyBuffer() {
        var buffer = Data()
        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesSingleCompleteLine() {
        var buffer = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1"}}}"#.utf8)
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.kind, .notification(method: "thread/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesTwoLinesConsumedBothLeavesBufferEmpty() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].kind, .notification(method: "thread/started"))
        XCTAssertEqual(messages[1].kind, .notification(method: "turn/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesKeepsTrailingPartialLineInBuffer() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/partial"#.utf8))

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(String(data: buffer, encoding: .utf8), #"{"jsonrpc":"2.0","method":"turn/partial"#)
    }

    func testDrainMessagesSkipsBlankLines() {
        var buffer = Data()
        buffer.append(0x0A)
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: - parseMessage kind detection

    func testParseMessageClassifiesRequest() {
        let data = Data(#"{"jsonrpc":"2.0","id":42,"method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .int(42)))
    }

    func testParseMessageClassifiesNotification() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .notification(method: "thread/started"))
    }

    func testParseMessageClassifiesResponse() {
        let data = Data(#"{"id":7,"result":{"ok":true}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .response(id: .int(7)))
    }

    func testParseMessageClassifiesError() {
        let data = Data(#"{"id":7,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .error(id: .int(7), code: -32601, message: "Method not found"))
    }

    func testParseMessageHandlesStringId() {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc-1","method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .string("abc-1")))
    }

    func testParseMessageRejectsInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertNil(CodexAppServerClient.parseMessage(data))
    }

    func testParseMessagePreservesRawParams() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1","preview":"hi"}}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        let params = msg?.raw["params"]?.asObject
        let thread = params?["thread"]?.asObject
        XCTAssertEqual(thread?["id"]?.asString, "t-1")
        XCTAssertEqual(thread?["preview"]?.asString, "hi")
    }

    // MARK: - AnyCodableLike

    func testAnyCodableLikeRoundTripsPrimitives() {
        XCTAssertEqual(AnyCodableLike.from(nil), .null)
        XCTAssertEqual(AnyCodableLike.from(NSNull()), .null)
        XCTAssertEqual(AnyCodableLike.from(true), .bool(true))
        XCTAssertEqual(AnyCodableLike.from(0), .int(0))
        XCTAssertEqual(AnyCodableLike.from(42), .int(42))
        XCTAssertEqual(AnyCodableLike.from("hi"), .string("hi"))

        // Floats end up as .double (bridged through NSNumber's float-check logic).
        if case .double(let value) = AnyCodableLike.from(3.14) {
            XCTAssertEqual(value, 3.14, accuracy: 0.0001)
        } else {
            XCTFail("expected .double for 3.14")
        }
    }

    func testAnyCodableLikeHandlesNestedObject() {
        let obj: [String: Any] = [
            "k1": "v1",
            "k2": 2,
            "k3": [1, 2, 3],
            "k4": ["inner": true]
        ]
        let wrapped = AnyCodableLike.from(obj)
        let dict = wrapped.asObject
        XCTAssertEqual(dict?["k1"]?.asString, "v1")
        XCTAssertEqual(dict?["k2"], .int(2))
        if case .array(let a) = dict?["k3"] ?? .null {
            XCTAssertEqual(a, [.int(1), .int(2), .int(3)])
        } else {
            XCTFail("expected array for k3")
        }
        XCTAssertEqual(dict?["k4"]?.asObject?["inner"]?.asBool, true)
    }

    func testParseMessagePreservesJSONBooleanTypes() {
        let data = Data(#"{"id":7,"result":{"ok":true,"blocked":false,"usedPercent":0}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        let result = msg?.raw["result"]?.asObject

        XCTAssertEqual(result?["ok"]?.asBool, true)
        XCTAssertEqual(result?["blocked"]?.asBool, false)
        XCTAssertEqual(result?["usedPercent"], .int(0))
    }
}
