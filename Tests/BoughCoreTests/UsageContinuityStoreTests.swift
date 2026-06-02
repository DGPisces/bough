import XCTest
import SQLite3
@testable import BoughCore

final class UsageContinuityStoreTests: XCTestCase {
    private var tempDir: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let cal = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageContinuityStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testStoreCreatesSchemaAndUsesWALMode() throws {
        let store = try makeStore()

        XCTAssertEqual(try store.journalMode().lowercased(), "wal")
        XCTAssertEqual(try store.acceptedSampleCount(), 0)
    }

    func testAcceptedSamplesUseMonotonicOrderingAndIgnoreOlderProviderSamples() throws {
        let store = try makeStore()
        let first = snapshot(weeklyUsed: 20, weeklyUpdatedAt: date(2026, 5, 14, 10), acceptedAt: date(2026, 5, 14, 10))
        let older = snapshot(weeklyUsed: 25, weeklyUpdatedAt: date(2026, 5, 14, 9), acceptedAt: date(2026, 5, 14, 11))
        let newer = snapshot(weeklyUsed: 30, weeklyUpdatedAt: date(2026, 5, 14, 12), acceptedAt: date(2026, 5, 14, 12))

        let firstSeq = try store.recordAcceptedSnapshot(first, acceptedAt: date(2026, 5, 14, 10))
        let olderSeq = try store.recordAcceptedSnapshot(older, acceptedAt: date(2026, 5, 14, 11))
        let newerSeq = try store.recordAcceptedSnapshot(newer, acceptedAt: date(2026, 5, 14, 12))

        XCTAssertEqual(firstSeq, 1)
        XCTAssertNil(olderSeq)
        XCTAssertEqual(newerSeq, 2)
        XCTAssertEqual(try store.acceptedSampleCount(tool: .codex), 2)
        XCTAssertEqual(try store.latestSnapshot(tool: .codex)?.weekly.snapshot?.usedPercent, 30)
    }

    func testDailyStateResetBreadcrumbAndCarryForwardSurviveReopen() throws {
        let path = storePath()
        do {
            let store = try UsageContinuityStore(path: path)
            try store.recordAcceptedSnapshot(
                snapshot(
                    weeklyUsed: 4,
                    weeklyUpdatedAt: date(2026, 5, 14, 18),
                    acceptedAt: date(2026, 5, 14, 18),
                    today: resetToday()
                ),
                acceptedAt: date(2026, 5, 14, 18)
            )
        }

        let reopened = try UsageContinuityStore(path: path)
        let restored = try XCTUnwrap(reopened.latestSnapshot(tool: .codex))
        let daily = try XCTUnwrap(reopened.latestDailyState(tool: .codex, localDate: "2026-05-14"))

        XCTAssertEqual(restored.availability, .stale(reason: UsageContinuityStore.restoredReason))
        XCTAssertEqual(restored.today?.basis.resetProvenance, .explicitReset)
        XCTAssertEqual(daily.resetProvenance, .explicitReset)
        XCTAssertEqual(daily.carryForwardPreResetUsedPercent, 20)
        XCTAssertEqual(daily.carryForwardPostResetUsedPercent, 4)
        XCTAssertEqual(daily.peakWeeklyUsedPercent, 80)
        XCTAssertEqual(try reopened.resetBreadcrumbCount(tool: .codex), 1)
    }

