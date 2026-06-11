import XCTest
@testable import BoughCore

final class JSONLTailerTests: XCTestCase {

    // MARK: - scanLines (pure)

    func testScanLinesEmptyInputProducesEmptyDeltaAndFragment() {
        let result = JSONLTailer.scanLines(Data())
        XCTAssertTrue(result.delta.isEmpty)
        XCTAssertEqual(result.trailingFragment, Data())
    }

    func testScanLinesExtractsAssistantTextFromSingleLine() {
        let line = assistantLine(text: "hello world") + "\n"
        let result = JSONLTailer.scanLines(Data(line.utf8))
        XCTAssertEqual(result.delta.lastAssistantMessage, "hello world")
        XCTAssertNil(result.delta.lastUserPrompt)
        XCTAssertEqual(result.trailingFragment, Data())
    }

    func testScanLinesExtractsUserPromptFromSingleLine() {
        let line = userLine(text: "what's the weather?") + "\n"
        let result = JSONLTailer.scanLines(Data(line.utf8))
        XCTAssertEqual(result.delta.lastUserPrompt, "what's the weather?")
        XCTAssertNil(result.delta.lastAssistantMessage)
    }

    func testScanLinesLatestLineWinsForEachRole() {
        let bytes = Data(([
            assistantLine(text: "first reply"),
            userLine(text: "first question"),
            assistantLine(text: "second reply"),
            userLine(text: "second question"),
        ].joined(separator: "\n") + "\n").utf8)

        let result = JSONLTailer.scanLines(bytes)
        XCTAssertEqual(result.delta.lastAssistantMessage, "second reply")
        XCTAssertEqual(result.delta.lastUserPrompt, "second question")
    }

    func testScanLinesTrailingPartialLineReturnsAsFragment() {
        let completeLine = assistantLine(text: "done") + "\n"
        let partial = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"half"
        let combined = Data((completeLine + partial).utf8)

        let result = JSONLTailer.scanLines(combined)
        XCTAssertEqual(result.delta.lastAssistantMessage, "done")
        XCTAssertEqual(result.trailingFragment, Data(partial.utf8))
    }

    func testScanLinesIgnoresIsMetaLines() {
        let meta = """
        {"type":"assistant","isMeta":true,"message":{"content":[{"type":"text","text":"boot"}]}}
        """
        let real = assistantLine(text: "real reply")
        let combined = Data((meta + "\n" + real + "\n").utf8)

        let result = JSONLTailer.scanLines(combined)
        XCTAssertEqual(result.delta.lastAssistantMessage, "real reply")
    }

    func testScanLinesIgnoresUnknownType() {
        let line = """
        {"type":"tool_use","message":{"content":[{"type":"text","text":"internal"}]}}
        """
        let result = JSONLTailer.scanLines(Data((line + "\n").utf8))
        XCTAssertTrue(result.delta.isEmpty)
    }

    // MARK: - extractText

    func testExtractTextFromPlainString() {
        XCTAssertEqual(JSONLTailer.extractText(from: "hi"), "hi")
        XCTAssertEqual(JSONLTailer.extractText(from: "  hi  "), "hi")
        XCTAssertNil(JSONLTailer.extractText(from: ""))
        XCTAssertNil(JSONLTailer.extractText(from: "   "))
    }

