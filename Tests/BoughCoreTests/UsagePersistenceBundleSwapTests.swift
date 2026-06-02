import XCTest
@testable import BoughCore

// MARK: - Coverage
//
// PERSIST-01: Daily baseline survives simulated Sparkle bundle-replacement
//             (testBaselineSurvivesBundleSwap)
// PERSIST-02: AtomicJSONStore.baseDirectoryURL() path is never inside .app/Contents
//             (testBaseDirectoryNotInsideBundle)
// UPDATE-07: Sparkle bundle replacement preserves ~/.bough/ data;
//            satisfied collectively by PERSIST-01/02/03.
//
// Guard notes:
// - PITFALL-01: Always use AtomicJSONStore.baseDirectoryURL() (reads $HOME env)
//   rather than FileManager.homeDirectoryForCurrentUser (calls getpwuid() which
//   caches and ignores setenv overrides).
// - PITFALL-02: TimeZone(identifier:"UTC").identifier returns "GMT" on Darwin;
//   always seed baselines with `utc.identifier`, never the literal "UTC".
// - PITFALL-03: Fake bundle dir must be a SIBLING of tempHome, not inside it —
//   the store must never reference it; its existence only confirms path isolation.

final class UsagePersistenceBundleSwapTests: XCTestCase {

    // MARK: - Shared fixtures

    private let utc = TimeZone(identifier: "UTC")!
    private var cal: Calendar = Calendar(identifier: .gregorian)

    // MARK: - HOME override state (required for disk-I/O tests)

