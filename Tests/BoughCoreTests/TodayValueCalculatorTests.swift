import XCTest
@testable import BoughCore

/// Boundary tests for `UsageForecastCalculator.forecast(weekly:baseline:now:
/// calendar:timeZone:) -> TodayValue?` after the Phase 5 / plan 05-02 rewrite.
///
/// Coverage targets TODAY-13 (severity remap), TODAY-17 (boundary grids), and
/// TODAY-12 (overdraft display). The accumulator side of TODAY-17 is covered
/// in `UsageDailyAccumulatorTests`.
final class TodayValueCalculatorTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let cal = Calendar(identifier: .gregorian)

    // MARK: - Fixture helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = utc
        return cal.date(from: components)!
    }

    private func weekly(
        usedPercent: Double,
        resetsAt: Date,
        windowDurationMins: Int = 7 * 24 * 60
    ) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowDurationMins: windowDurationMins,
            sourceLabel: "Codex",
            updatedAt: resetsAt
        )
    }

    private func baseline(
        localDate: String,
        weeklyUsedAtDayStart: Double,
        todayAllowanceOfWeek: Double,
        capturedAt: Date? = nil
    ) -> DailyBaseline {
        DailyBaseline(
            tool: .codex,
            localDate: localDate,
            weeklyUsedAtDayStart: weeklyUsedAtDayStart,
            todayAllowanceOfWeek: todayAllowanceOfWeek,
            timeZoneIdentifier: utc.identifier,
            capturedAt: capturedAt ?? date(2026, 5, 14, 0, 0)
        )
    }

    // MARK: - Allowance formula

    func testAllowanceFormula_FullWeek_50PctUsed_7DaysRemaining() {
        // 7 days remaining + 50% used → allowance = 50/7 ≈ 7.143%
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 50, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 50.0 / 7.0, accuracy: 0.001)
    }

    func testAllowanceFormula_LateWeek_96PctUsed_1DayRemaining() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 15, 0)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 96, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 4.0, accuracy: 0.001)
    }

    func testAllowanceFormula_FullyDepleted_100PctUsed() {
        // usedPercent = 100 → remaining = 0 → allowance = 0 / max(1, days)
        // = 0. The calculator must still return a TodayValue (not nil).
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 16, 0)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 100, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result, "fully-depleted weekly with future reset must produce a TodayValue, not nil")
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.pct ?? -1, 100.0,
                       "First tick with no baseline returns pct=100 placeholder regardless of weekly state")
    }

    func testDaysRemainingZero_ClampedToOne() {
        // weekly.resetsAt is in the very near future (under a day) — local-day
        // delta computes to 0 days; the calculator's max(1.0, ...) floor
        // means allowance = (100 - usedPercent) / 1. Bounded sentinel per
        // CONVENTIONS, not a fallback.
        let now = date(2026, 5, 14, 23, 50)
        let resetsAt = date(2026, 5, 14, 23, 59)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 25, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 75.0, accuracy: 0.001,
                       "max(1.0, daysRemaining) clamp produces allowance = (100 - usedPercent) / 1")
    }

    // MARK: - Normalized pct

    func testPct100_FreshBaseline_NoUsageSinceMidnight() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 30, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testPct0_TodayUsedEqualsAllowance() {
        let now = date(2026, 5, 14, 18)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 40, resetsAt: resetsAt),  // used = 40 - 30 = 10 = allowance
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .depleted)
    }

    func testPctNegative_SimpleOverdraft() {
        // allowance = 10, today_used = 14 → pct = ((10 - 14) / 10) * 100 = -40
        let now = date(2026, 5, 14, 20)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 44, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? -1, -40.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .overdraft)
    }

    // MARK: - Overdraft display value tests (TODAY-12)

    func testOverdraftPctMinusOne() {
        let now = date(2026, 5, 14, 20)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 40.1, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 0, -1.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .overdraft)
    }

    func testOverdraftPctMinusFourty() {
        let now = date(2026, 5, 14, 20)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 44, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 0, -40.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .overdraft)
    }

    func testOverdraftPctMinusTwoHundred() {
        // allowance = 5, today_used = 15 → pct = ((5 - 15) / 5) * 100 = -200
        let now = date(2026, 5, 14, 22)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 5)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 45, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 0, -200.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .overdraft)
    }

    // MARK: - Severity remap (TODAY-13 / D-05)
    //
    // The severity remap is gated through forecast(...). To exercise individual
    // pct values precisely, we construct a baseline + weekly tick pair whose
    // today_used / allowance ratio produces the exact target pct.

    private func severityForPct(_ targetPct: Double) -> TodaySeverity? {
        // Use allowance = 10 so the math stays well-inside UsageWindowSnapshot's
        // 0..100 usedPercent clamp. With baseline.weeklyUsedAtDayStart = 0 and
        // allowance = 10:
        //   pct = ((10 - today_used) / 10) * 100
        // → today_used = 10 - (targetPct / 10)
        // For targetPct = -0.001: today_used = 10.0001 (safely below 100).
        let now = date(2026, 5, 14, 20)
        let resetsAt = date(2026, 5, 21, 0)
        let allowance = 10.0
        let todayUsed = allowance - (targetPct / 10.0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 0, todayAllowanceOfWeek: allowance)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: todayUsed, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        return result?.severity
    }

    func testSeverity_HealthyAbove20Pct() {
        XCTAssertEqual(severityForPct(21), .healthy)
    }

    func testSeverity_HealthyAt100Pct() {
        XCTAssertEqual(severityForPct(100), .healthy)
    }

    func testSeverity_CautionExactly20Pct() {
        // D-05: caution band is 5 <= pct <= 20 (inclusive on both ends).
        XCTAssertEqual(severityForPct(20), .caution)
    }

    func testSeverity_CautionAt5Pct() {
        XCTAssertEqual(severityForPct(5), .caution)
    }

    func testSeverity_DepletedJustUnder5Pct() {
        XCTAssertEqual(severityForPct(4.999), .depleted)
    }

    func testSeverity_DepletedAt0Pct() {
        XCTAssertEqual(severityForPct(0), .depleted)
    }

    func testSeverity_OverdraftJustBelow0Pct() {
        XCTAssertEqual(severityForPct(-0.001), .overdraft)
    }

    // MARK: - Cross-reset within today (TODAY-09 / spec §8.1)

    func testCrossResetWithinToday_DeltaFromBaselineNoSegmentMath() {
        // Spec §8.1: the calculator no longer does cross-reset segment math —
        // the accumulator re-locks the baseline at the reset. Exercising the
        // calculator alone with a stale pre-reset baseline (80) and post-reset
        // weekly used = 4 yields today_used = max(0, 4 - 80) = 0 → pct = 100.
        // The provenance annotation is kept for display/telemetry.
        let postResetTick = date(2026, 5, 14, 13)
        let nextWeekReset = date(2026, 5, 21, 12)
        let b = baseline(
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 80,
            todayAllowanceOfWeek: 20,
            capturedAt: date(2026, 5, 14, 6)
        )
        // Post-reset weekly: usedPercent dropped, new resetsAt next week.
        let weeklyPostReset = weekly(usedPercent: 4, resetsAt: nextWeekReset)
        let priorWeekly = weekly(usedPercent: 80, resetsAt: date(2026, 5, 14, 12))

        let result = UsageForecastCalculator.forecast(
            weekly: weeklyPostReset,
            baseline: b,
            priorWeekly: priorWeekly,
            now: postResetTick,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pct ?? 999, 100.0, accuracy: 0.001,
                       "spec §8.1: today_used = max(0, used - baseline); no pre-reset segment carry-forward")
        XCTAssertEqual(result?.basis.weeklyResetAlreadyFiredToday, true)
        XCTAssertEqual(result?.basis.resetProvenance, .explicitReset)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testImplicitResetAnnotatedWhenDropExceedsToleranceAndBoundaryMovesForward() {
        let now = date(2026, 5, 14, 13)
        let originalReset = date(2026, 5, 16, 12)
        let nextReset = date(2026, 5, 21, 12)
        let b = baseline(
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 82,
            todayAllowanceOfWeek: 20,
            capturedAt: date(2026, 5, 14, 6)
        )
        let priorWeekly = weekly(usedPercent: 86, resetsAt: originalReset)
        let currentWeekly = weekly(usedPercent: 5, resetsAt: nextReset)

        let result = UsageForecastCalculator.forecast(
            weekly: currentWeekly,
            baseline: b,
            priorWeekly: priorWeekly,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        // Spec §8.1: no carry-forward math — today_used = max(0, 5 - 82) = 0
        // → pct = 100. Provenance still classifies the early reset as implicit.
        XCTAssertEqual(result?.pct ?? 999, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.basis.weeklyResetAlreadyFiredToday, true)
        XCTAssertEqual(result?.basis.resetProvenance, .implicitReset)
        XCTAssertEqual(result?.basis.resetMetadata?.dropPercent ?? 0, 81.0, accuracy: 0.001)
    }

    func testSmallDropbackIsIgnoredAndDoesNotCarryForward() {
        let now = date(2026, 5, 14, 13)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)
        let priorWeekly = weekly(usedPercent: 35, resetsAt: date(2026, 5, 21, 12))
        let currentWeekly = weekly(usedPercent: 33, resetsAt: date(2026, 5, 28, 12))

        let result = UsageForecastCalculator.forecast(
            weekly: currentWeekly,
            baseline: b,
            priorWeekly: priorWeekly,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 999, 70.0, accuracy: 0.001)
        XCTAssertEqual(result?.basis.weeklyResetAlreadyFiredToday, false)
        XCTAssertEqual(result?.basis.resetProvenance, .correctionIgnored)
    }

    func testLargeDropWithUnchangedBoundaryIsIgnored() {
        let now = date(2026, 5, 14, 13)
        let reset = date(2026, 5, 21, 12)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)
        let priorWeekly = weekly(usedPercent: 50, resetsAt: reset)
        let currentWeekly = weekly(usedPercent: 20, resetsAt: reset)

        let result = UsageForecastCalculator.forecast(
            weekly: currentWeekly,
            baseline: b,
            priorWeekly: priorWeekly,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 999, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.basis.weeklyResetAlreadyFiredToday, false)
        XCTAssertEqual(result?.basis.resetProvenance, .correctionIgnored)
    }

    func testNoPriorWeeklySampleDoesNotClassifyReset() {
        let now = date(2026, 5, 14, 13)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 80, todayAllowanceOfWeek: 20)
        let currentWeekly = weekly(usedPercent: 4, resetsAt: date(2026, 5, 21, 12))

        let result = UsageForecastCalculator.forecast(
            weekly: currentWeekly,
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? 999, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.basis.weeklyResetAlreadyFiredToday, false)
        XCTAssertEqual(result?.basis.resetProvenance, .ordinaryProgress)
    }

    // MARK: - Weekly_used boundary grid (TODAY-17)

    func testBoundary_WeeklyUsedZero() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 0)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 0, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testBoundary_WeeklyUsedFifty() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 0)
        let b = baseline(localDate: "2026-05-14", weeklyUsedAtDayStart: 50, todayAllowanceOfWeek: 10)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 50, resetsAt: resetsAt),
            baseline: b,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testBoundary_WeeklyUsedNinetySix() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 0)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 96, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001,
                       "Nil baseline always returns pct=100 placeholder")
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testBoundary_WeeklyUsedOneHundred() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 0)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 100, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertNotNil(result, "100% used + future reset must still produce TodayValue")
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 0.0, accuracy: 0.001)
    }

    // MARK: - Days_remaining boundary grid (TODAY-17)

    func testBoundary_DaysRemainingZero_Clamped() {
        let now = date(2026, 5, 14, 23, 50)
        let resetsAt = date(2026, 5, 14, 23, 59)  // < 1 day
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 30, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 70.0, accuracy: 0.001,
                       "max(1.0, daysRemaining) clamp keeps allowance well-defined")
    }

    func testBoundary_DaysRemainingOne() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 15, 0)  // tomorrow midnight
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 30, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        // (100 - 30) / 1 = 70
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 70.0, accuracy: 0.001)
    }

    func testBoundary_DaysRemainingSix() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 20, 10)  // 6 days out
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 30, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        // (100 - 30) / 6 ≈ 11.667
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 70.0 / 6.0, accuracy: 0.001)
    }

    func testBoundary_DaysRemainingSeven() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)  // 7 days out
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 30, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.todayAllowanceOfWeek ?? -1, 70.0 / 7.0, accuracy: 0.001)
    }

    // MARK: - Non-standard window duration (TODAY-17)

    func testNonStandardWeeklyWindowDuration_FullDay() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 25, resetsAt: resetsAt, windowDurationMins: 24 * 60),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.todayAllowanceOfWeek.isNaN ?? true)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testNonStandardWeeklyWindowDuration_LessThan24h() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 25, resetsAt: resetsAt, windowDurationMins: 6 * 60),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.todayAllowanceOfWeek.isNaN ?? true,
                       "non-standard short window must not produce NaN allowance")
        XCTAssertEqual(result?.severity, .healthy,
                       "calculator must produce a well-defined severity regardless of windowDurationMins")
    }

    func testFullyExhaustedWeeklyWindowProducesFiniteTodayValue() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let baseline = baseline(
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 100,
            todayAllowanceOfWeek: 0
        )

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 100, resetsAt: resetsAt),
            baseline: baseline,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pct, 0)
        XCTAssertEqual(result?.todayAllowanceOfWeek, 0)
        XCTAssertEqual(result?.severity, .depleted)
        XCTAssertFalse(result?.pct.isNaN ?? true)
        XCTAssertTrue(result?.pct.isFinite ?? false)
    }

    // MARK: - Nil-baseline + nil-input paths

    func testNilBaseline_ReturnsHundredPercent() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 50, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }

    func testForecastReturnsNil_WhenResetsAtIsInPast() {
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 14, 9)
        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 25, resetsAt: resetsAt),
            baseline: nil,
            now: now,
            calendar: cal,
            timeZone: utc
        )
        XCTAssertNil(result)
    }

    // MARK: - Baseline mismatch sentinel

    func testBaselineMismatchOnLocalDate_FallsBackToHundredPercent() {
        // Baseline says yesterday; now is today. The calculator's bounded-
        // sentinel branch returns pct=100 because the accumulator has not yet
        // realigned the baseline keying.
        let now = date(2026, 5, 14, 10)
        let resetsAt = date(2026, 5, 21, 10)
        let staleBaseline = baseline(localDate: "2026-05-13", weeklyUsedAtDayStart: 30, todayAllowanceOfWeek: 10)

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 35, resetsAt: resetsAt),
            baseline: staleBaseline,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }

    // MARK: - Reset bucket normalization (spec §8.2)

    func testResetBucketNormalizationAbsorbsJitter() {
        // 1_781_406_000 is divisible by 300, so `base` is bucket-aligned:
        // +299s stays inside the same 5-minute bucket, +301s crosses it.
        let base = Date(timeIntervalSince1970: 1_781_406_000)

        XCTAssertEqual(
            UsageResetEvaluator.normalizedResetBucket(base.addingTimeInterval(299)),
            UsageResetEvaluator.normalizedResetBucket(base)
        )
        XCTAssertNotEqual(
            UsageResetEvaluator.normalizedResetBucket(base.addingTimeInterval(301)),
            UsageResetEvaluator.normalizedResetBucket(base)
        )
    }

    func testJitteredResetBoundaryDoesNotTriggerImplicitReset() {
        // Server-side resets_at jitter inside one 5-minute bucket must not
        // register as a moved boundary even with a large usedPercent drop.
        let bucketAlignedReset = Date(timeIntervalSince1970: 1_781_406_000)
        let now = bucketAlignedReset.addingTimeInterval(-3600)
        let priorWeekly = weekly(usedPercent: 50, resetsAt: bucketAlignedReset)
        let currentWeekly = weekly(usedPercent: 10, resetsAt: bucketAlignedReset.addingTimeInterval(90))

        let evaluation = UsageResetEvaluator.evaluate(
            weekly: currentWeekly,
            priorWeekly: priorWeekly,
            now: now
        )

        XCTAssertEqual(evaluation.provenance, .correctionIgnored)
    }

    // MARK: - Re-locked baseline (spec §8.1)

    func testForecastAfterRelockedBaselineStartsAtFull() {
        // After the accumulator re-locks at a reset (weeklyUsedAtDayStart = 3,
        // allowance recomputed against the new week), the very next forecast
        // reports a full allowance — no phantom overdraft.
        let now = date(2026, 5, 14, 13)
        let resetsAt = date(2026, 5, 21, 12)
        let relocked = DailyBaseline(
            tool: .codex,
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 3,
            todayAllowanceOfWeek: (100.0 - 3.0) / 7.0,
            timeZoneIdentifier: utc.identifier,
            capturedAt: now,
            lastHandledResetIntervalID: "x"
        )

        let result = UsageForecastCalculator.forecast(
            weekly: weekly(usedPercent: 3, resetsAt: resetsAt),
            baseline: relocked,
            now: now,
            calendar: cal,
            timeZone: utc
        )

        XCTAssertEqual(result?.pct ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(result?.severity, .healthy)
    }
}