    func testExtractTextFromMixedBlocks() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "part one"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
            ["type": "text", "text": "part two"]
        ]
        XCTAssertEqual(JSONLTailer.extractText(from: blocks), "part one\npart two")
    }

    func testExtractTextFromEmptyArrayReturnsNil() {
        XCTAssertNil(JSONLTailer.extractText(from: [[String: Any]]()))
    }

    func testExtractTextFromUnknownShapeReturnsNil() {
        XCTAssertNil(JSONLTailer.extractText(from: 42))
        XCTAssertNil(JSONLTailer.extractText(from: nil))
    }

    // MARK: - Integration: tail a real file

    func testAttachAndDetectAppendedLine() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "delta delivered")
        let captured = LockedBox<ConversationTailDelta?>(nil)

        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { delta in
                captured.set(delta)
                expectation.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        let line = assistantLine(text: "ping") + "\n"
        try appendToFile(url: url, content: line)

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(captured.get()?.sessionId, "s1")
        XCTAssertEqual(captured.get()?.lastAssistantMessage, "ping")

        tailer.detach(sessionId: "s1")
    }

    func testAttachIgnoresPreexistingContentByDefault() throws {
        let url = temporaryFileURL()
        let pre = assistantLine(text: "already written") + "\n"
        try Data(pre.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let receivedDelta = self.expectation(description: "delta fires for new append only")

        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { delta in
                XCTAssertEqual(delta.lastAssistantMessage, "fresh")
                receivedDelta.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed
        try appendToFile(url: url, content: assistantLine(text: "fresh") + "\n")

        wait(for: [receivedDelta], timeout: 2)
        tailer.detach(sessionId: "s1")
    }

    func testSplitAppendedLineIsParsedOnce() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "delta delivered after line completes")
        let captured = LockedBox<ConversationTailDelta?>(nil)

        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { delta in
                captured.set(delta)
                expectation.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        let line = assistantLine(text: "split once") + "\n"
        let splitIndex = line.index(line.startIndex, offsetBy: line.count / 2)
        try appendToFile(url: url, content: String(line[..<splitIndex]))
        // Coverage-only pause: lets the fragment usually arrive first. If the
        // two appends coalesce the test still passes, so this cannot flake red.
        Thread.sleep(forTimeInterval: 0.15)
        try appendToFile(url: url, content: String(line[splitIndex...]))

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(captured.get()?.lastAssistantMessage, "split once")
        tailer.detach(sessionId: "s1")
    }

    func testAssistantLineWithWhitespaceAroundTypeColonIsParsed() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "initial delta delivered")
        let captured = LockedBox<ConversationTailDelta?>(nil)
        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { delta in
                captured.set(delta)
                expectation.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        let line = #"{"type" : "assistant","message":{"content":[{"type":"text","text":"spaced type"}]}}"# + "\n"
        try appendToFile(url: url, content: line)

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(captured.get()?.lastAssistantMessage, "spaced type")
        tailer.detach(sessionId: "s1")
    }

    func testDetachStopsFurtherCallbacks() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let callCount = LockedBox(0)
        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { _ in callCount.mutate { $0 += 1 } }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        try appendToFile(url: url, content: assistantLine(text: "first") + "\n")
        XCTAssertTrue(spinUntil { callCount.get() == 1 }, "first append was not delivered")
        queue.sync {}  // drain any coalesced source events before detach

        tailer.detach(sessionId: "s1")
        queue.sync {}  // barrier guarantees the source is cancelled

        try appendToFile(url: url, content: assistantLine(text: "ignored") + "\n")
        queue.sync {}  // drain the queue; a cancelled source cannot deliver more events

        XCTAssertEqual(callCount.get(), 1)
    }

    func testDelayedReplacementAfterDeleteIsRetried() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "delta delivered after delayed replacement")
        let captured = LockedBox<ConversationTailDelta?>(nil)
        let queue = DispatchQueue(label: "tailer-test")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { delta in
                captured.set(delta)
                expectation.fulfill()
            }
        )
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(spinUntil { tailer.activeSessionCount == 0 }, "delete event was not observed")

        try Data("".utf8).write(to: url)
        XCTAssertTrue(
            spinUntil(timeout: 5.0) { tailer.activeSessionCount == 1 },
            "tailer did not reattach to the replaced file"
        )
        try appendToFile(url: url, content: assistantLine(text: "after rotate") + "\n")

        wait(for: [expectation], timeout: 3)

        XCTAssertEqual(captured.get()?.sessionId, "s1")
        XCTAssertEqual(captured.get()?.lastAssistantMessage, "after rotate")
        tailer.detach(sessionId: "s1")
    }

    func testActiveSessionCountCanBeReadFromDeltaCallback() throws {
        let url = temporaryFileURL()
        try Data("".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = self.expectation(description: "delta reads active count")
        let count = LockedBox<Int?>(nil)
        let tailerBox = LockedBox<JSONLTailer?>(nil)
        let queue = DispatchQueue(label: "tailer-test-active-count")
        let tailer = JSONLTailer(
            queue: queue,
            onDelta: { _ in
                guard let tailer = tailerBox.get() else { return }
                count.set(tailer.activeSessionCount)
                expectation.fulfill()
            }
        )
        tailerBox.set(tailer)
        tailer.attach(sessionId: "s1", filePath: url.path)
        queue.sync {}  // attach is queue.async; barrier guarantees the watch is installed

        try appendToFile(url: url, content: assistantLine(text: "count") + "\n")

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(count.get(), 1)
        tailer.detach(sessionId: "s1")
    }

    // MARK: - Deterministic waits

    /// Synchronously polls `predicate` until true or `timeout` elapses.
    /// DispatchSource event delivery is asynchronous; fixed sleeps under CI
    /// load either flake or hide bugs, so wait on observable state instead.
    private func spinUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }

    // MARK: - Fixtures

    private func assistantLine(text: String) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "text", "text": text]
                ]
            ]
        ]
        return jsonString(payload)
    }

    private func userLine(text: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "content": text
            ]
        ]
        return jsonString(payload)
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let string = String(data: data, encoding: .utf8) else {
                preconditionFailure("JSON fixture encoded non-UTF8 data")
            }
            return string
        } catch {
            preconditionFailure("JSON fixture is not serializable: \(error)")
        }
    }

    private func temporaryFileURL() -> URL {
        let name = "jsonl-tailer-\(UUID().uuidString).jsonl"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private func appendToFile(url: URL, content: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
        try handle.close()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
