import Foundation
import SQLite3

public enum UsageContinuityStoreError: Error, Equatable {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
}

public struct UsageContinuityDailyState: Equatable, Sendable {
    public let tool: UsageTool
    public let localDate: String
    public let weeklyUsedAtDayStart: Double
    public let weeklyUsedNow: Double
    public let todayAllowanceOfWeek: Double
    public let daysRemainingUntilWeeklyReset: Double
    public let weeklyResetAlreadyFiredToday: Bool
    public let resetProvenance: UsageResetProvenance
    public let peakWeeklyUsedPercent: Double
    public let carryForwardPreResetUsedPercent: Double?
    public let carryForwardPostResetUsedPercent: Double?
    public let capturedAt: Date
}

public struct UsageContinuityRepairRecord: Equatable, Sendable {
    public let originalPath: String
    public let preservedPath: String
    public let reason: String
    public let createdAt: Date
}

public struct UsageRecoveryReminderPreference: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let isEnabled: Bool
    public let updatedAt: Date

    public init(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        isEnabled: Bool,
        updatedAt: Date
    ) {
        self.tool = tool
        self.windowKind = windowKind
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public struct UsageRecoveryEdgeRecord: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let resetIntervalID: String
    public let detectedAt: Date
    public let firedAt: Date?
    public let reminderIdentifier: String?
    public let errorMessage: String?
}

public struct UsageThresholdNotificationPreference: Equatable, Sendable {
    public let tool: UsageTool
    public let isEnabled: Bool
    public let updatedAt: Date

    public init(tool: UsageTool, isEnabled: Bool, updatedAt: Date) {
        self.tool = tool
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public struct UsageThresholdNotificationRecord: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let thresholdPct: Double
    public let resetIntervalID: String
    public let detectedAt: Date
    public let firedAt: Date?
    public let reminderIdentifier: String?
    public let lastError: String?

    public init(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        thresholdPct: Double,
        resetIntervalID: String,
        detectedAt: Date,
        firedAt: Date?,
        reminderIdentifier: String?,
        lastError: String?
    ) {
        self.tool = tool
        self.windowKind = windowKind
        self.thresholdPct = thresholdPct
        self.resetIntervalID = resetIntervalID
        self.detectedAt = detectedAt
        self.firedAt = firedAt
        self.reminderIdentifier = reminderIdentifier
        self.lastError = lastError
    }
}

public final class UsageContinuityStore {
    public static let restoredReason = "Restored from continuity store"

    public let path: String
    private var db: OpaquePointer?
    private let now: () -> Date

    public convenience init(now: @escaping () -> Date = Date.init) throws {
        try self.init(path: Self.defaultPath(), now: now)
    }

    public init(path: String, now: @escaping () -> Date = Date.init) throws {
        self.path = path
        self.now = now
        try Self.createParentDirectory(for: path)
        try openOrRepair()
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    public static func liveOrNil() -> UsageContinuityStore? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return nil
        }
        return try? UsageContinuityStore()
    }

    public static func defaultPath() -> String {
        AtomicJSONStore.baseDirectoryURL()
            .appendingPathComponent("usage-continuity.sqlite")
            .path
    }

    public func journalMode() throws -> String {
        try queryString("PRAGMA journal_mode") ?? ""
    }

    @discardableResult
    public func importLegacyBaselines(_ baselines: [UsageTool: DailyBaseline], migratedAt: Date) throws -> Bool {
        guard try migrationDate(id: "usage-daily-json-v1") == nil else { return false }

        for (_, baseline) in baselines {
            let state = UsageContinuityDailyState(
                tool: baseline.tool,
                localDate: baseline.localDate,
                weeklyUsedAtDayStart: baseline.weeklyUsedAtDayStart,
                weeklyUsedNow: baseline.weeklyUsedAtDayStart,
                todayAllowanceOfWeek: baseline.todayAllowanceOfWeek,
                daysRemainingUntilWeeklyReset: 1,
                weeklyResetAlreadyFiredToday: false,
                resetProvenance: .ordinaryProgress,
                peakWeeklyUsedPercent: baseline.weeklyUsedAtDayStart,
                carryForwardPreResetUsedPercent: nil,
                carryForwardPostResetUsedPercent: nil,
                capturedAt: baseline.capturedAt
            )
            try upsertDailyState(state)
        }

        try execute(
            "INSERT INTO migrations(id, migrated_at, detail) VALUES (?, ?, ?)",
            bindings: [
                .text("usage-daily-json-v1"),
                .double(migratedAt.timeIntervalSince1970),
                .text("Imported legacy usage-daily.json baselines")
            ]
        )
        return true
    }

    public func migrationDate(id: String) throws -> Date? {
        try queryDouble("SELECT migrated_at FROM migrations WHERE id = ?", bindings: [.text(id)])
            .map(Date.init(timeIntervalSince1970:))
    }

