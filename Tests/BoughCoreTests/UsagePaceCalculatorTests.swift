import XCTest
@testable import BoughCore

final class UsagePaceCalculatorTests: XCTestCase {
    private func weekly(used: Double, resetsIn seconds: TimeInterval, now: Date) -> UsageWindowSnapshot {
        UsageWindowSnapshot(kind: .weekly, usedPercent: used,
            resetsAt: now.addingTimeInterval(seconds),
            windowDurationMins: 10080, sourceLabel: "t", updatedAt: now)
    }

    func testOnTrackAtLinearExpectation() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 窗口过半（剩 3.5 天）→ expected 50；actual 51 → onTrack（|delta|≤2）
        let pace = try XCTUnwrap(UsagePaceCalculator.pace(
            for: weekly(used: 51, resetsIn: 3.5 * 24 * 3600, now: now), now: now))
        XCTAssertEqual(pace.expectedUsedPercent, 50, accuracy: 0.01)
        XCTAssertEqual(pace.stage, .onTrack)
        XCTAssertTrue(pace.willLastToReset)
        XCTAssertNil(pace.etaAt)
    }

    func testFarAheadProducesETA() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 过 1/7（剩 6 天）→ expected ≈14.3；actual 60 → farAhead；
        // rate = 60/86400s → 剩 40% 在重置前耗尽 → etaAt 非空
        let pace = try XCTUnwrap(UsagePaceCalculator.pace(
            for: weekly(used: 60, resetsIn: 6 * 24 * 3600, now: now), now: now))
        XCTAssertEqual(pace.stage, .farAhead)
        XCTAssertFalse(pace.willLastToReset)
        let eta = try XCTUnwrap(pace.etaAt)
        // remaining 40 / (60/1d) = 0.6667 天
        XCTAssertEqual(eta.timeIntervalSince(now), 40.0 / (60.0 / (24 * 3600)), accuracy: 1)
    }

    func testBehindStage() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // expected 50；actual 40 → delta -10 → behind
        let pace = try XCTUnwrap(UsagePaceCalculator.pace(
            for: weekly(used: 40, resetsIn: 3.5 * 24 * 3600, now: now), now: now))
        XCTAssertEqual(pace.stage, .behind)
        XCTAssertTrue(pace.willLastToReset)
    }

    func testInvalidWindowsReturnNil() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 重置已过
        XCTAssertNil(UsagePaceCalculator.pace(for: weekly(used: 10, resetsIn: -60, now: now), now: now))
        // resetsAt 比窗口时长还远（数据异常）
        XCTAssertNil(UsagePaceCalculator.pace(for: weekly(used: 10, resetsIn: 8 * 24 * 3600, now: now), now: now))
    }

    func testZeroElapsedWithUsageReturnsNil() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(UsagePaceCalculator.pace(
            for: weekly(used: 5, resetsIn: 7 * 24 * 3600, now: now), now: now))
    }
}