    func testLegacyBaselineMigrationIsIdempotentAndLeavesJSONUntouched() throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempDir.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }

        let baseline = DailyBaseline(
            tool: .codex,
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 42,
            todayAllowanceOfWeek: 12,
            timeZoneIdentifier: utc.identifier,
            capturedAt: date(2026, 5, 14, 8)
        )
        try AtomicJSONStore.write([UsageTool.codex.rawValue: baseline], to: "usage-daily.json")
        let legacyURL = tempDir.appendingPathComponent(".bough/usage-daily.json")
        let before = try Data(contentsOf: legacyURL)

        let store = try makeStore()
        XCTAssertTrue(try store.importLegacyBaselines([.codex: baseline], migratedAt: date(2026, 5, 14, 9)))
        XCTAssertFalse(try store.importLegacyBaselines([.codex: baseline], migratedAt: date(2026, 5, 14, 10)))
        let after = try Data(contentsOf: legacyURL)
        let daily = try XCTUnwrap(store.latestDailyState(tool: .codex, localDate: "2026-05-14"))

        XCTAssertEqual(before, after)
        XCTAssertEqual(daily.weeklyUsedAtDayStart, 42)
        XCTAssertNotNil(try store.migrationDate(id: "usage-daily-json-v1"))
    }

    func testCorruptStoreIsPreservedAndFreshStoreRecordsRepair() throws {
        let path = storePath()
        try "not a sqlite database".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))

        let store = try UsageContinuityStore(path: path, now: { Date(timeIntervalSince1970: 1234) })
        let records = try store.repairRecords()
        try store.recordAcceptedSnapshot(snapshot(weeklyUsed: 10), acceptedAt: date(2026, 5, 14, 10))

        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: records[0].preservedPath))
        XCTAssertEqual(try store.acceptedSampleCount(), 1)
    }

    func testRecoveryReminderPreferencesDefaultOffAndPersistPerProviderWindow() throws {
        let store = try makeStore()
        let zero = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(try store.recoveryReminderPreference(tool: .codex, windowKind: .fiveHour), UsageRecoveryReminderPreference(
            tool: .codex,
            windowKind: .fiveHour,
            isEnabled: false,
            updatedAt: zero
        ))

        let updated = Date(timeIntervalSince1970: 1_234)
        try store.setRecoveryReminderPreference(tool: .codex, windowKind: .fiveHour, isEnabled: true, updatedAt: updated)
        try store.setRecoveryReminderPreference(tool: .claudeCode, windowKind: .weekly, isEnabled: true, updatedAt: updated)

        XCTAssertTrue(try store.recoveryReminderPreference(tool: .codex, windowKind: .fiveHour).isEnabled)
        XCTAssertFalse(try store.recoveryReminderPreference(tool: .codex, windowKind: .weekly).isEnabled)
        XCTAssertTrue(try store.recoveryReminderPreference(tool: .claudeCode, windowKind: .weekly).isEnabled)
    }

    func testRecoveryEdgesPersistAndDedupeAcrossReopen() throws {
        let path = storePath()
        let candidate = UsageRecoveryCandidate(
            tool: .codex,
            windowKind: .weekly,
            resetIntervalID: "weekly:10080:2000",
            acceptedSequence: 1,
            priorUsedPercent: 100,
            currentUsedPercent: 60,
            detectedAt: Date(timeIntervalSince1970: 1_900)
        )
        let edge = UsageRecoveryEdge(
            tool: .codex,
            windowKind: .weekly,
            resetIntervalID: "weekly:10080:2000",
            acceptedSequence: 2,
            priorUsedPercent: 100,
            currentUsedPercent: 12,
            resetProvenance: .explicitReset,
            detectedAt: Date(timeIntervalSince1970: 2_000)
        )

        do {
            let store = try UsageContinuityStore(path: path)
            try store.recordRecoveryCandidate(candidate)
            XCTAssertEqual(try store.recoveryCandidate(tool: .codex, windowKind: .weekly, resetIntervalID: candidate.resetIntervalID), candidate)
            try store.recordRecoveryEdge(edge)
            try store.clearRecoveryCandidate(tool: .codex, windowKind: .weekly, resetIntervalID: candidate.resetIntervalID)
            try store.recordRecoveryEdge(edge)
            XCTAssertNil(try store.recoveryCandidate(tool: .codex, windowKind: .weekly, resetIntervalID: candidate.resetIntervalID))
            XCTAssertTrue(try store.hasRecoveryEdge(tool: .codex, windowKind: .weekly, resetIntervalID: edge.resetIntervalID))
            XCTAssertEqual(try store.recoveryEdgeRecords().count, 1)
            try store.markRecoveryReminderCreated(
                tool: .codex,
                windowKind: .weekly,
                resetIntervalID: edge.resetIntervalID,
                reminderIdentifier: "reminder-1",
                firedAt: Date(timeIntervalSince1970: 2_100)
            )
        }

        let reopened = try UsageContinuityStore(path: path)
        let records = try reopened.recoveryEdgeRecords(tool: .codex)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reminderIdentifier, "reminder-1")
        XCTAssertEqual(records.first?.firedAt, Date(timeIntervalSince1970: 2_100))
    }

    func testThresholdNotificationPreferenceDefaultsOffPerTool() throws {
        let store = try makeStore()
        let zero = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            try store.thresholdNotificationPreference(tool: .codex),
            UsageThresholdNotificationPreference(tool: .codex, isEnabled: false, updatedAt: zero)
        )
        XCTAssertEqual(
            try store.thresholdNotificationPreference(tool: .claudeCode),
            UsageThresholdNotificationPreference(tool: .claudeCode, isEnabled: false, updatedAt: zero)
        )

        let updated = Date(timeIntervalSince1970: 1_234)
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: updated)

        XCTAssertTrue(try store.thresholdNotificationPreference(tool: .codex).isEnabled)
        XCTAssertFalse(try store.thresholdNotificationPreference(tool: .claudeCode).isEnabled)
    }

    func testThresholdNotificationPreferencePersistsAcrossReopen() throws {
        let path = storePath()
        let updated = Date(timeIntervalSince1970: 5_000)
        do {
            let store = try UsageContinuityStore(path: path)
            try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: updated)
            try store.setThresholdNotificationPreference(tool: .claudeCode, isEnabled: false, updatedAt: updated)
            // Overwrite to confirm ON CONFLICT path keeps single row per tool.
            try store.setThresholdNotificationPreference(
                tool: .codex,
                isEnabled: true,
                updatedAt: Date(timeIntervalSince1970: 6_000)
            )
        }

        let reopened = try UsageContinuityStore(path: path)
        let codex = try reopened.thresholdNotificationPreference(tool: .codex)
        let claude = try reopened.thresholdNotificationPreference(tool: .claudeCode)

        XCTAssertTrue(codex.isEnabled)
        XCTAssertEqual(codex.updatedAt, Date(timeIntervalSince1970: 6_000))
        XCTAssertFalse(claude.isEnabled)
        XCTAssertEqual(claude.updatedAt, updated)
    }

    func testRecordThresholdCrossingDedupsAcrossReopen() throws {
        let path = storePath()
        let intervalID = "weekly:10080:3000"
        let detected = Date(timeIntervalSince1970: 3_000)

        do {
            let store = try UsageContinuityStore(path: path)
            try store.recordThresholdCrossing(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: 20.0,
                resetIntervalID: intervalID,
                detectedAt: detected
            )
            // Same primary-key tuple — second insert is ignored by INSERT OR IGNORE.
            try store.recordThresholdCrossing(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: 20.0,
                resetIntervalID: intervalID,
                detectedAt: Date(timeIntervalSince1970: 3_500)
            )
            // Different threshold for the same window/interval — new row.
            try store.recordThresholdCrossing(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: 5.0,
                resetIntervalID: intervalID,
                detectedAt: Date(timeIntervalSince1970: 3_600)
            )
        }

        let reopened = try UsageContinuityStore(path: path)
        let pending = try reopened.pendingThresholdNotificationRecords()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.thresholdPct), [20.0, 5.0])
        XCTAssertEqual(pending.first?.detectedAt, detected)
        XCTAssertEqual(pending.first?.resetIntervalID, intervalID)
        XCTAssertNil(pending.first?.firedAt)
        XCTAssertNil(pending.first?.lastError)
    }

    func testPendingThresholdNotificationRecordsOrderedByDetection() throws {
        let store = try makeStore()
        try store.recordThresholdCrossing(
            tool: .claudeCode,
            windowKind: .weekly,
            thresholdPct: 0.0,
            resetIntervalID: "weekly:10080:4001",
            detectedAt: Date(timeIntervalSince1970: 4_200)
        )
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 20.0,
            resetIntervalID: "weekly:10080:4000",
            detectedAt: Date(timeIntervalSince1970: 4_000)
        )
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 5.0,
            resetIntervalID: "weekly:10080:4000",
            detectedAt: Date(timeIntervalSince1970: 4_100)
        )

        let pending = try store.pendingThresholdNotificationRecords()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.map(\.detectedAt.timeIntervalSince1970), [4_000, 4_100, 4_200])
        XCTAssertEqual(pending.map(\.tool), [.codex, .codex, .claudeCode])
    }

    func testMarkThresholdNotificationCreatedRemovesFromPending() throws {
        let path = storePath()
        let store = try UsageContinuityStore(path: path)
        let intervalID = "weekly:10080:5000"
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 5.0,
            resetIntervalID: intervalID,
            detectedAt: Date(timeIntervalSince1970: 5_000)
        )
        XCTAssertEqual(try store.pendingThresholdNotificationRecords().count, 1)

        try store.markThresholdNotificationCreated(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 5.0,
            resetIntervalID: intervalID,
            reminderIdentifier: "threshold-codex-5-5000",
            firedAt: Date(timeIntervalSince1970: 5_100)
        )

        XCTAssertTrue(try store.pendingThresholdNotificationRecords().isEmpty)

        // Confirm the fired row is preserved (not deleted) — direct probe per task spec.
        XCTAssertEqual(try Self.totalThresholdRecordCount(at: path), 1)

        // INSERT OR IGNORE on the same primary key must not resurrect the row as pending.
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 5.0,
            resetIntervalID: intervalID,
            detectedAt: Date(timeIntervalSince1970: 5_999)
        )
        XCTAssertTrue(try store.pendingThresholdNotificationRecords().isEmpty)
    }

    func testMarkThresholdNotificationFailedRecordsLastErrorWithoutSettingFiredAt() throws {
        let store = try makeStore()
        let intervalID = "weekly:10080:6000"
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 0.0,
            resetIntervalID: intervalID,
            detectedAt: Date(timeIntervalSince1970: 6_000)
        )
        try store.markThresholdNotificationFailed(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 0.0,
            resetIntervalID: intervalID,
            lastError: "transient_send_failed"
        )

        let pending = try store.pendingThresholdNotificationRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.firedAt)
        XCTAssertEqual(pending.first?.lastError, "transient_send_failed")
    }

    func testPendingThresholdNotificationRecordsExcludeTerminalFailuresButKeepTransientFailures() throws {
        let path = storePath()
        let store = try UsageContinuityStore(path: path)
        let cases: [(threshold: Double, intervalID: String, error: String)] = [
            (20.0, "weekly:10080:terminal-stale", "stale_interval"),
            (5.0, "weekly:10080:terminal-permission", "permission_denied"),
            (0.0, "weekly:10080:terminal-not-allowed", "notifications_not_allowed"),
            (20.0, "weekly:10080:transient", "transient_send_failed")
        ]

        for item in cases {
            try store.recordThresholdCrossing(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: item.threshold,
                resetIntervalID: item.intervalID,
                detectedAt: Date(timeIntervalSince1970: 8_000 + item.threshold)
            )
            try store.markThresholdNotificationFailed(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: item.threshold,
                resetIntervalID: item.intervalID,
                lastError: item.error
            )
        }

        let pending = try store.pendingThresholdNotificationRecords()
        XCTAssertEqual(pending.map(\.resetIntervalID), ["weekly:10080:transient"])
        XCTAssertEqual(pending.first?.lastError, "transient_send_failed")
        XCTAssertEqual(try Self.totalThresholdRecordCount(at: path), 4)
    }

    func testThresholdNotificationsMasterEnabledReadsOnlyMasterRow() throws {
        let store = try makeStore()

        XCTAssertFalse(try store.thresholdNotificationsMasterEnabled())

        try store.setThresholdNotificationPreference(
            tool: .codex,
            isEnabled: true,
            updatedAt: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertFalse(try store.thresholdNotificationsMasterEnabled())

        try store.setThresholdNotificationsMasterEnabled(
            isEnabled: true,
            updatedAt: Date(timeIntervalSince1970: 9_100)
        )
        XCTAssertTrue(try store.thresholdNotificationsMasterEnabled())
    }

    func testThresholdSchemaMigrationIsIdempotent() throws {
        let path = storePath()
        let intervalID = "weekly:10080:7000"
        do {
            let store = try UsageContinuityStore(path: path)
            try store.setThresholdNotificationPreference(
                tool: .codex,
                isEnabled: true,
                updatedAt: Date(timeIntervalSince1970: 7_000)
            )
            try store.recordThresholdCrossing(
                tool: .codex,
                windowKind: .weekly,
                thresholdPct: 20.0,
                resetIntervalID: intervalID,
                detectedAt: Date(timeIntervalSince1970: 7_100)
            )
        }

        // Re-running createSchema on an already-migrated store is a no-op (Phase 24 D-04).
        let reopened = try UsageContinuityStore(path: path)
        XCTAssertTrue(try reopened.thresholdNotificationPreference(tool: .codex).isEnabled)
        let pending = try reopened.pendingThresholdNotificationRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.thresholdPct, 20.0)
        XCTAssertEqual(pending.first?.resetIntervalID, intervalID)
    }

    // MARK: - Helpers

    private func makeStore() throws -> UsageContinuityStore {
        try UsageContinuityStore(path: storePath())
    }

    private func storePath() -> String {
        tempDir.appendingPathComponent("usage-continuity.sqlite").path
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

    private func window(
        kind: UsageWindowKind,
        used: Double,
        updatedAt: Date? = nil
    ) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: kind,
            usedPercent: used,
            resetsAt: date(2026, 5, 21, 12),
            windowDurationMins: kind == .weekly ? 10_080 : 300,
            sourceLabel: "test",
            updatedAt: updatedAt ?? date(2026, 5, 14, 10)
        )
    }

    private func snapshot(
        weeklyUsed: Double,
        weeklyUpdatedAt: Date? = nil,
        acceptedAt: Date = Date(timeIntervalSince1970: 1_000),
        today: TodayValue? = nil,
        tool: UsageTool = .codex
    ) -> UsageSnapshot {
        UsageSnapshot(
            tool: tool,
            planName: "prolite",
            fiveHour: .available(window(kind: .fiveHour, used: 10, updatedAt: weeklyUpdatedAt)),
            weekly: .available(window(kind: .weekly, used: weeklyUsed, updatedAt: weeklyUpdatedAt)),
            today: today,
            availability: .available,
            lastRefresh: acceptedAt
        )
    }

    private static func totalThresholdRecordCount(at path: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            throw NSError(domain: "TestProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close_v2(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM threshold_notification_records", -1, &stmt, nil) == SQLITE_OK,
              let query = stmt else {
            throw NSError(domain: "TestProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "prepare failed"])
        }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw NSError(domain: "TestProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "step failed"])
        }
        return Int(sqlite3_column_int(query, 0))
    }

    private func resetToday() -> TodayValue {
        let metadata = UsageResetSampleMetadata(
            priorUsedPercent: 80,
            currentUsedPercent: 4,
            priorResetsAt: date(2026, 5, 14, 12),
            currentResetsAt: date(2026, 5, 21, 12),
            dropPercent: 76,
            tolerancePercent: 2
        )
        let basis = TodayBasis(
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: 80,
            weeklyUsedNow: 4,
            todayAllowanceOfWeek: 20,
            daysRemainingUntilWeeklyReset: 7,
            weeklyResetAlreadyFiredToday: true,
            resetProvenance: .explicitReset,
            resetMetadata: metadata
        )
        return TodayValue(pct: -20, todayAllowanceOfWeek: 20, severity: .overdraft, basis: basis)
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