    @discardableResult
    public func recordAcceptedSnapshot(_ snapshot: UsageSnapshot, acceptedAt: Date) throws -> Int64? {
        let providerUpdatedAt = Self.providerUpdatedAt(for: snapshot) ?? acceptedAt
        if let latest = try latestProviderUpdatedAt(tool: snapshot.tool),
           providerUpdatedAt <= latest {
            return nil
        }

        let fiveHour = snapshot.fiveHour.availableSnapshot
        let weekly = snapshot.weekly.availableSnapshot
        let today = snapshot.today
        let carry = Self.carryForwardSegments(today)
        let staleReason = snapshot.availability.reason

        try execute(
            """
            INSERT INTO accepted_samples(
              tool, plan_name, accepted_at, provider_updated_at,
              five_hour_used, five_hour_resets_at, five_hour_updated_at, five_hour_duration, five_hour_source,
              weekly_used, weekly_resets_at, weekly_updated_at, weekly_duration, weekly_source,
              availability, stale_reason,
              today_pct, today_allowance, today_severity, today_local_date,
              today_weekly_start, today_weekly_now, today_days_remaining, today_reset_fired,
              reset_provenance, carry_pre, carry_post
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(snapshot.tool.rawValue),
                .optionalText(snapshot.planName),
                .double(acceptedAt.timeIntervalSince1970),
                .double(providerUpdatedAt.timeIntervalSince1970),
                .optionalDouble(fiveHour?.usedPercent),
                .optionalDate(fiveHour?.resetsAt),
                .optionalDate(fiveHour?.updatedAt),
                .optionalInt(fiveHour?.windowDurationMins),
                .optionalText(fiveHour?.sourceLabel),
                .optionalDouble(weekly?.usedPercent),
                .optionalDate(weekly?.resetsAt),
                .optionalDate(weekly?.updatedAt),
                .optionalInt(weekly?.windowDurationMins),
                .optionalText(weekly?.sourceLabel),
                .text(snapshot.availability.storageValue),
                .optionalText(staleReason),
                .optionalDouble(today?.pct),
                .optionalDouble(today?.todayAllowanceOfWeek),
                .optionalText(today?.severity.rawValue),
                .optionalText(today?.basis.localDate),
                .optionalDouble(today?.basis.weeklyUsedAtDayStart),
                .optionalDouble(today?.basis.weeklyUsedNow),
                .optionalDouble(today?.basis.daysRemainingUntilWeeklyReset),
                .optionalBool(today?.basis.weeklyResetAlreadyFiredToday),
                .optionalText(today?.basis.resetProvenance.rawValue),
                .optionalDouble(carry.pre),
                .optionalDouble(carry.post)
            ]
        )

        let seq = sqlite3_last_insert_rowid(requiredDB())
        if let today {
            let peak = max(
                try latestDailyState(tool: snapshot.tool, localDate: today.basis.localDate)?.peakWeeklyUsedPercent ?? 0,
                today.basis.weeklyUsedAtDayStart,
                today.basis.weeklyUsedNow
            )
            let state = UsageContinuityDailyState(
                tool: snapshot.tool,
                localDate: today.basis.localDate,
                weeklyUsedAtDayStart: today.basis.weeklyUsedAtDayStart,
                weeklyUsedNow: today.basis.weeklyUsedNow,
                todayAllowanceOfWeek: today.todayAllowanceOfWeek,
                daysRemainingUntilWeeklyReset: today.basis.daysRemainingUntilWeeklyReset,
                weeklyResetAlreadyFiredToday: today.basis.weeklyResetAlreadyFiredToday,
                resetProvenance: today.basis.resetProvenance,
                peakWeeklyUsedPercent: peak,
                carryForwardPreResetUsedPercent: carry.pre,
                carryForwardPostResetUsedPercent: carry.post,
                capturedAt: acceptedAt
            )
            try upsertDailyState(state)

            if let metadata = today.basis.resetMetadata,
               today.basis.resetProvenance == .explicitReset || today.basis.resetProvenance == .implicitReset {
                try execute(
                    """
                    INSERT INTO reset_breadcrumbs(
                      tool, local_date, provenance, prior_used, current_used,
                      prior_resets_at, current_resets_at, drop_percent,
                      accepted_sample_seq, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(snapshot.tool.rawValue),
                        .text(today.basis.localDate),
                        .text(today.basis.resetProvenance.rawValue),
                        .double(metadata.priorUsedPercent),
                        .double(metadata.currentUsedPercent),
                        .double(metadata.priorResetsAt.timeIntervalSince1970),
                        .double(metadata.currentResetsAt.timeIntervalSince1970),
                        .double(metadata.dropPercent),
                        .int64(seq),
                        .double(acceptedAt.timeIntervalSince1970)
                    ]
                )
            }
        }

        return seq
    }

    public func latestSnapshot(tool: UsageTool) throws -> UsageSnapshot? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT plan_name, accepted_at,
          five_hour_used, five_hour_resets_at, five_hour_updated_at, five_hour_duration, five_hour_source,
          weekly_used, weekly_resets_at, weekly_updated_at, weekly_duration, weekly_source,
          today_pct, today_allowance, today_severity, today_local_date,
          today_weekly_start, today_weekly_now, today_days_remaining, today_reset_fired,
          reset_provenance, carry_pre, carry_post
        FROM accepted_samples WHERE tool = ? ORDER BY seq DESC LIMIT 1
        """
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text(tool.rawValue), to: query, index: 1)

        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        let planName = columnText(query, 0)
        let acceptedAt = Date(timeIntervalSince1970: sqlite3_column_double(query, 1))
        let fiveHour = Self.windowSlot(
            kind: .fiveHour,
            used: columnOptionalDouble(query, 2),
            resetsAt: columnOptionalDate(query, 3),
            updatedAt: columnOptionalDate(query, 4),
            duration: columnOptionalInt(query, 5),
            source: columnText(query, 6)
        )
        let weekly = Self.windowSlot(
            kind: .weekly,
            used: columnOptionalDouble(query, 7),
            resetsAt: columnOptionalDate(query, 8),
            updatedAt: columnOptionalDate(query, 9),
            duration: columnOptionalInt(query, 10),
            source: columnText(query, 11)
        )
        let today = Self.todayValue(from: query, startIndex: 12)

        return UsageSnapshot(
            tool: tool,
            planName: planName,
            fiveHour: fiveHour,
            weekly: weekly,
            today: today,
            availability: .stale(reason: Self.restoredReason),
            lastRefresh: acceptedAt
        )
    }

    public func latestDailyState(tool: UsageTool, localDate: String) throws -> UsageContinuityDailyState? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT weekly_start, weekly_now, today_allowance, days_remaining,
          reset_fired, reset_provenance, peak_weekly_used, carry_pre, carry_post, captured_at
        FROM daily_state WHERE tool = ? AND local_date = ? LIMIT 1
        """
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text(tool.rawValue), to: query, index: 1)
        try bind(.text(localDate), to: query, index: 2)
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return UsageContinuityDailyState(
            tool: tool,
            localDate: localDate,
            weeklyUsedAtDayStart: sqlite3_column_double(query, 0),
            weeklyUsedNow: sqlite3_column_double(query, 1),
            todayAllowanceOfWeek: sqlite3_column_double(query, 2),
            daysRemainingUntilWeeklyReset: sqlite3_column_double(query, 3),
            weeklyResetAlreadyFiredToday: sqlite3_column_int(query, 4) != 0,
            resetProvenance: UsageResetProvenance(rawValue: columnText(query, 5) ?? "") ?? .ordinaryProgress,
            peakWeeklyUsedPercent: sqlite3_column_double(query, 6),
            carryForwardPreResetUsedPercent: columnOptionalDouble(query, 7),
            carryForwardPostResetUsedPercent: columnOptionalDouble(query, 8),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 9))
        )
    }

    public func acceptedSampleCount(tool: UsageTool? = nil) throws -> Int {
        if let tool {
            return try Int(queryDouble("SELECT COUNT(*) FROM accepted_samples WHERE tool = ?", bindings: [.text(tool.rawValue)]) ?? 0)
        }
        return try Int(queryDouble("SELECT COUNT(*) FROM accepted_samples") ?? 0)
    }

    public func resetBreadcrumbCount(tool: UsageTool? = nil) throws -> Int {
        if let tool {
            return try Int(queryDouble("SELECT COUNT(*) FROM reset_breadcrumbs WHERE tool = ?", bindings: [.text(tool.rawValue)]) ?? 0)
        }
        return try Int(queryDouble("SELECT COUNT(*) FROM reset_breadcrumbs") ?? 0)
    }

    public func latestAcceptedSampleSequence(tool: UsageTool) throws -> Int64? {
        try queryDouble(
            "SELECT seq FROM accepted_samples WHERE tool = ? ORDER BY seq DESC LIMIT 1",
            bindings: [.text(tool.rawValue)]
        ).map(Int64.init)
    }

    public func repairRecords() throws -> [UsageContinuityRepairRecord] {
        var stmt: OpaquePointer?
        let sql = "SELECT original_path, preserved_path, reason, created_at FROM repairs ORDER BY id ASC"
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        var records: [UsageContinuityRepairRecord] = []
        while sqlite3_step(query) == SQLITE_ROW {
            records.append(UsageContinuityRepairRecord(
                originalPath: columnText(query, 0) ?? "",
                preservedPath: columnText(query, 1) ?? "",
                reason: columnText(query, 2) ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3))
            ))
        }
        return records
    }

    public func recoveryReminderPreference(tool: UsageTool, windowKind: UsageWindowKind) throws -> UsageRecoveryReminderPreference {
        var stmt: OpaquePointer?
        let sql = "SELECT enabled, updated_at FROM recovery_reminder_preferences WHERE tool = ? AND window_kind = ? LIMIT 1"
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text(tool.rawValue), to: query, index: 1)
        try bind(.text(windowKind.rawValue), to: query, index: 2)
        guard sqlite3_step(query) == SQLITE_ROW else {
            return UsageRecoveryReminderPreference(
                tool: tool,
                windowKind: windowKind,
                isEnabled: false,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        return UsageRecoveryReminderPreference(
            tool: tool,
            windowKind: windowKind,
            isEnabled: sqlite3_column_int(query, 0) != 0,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 1))
        )
    }

    public func setRecoveryReminderPreference(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        isEnabled: Bool,
        updatedAt: Date
    ) throws {
        try execute(
            """
            INSERT INTO recovery_reminder_preferences(tool, window_kind, enabled, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tool, window_kind) DO UPDATE SET
              enabled=excluded.enabled,
              updated_at=excluded.updated_at
            """,
            bindings: [
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .bool(isEnabled),
                .double(updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func hasRecoveryEdge(tool: UsageTool, windowKind: UsageWindowKind, resetIntervalID: String) throws -> Bool {
        let count = try queryDouble(
            "SELECT COUNT(*) FROM recovery_edges WHERE tool = ? AND window_kind = ? AND reset_interval_id = ?",
            bindings: [.text(tool.rawValue), .text(windowKind.rawValue), .text(resetIntervalID)]
        ) ?? 0
        return count > 0
    }

    public func recordRecoveryEdge(_ edge: UsageRecoveryEdge) throws {
        try execute(
            """
            INSERT OR IGNORE INTO recovery_edges(
              tool, window_kind, reset_interval_id, detected_at,
              fired_at, reminder_identifier, error_message
            ) VALUES (?, ?, ?, ?, NULL, NULL, NULL)
            """,
            bindings: [
                .text(edge.tool.rawValue),
                .text(edge.windowKind.rawValue),
                .text(edge.resetIntervalID),
                .double(edge.detectedAt.timeIntervalSince1970)
            ]
        )
    }

    public func recoveryCandidate(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String
    ) throws -> UsageRecoveryCandidate? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT accepted_sample_seq, prior_used, current_used, detected_at
        FROM recovery_candidates
        WHERE tool = ? AND window_kind = ? AND reset_interval_id = ?
        LIMIT 1
        """
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text(tool.rawValue), to: query, index: 1)
        try bind(.text(windowKind.rawValue), to: query, index: 2)
        try bind(.text(resetIntervalID), to: query, index: 3)
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return UsageRecoveryCandidate(
            tool: tool,
            windowKind: windowKind,
            resetIntervalID: resetIntervalID,
            acceptedSequence: sqlite3_column_int64(query, 0),
            priorUsedPercent: sqlite3_column_double(query, 1),
            currentUsedPercent: sqlite3_column_double(query, 2),
            detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3))
        )
    }

    public func recordRecoveryCandidate(_ candidate: UsageRecoveryCandidate) throws {
        try execute(
            """
            INSERT INTO recovery_candidates(
              tool, window_kind, reset_interval_id, accepted_sample_seq,
              prior_used, current_used, detected_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(tool, window_kind, reset_interval_id) DO UPDATE SET
              accepted_sample_seq=excluded.accepted_sample_seq,
              prior_used=excluded.prior_used,
              current_used=excluded.current_used,
              detected_at=excluded.detected_at
            """,
            bindings: [
                .text(candidate.tool.rawValue),
                .text(candidate.windowKind.rawValue),
                .text(candidate.resetIntervalID),
                .int64(candidate.acceptedSequence),
                .double(candidate.priorUsedPercent),
                .double(candidate.currentUsedPercent),
                .double(candidate.detectedAt.timeIntervalSince1970)
            ]
        )
    }

    public func clearRecoveryCandidate(tool: UsageTool, windowKind: UsageWindowKind, resetIntervalID: String) throws {
        try execute(
            "DELETE FROM recovery_candidates WHERE tool = ? AND window_kind = ? AND reset_interval_id = ?",
            bindings: [.text(tool.rawValue), .text(windowKind.rawValue), .text(resetIntervalID)]
        )
    }

    public func markRecoveryReminderCreated(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String,
        reminderIdentifier: String,
        firedAt: Date
    ) throws {
        try execute(
            """
            UPDATE recovery_edges
            SET fired_at = ?, reminder_identifier = ?, error_message = NULL
            WHERE tool = ? AND window_kind = ? AND reset_interval_id = ?
            """,
            bindings: [
                .double(firedAt.timeIntervalSince1970),
                .text(reminderIdentifier),
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .text(resetIntervalID)
            ]
        )
    }

    public func markRecoveryReminderFailed(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String,
        errorMessage: String
    ) throws {
        try execute(
            """
            UPDATE recovery_edges
            SET error_message = ?
            WHERE tool = ? AND window_kind = ? AND reset_interval_id = ?
            """,
            bindings: [
                .text(errorMessage),
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .text(resetIntervalID)
            ]
        )
    }

    public func recoveryEdgeRecords(tool: UsageTool? = nil) throws -> [UsageRecoveryEdgeRecord] {
        let sql: String
        let bindings: [SQLiteBinding]
        if let tool {
            sql = """
            SELECT tool, window_kind, reset_interval_id, detected_at, fired_at, reminder_identifier, error_message
            FROM recovery_edges WHERE tool = ? ORDER BY detected_at ASC
            """
            bindings = [.text(tool.rawValue)]
        } else {
            sql = """
            SELECT tool, window_kind, reset_interval_id, detected_at, fired_at, reminder_identifier, error_message
            FROM recovery_edges ORDER BY detected_at ASC
            """
            bindings = []
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: query, index: Int32(offset + 1))
        }

        var records: [UsageRecoveryEdgeRecord] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let toolRaw = columnText(query, 0),
                  let tool = UsageTool(rawValue: toolRaw),
                  let windowRaw = columnText(query, 1),
                  let windowKind = UsageWindowKind(rawValue: windowRaw),
                  let resetIntervalID = columnText(query, 2) else {
                continue
            }
            records.append(UsageRecoveryEdgeRecord(
                tool: tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID,
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3)),
                firedAt: columnOptionalDate(query, 4),
                reminderIdentifier: columnText(query, 5),
                errorMessage: columnText(query, 6)
            ))
        }
        return records
    }

    public func thresholdNotificationPreference(tool: UsageTool) throws -> UsageThresholdNotificationPreference {
        var stmt: OpaquePointer?
        let sql = "SELECT enabled, updated_at FROM threshold_notification_preferences WHERE tool = ? LIMIT 1"
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text(tool.rawValue), to: query, index: 1)
        guard sqlite3_step(query) == SQLITE_ROW else {
            return UsageThresholdNotificationPreference(
                tool: tool,
                isEnabled: false,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        return UsageThresholdNotificationPreference(
            tool: tool,
            isEnabled: sqlite3_column_int(query, 0) != 0,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 1))
        )
    }

    public func thresholdNotificationsMasterEnabled() throws -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT enabled FROM threshold_notification_preferences WHERE tool = ? LIMIT 1"
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        try bind(.text("__master__"), to: query, index: 1)
        guard sqlite3_step(query) == SQLITE_ROW else {
            return false
        }
        return sqlite3_column_int(query, 0) != 0
    }

    public func setThresholdNotificationsMasterEnabled(isEnabled: Bool, updatedAt: Date) throws {
        try execute(
            """
            INSERT INTO threshold_notification_preferences(tool, enabled, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(tool) DO UPDATE SET
              enabled=excluded.enabled,
              updated_at=excluded.updated_at
            """,
            bindings: [
                .text("__master__"),
                .bool(isEnabled),
                .double(updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func setThresholdNotificationPreference(
        tool: UsageTool,
        isEnabled: Bool,
        updatedAt: Date
    ) throws {
        try execute(
            """
            INSERT INTO threshold_notification_preferences(tool, enabled, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(tool) DO UPDATE SET
              enabled=excluded.enabled,
              updated_at=excluded.updated_at
            """,
            bindings: [
                .text(tool.rawValue),
                .bool(isEnabled),
                .double(updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func recordThresholdCrossing(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        thresholdPct: Double,
        resetIntervalID: String,
        detectedAt: Date
    ) throws {
        try execute(
            """
            INSERT OR IGNORE INTO threshold_notification_records(
              tool, window_kind, threshold_pct, reset_interval_id, detected_at,
              fired_at, reminder_identifier, last_error
            ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL)
            """,
            bindings: [
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .double(thresholdPct),
                .text(resetIntervalID),
                .double(detectedAt.timeIntervalSince1970)
            ]
        )
    }

    public func pendingThresholdNotificationRecords() throws -> [UsageThresholdNotificationRecord] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT tool, window_kind, threshold_pct, reset_interval_id, detected_at,
          fired_at, reminder_identifier, last_error
        FROM threshold_notification_records
        WHERE fired_at IS NULL
          AND (last_error IS NULL OR last_error NOT IN ('stale_interval', 'permission_denied', 'notifications_not_allowed'))
        ORDER BY detected_at ASC
        """
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        var records: [UsageThresholdNotificationRecord] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let toolRaw = columnText(query, 0),
                  let tool = UsageTool(rawValue: toolRaw),
                  let windowRaw = columnText(query, 1),
                  let windowKind = UsageWindowKind(rawValue: windowRaw),
                  let resetIntervalID = columnText(query, 3) else {
                continue
            }
            records.append(UsageThresholdNotificationRecord(
                tool: tool,
                windowKind: windowKind,
                thresholdPct: sqlite3_column_double(query, 2),
                resetIntervalID: resetIntervalID,
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 4)),
                firedAt: columnOptionalDate(query, 5),
                reminderIdentifier: columnText(query, 6),
                lastError: columnText(query, 7)
            ))
        }
        return records
    }

    public func markThresholdNotificationCreated(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        thresholdPct: Double,
        resetIntervalID: String,
        reminderIdentifier: String,
        firedAt: Date
    ) throws {
        try execute(
            """
            UPDATE threshold_notification_records
            SET fired_at = ?, reminder_identifier = ?, last_error = NULL
            WHERE tool = ? AND window_kind = ? AND threshold_pct = ? AND reset_interval_id = ?
            """,
            bindings: [
                .double(firedAt.timeIntervalSince1970),
                .text(reminderIdentifier),
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .double(thresholdPct),
                .text(resetIntervalID)
            ]
        )
    }

    public func markThresholdNotificationFailed(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        thresholdPct: Double,
        resetIntervalID: String,
        lastError: String
    ) throws {
        try execute(
            """
            UPDATE threshold_notification_records
            SET last_error = ?
            WHERE tool = ? AND window_kind = ? AND threshold_pct = ? AND reset_interval_id = ?
            """,
            bindings: [
                .text(lastError),
                .text(tool.rawValue),
                .text(windowKind.rawValue),
                .double(thresholdPct),
                .text(resetIntervalID)
            ]
        )
    }

    // MARK: - Open / schema / repair

    private static func createParentDirectory(for path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func openOrRepair() throws {
        do {
            try open()
            try createSchema()
            try verifyIntegrity()
        } catch {
            close()
            guard FileManager.default.fileExists(atPath: path) else { throw error }
            let preservedPath = "\(path).corrupt-\(Int(now().timeIntervalSince1970))"
            try? FileManager.default.removeItem(atPath: preservedPath)
            try FileManager.default.moveItem(atPath: path, toPath: preservedPath)
            try open()
            try createSchema()
            try recordRepair(originalPath: path, preservedPath: preservedPath, reason: "\(error)")
        }
    }

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close_v2(handle) }
            throw UsageContinuityStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(handle, 1000)
        db = handle
    }

    private func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    private func createSchema() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
        CREATE TABLE IF NOT EXISTS metadata(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS accepted_samples(
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          plan_name TEXT,
          accepted_at REAL NOT NULL,
          provider_updated_at REAL NOT NULL,
          five_hour_used REAL,
          five_hour_resets_at REAL,
          five_hour_updated_at REAL,
          five_hour_duration INTEGER,
          five_hour_source TEXT,
          weekly_used REAL,
          weekly_resets_at REAL,
          weekly_updated_at REAL,
          weekly_duration INTEGER,
          weekly_source TEXT,
          availability TEXT NOT NULL,
          stale_reason TEXT,
          today_pct REAL,
          today_allowance REAL,
          today_severity TEXT,
          today_local_date TEXT,
          today_weekly_start REAL,
          today_weekly_now REAL,
          today_days_remaining REAL,
          today_reset_fired INTEGER,
          reset_provenance TEXT,
          carry_pre REAL,
          carry_post REAL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_accepted_samples_tool_seq ON accepted_samples(tool, seq)")
        try execute("""
        CREATE TABLE IF NOT EXISTS daily_state(
          tool TEXT NOT NULL,
          local_date TEXT NOT NULL,
          weekly_start REAL NOT NULL,
          weekly_now REAL NOT NULL,
          today_allowance REAL NOT NULL,
          days_remaining REAL NOT NULL,
          reset_fired INTEGER NOT NULL,
          reset_provenance TEXT NOT NULL,
          peak_weekly_used REAL NOT NULL,
          carry_pre REAL,
          carry_post REAL,
          captured_at REAL NOT NULL,
          PRIMARY KEY(tool, local_date)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS reset_breadcrumbs(
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          local_date TEXT NOT NULL,
          provenance TEXT NOT NULL,
          prior_used REAL NOT NULL,
          current_used REAL NOT NULL,
          prior_resets_at REAL NOT NULL,
          current_resets_at REAL NOT NULL,
          drop_percent REAL NOT NULL,
          accepted_sample_seq INTEGER NOT NULL,
          created_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS migrations(
          id TEXT PRIMARY KEY,
          migrated_at REAL NOT NULL,
          detail TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS repairs(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at REAL NOT NULL,
          original_path TEXT NOT NULL,
          preserved_path TEXT NOT NULL,
          reason TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS recovery_reminder_preferences(
          tool TEXT NOT NULL,
          window_kind TEXT NOT NULL,
          enabled INTEGER NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(tool, window_kind)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS recovery_edges(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          window_kind TEXT NOT NULL,
          reset_interval_id TEXT NOT NULL,
          detected_at REAL NOT NULL,
          fired_at REAL,
          reminder_identifier TEXT,
          error_message TEXT,
          UNIQUE(tool, window_kind, reset_interval_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_recovery_edges_tool_window ON recovery_edges(tool, window_kind)")
        try execute("""
        CREATE TABLE IF NOT EXISTS threshold_notification_preferences(
          tool TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL,
          PRIMARY KEY(tool)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS threshold_notification_records(
          tool TEXT NOT NULL,
          window_kind TEXT NOT NULL,
          threshold_pct REAL NOT NULL,
          reset_interval_id TEXT NOT NULL,
          detected_at REAL NOT NULL,
          fired_at REAL,
          reminder_identifier TEXT,
          last_error TEXT,
          PRIMARY KEY(tool, window_kind, threshold_pct, reset_interval_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_threshold_records_tool_window ON threshold_notification_records(tool, window_kind)")
        try execute("""
        CREATE TABLE IF NOT EXISTS recovery_candidates(
          tool TEXT NOT NULL,
          window_kind TEXT NOT NULL,
          reset_interval_id TEXT NOT NULL,
          accepted_sample_seq INTEGER NOT NULL,
          prior_used REAL NOT NULL,
          current_used REAL NOT NULL,
          detected_at REAL NOT NULL,
          PRIMARY KEY(tool, window_kind, reset_interval_id)
        )
        """)
        try execute("INSERT OR REPLACE INTO metadata(key, value) VALUES ('schema_version', '1')")
    }

    private func verifyIntegrity() throws {
        let result = try queryString("PRAGMA integrity_check")
        guard result == "ok" else {
            throw UsageContinuityStoreError.executeFailed("integrity_check: \(result ?? "nil")")
        }
    }

    private func recordRepair(originalPath: String, preservedPath: String, reason: String) throws {
        try execute(
            "INSERT INTO repairs(created_at, original_path, preserved_path, reason) VALUES (?, ?, ?, ?)",
            bindings: [
                .double(now().timeIntervalSince1970),
                .text(originalPath),
                .text(preservedPath),
                .text(reason)
            ]
        )
    }

    private func upsertDailyState(_ state: UsageContinuityDailyState) throws {
        try execute(
            """
            INSERT INTO daily_state(
              tool, local_date, weekly_start, weekly_now, today_allowance,
              days_remaining, reset_fired, reset_provenance, peak_weekly_used,
              carry_pre, carry_post, captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(tool, local_date) DO UPDATE SET
              weekly_start=excluded.weekly_start,
              weekly_now=excluded.weekly_now,
              today_allowance=excluded.today_allowance,
              days_remaining=excluded.days_remaining,
              reset_fired=excluded.reset_fired,
              reset_provenance=excluded.reset_provenance,
              peak_weekly_used=max(daily_state.peak_weekly_used, excluded.peak_weekly_used),
              carry_pre=excluded.carry_pre,
              carry_post=excluded.carry_post,
              captured_at=excluded.captured_at
            """,
            bindings: [
                .text(state.tool.rawValue),
                .text(state.localDate),
                .double(state.weeklyUsedAtDayStart),
                .double(state.weeklyUsedNow),
                .double(state.todayAllowanceOfWeek),
                .double(state.daysRemainingUntilWeeklyReset),
                .bool(state.weeklyResetAlreadyFiredToday),
                .text(state.resetProvenance.rawValue),
                .double(state.peakWeeklyUsedPercent),
                .optionalDouble(state.carryForwardPreResetUsedPercent),
                .optionalDouble(state.carryForwardPostResetUsedPercent),
                .double(state.capturedAt.timeIntervalSince1970)
            ]
        )
    }

    // MARK: - SQLite helpers

    private enum SQLiteBinding {
        case null
        case text(String)
        case double(Double)
        case int(Int)
        case int64(Int64)
        case bool(Bool)

        static func optionalText(_ value: String?) -> SQLiteBinding {
            value.map(SQLiteBinding.text) ?? .null
        }

        static func optionalDouble(_ value: Double?) -> SQLiteBinding {
            value.map(SQLiteBinding.double) ?? .null
        }

        static func optionalInt(_ value: Int?) -> SQLiteBinding {
            value.map(SQLiteBinding.int) ?? .null
        }

        static func optionalBool(_ value: Bool?) -> SQLiteBinding {
            value.map(SQLiteBinding.bool) ?? .null
        }

        static func optionalDate(_ value: Date?) -> SQLiteBinding {
            value.map { .double($0.timeIntervalSince1970) } ?? .null
        }
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: query, index: Int32(offset + 1))
        }
        let status = sqlite3_step(query)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw UsageContinuityStoreError.stepFailed(lastErrorMessage())
        }
    }

    private func queryString(_ sql: String, bindings: [SQLiteBinding] = []) throws -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: query, index: Int32(offset + 1))
        }
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return columnText(query, 0)
    }

    private func queryDouble(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(requiredDB(), sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else {
            throw UsageContinuityStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(query) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, to: query, index: Int32(offset + 1))
        }
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(query, 0)
    }

    private func latestProviderUpdatedAt(tool: UsageTool) throws -> Date? {
        try queryDouble(
            "SELECT provider_updated_at FROM accepted_samples WHERE tool = ? ORDER BY seq DESC LIMIT 1",
            bindings: [.text(tool.rawValue)]
        ).map(Date.init(timeIntervalSince1970:))
    }

    private func bind(_ binding: SQLiteBinding, to stmt: OpaquePointer, index: Int32) throws {
        let status: Int32
        switch binding {
        case .null:
            status = sqlite3_bind_null(stmt, index)
        case .text(let value):
            status = value.withCString {
                sqlite3_bind_text(stmt, index, $0, -1, Self.sqliteTransient)
            }
        case .double(let value):
            status = sqlite3_bind_double(stmt, index, value)
        case .int(let value):
            status = sqlite3_bind_int(stmt, index, Int32(value))
        case .int64(let value):
            status = sqlite3_bind_int64(stmt, index, value)
        case .bool(let value):
            status = sqlite3_bind_int(stmt, index, value ? 1 : 0)
        }
        guard status == SQLITE_OK else {
            throw UsageContinuityStoreError.bindFailed(lastErrorMessage())
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, index))
    }

    private func columnOptionalDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        columnOptionalDouble(stmt, index).map(Date.init(timeIntervalSince1970:))
    }

    private func requiredDB() -> OpaquePointer {
        db!
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite handle unavailable"
    }

    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    // MARK: - Model helpers

    private static func providerUpdatedAt(for snapshot: UsageSnapshot) -> Date? {
        [snapshot.fiveHour.availableSnapshot?.updatedAt, snapshot.weekly.availableSnapshot?.updatedAt]
            .compactMap { $0 }
            .max()
    }

    private static func carryForwardSegments(_ today: TodayValue?) -> (pre: Double?, post: Double?) {
        guard let today, today.basis.weeklyResetAlreadyFiredToday else { return (nil, nil) }
        return (
            max(0, 100.0 - today.basis.weeklyUsedAtDayStart),
            max(0, today.basis.weeklyUsedNow)
        )
    }

    private static func windowSlot(
        kind: UsageWindowKind,
        used: Double?,
        resetsAt: Date?,
        updatedAt: Date?,
        duration: Int?,
        source: String?
    ) -> UsageWindowSlot {
        guard let used, let resetsAt, let updatedAt, let duration else {
            return .unavailable(reason: restoredReason)
        }
        let snapshot = UsageWindowSnapshot(
            kind: kind,
            usedPercent: used,
            resetsAt: resetsAt,
            windowDurationMins: duration,
            sourceLabel: source ?? "",
            updatedAt: updatedAt
        )
        return .stale(snapshot, reason: restoredReason)
    }

    private static func todayValue(from stmt: OpaquePointer, startIndex: Int32) -> TodayValue? {
        guard sqlite3_column_type(stmt, startIndex) != SQLITE_NULL else { return nil }
        let pct = sqlite3_column_double(stmt, startIndex)
        let allowance = sqlite3_column_double(stmt, startIndex + 1)
        let severity = TodaySeverity(rawValue: sqlite3_column_text(stmt, startIndex + 2).map { String(cString: $0) } ?? "") ?? .unknown
        let localDate = sqlite3_column_text(stmt, startIndex + 3).map { String(cString: $0) } ?? ""
        let weeklyStart = sqlite3_column_double(stmt, startIndex + 4)
        let weeklyNow = sqlite3_column_double(stmt, startIndex + 5)
        let daysRemaining = sqlite3_column_double(stmt, startIndex + 6)
        let resetFired = sqlite3_column_int(stmt, startIndex + 7) != 0
        let provenance = UsageResetProvenance(rawValue: sqlite3_column_text(stmt, startIndex + 8).map { String(cString: $0) } ?? "") ?? .ordinaryProgress
        let basis = TodayBasis(
            localDate: localDate,
            weeklyUsedAtDayStart: weeklyStart,
            weeklyUsedNow: weeklyNow,
            todayAllowanceOfWeek: allowance,
            daysRemainingUntilWeeklyReset: daysRemaining,
            weeklyResetAlreadyFiredToday: resetFired,
            resetProvenance: provenance
        )
        return TodayValue(pct: pct, todayAllowanceOfWeek: allowance, severity: severity, basis: basis)
    }
}

private extension UsageWindowSlot {
    var availableSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .unavailable:
            return nil
        }
    }
}

private extension UsageAvailability {
    var storageValue: String {
        switch self {
        case .loading: return "loading"
        case .available: return "available"
        case .partial: return "partial"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        }
    }

    var reason: String? {
        switch self {
        case .partial(let reason), .stale(let reason), .unavailable(let reason):
            return reason
        case .loading, .available:
            return nil
        }
    }
}
