import XCTest
@testable import BoughCore

/// Boundary tests for the Phase 5 / plan 05-01 persistence-layer state
/// machine. Every test injects an in-memory `AtomicJSONStorage` so no test
/// touches `~/.bough/usage-daily.json` on disk — the closures capture a
/// `[String: DailyBaseline]` dict by reference and the suite remains
/// hermetic under `swift test --parallel`.
///
/// Coverage targets TODAY-17 sub-bullets in REQUIREMENTS.md:
/// - cross-midnight (TODAY-08)
/// - weekly-reset mid-day (TODAY-09 — accumulator side; calculator side in
///   TodayValueCalculatorTests)
/// - timezone change (TODAY-10)
/// - DST spring-forward + fall-back (within-same-local-date)
/// - first-launch baseline gap (TODAY-11 / D-13 / D-14)
/// - app-killed-and-relaunched-same-day (TODAY-17)
/// - dual-source isolation (D-03 — Codex baseline does not affect ClaudeCode)
/// - persistence is written after every reseed (TODAY-07)
final class UsageDailyAccumulatorTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let cal = Calendar(identifier: .gregorian)

    // MARK: - In-memory storage helper

    /// Returns a `(storage, peek, writeCallCount)` triple. The closures back
    /// to a captured class instance so the dict outlives any single closure
    /// call. `writeCallCount` is incremented on every `write` invocation so
    /// tests can assert call patterns (e.g. test 11/12 below).
    private final class InMemoryStore {
        var dict: [String: DailyBaseline] = [:]
        var writeCallCount: Int = 0
    }

    private func makeInMemoryStorage(seed: [String: DailyBaseline] = [:]) -> (AtomicJSONStorage, InMemoryStore) {
        let backing = InMemoryStore()
        backing.dict = seed
        let storage = AtomicJSONStorage(
            write: { newDict in
                backing.dict = newDict
                backing.writeCallCount += 1
            },
            read: {
                backing.dict
            }
        )
        return (storage, backing)
    }

    // MARK: - Date / window fixture helpers

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0,
        timeZone: TimeZone? = nil
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = timeZone ?? utc
        return cal.date(from: components)!
    }

    private func weekly(
        usedPercent: Double,
        resetsAt: Date,
        windowDurationMins: Int = 7 * 24 * 60,
        sourceLabel: String = "Codex"
    ) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowDurationMins: windowDurationMins,
            sourceLabel: sourceLabel,
            updatedAt: resetsAt
        )
    }

    // MARK: - Tests

    func testFirstTickWithNoBaselineSeedsAndFlagsIsFirstLaunch() {
        let (storage, backing) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let now = date(2026, 5, 14, 10, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 25, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: now, calendar: cal, timeZone: utc)

        XCTAssertTrue(accumulator.isFirstLaunch(for: .codex))
        XCTAssertNotNil(accumulator.baseline(for: .codex))
        XCTAssertEqual(accumulator.baseline(for: .codex)?.weeklyUsedAtDayStart, 25)
        XCTAssertEqual(accumulator.baseline(for: .codex)?.localDate, "2026-05-14")
        XCTAssertEqual(backing.dict.count, 1)
        XCTAssertNotNil(backing.dict[UsageTool.codex.rawValue])
    }

    func testSecondTickSameDayDoesNotReseed() {
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let firstNow = date(2026, 5, 14, 10, 0, timeZone: utc)
        let secondNow = date(2026, 5, 14, 14, 30, timeZone: utc)
        let weeklyAtFirst = weekly(usedPercent: 25, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))
        let weeklyAtSecond = weekly(usedPercent: 30, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyAtFirst, tool: .codex, now: firstNow, calendar: cal, timeZone: utc)
        let capturedAfterFirst = accumulator.baseline(for: .codex)?.capturedAt

        accumulator.recordTick(weekly: weeklyAtSecond, tool: .codex, now: secondNow, calendar: cal, timeZone: utc)

        // Same localDate + timeZoneIdentifier → baseline preserved unchanged.
        XCTAssertEqual(accumulator.baseline(for: .codex)?.capturedAt, capturedAfterFirst)
        XCTAssertEqual(accumulator.baseline(for: .codex)?.weeklyUsedAtDayStart, 25)
    }

    func testCrossMidnightReseedsBaseline() {
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let beforeMidnight = date(2026, 5, 14, 23, 55, timeZone: utc)
        let afterMidnight = date(2026, 5, 15, 0, 5, timeZone: utc)
        let weeklyBefore = weekly(usedPercent: 25, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))
        let weeklyAfter = weekly(usedPercent: 28, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyBefore, tool: .codex, now: beforeMidnight, calendar: cal, timeZone: utc)
        XCTAssertEqual(accumulator.baseline(for: .codex)?.localDate, "2026-05-14")

        accumulator.recordTick(weekly: weeklyAfter, tool: .codex, now: afterMidnight, calendar: cal, timeZone: utc)

        XCTAssertEqual(accumulator.baseline(for: .codex)?.localDate, "2026-05-15")
        XCTAssertEqual(accumulator.baseline(for: .codex)?.weeklyUsedAtDayStart, 28,
                       "Cross-midnight reseed must capture the CURRENT weekly.usedPercent (TODAY-08)")
        // Within-process midnight rollover → first-launch flag remains false
        // (it was set on the first tick before midnight, and remains in-memory
        // until the next reseed — at which point it flips back to false because
        // a prior baseline existed).
        XCTAssertFalse(accumulator.isFirstLaunch(for: .codex),
                       "Same-process cross-midnight reseed must NOT re-flag first-launch")
    }

    func testWeeklyResetMidDayKeepsBaseline() {
        // TODAY-09: when the weekly reset fires inside the local day, the
        // accumulator keeps the baseline stable. The calculator handles the
        // pre/post-reset segment math (covered in TodayValueCalculatorTests).
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let beforeReset = date(2026, 5, 14, 10, 0, timeZone: utc)
        let afterReset = date(2026, 5, 14, 18, 0, timeZone: utc)
        let resetAt = date(2026, 5, 14, 12, 0, timeZone: utc)
        let postResetAt = date(2026, 5, 21, 0, 0, timeZone: utc)
        let weeklyBefore = weekly(usedPercent: 80, resetsAt: resetAt)
        // Post-reset weekly snapshot: usedPercent dropped sharply, new resetsAt.
        let weeklyAfter = weekly(usedPercent: 5, resetsAt: postResetAt)

        accumulator.recordTick(weekly: weeklyBefore, tool: .codex, now: beforeReset, calendar: cal, timeZone: utc)
        let baselineBefore = accumulator.baseline(for: .codex)

        accumulator.recordTick(weekly: weeklyAfter, tool: .codex, now: afterReset, calendar: cal, timeZone: utc)

        let baselineAfter = accumulator.baseline(for: .codex)
        XCTAssertEqual(baselineBefore?.localDate, baselineAfter?.localDate)
        XCTAssertEqual(baselineBefore?.weeklyUsedAtDayStart, baselineAfter?.weeklyUsedAtDayStart,
                       "Mid-day weekly reset must NOT reseed (D-05 / TODAY-09)")
        XCTAssertEqual(baselineBefore?.capturedAt, baselineAfter?.capturedAt,
                       "Baseline must be byte-for-byte unchanged across a mid-day reset")
    }

    func testTimezoneChangeMidDayReseedsBaseline() {
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let firstNow = date(2026, 5, 14, 10, 0, timeZone: utc)
        // After TZ change to LA, the wall-clock instant is the same but the
        // timezone identifier differs — TODAY-10 invalidates the baseline.
        let secondNow = firstNow.addingTimeInterval(30 * 60)
        let weeklyTick = weekly(usedPercent: 25, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: firstNow, calendar: cal, timeZone: utc)
        // Apple's TimeZone(identifier: "UTC") canonicalizes to "GMT" on Darwin;
        // pin the assertion to `utc.identifier` rather than the string literal
        // so the test is platform-agnostic.
        XCTAssertEqual(accumulator.baseline(for: .codex)?.timeZoneIdentifier, utc.identifier)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: secondNow, calendar: cal, timeZone: losAngeles)

        XCTAssertEqual(accumulator.baseline(for: .codex)?.timeZoneIdentifier, losAngeles.identifier,
                       "Mid-day TZ change must reseed the baseline (TODAY-10)")
        XCTAssertNotEqual(accumulator.baseline(for: .codex)?.timeZoneIdentifier, utc.identifier,
                          "After TZ change, the stored identifier must not equal the original")
    }

    func testDSTSpringForwardDoesNotReseedWhenStaysInSameLocalDate() {
        // 2026 US DST spring-forward: 2026-03-08 02:00 PST → 03:00 PDT.
        // Both ticks fall on the same local calendar day in America/Los_Angeles.
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let beforeJump = date(2026, 3, 8, 1, 30, timeZone: losAngeles)
        let afterJump = date(2026, 3, 8, 4, 0, timeZone: losAngeles)
        let resetAt = date(2026, 3, 12, 0, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 25, resetsAt: resetAt)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: beforeJump, calendar: cal, timeZone: losAngeles)
        let firstBaseline = accumulator.baseline(for: .codex)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: afterJump, calendar: cal, timeZone: losAngeles)
        let secondBaseline = accumulator.baseline(for: .codex)

        XCTAssertEqual(firstBaseline?.localDate, secondBaseline?.localDate)
        XCTAssertEqual(firstBaseline?.localDate, "2026-03-08")
        XCTAssertEqual(firstBaseline?.weeklyUsedAtDayStart, secondBaseline?.weeklyUsedAtDayStart,
                       "DST spring-forward within the same local day must NOT reseed")
    }

    func testDSTFallBackDoesNotReseedWhenStaysInSameLocalDate() {
        // 2026 US DST fall-back: 2026-11-01 02:00 PDT → 01:00 PST (the 01:30
        // window happens twice). Both ticks must fall on the same local day.
        let (storage, _) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let beforeFallback = date(2026, 11, 1, 1, 30, timeZone: losAngeles)
        let afterFallback = beforeFallback.addingTimeInterval(3 * 3600)  // wall-clock 04:30 local
        let resetAt = date(2026, 11, 7, 0, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 25, resetsAt: resetAt)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: beforeFallback, calendar: cal, timeZone: losAngeles)
        let firstBaseline = accumulator.baseline(for: .codex)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: afterFallback, calendar: cal, timeZone: losAngeles)
        let secondBaseline = accumulator.baseline(for: .codex)

        XCTAssertEqual(firstBaseline?.localDate, secondBaseline?.localDate)
        XCTAssertEqual(firstBaseline?.localDate, "2026-11-01")
        XCTAssertEqual(firstBaseline?.weeklyUsedAtDayStart, secondBaseline?.weeklyUsedAtDayStart,
                       "DST fall-back within the same local day must NOT reseed")
    }

    func testFirstLaunchAfterLongQuit_NoOnDiskBaseline_FlagsIsFirstLaunch() {
        // Distinct from testFirstTick...: this test verifies the dict gets
        // populated AFTER the first tick (proving the persistence boundary
        // engaged), even though the in-process flag was already covered by
        // test 1.
        let (storage, backing) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        XCTAssertEqual(backing.dict.count, 0, "Precondition: empty store")

        let now = date(2026, 5, 14, 9, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 10, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: now, calendar: cal, timeZone: utc)

        XCTAssertEqual(backing.dict.count, 1)
        XCTAssertTrue(accumulator.isFirstLaunch(for: .codex))
    }

    func testAppKilledAndRelaunchedSameDay_ReusesBaseline() {
        // Seed the dict with a baseline captured at 09:00 today; construct a
        // fresh accumulator (simulating app relaunch) and tick again at 14:00.
        // The accumulator must reuse the persisted baseline and NOT flag
        // first-launch (since a prior baseline existed on disk).
        let savedBaseline = DailyBaseline(
            tool: .codex,
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 18,
            todayAllowanceOfWeek: 16.4,
            // Use `utc.identifier` instead of the literal "UTC" — Apple
            // canonicalizes the same TimeZone instance to "GMT" on Darwin,
            // so the persisted identifier must match what `timeZone.identifier`
            // returns at recordTick time or the keying predicate will treat the
            // seeded baseline as stale and reseed.
            timeZoneIdentifier: utc.identifier,
            capturedAt: date(2026, 5, 14, 9, 0, timeZone: utc)
        )
        let (storage, _) = makeInMemoryStorage(seed: [UsageTool.codex.rawValue: savedBaseline])

        let accumulator = UsageDailyAccumulator(store: storage)
        let relaunchTick = date(2026, 5, 14, 14, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 22, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: relaunchTick, calendar: cal, timeZone: utc)

        XCTAssertEqual(accumulator.baseline(for: .codex), savedBaseline,
                       "Same-day relaunch must reuse the persisted baseline byte-for-byte")
        XCTAssertFalse(accumulator.isFirstLaunch(for: .codex),
                       "App-killed-and-relaunched-same-day must NOT flag first-launch")
    }

    func testCodexAndClaudeCodeBaselinesAreIsolated() {
        // D-03 / TODAY-17 dual-source isolation: reseeding one tool's baseline
        // must not affect the other tool's stored values.
        let (storage, backing) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let day1 = date(2026, 5, 14, 10, 0, timeZone: utc)
        let day2 = date(2026, 5, 15, 10, 0, timeZone: utc)
        let weeklyDay1 = weekly(usedPercent: 30, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))
        let weeklyDay2 = weekly(usedPercent: 60, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        // Day 1: both tools tick.
        accumulator.recordTick(weekly: weeklyDay1, tool: .codex, now: day1, calendar: cal, timeZone: utc)
        accumulator.recordTick(weekly: weeklyDay1, tool: .claudeCode, now: day1, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.dict.count, 2)
        let claudeBaselineDay1 = accumulator.baseline(for: .claudeCode)
        XCTAssertNotNil(claudeBaselineDay1)

        // Day 2: only Codex ticks. ClaudeCode baseline must be untouched.
        accumulator.recordTick(weekly: weeklyDay2, tool: .codex, now: day2, calendar: cal, timeZone: utc)

        XCTAssertEqual(accumulator.baseline(for: .codex)?.localDate, "2026-05-15",
                       "Codex baseline must reseed for day 2")
        XCTAssertEqual(accumulator.baseline(for: .claudeCode), claudeBaselineDay1,
                       "ClaudeCode baseline must NOT be touched by a Codex reseed (D-03)")
    }

    func testRecordTickPersistsAfterEveryUpdate() {
        // TODAY-07: every baseline-update reseed must write through to the
        // injected storage. Verified by counting write closure invocations.
        let (storage, backing) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let day1 = date(2026, 5, 14, 10, 0, timeZone: utc)
        let day2 = date(2026, 5, 15, 10, 0, timeZone: utc)
        let day3 = date(2026, 5, 16, 10, 0, timeZone: utc)
        let weeklyTick = weekly(usedPercent: 25, resetsAt: date(2026, 5, 21, 0, 0, timeZone: utc))

        XCTAssertEqual(backing.writeCallCount, 0)

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: day1, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.writeCallCount, 1, "First tick (seed) must write")

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: day2, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.writeCallCount, 2, "Cross-midnight reseed must write")

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: day3, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.writeCallCount, 3, "Each subsequent cross-midnight reseed must write")
    }

    func testRecordTickDoesNotPersistWhenBaselineUnchanged() {
        // Counterpart to the previous test: when the baseline does NOT need
        // to be reseeded (same localDate + same TZ + same tool), the
        // accumulator must NOT perform an extraneous write. This is both a
        // perf guard and a correctness guard (it confirms the implementation
        // is actually evaluating the keying predicate, not blindly writing
        // on every tick).
        let (storage, backing) = makeInMemoryStorage()
        let accumulator = UsageDailyAccumulator(store: storage)
        let firstNow = date(2026, 5, 14, 10, 0, timeZone: utc)
        let secondNow = date(2026, 5, 14, 14, 30, timeZone: utc)
        let weeklyAtFirst = weekly(usedPercent: 25, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))
        let weeklyAtSecond = weekly(usedPercent: 30, resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc))

        accumulator.recordTick(weekly: weeklyAtFirst, tool: .codex, now: firstNow, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.writeCallCount, 1)

        accumulator.recordTick(weekly: weeklyAtSecond, tool: .codex, now: secondNow, calendar: cal, timeZone: utc)
        XCTAssertEqual(backing.writeCallCount, 1,
                       "Same-day same-TZ second tick must NOT write (baseline unchanged)")
        // Content invariant: dict still has exactly one entry, unchanged.
        XCTAssertEqual(backing.dict.count, 1)
    }
}
