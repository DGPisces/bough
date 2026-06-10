import XCTest
@testable import Bough
@testable import BoughCore

@MainActor
final class UsageStoreContinuityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDir: URL!
    private var lockedEnvironment = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UsageStoreContinuityTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreContinuityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TestHelpers.processEnvironmentLock.lock()
        lockedEnvironment = true
    }

    override func tearDownWithError() throws {
        if let defaults, let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        defaults = nil
        suiteName = nil
        if lockedEnvironment {
            TestHelpers.processEnvironmentLock.unlock()
            lockedEnvironment = false
        }
        try super.tearDownWithError()
    }

    func testStartupRestoresPersistedCodexSnapshotAsStaleBeforeRefresh() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let path = storePath()
        let continuity = try UsageContinuityStore(path: path)
        let first = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { current },
            continuityStore: continuity
        )
        first.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 24))

        current = Date(timeIntervalSince1970: 1_100)
        let reopenedContinuity = try UsageContinuityStore(path: path)
        let restored = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { current },
            continuityStore: reopenedContinuity
        )
        let snapshot = restored.snapshot(for: .codex)

        XCTAssertEqual(snapshot.availability, .stale(reason: UsageContinuityStore.restoredReason))
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 24)
        XCTAssertEqual(snapshot.weekly.staleReason, UsageContinuityStore.restoredReason)
        XCTAssertNotNil(snapshot.today)
    }

    func testLegacyDailyJSONMigrationDoesNotFlagFirstLaunchRecovery() throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempDir.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }

        let baseline = DailyBaseline(
            tool: .codex,
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 36,
            todayAllowanceOfWeek: 16,
            timeZoneIdentifier: TimeZone(identifier: "UTC")!.identifier,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        try AtomicJSONStore.write([UsageTool.codex.rawValue: baseline], to: "usage-daily.json")

        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_100) },
            continuityStore: continuity
        )

        XCTAssertFalse(store.isFirstLaunchBaseline(for: .codex))
        XCTAssertNotNil(try continuity.migrationDate(id: "usage-daily-json-v1"))
        let migrated = try XCTUnwrap(continuity.latestDailyState(tool: .codex, localDate: "2026-05-14"))
        XCTAssertEqual(migrated.weeklyUsedAtDayStart, 36)
    }

    func testContinuityRowsAreProviderIsolated() throws {
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_000) },
            continuityStore: continuity
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))
        store.applyClaudeCodePayload(Self.claudePayload(weeklyUsedPercent: 33), receivedAt: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(try continuity.acceptedSampleCount(tool: .codex), 1)
        XCTAssertEqual(try continuity.acceptedSampleCount(tool: .claudeCode), 1)
        XCTAssertEqual(try continuity.latestSnapshot(tool: .codex)?.weekly.snapshot?.usedPercent, 20)
        XCTAssertEqual(try continuity.latestSnapshot(tool: .claudeCode)?.weekly.snapshot?.usedPercent, 33)
    }

    func testHelperOwnedModeDoesNotWriteAppAppliedAcceptedSamples() throws {
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_000) },
            continuityStore: continuity,
            continuityWriteMode: .helperOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))
        store.applyClaudeCodePayload(Self.claudePayload(weeklyUsedPercent: 33), receivedAt: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(try continuity.acceptedSampleCount(tool: .codex), 0)
        XCTAssertEqual(try continuity.acceptedSampleCount(tool: .claudeCode), 0)
    }

    func testAppOwnedModeStillWritesAcceptedSamples() throws {
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_000) },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))

        XCTAssertEqual(try continuity.acceptedSampleCount(tool: .codex), 1)
    }

    func testAppOwnedModeRecordsRecoveryEdgeOnce() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { current },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 2_000, fiveHourUsedPercent: 100, weeklyUsedPercent: 100))
        current = Date(timeIntervalSince1970: 1_100)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, fiveHourUsedPercent: 20, weeklyUsedPercent: 20))
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, fiveHourUsedPercent: 20, weeklyUsedPercent: 20))

        let records = try continuity.recoveryEdgeRecords(tool: .codex)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.windowKind)), [.fiveHour, .weekly])
    }

    func testAppOwnedModePersistsCandidateForTwoSampleRecoveryConfirmation() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { current },
            continuityStore: continuity,
            continuityWriteMode: .appOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 3_000, fiveHourUsedPercent: 100, weeklyUsedPercent: 20))
        current = Date(timeIntervalSince1970: 1_100)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 3_000, fiveHourUsedPercent: 60, weeklyUsedPercent: 20))

        let resetIntervalID = "fiveHour:300:2000"
        XCTAssertEqual(try continuity.recoveryEdgeRecords(tool: .codex), [])
        XCTAssertNotNil(try continuity.recoveryCandidate(tool: .codex, windowKind: .fiveHour, resetIntervalID: resetIntervalID))

        current = Date(timeIntervalSince1970: 1_200)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 3_000, fiveHourUsedPercent: 55, weeklyUsedPercent: 20))

        let records = try continuity.recoveryEdgeRecords(tool: .codex)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.windowKind, .fiveHour)
        XCTAssertNil(try continuity.recoveryCandidate(tool: .codex, windowKind: .fiveHour, resetIntervalID: resetIntervalID))
    }

    func testHelperOwnedModeDoesNotRecordAppRecoveryEdges() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let continuity = try UsageContinuityStore(path: storePath())
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { current },
            continuityStore: continuity,
            continuityWriteMode: .helperOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 2_000, fiveHourUsedPercent: 100, weeklyUsedPercent: 100))
        current = Date(timeIntervalSince1970: 1_100)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, fiveHourUsedPercent: 20, weeklyUsedPercent: 20))

        XCTAssertEqual(try continuity.recoveryEdgeRecords(tool: .codex), [])
    }

    func testHelperOwnedModeRestoresPersistedSnapshotsButDoesNotOverwriteThem() throws {
        let path = storePath()
        do {
            let continuity = try UsageContinuityStore(path: path)
            let writer = UsageStore(
                defaults: defaults,
                scheduler: RecordingContinuityScheduler(),
                monitorClaudeCode: false,
                now: { Date(timeIntervalSince1970: 1_000) },
                continuityStore: continuity,
                continuityWriteMode: .appOwned
            )
            writer.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))
        }

        let reopenedContinuity = try UsageContinuityStore(path: path)
        let reader = UsageStore(
            defaults: defaults,
            scheduler: RecordingContinuityScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_100) },
            continuityStore: reopenedContinuity,
            continuityWriteMode: .helperOwned
        )

        XCTAssertEqual(reader.snapshot(for: .codex).availability, .stale(reason: UsageContinuityStore.restoredReason))
        XCTAssertEqual(reader.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)

        reader.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 44))

        XCTAssertEqual(try reopenedContinuity.acceptedSampleCount(tool: .codex), 1)
        XCTAssertEqual(try reopenedContinuity.latestSnapshot(tool: .codex)?.weekly.snapshot?.usedPercent, 20)
    }

    // MARK: - Helpers

    private func storePath() -> String {
        tempDir.appendingPathComponent("usage-continuity.sqlite").path
    }

    private static func codexResult(
        weeklyReset: Int64,
        fiveHourUsedPercent: Int64 = 10,
        weeklyUsedPercent: Int64 = 20
    ) -> [String: AnyCodableLike] {
        [
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitId": .string("codex"),
                    "primary": .object(["usedPercent": .int(fiveHourUsedPercent), "windowDurationMins": .int(300), "resetsAt": .int(2_000)]),
                    "secondary": .object(["usedPercent": .int(weeklyUsedPercent), "windowDurationMins": .int(10_080), "resetsAt": .int(weeklyReset)]),
                    "planType": .string("prolite")
                ])
            ])
        ]
    }

    private static func claudePayload(
        fiveHourUsedPercent: Int = 12,
        weeklyUsedPercent: Int = 24,
        weeklyReset: Int64 = 100_000
    ) -> Data {
        Data(
            """
            {
              "version": 1,
              "model": {"display_name": "Claude Sonnet 4"},
              "rate_limits": {
                "five_hour": {
                  "used_percent": \(fiveHourUsedPercent),
                  "resets_at": 2000,
                  "window_duration_mins": 300
                },
                "seven_day": {
                  "used_percent": \(weeklyUsedPercent),
                  "resets_at": \(weeklyReset),
                  "window_duration_mins": 10080
                }
              }
            }
            """.utf8
        )
    }
}

private final class RecordingContinuityScheduler: UsageRefreshScheduling {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func stop() {}
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }

    var staleReason: String? {
        if case .stale(_, let reason) = self { return reason }
        return nil
    }
}
