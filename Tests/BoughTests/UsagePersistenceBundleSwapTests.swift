import XCTest
@testable import Bough
@testable import BoughCore

/// Phase 28 / Plan 01 / V040-QUAL-01 reproduction fixtures.
///
/// These six rows reproduce the Today-usage 100% regression that fires after
/// manually quitting `Bough.app`, after relaunch, and after a Sparkle bundle
/// replacement, in both helper-disabled (app-owned) and helper-enabled
/// (helper-owned) writer modes. Each fixture seeds the indicated persistence,
/// instantiates a fresh `UsageStore`, drives one fresh provider sample, and
/// asserts that the resulting forecast is NOT the pct=100 placeholder.
///
/// Plan deviation: the plan listed `Tests/BoughCoreTests/UsagePersistenceBundleSwapTests.swift`
/// as the host file. `UsageStore.applyCodexRateLimitResult` lives in the
/// `Bough` executable target, which `BoughCoreTests` cannot import. The fixtures
/// were placed in this `Tests/BoughTests` file with the same name per the plan's
/// "Claude's discretion" clause for test target placement.
@MainActor
final class UsagePersistenceBundleSwapTests: XCTestCase {

    private var tempHome: URL!
    private var originalHome: String?
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var lockedEnvironment = false
    private let tz = TimeZone.current
    private let cal = Calendar.current

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagePersistenceBundleSwapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        TestHelpers.processEnvironmentLock.lock()
        lockedEnvironment = true
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)

        suiteName = "UsagePersistenceBundleSwapTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if lockedEnvironment {
            if let original = originalHome { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        if lockedEnvironment {
            TestHelpers.processEnvironmentLock.unlock()
            lockedEnvironment = false
        }
        try super.tearDownWithError()
    }

    // MARK: - Reproduction matrix

    /// R1: Manual `Bough.app` quit → relaunch, app-owned writer mode. Both
    /// stores seeded with today's baseline. Cold start should restore the
    /// snapshot and the first fresh sample should compute the correct Today %.
    func test_today_percent_survives_cold_start_R1_manual_quit_app_owned() throws {
        let now = Date()
        try seedJSON(localDate: try today(now: now), weeklyUsedAtDayStart: 20, tz: tz)
        let path = continuityPath()
        try seedSQLite(path: path, localDate: try today(now: now), weeklyUsed: 35, todayPct: 70)

        let continuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        XCTAssertTrue(store.applyCodexRateLimitResult(Self.codexResult(weeklyUsedPercent: 38)))
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R1",
            weeklyUsedAtDayStart: 20,
            weeklyUsedNow: 38,
            todayAllowanceOfWeek: 80.0 / 7.0
        )
    }

    /// R2: Manual `Bough.app` quit → relaunch, helper-owned writer mode. App
    /// reads continuity after helper accepted the new sample via
    /// `UsageMonitorRunner.acceptCodexRateLimitResult`.
    func test_today_percent_survives_cold_start_R2_manual_quit_helper_owned() throws {
        let now = Date()
        try seedJSON(localDate: try today(now: now), weeklyUsedAtDayStart: 20, tz: tz)
        let path = continuityPath()
        try seedSQLite(path: path, localDate: try today(now: now), weeklyUsed: 35, todayPct: 70)

        // Helper processes the fresh sample first.
        let helperContinuity = try UsageContinuityStore(path: path)
        let runner = UsageMonitorRunner(
            continuityStore: helperContinuity,
            statusPath: tempHome.appendingPathComponent(".bough/usage-monitor-status.json").path,
            now: { now },
            calendar: cal,
            timeZone: tz
        )
        let helperOutcome = runner.acceptCodexRateLimitResult(
            Self.codexResult(weeklyUsedPercent: 38),
            receivedAt: now
        )
        guard case .accepted = helperOutcome else {
            XCTFail("Helper did not accept the fresh sample (R2): \(helperOutcome)")
            return
        }

        // App opens in helper-owned mode and restores the helper-written snapshot.
        let appContinuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: appContinuity,
            continuityWriteMode: .helperOwned
        )
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R2",
            weeklyUsedAtDayStart: 20,
            weeklyUsedNow: 38,
            todayAllowanceOfWeek: 80.0 / 7.0
        )
    }

    func test_usage_monitor_status_file_is_private_when_helper_creates_bough_dir() throws {
        let now = Date()
        let statusURL = tempHome.appendingPathComponent(".bough/usage-monitor-status.json")
        let continuity = try UsageContinuityStore(path: tempHome.appendingPathComponent("monitor-continuity.sqlite").path)
        let runner = UsageMonitorRunner(
            continuityStore: continuity,
            statusPath: statusURL.path,
            now: { now },
            calendar: cal,
            timeZone: tz
        )

        let outcome = runner.acceptCodexRateLimitResult(
            Self.codexResult(weeklyUsedPercent: 38),
            receivedAt: now
        )

        guard case .accepted = outcome else {
            XCTFail("Helper did not accept the fresh sample: \(outcome)")
            return
        }

        XCTAssertEqual(
            try posixPermissions(statusURL.deletingLastPathComponent()),
            BoughPrivateStorage.directoryPermissions
        )
        XCTAssertEqual(
            try posixPermissions(statusURL),
            BoughPrivateStorage.filePermissions
        )
    }

    /// R3: Same-session relaunch with stale `.stale("Restored from continuity store")`
    /// snapshot replacing the live snapshot in `UsageStore.snapshots`. App-owned mode.
    func test_today_percent_survives_cold_start_R3_relaunch_app_owned() throws {
        let now = Date()
        try seedJSON(localDate: try today(now: now), weeklyUsedAtDayStart: 30, tz: tz)
        let path = continuityPath()
        try seedSQLite(path: path, localDate: try today(now: now), weeklyUsed: 45, todayPct: 60)

        let continuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        XCTAssertTrue(store.applyCodexRateLimitResult(Self.codexResult(weeklyUsedPercent: 48)))
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R3",
            weeklyUsedAtDayStart: 30,
            weeklyUsedNow: 48,
            todayAllowanceOfWeek: 70.0 / 7.0
        )
    }

    /// R4: Same-session relaunch in helper-owned mode. Helper accepts first;
    /// app then restores and displays.
    func test_today_percent_survives_cold_start_R4_relaunch_helper_owned() throws {
        let now = Date()
        try seedJSON(localDate: try today(now: now), weeklyUsedAtDayStart: 30, tz: tz)
        let path = continuityPath()
        try seedSQLite(path: path, localDate: try today(now: now), weeklyUsed: 45, todayPct: 60)

        let helperContinuity = try UsageContinuityStore(path: path)
        let runner = UsageMonitorRunner(
            continuityStore: helperContinuity,
            statusPath: tempHome.appendingPathComponent(".bough/usage-monitor-status.json").path,
            now: { now },
            calendar: cal,
            timeZone: tz
        )
        let helperOutcome = runner.acceptCodexRateLimitResult(
            Self.codexResult(weeklyUsedPercent: 48),
            receivedAt: now
        )
        guard case .accepted = helperOutcome else {
            XCTFail("Helper did not accept the fresh sample (R4): \(helperOutcome)")
            return
        }

        let appContinuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: appContinuity,
            continuityWriteMode: .helperOwned
        )
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R4",
            weeklyUsedAtDayStart: 30,
            weeklyUsedNow: 48,
            todayAllowanceOfWeek: 70.0 / 7.0
        )
    }

    /// R5: Sparkle bundle replacement consequence. SQLite-only seed (legacy
    /// JSON absent — Pitfall 3 in 28-RESEARCH says do NOT also recreate JSON in
    /// setUp, because that masks the contamination this row asserts).
    func test_today_percent_survives_cold_start_R5_sparkle_bundle_swap() throws {
        let now = Date()
        // Intentionally no seedJSON call. usage-daily.json is absent.
        let path = continuityPath()
        try seedSQLite(path: path, localDate: try today(now: now), weeklyUsed: 28, todayPct: 55)

        let continuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        XCTAssertTrue(store.applyCodexRateLimitResult(Self.codexResult(weeklyUsedPercent: 30)))
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R5",
            weeklyUsedAtDayStart: 20,
            weeklyUsedNow: 30,
            todayAllowanceOfWeek: 14
        )
    }

    /// R6: Dual-store contamination where JSON carries a stale yesterday
    /// baseline but SQLite carries today's daily_state. The legacy JSON
    /// baseline overrides the SQLite source of truth — the cold-start ordering
    /// bug at the heart of V040-QUAL-01.
    func test_today_percent_survives_cold_start_R6_dual_store_contamination() throws {
        let now = Date()
        let yesterday = try today(now: now.addingTimeInterval(-86400))
        let today = try today(now: now)
        try seedJSON(localDate: yesterday, weeklyUsedAtDayStart: 20, tz: tz)
        let path = continuityPath()
        try seedSQLite(path: path, localDate: today, weeklyUsed: 35, todayPct: 70)

        let continuity = try UsageContinuityStore(path: path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingScheduler(),
            now: { now },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        XCTAssertTrue(store.applyCodexRateLimitResult(Self.codexResult(weeklyUsedPercent: 38)))
        let snap = store.snapshot(for: .codex)
        try assertToday(
            snap,
            now: now,
            row: "R6",
            weeklyUsedAtDayStart: 20,
            weeklyUsedNow: 38,
            todayAllowanceOfWeek: 14
        )
    }

    // MARK: - Assertion + helpers

    private func assertToday(
        _ snap: UsageSnapshot,
        now: Date,
        row: String,
        weeklyUsedAtDayStart: Double,
        weeklyUsedNow: Double,
        todayAllowanceOfWeek: Double
    ) throws {
        let todayValue = try XCTUnwrap(snap.today, "[\(row)] snapshot.today must be non-nil after a fresh sample")
        XCTAssertTrue(todayValue.pct.isFinite, "[\(row)] Today pct must be finite")
        let todayUsed = max(0, weeklyUsedNow - weeklyUsedAtDayStart)
        let expectedPct = ((todayAllowanceOfWeek - todayUsed) / todayAllowanceOfWeek) * 100.0
        XCTAssertEqual(
            todayValue.pct,
            expectedPct,
            accuracy: 0.0001,
            "[\(row)] Today pct must reflect the restored baseline and fresh weekly sample"
        )
        XCTAssertNotEqual(
            todayValue.pct, 100,
            "[\(row)] Today must not regress to 100% on cold start with seeded prior usage"
        )
        XCTAssertEqual(todayValue.todayAllowanceOfWeek, todayAllowanceOfWeek, accuracy: 0.0001)
        XCTAssertEqual(
            todayValue.basis.localDate, try today(now: now),
            "[\(row)] basis.localDate must match the live today's local date"
        )
        XCTAssertEqual(todayValue.basis.weeklyUsedAtDayStart, weeklyUsedAtDayStart, accuracy: 0.0001)
        XCTAssertEqual(todayValue.basis.weeklyUsedNow, weeklyUsedNow, accuracy: 0.0001)
        XCTAssertEqual(todayValue.basis.todayAllowanceOfWeek, todayAllowanceOfWeek, accuracy: 0.0001)
        XCTAssertFalse(todayValue.basis.weeklyResetAlreadyFiredToday)
    }

    private func continuityPath() -> String {
        tempHome.appendingPathComponent(".bough/usage-continuity.sqlite").path
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    private func today(now: Date) throws -> String {
        var localCal = cal
        localCal.timeZone = tz
        let c = localCal.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "%04d-%02d-%02d",
            try XCTUnwrap(c.year),
            try XCTUnwrap(c.month),
            try XCTUnwrap(c.day)
        )
    }

    private func seedJSON(localDate: String, weeklyUsedAtDayStart: Double, tz: TimeZone) throws {
        let baseline = DailyBaseline(
            tool: .codex,
            localDate: localDate,
            weeklyUsedAtDayStart: weeklyUsedAtDayStart,
            todayAllowanceOfWeek: (100.0 - weeklyUsedAtDayStart) / 7.0,
            timeZoneIdentifier: tz.identifier,
            capturedAt: Date().addingTimeInterval(-3600)
        )
        try AtomicJSONStore.write([UsageTool.codex.rawValue: baseline], to: "usage-daily.json")
    }

    private func seedSQLite(path: String, localDate: String, weeklyUsed: Double, todayPct: Double) throws {
        let store = try UsageContinuityStore(path: path)
        let now = Date().addingTimeInterval(-1800)
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: weeklyUsed,
            resetsAt: Date().addingTimeInterval(86400 * 3),
            windowDurationMins: 7 * 24 * 60,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let fiveHour = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 10,
            resetsAt: Date().addingTimeInterval(3600),
            windowDurationMins: 300,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let basis = TodayBasis(
            localDate: localDate,
            weeklyUsedAtDayStart: 20,
            weeklyUsedNow: weeklyUsed,
            todayAllowanceOfWeek: 14,
            daysRemainingUntilWeeklyReset: 3,
            weeklyResetAlreadyFiredToday: false
        )
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .available(fiveHour),
            weekly: .available(weekly),
            today: TodayValue(pct: todayPct, todayAllowanceOfWeek: 14, severity: .healthy, basis: basis),
            availability: .available,
            lastRefresh: now
        )
        try store.recordAcceptedSnapshot(snapshot, acceptedAt: now)
    }

    private static func codexResult(weeklyUsedPercent: Int64) -> [String: AnyCodableLike] {
        [
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitId": .string("codex"),
                    "primary": .object([
                        "usedPercent": .int(10),
                        "windowDurationMins": .int(300),
                        "resetsAt": .double(Date().addingTimeInterval(3600).timeIntervalSince1970)
                    ]),
                    "secondary": .object([
                        "usedPercent": .int(weeklyUsedPercent),
                        "windowDurationMins": .int(10_080),
                        "resetsAt": .double(Date().addingTimeInterval(86400 * 3).timeIntervalSince1970)
                    ]),
                    "planType": .string("prolite")
                ])
            ])
        ]
    }
}

private final class RecordingScheduler: UsageRefreshScheduling {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func stop() {}
}
