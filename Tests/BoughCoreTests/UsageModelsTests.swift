import XCTest
@testable import BoughCore

final class UsageModelsTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_778_000_000)

    func testParsesReadResponsePreferringCodexBucket() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimits":{"limitId":"fallback","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1778050000},"secondary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1778600000},"planType":"fallback"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":56,"windowDurationMins":300,"resetsAt":1778052871},"secondary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.tool, .codex)
        XCTAssertEqual(snapshot.planName, "prolite")
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 56)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 9)
        XCTAssertEqual(snapshot.weekly.snapshot?.resetsAt, Date(timeIntervalSince1970: 1_778_639_671))
        XCTAssertEqual(snapshot.availability, .available)
    }

    func testParsesReadResponsePreferringAggregateCodexBucketWithoutActiveLimitId() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1778547844},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1778660972},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 86)
        XCTAssertEqual(snapshot.fiveHour.snapshot?.resetsAt, Date(timeIntervalSince1970: 1_778_543_448))
        XCTAssertEqual(snapshot.weekly.snapshot?.resetsAt, Date(timeIntervalSince1970: 1_778_639_671))
    }

    func testParsesLiveCodexPayloadShapeUsingAggregateBucket() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":34,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1778547844},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1778660972},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 34)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 90)
    }

    func testParsesReadResponseUsingExplicitActiveCodexLimitId() throws {
        let message = try parse("""
        {"id":2,"result":{"activeLimitId":"codex_beta","rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1778547844},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1778660972},"planType":"prolite"},"codex_beta":{"limitId":"codex_beta","limitName":"GPT-5.4-Codex","primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1778547000},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1778660000},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 7)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 17)
    }

    func testParsesReadResponseFallingBackToAggregateWhenMultipleModelBucketsHaveNoActiveLimitId() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex_alpha":{"limitId":"codex_alpha","limitName":"Model A","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1778547000},"secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1778660000},"planType":"prolite"},"codex_beta":{"limitId":"codex_beta","limitName":"Model B","primary":{"usedPercent":2,"windowDurationMins":300,"resetsAt":1778548000},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1778661000},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 86)
    }

    func testParsesReadResponseFallingBackToAggregateWhenOnlyModelBucketIsPartial() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1778547844},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 86)
    }

    func testParsesReadResponseFallingBackToSingleModelWhenAggregateIsMalformed() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"planType":"prolite"},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":1778547844},"secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1778660972},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 6)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 16)
    }

    func testParsesReadResponseFallingBackToAggregateWhenActiveBucketIsPartial() throws {
        let message = try parse("""
        {"id":2,"result":{"activeLimitId":"codex_bengalfox","rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1778547844},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 86)
    }

    func testParsesReadResponseFallingBackToAggregateWhenActiveBucketIsPartialAndAnotherModelIsComplete() throws {
        let message = try parse("""
        {"id":2,"result":{"activeLimitId":"codex_beta","rateLimitsByLimitId":{"codex_beta":{"limitId":"codex_beta","limitName":"Active Model","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1778547000},"planType":"prolite"},"codex_alpha":{"limitId":"codex_alpha","limitName":"Inactive Model","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1778547000},"secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1778660000},"planType":"prolite"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":14,"windowDurationMins":300,"resetsAt":1778543448},"secondary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 86)
    }

    func testFallsBackToTopLevelRateLimits() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":41,"windowDurationMins":300,"resetsAt":1778052871},"secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 41)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 8)
    }

    func testParsesUpdatedNotificationAndMapsSwappedDurations() throws {
        let message = try parse("""
        {"method":"account/rateLimits/updated","params":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1778052871},"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1778639671},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 40)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 12)
        XCTAssertEqual(snapshot.availability, .available)
    }

    func testPartialAndUnknownDurationBuckets() throws {
        let message = try parse("""
        {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":56,"windowDurationMins":300,"resetsAt":1778052871},"secondary":{"usedPercent":77,"windowDurationMins":1440,"resetsAt":1778060000},"planType":"prolite"}}}}
        """)

        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 56)
        XCTAssertEqual(snapshot.weekly, .unavailable(reason: "Weekly window unavailable"))
        XCTAssertEqual(snapshot.availability, .partial(reason: "Weekly window unavailable"))
    }

    func testMalformedRateLimitPayloadReturnsNil() throws {
        let message = try parse(#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":"bad","windowDurationMins":300,"resetsAt":1778052871}}}}}"#)
        XCTAssertNil(CodexRateLimitParser.parse(message: message, receivedAt: receivedAt))
    }

    // testForecastUsesExactHoursUntilResetAndMidnight removed in Phase 5 / 05-02:
    // the safe* / hoursUntil* fields were dropped in D-10 and the A3' contract
    // is covered by plan 05-03's UsageForecastCalculatorTests rebuild.

    func testPastWeeklyResetMakesForecastUnavailable() {
        let now = Date(timeIntervalSince1970: 2_000)
        let weekly = UsageWindowSnapshot(kind: .weekly, usedPercent: 20, resetsAt: Date(timeIntervalSince1970: 1_999), windowDurationMins: 10080, sourceLabel: "Codex", updatedAt: now)
        XCTAssertNil(UsageForecastCalculator.forecast(weekly: weekly, baseline: nil, now: now, calendar: .current, timeZone: .current))
    }

    func testClaudeUnavailableSnapshotDoesNotInventPercentages() {
        let snapshot = UsageSnapshot.claudeUnavailable(now: receivedAt)
        XCTAssertEqual(snapshot.tool, .claudeCode)
        XCTAssertEqual(snapshot.fiveHour, .unavailable(reason: "No reliable local quota source"))
        XCTAssertEqual(snapshot.weekly, .unavailable(reason: "No reliable local quota source"))
        XCTAssertEqual(snapshot.availability, .unavailable(reason: "No reliable local quota source"))
    }

    private func parse(_ json: String) throws -> CodexJSONRPCMessage {
        try XCTUnwrap(CodexAppServerClient.parseMessage(Data(json.utf8)))
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let value), .stale(let value, _): return value
        case .loading, .unavailable: return nil
        }
    }
}
