import XCTest
@testable import BoughCore

final class UsageMonitorRunnerTests: XCTestCase {
    private var tempDir: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let cal = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageMonitorRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAcceptedClaudePayloadWritesContinuitySample() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let runner = makeRunner(store: store)

        let outcome = runner.acceptClaudePayload(claudePayload(weeklyUsed: 42, updatedAt: date(2026, 5, 19, 9)), receivedAt: date(2026, 5, 19, 9))

        XCTAssertEqual(outcome, .accepted(tool: .claudeCode))
        XCTAssertEqual(try store.acceptedSampleCount(tool: .claudeCode), 1)
        let restored = try XCTUnwrap(store.latestSnapshot(tool: .claudeCode))
        XCTAssertEqual(restored.weekly.snapshot?.usedPercent, 42)
        XCTAssertNotNil(restored.today)
    }

    func testEqualOrOlderSamplesAreNotDuplicated() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let statusURL = tempDir.appendingPathComponent("status.json")
        let runner = makeRunner(store: store, statusPath: statusURL.path)
        let firstAt = date(2026, 5, 19, 9)
        let olderAt = firstAt.addingTimeInterval(-60)

        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 42, updatedAt: firstAt), receivedAt: firstAt),
            .accepted(tool: .claudeCode)
        )
        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 50, updatedAt: olderAt), receivedAt: olderAt),
            .duplicate(tool: .claudeCode)
        )

        XCTAssertEqual(try store.acceptedSampleCount(tool: .claudeCode), 1)
        XCTAssertEqual(try store.latestSnapshot(tool: .claudeCode)?.weekly.snapshot?.usedPercent, 42)
        let status = try decodedStatus(at: statusURL)
        XCTAssertEqual(status.state, .running)
        XCTAssertNil(status.lastAcceptedSampleAt)
        XCTAssertNil(status.reason)
    }

    func testDisabledClaudeProviderSkipsWithoutWritingContinuitySample() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let commandURL = tempDir.appendingPathComponent("command.json")
        try writeCommand(UsageMonitorCommand(enabledTools: [.codex]), to: commandURL)
        let runner = makeRunner(store: store, commandPath: commandURL.path)

        let outcome = runner.acceptClaudePayload(
            claudePayload(weeklyUsed: 42, updatedAt: date(2026, 5, 19, 9)),
            receivedAt: date(2026, 5, 19, 9)
        )

        XCTAssertEqual(outcome, .skipped(tool: .claudeCode))
        XCTAssertEqual(try store.acceptedSampleCount(tool: .claudeCode), 0)
    }

    func testHelperRunnerRecordsRecoveryEdgeOnce() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let runner = makeRunner(store: store)
        let firstAt = date(2026, 5, 19, 9)
        let secondAt = date(2026, 5, 19, 10)

        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 100, updatedAt: firstAt), receivedAt: firstAt),
            .accepted(tool: .claudeCode)
        )
        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 20, updatedAt: secondAt), receivedAt: secondAt),
            .accepted(tool: .claudeCode)
        )
        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 20, updatedAt: secondAt), receivedAt: secondAt),
            .duplicate(tool: .claudeCode)
        )

        let records = try store.recoveryEdgeRecords(tool: .claudeCode)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.windowKind, .weekly)
    }

    func testHelperRunnerPersistsCandidateForTwoSampleRecoveryConfirmation() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let runner = makeRunner(store: store)
        let firstAt = date(2026, 5, 19, 9)
        let secondAt = date(2026, 5, 19, 10)
        let thirdAt = date(2026, 5, 19, 11)
        let resetAt = Int(firstAt.addingTimeInterval(86_400 * 7).timeIntervalSince1970)

        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 100, updatedAt: firstAt, weeklyReset: resetAt), receivedAt: firstAt),
            .accepted(tool: .claudeCode)
        )
        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 60, updatedAt: secondAt, weeklyReset: resetAt), receivedAt: secondAt),
            .accepted(tool: .claudeCode)
        )

        let resetIntervalID = "weekly:10080:\(resetAt)"
        XCTAssertEqual(try store.recoveryEdgeRecords(tool: .claudeCode), [])
        XCTAssertNotNil(try store.recoveryCandidate(tool: .claudeCode, windowKind: .weekly, resetIntervalID: resetIntervalID))

        XCTAssertEqual(
            runner.acceptClaudePayload(claudePayload(weeklyUsed: 55, updatedAt: thirdAt, weeklyReset: resetAt), receivedAt: thirdAt),
            .accepted(tool: .claudeCode)
        )

        let records = try store.recoveryEdgeRecords(tool: .claudeCode)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.windowKind, .weekly)
        XCTAssertNil(try store.recoveryCandidate(tool: .claudeCode, windowKind: .weekly, resetIntervalID: resetIntervalID))
    }

    func testStatusPayloadContainsNoSensitiveInputFields() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let statusURL = tempDir.appendingPathComponent("status.json")
        let runner = makeRunner(store: store, statusPath: statusURL.path)

        _ = runner.acceptClaudePayload(claudePayload(weeklyUsed: 33, updatedAt: date(2026, 5, 19, 9)), receivedAt: date(2026, 5, 19, 9))

        let data = try Data(contentsOf: statusURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)
        XCTAssertFalse(keys.contains("prompt"))
        XCTAssertFalse(keys.contains("transcript"))
        XCTAssertFalse(keys.contains("command"))
        XCTAssertFalse(keys.contains("filePath"))
        XCTAssertFalse(keys.contains("path"))
        XCTAssertEqual(object["writerOwner"] as? String, "helper")
        XCTAssertEqual(object["state"] as? String, "running")
    }

    func testRunOnceCollectsCodexAndClaudeCodeInOneBackgroundCycle() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let claudeURL = tempDir.appendingPathComponent("claude-usage.json")
        try claudePayload(weeklyUsed: 42, updatedAt: date(2026, 5, 19, 9)).write(to: claudeURL)
        let codexReader = FakeCodexRateLimitMonitorReader(result: .success(codexResult(weeklyUsed: 24)))
        let runner = makeRunner(store: store, codexRateLimitReader: codexReader)

        let outcomes = runner.runOnce()

        XCTAssertEqual(outcomes, [.accepted(tool: .codex), .accepted(tool: .claudeCode)])
        XCTAssertEqual(codexReader.readCount, 1)
        XCTAssertEqual(try store.acceptedSampleCount(tool: .codex), 1)
        XCTAssertEqual(try store.acceptedSampleCount(tool: .claudeCode), 1)
    }

    func testRunOnceRespectsProviderCommandWithoutBlockingOtherProvider() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let commandURL = tempDir.appendingPathComponent("command.json")
        try writeCommand(UsageMonitorCommand(enabledTools: [.codex]), to: commandURL)
        try claudePayload(weeklyUsed: 42, updatedAt: date(2026, 5, 19, 9))
            .write(to: tempDir.appendingPathComponent("claude-usage.json"))
        let codexReader = FakeCodexRateLimitMonitorReader(result: .success(codexResult(weeklyUsed: 24)))
        let runner = makeRunner(store: store, commandPath: commandURL.path, codexRateLimitReader: codexReader)

        let outcomes = runner.runOnce()

        XCTAssertEqual(outcomes, [.accepted(tool: .codex), .skipped(tool: .claudeCode)])
        XCTAssertEqual(try store.acceptedSampleCount(tool: .codex), 1)
        XCTAssertEqual(try store.acceptedSampleCount(tool: .claudeCode), 0)
    }

    func testCodexExecutableUnavailableDoesNotWriteFakeAvailableSample() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let codexReader = FakeCodexRateLimitMonitorReader(
            result: .failure(CodexAppServerError.executableMissing("/Applications/Codex.app/Contents/Resources/codex"))
        )
        let runner = makeRunner(store: store, codexRateLimitReader: codexReader)

        let outcome = runner.runCodexOnce()

        XCTAssertEqual(outcome, .unavailable(reason: "Codex usage source unavailable"))
        XCTAssertEqual(try store.acceptedSampleCount(tool: .codex), 0)
    }

    func testStaleClaudeSourceMarksFiveHourAndWeeklyStale() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let runner = makeRunner(store: store)
        let staleAt = date(2026, 5, 19, 8)

        let outcome = runner.acceptClaudePayload(
            claudePayload(weeklyUsed: 42, updatedAt: staleAt),
            receivedAt: staleAt
        )

        XCTAssertEqual(outcome, .stale(tool: .claudeCode))
        let restored = try XCTUnwrap(store.latestSnapshot(tool: .claudeCode))
        if case .stale = restored.availability {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected stale availability")
        }
        XCTAssertNotNil(restored.fiveHour.staleReason)
        XCTAssertNotNil(restored.weekly.staleReason)
        XCTAssertNil(restored.today)
    }

    func testStaleCodexSourceMarksFiveHourAndWeeklyStale() throws {
        let store = try UsageContinuityStore(path: continuityPath())
        let runner = makeRunner(store: store)
        let staleAt = date(2026, 5, 19, 8)

        let outcome = runner.acceptCodexRateLimitResult(codexResult(weeklyUsed: 42), receivedAt: staleAt)

        XCTAssertEqual(outcome, .stale(tool: .codex))
        let restored = try XCTUnwrap(store.latestSnapshot(tool: .codex))
        if case .stale = restored.availability {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected stale availability")
        }
        XCTAssertNotNil(restored.fiveHour.staleReason)
        XCTAssertNotNil(restored.weekly.staleReason)
        XCTAssertNil(restored.today)
    }

    func testAppClosedIdleIntervalIsFiveMinutes() {
        XCTAssertEqual(UsageMonitorRunner.appClosedIdleInterval, 300)
    }

    // MARK: - Helpers

    private func makeRunner(
        store: UsageContinuityStore,
        statusPath: String? = nil,
        commandPath: String? = nil,
        codexRateLimitReader: CodexRateLimitMonitorReading? = nil
    ) -> UsageMonitorRunner {
        let storage = BaselineMemoryStore()
        let accumulator = UsageDailyAccumulator(
            store: AtomicJSONStorage(
                write: { storage.write($0) },
                read: { storage.read() }
            )
        )
        return UsageMonitorRunner(
            continuityStore: store,
            dailyAccumulator: accumulator,
            claudeUsageFilePath: tempDir.appendingPathComponent("claude-usage.json").path,
            statusPath: statusPath ?? tempDir.appendingPathComponent("usage-monitor-status.json").path,
            commandPath: commandPath ?? tempDir.appendingPathComponent("usage-monitor-command.json").path,
            codexRateLimitReader: codexRateLimitReader,
            now: { self.date(2026, 5, 19, 9) },
            calendar: cal,
            timeZone: utc
        )
    }

    private func writeCommand(_ command: UsageMonitorCommand, to url: URL) throws {
        let encoder = JSONEncoder()
        try encoder.encode(command).write(to: url, options: .atomic)
    }

    private func continuityPath() -> String {
        tempDir.appendingPathComponent("usage-continuity.sqlite").path
    }

    private func decodedStatus(at url: URL) throws -> UsageMonitorStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageMonitorStatus.self, from: Data(contentsOf: url))
    }

    private func claudePayload(weeklyUsed: Double, updatedAt: Date, weeklyReset: Int? = nil) -> Data {
        let payload = """
        {
          "version": 1,
          "model": "sonnet",
          "rate_limits": {
            "five_hour": {
              "used_percentage": 12,
              "resets_at": \(Int(updatedAt.addingTimeInterval(300).timeIntervalSince1970))
            },
            "seven_day": {
              "used_percentage": \(weeklyUsed),
              "resets_at": \(weeklyReset ?? Int(updatedAt.addingTimeInterval(86_400 * 7).timeIntervalSince1970))
            }
          }
        }
        """
        return Data(payload.utf8)
    }

    private func codexResult(weeklyUsed: Double) -> [String: AnyCodableLike] {
        [
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitId": .string("codex"),
                    "primary": .object([
                        "usedPercent": .double(12),
                        "windowDurationMins": .int(300),
                        "resetsAt": .int(Int64(date(2026, 5, 19, 14).timeIntervalSince1970))
                    ]),
                    "secondary": .object([
                        "usedPercent": .double(weeklyUsed),
                        "windowDurationMins": .int(10_080),
                        "resetsAt": .int(Int64(date(2026, 5, 26, 9).timeIntervalSince1970))
                    ]),
                    "planType": .string("pro")
                ])
            ])
        ]
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = utc
        return cal.date(from: components)!
    }
}

private final class BaselineMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: DailyBaseline] = [:]

    func write(_ value: [String: DailyBaseline]) {
        lock.lock()
        defer { lock.unlock() }
        storage = value
    }

    func read() -> [String: DailyBaseline] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .unavailable:
            return nil
        }
    }

    var staleReason: String? {
        switch self {
        case .stale(_, let reason):
            return reason
        case .loading, .available, .unavailable:
            return nil
        }
    }
}

private final class FakeCodexRateLimitMonitorReader: CodexRateLimitMonitorReading {
    private let result: Result<[String: AnyCodableLike], Error>
    private(set) var readCount = 0

    init(result: Result<[String: AnyCodableLike], Error>) {
        self.result = result
    }

    func readRateLimits() throws -> [String: AnyCodableLike] {
        readCount += 1
        return try result.get()
    }
}