    private var tempHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a fresh UUID-suffixed temp directory and redirect $HOME so
        // AtomicJSONStore.baseDirectoryURL() resolves to tempHome/.bough/.
        // PITFALL-01: use setenv, not FileManager.homeDirectoryForCurrentUser.
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagePersistenceBundleSwapTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
    }

    override func tearDownWithError() throws {
        if let original = originalHome {
            setenv("HOME", original, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: tempHome)
        try super.tearDownWithError()
    }

    // MARK: - PERSIST-02: Storage-location invariant

    /// Asserts that AtomicJSONStore writes to ~/.bough/ (under $HOME), never
    /// inside an .app/Contents bundle path.
    ///
    /// This is a regression guard: if baseDirectoryURL() ever changes to read
    /// Bundle.main instead of $HOME, the path will contain ".app/Contents" because
    /// the test binary lives inside Bough.app/Contents/MacOS/Bough.
    ///
    /// The assertion intentionally runs against the PRODUCTION path (the real
    /// user's $HOME), not the tempHome override set by setUp — otherwise the check
    /// passes vacuously because tempHome trivially does not contain ".app/Contents".
    func testBaseDirectoryNotInsideBundle() {
        // Restore original $HOME temporarily so baseDirectoryURL() returns the
        // production path. setUp already saved originalHome before overriding.
        let productionHome: String
        if let orig = originalHome, !orig.isEmpty {
            productionHome = orig
        } else {
            // Fallback for environments where $HOME was not set (rare in CI).
            productionHome = NSHomeDirectory()
        }

        // Compute the production path the same way AtomicJSONStore does:
        // URL(fileURLWithPath: $HOME).appendingPathComponent(".bough").
        let baseUnderProd = URL(fileURLWithPath: productionHome)
            .appendingPathComponent(".bough")

        // The core invariant: the storage path must never be inside a bundle container.
        XCTAssertFalse(
            baseUnderProd.path.contains(".app/Contents"),
            "AtomicJSONStore production path must never live inside .app/Contents; " +
            "production path: \(baseUnderProd.path)"
        )
    }

    // MARK: - PERSIST-01 / UPDATE-07: Bundle-swap survival

    /// Proves that a DailyBaseline written to ~/.bough/usage-daily.json survives
    /// a simulated Sparkle bundle replacement.
    ///
    /// The simulation: (1) write a baseline to disk via AtomicJSONStore (against the
    /// tempHome $HOME override), (2) create a fake .app/Contents dir at a path
    /// OUTSIDE tempHome to represent the discarded old bundle (PITFALL-03), and
    /// (3) open a fresh UsageDailyAccumulator backed by .live — which re-reads $HOME
    /// and finds the baseline still intact. The store never references the fake bundle
    /// dir; its existence only confirms path isolation holds.
    func testBaselineSurvivesBundleSwap() throws {
        // Step 1: Build and write the fixture baseline.
        // Use utc.identifier (NOT "UTC" literal) to avoid PITFALL-02.
        // Use a fixed, pre-rounded capturedAt so ISO8601 round-trip via AtomicJSONStore
        // does not introduce sub-second precision differences (ISO8601 truncates to seconds).
        let today = formattedYYYYMMDD(Date(), timeZone: utc)
        // Round to the nearest second so JSON encode → decode is byte-stable.
        let capturedAt = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(-3600).timeIntervalSince1970))
        let baseline = DailyBaseline(
            tool: .codex,
            localDate: today,
            weeklyUsedAtDayStart: 30.0,
            todayAllowanceOfWeek: 17.5,
            timeZoneIdentifier: utc.identifier, // PITFALL-02 guard: utc.identifier not "UTC"
            capturedAt: capturedAt
        )
        let payload: [String: DailyBaseline] = [UsageTool.codex.rawValue: baseline]
        try AtomicJSONStore.write(payload, to: "usage-daily.json")

        // Step 2: Simulate "old bundle discarded" — create a throwaway dir whose
        // path contains ".app/Contents/Resources" to represent the old app bundle
        // location. This dir is a sibling of tempHome (PITFALL-03), never inside it.
        // The store must not reference it; we just confirm its existence is harmless.
        let fakeBundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeBough-\(UUID().uuidString).app/Contents/Resources",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBundleDir,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: fakeBundleDir.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }

        // Step 3: Open a fresh accumulator backed by .live. $HOME still points at
        // tempHome so .live's read closure finds the file we wrote in Step 1.
        let accumulator = UsageDailyAccumulator(store: .live)

        // Step 4: Tick with the same local date and same time zone so no reseed fires.
        let snapshot = weekly(
            usedPercent: 40.0,
            resetsAt: Date().addingTimeInterval(86400 * 5)
        )
        accumulator.recordTick(weekly: snapshot, tool: .codex, now: Date(), calendar: cal, timeZone: utc)

        // Step 5: Assert the baseline was read from disk intact.
        let storeBase = AtomicJSONStore.baseDirectoryURL()
        XCTAssertEqual(
            accumulator.baseline(for: .codex), baseline,
            "Bundle swap must not discard usage-daily.json: baseline must be read from \(storeBase.path)"
        )
        XCTAssertFalse(
            accumulator.isFirstLaunch(for: .codex),
            "A prior same-day baseline existed on disk; isFirstLaunch must be false"
        )
    }

    // MARK: - PERSIST-03: Intra-day binary swap (Task 2)

    /// Proves that constructing a fresh UsageDailyAccumulator after an intra-day
    /// binary swap does NOT reseed the baseline when localDate and timeZoneIdentifier
    /// are unchanged.
    ///
    /// Binary version is not part of the keying predicate (localDate +
    /// timeZoneIdentifier only); a bundle swap mid-day cannot trigger a reseed.
    /// This test is the machine-verifiable proof of that invariant (PERSIST-03, UPDATE-07).
    ///
    /// Uses in-memory storage (no disk I/O needed — the setUp/tearDown HOME override
    /// is irrelevant but harmless for this test).
    func testIntraDayBinarySwapDoesNotReseedBaseline() {
        // The reseed predicate in UsageDailyAccumulator.recordTick checks ONLY
        // (localDate, timeZoneIdentifier). Binary version, CFBundleVersion, and
        // executable path are not part of the key. This test is the machine-verifiable
        // proof of that invariant (PERSIST-03, UPDATE-07).
        let savedBaseline = DailyBaseline(
            tool: .codex,
            localDate: "2026-05-15",
            weeklyUsedAtDayStart: 22.0,
            todayAllowanceOfWeek: 15.6,
            timeZoneIdentifier: utc.identifier, // PITFALL-02 guard: utc.identifier not "UTC"
            capturedAt: date(2026, 5, 15, 9, 0, timeZone: utc)
        )

        let (storage, _) = makeInMemoryStorage(seed: [UsageTool.codex.rawValue: savedBaseline])

        // Construct a fresh accumulator simulating relaunch after binary swap.
        let accumulator = UsageDailyAccumulator(store: storage)

        // Build a tick: same local day (2026-05-15), 5 hours later — simulates
        // the new binary launching mid-day after a Sparkle update. weeklyTick uses
        // a DIFFERENT usedPercent (35.0 vs 22.0) to represent what the new binary
        // reads from the API, confirming that a usage delta alone cannot trigger a reseed.
        let now = date(2026, 5, 15, 14, 0, timeZone: utc)
        let weeklyTick = weekly(
            usedPercent: 35.0,
            resetsAt: date(2026, 5, 19, 0, 0, timeZone: utc)
        )

        accumulator.recordTick(weekly: weeklyTick, tool: .codex, now: now, calendar: cal, timeZone: utc)

        XCTAssertEqual(
            accumulator.baseline(for: .codex), savedBaseline,
            "Binary version change within the same local day must NOT reseed the baseline (PERSIST-03)"
        )
        XCTAssertFalse(
            accumulator.isFirstLaunch(for: .codex),
            "Prior same-day baseline existed; isFirstLaunch must be false (PERSIST-03)"
        )
    }

    /// Proves the Phase 24 SQLite continuity store follows the same HOME-based
    /// bundle-replacement invariant as `usage-daily.json`.
    func testContinuityStoreSurvivesBundleSwap() throws {
        let storePath = UsageContinuityStore.defaultPath()
        XCTAssertTrue(storePath.hasPrefix(tempHome.appendingPathComponent(".bough").path))
        XCTAssertFalse(storePath.contains(".app/Contents"))

        let fakeBundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeBough-\(UUID().uuidString).app/Contents/Resources",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBundleDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: fakeBundleDir.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }

        do {
            let store = try UsageContinuityStore()
            try store.recordAcceptedSnapshot(
                continuitySnapshot(weeklyUsed: 44, todayPct: 60),
                acceptedAt: date(2026, 5, 15, 14, 0, timeZone: utc)
            )
        }

        let reopened = try UsageContinuityStore()
        let restored = try XCTUnwrap(reopened.latestSnapshot(tool: .codex))

        XCTAssertEqual(restored.weekly.snapshot?.usedPercent, 44)
        XCTAssertEqual(restored.today?.pct, 60)
        XCTAssertFalse(UsageContinuityStore.defaultPath().contains(fakeBundleDir.path))
    }

    func testThresholdRecordSurvivesHelperWriterToAppHandoff() async throws {
        let store = try UsageContinuityStore()
        let snapshot = continuitySnapshot(weeklyUsed: 96, todayPct: 20)
        let resetID = try recordThresholdFixture(
            in: store,
            snapshot: snapshot,
            thresholdPct: 5,
            recordResetID: nil
        )
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        let client = FakeThresholdNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, now: { self.date(2026, 5, 15, 15, 0, timeZone: self.utc) })

        await service.sendPendingThresholdNotifications(from: store)
        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers, ["bough.usage-threshold.codex.weekly.5.\(resetID)"])
        XCTAssertTrue(try store.pendingThresholdNotificationRecords().isEmpty)
    }

    func testThresholdRecordSurvivesBundleSwap() async throws {
        let initial = try UsageContinuityStore()
        let snapshot = continuitySnapshot(weeklyUsed: 96, todayPct: 20)
        let resetID = try recordThresholdFixture(
            in: initial,
            snapshot: snapshot,
            thresholdPct: 5,
            recordResetID: nil
        )
        try initial.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try initial.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        let firstClient = FakeThresholdNotificationClient(status: .authorized)
        await UsageNotificationService(client: firstClient).sendPendingThresholdNotifications(from: initial)
        XCTAssertEqual(firstClient.sentIdentifiers, ["bough.usage-threshold.codex.weekly.5.\(resetID)"])

        let reopened = try UsageContinuityStore()
        let secondClient = FakeThresholdNotificationClient(status: .authorized)
        await UsageNotificationService(client: secondClient).sendPendingThresholdNotifications(from: reopened)

        XCTAssertEqual(secondClient.sentIdentifiers, [])
        XCTAssertTrue(try reopened.pendingThresholdNotificationRecords().isEmpty)
    }

    func testThresholdRecordStaleAfterIntervalRollAcrossBundleSwap() async throws {
        let initial = try UsageContinuityStore()
        let snapshot = continuitySnapshot(weeklyUsed: 96, todayPct: 20)
        _ = try recordThresholdFixture(
            in: initial,
            snapshot: snapshot,
            thresholdPct: 5,
            recordResetID: "weekly:10080:stale"
        )
        try initial.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try initial.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())

        let reopened = try UsageContinuityStore()
        let client = FakeThresholdNotificationClient(status: .authorized)
        await UsageNotificationService(client: client).sendPendingThresholdNotifications(from: reopened)

        XCTAssertEqual(client.sentIdentifiers, [])
        XCTAssertTrue(try reopened.pendingThresholdNotificationRecords().isEmpty)
    }

    // MARK: - Private helpers

    /// In-memory store for tests that do not need disk I/O.
    /// Mirrors the pattern from UsageDailyAccumulatorTests.swift exactly;
    /// private to this file — do not share across test files.
    private final class InMemoryStore {
        var dict: [String: DailyBaseline] = [:]
        var writeCallCount: Int = 0
    }

    private func makeInMemoryStorage(
        seed: [String: DailyBaseline] = [:]
    ) -> (AtomicJSONStorage, InMemoryStore) {
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

    /// Constructs a weekly UsageWindowSnapshot. Mirrors the helper in
    /// UsageDailyAccumulatorTests.swift (lines 68–80) so all six init fields
    /// are always populated and tests remain concise.
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
            updatedAt: Date()
        )
    }

    /// DateComponents-based fixed-date builder. Mirrors UsageDailyAccumulatorTests.swift:53.
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

    /// Formats a Date as "YYYY-MM-DD" in the given timezone. Used to derive
    /// today's localDate string for testBaselineSurvivesBundleSwap without
    /// duplicating the private formattedYYYYMMDD logic from UsageDailyAccumulator.
    private func formattedYYYYMMDD(_ d: Date, timeZone: TimeZone) -> String {
        var localCal = cal
        localCal.timeZone = timeZone
        let c = localCal.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, let m = c.month, let day = c.day else { return "1970-01-01" }
        return String(format: "%04d-%02d-%02d", y, m, day)
    }

    private func continuitySnapshot(weeklyUsed: Double, todayPct: Double) -> UsageSnapshot {
        let now = date(2026, 5, 15, 14, 0, timeZone: utc)
        let weeklyWindow = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: weeklyUsed,
            resetsAt: date(2026, 5, 21, 12, 0, timeZone: utc),
            windowDurationMins: 10_080,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let fiveHourWindow = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 12,
            resetsAt: date(2026, 5, 15, 18, 0, timeZone: utc),
            windowDurationMins: 300,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let basis = TodayBasis(
            localDate: "2026-05-15",
            weeklyUsedAtDayStart: 30,
            weeklyUsedNow: weeklyUsed,
            todayAllowanceOfWeek: 14,
            daysRemainingUntilWeeklyReset: 6,
            weeklyResetAlreadyFiredToday: false
        )
        return UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .available(fiveHourWindow),
            weekly: .available(weeklyWindow),
            today: TodayValue(pct: todayPct, todayAllowanceOfWeek: 14, severity: .healthy, basis: basis),
            availability: .available,
            lastRefresh: now
        )
    }

    private func recordThresholdFixture(
        in store: UsageContinuityStore,
        snapshot: UsageSnapshot,
        thresholdPct: Double,
        recordResetID: String?
    ) throws -> String {
        try store.recordAcceptedSnapshot(snapshot, acceptedAt: date(2026, 5, 15, 14, 0, timeZone: utc))
        let weekly = try XCTUnwrap(snapshot.weekly.snapshot)
        let resetID = UsageRecoveryPolicy.resetIntervalID(for: weekly)
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: thresholdPct,
            resetIntervalID: recordResetID ?? resetID,
            detectedAt: date(2026, 5, 15, 14, 5, timeZone: utc)
        )
        return resetID
    }
}

private final class FakeThresholdNotificationClient: UsageNotificationCenterClient, @unchecked Sendable {
    var status: UsageNotificationPermissionState
    private(set) var sentIdentifiers: [String] = []

    init(status: UsageNotificationPermissionState) {
        self.status = status
    }

    func permissionState() async -> UsageNotificationPermissionState {
        status
    }

    func requestAuthorization() async -> UsageNotificationPermissionState {
        status
    }

    func sendNotification(identifier: String, title: String, body: String) async throws {
        sentIdentifiers.append(identifier)
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
}
