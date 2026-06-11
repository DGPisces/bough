import Foundation

public enum UsageTool: String, Codable, Equatable, Sendable {
    case codex
    case claudeCode

    public static let reliableQuotaProviders: [UsageTool] = [.codex]
    public static let selectableQuotaProviders: [UsageTool] = [.codex, .claudeCode]
}

public enum UsageWindowKind: String, Codable, Equatable, Sendable {
    case fiveHour
    case weekly
}

public struct UsageWindowSnapshot: Equatable, Sendable {
    public let kind: UsageWindowKind
    public let usedPercent: Double
    public let resetsAt: Date
    public let windowDurationMins: Int
    public let sourceLabel: String
    public let updatedAt: Date

    public init(
        kind: UsageWindowKind,
        usedPercent: Double,
        resetsAt: Date,
        windowDurationMins: Int,
        sourceLabel: String,
        updatedAt: Date
    ) {
        self.kind = kind
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
        self.sourceLabel = sourceLabel
        self.updatedAt = updatedAt
    }
}

public enum UsageWindowSlot: Equatable, Sendable {
    case loading
    case available(UsageWindowSnapshot)
    case stale(UsageWindowSnapshot, reason: String)
    case unavailable(reason: String)

    public var hasData: Bool {
        switch self {
        case .available, .stale:
            return true
        case .loading, .unavailable:
            return false
        }
    }
}

public enum UsageAvailability: Equatable, Sendable {
    case loading
    case available
    case partial(reason: String)
    case stale(reason: String)
    case unavailable(reason: String)
}

/// Severity classification for the Today daily-allowance band (D-05 / D-06).
///
/// 5 cases: `healthy` (>20% of today's allowance remaining), `caution` (5–20%),
/// `depleted` (0–5%), `overdraft` (negative — today_used has exceeded the
/// locked-at-midnight allowance), and `unknown` (forecast not yet available).
///
/// Per CONVENTIONS, every switch over `TodaySeverity` is exhaustive — no
/// `@unknown default`. Adding a new case is a deliberate global rewire.
public enum TodaySeverity: String, Codable, Equatable, Sendable {
    case healthy
    case caution
    case depleted
    case overdraft
    case unknown
}

public enum UsageResetProvenance: String, Equatable, Sendable {
    case ordinaryProgress = "ordinary_progress"
    case explicitReset = "explicit_reset"
    case implicitReset = "implicit_reset"
    case correctionIgnored = "correction_ignored"
}

public struct UsageResetSampleMetadata: Equatable, Sendable {
    public let priorUsedPercent: Double
    public let currentUsedPercent: Double
    public let priorResetsAt: Date
    public let currentResetsAt: Date
    public let dropPercent: Double
    public let tolerancePercent: Double

    public init(
        priorUsedPercent: Double,
        currentUsedPercent: Double,
        priorResetsAt: Date,
        currentResetsAt: Date,
        dropPercent: Double,
        tolerancePercent: Double
    ) {
        self.priorUsedPercent = priorUsedPercent
        self.currentUsedPercent = currentUsedPercent
        self.priorResetsAt = priorResetsAt
        self.currentResetsAt = currentResetsAt
        self.dropPercent = dropPercent
        self.tolerancePercent = tolerancePercent
    }
}

/// Telemetry / smoke surface for `TodayValue` (D-10 — replaces the four
/// removed `UsageForecast.safe*` fields). Carries the basis values the UI
/// renders below the Today row (TODAY-16) and that future telemetry can log.
public struct TodayBasis: Equatable, Sendable {
    /// `YYYY-MM-DD` (local TZ) the baseline was captured.
    public let localDate: String
    /// `weekly.usedPercent` at the moment of baseline capture (locked at midnight).
    public let weeklyUsedAtDayStart: Double
    /// `weekly.usedPercent` at the most recent tick (post-reset value when the
    /// weekly reset fired today, TODAY-09 — the baseline is re-locked at the
    /// reset, so the delta from baseline stays today's usage).
    public let weeklyUsedNow: Double
    /// Allowance for today as a percentage of the weekly window — locked at the
    /// local-midnight snapshot.
    public let todayAllowanceOfWeek: Double
    /// Whole-day count from local-day-start(now) to local-day-start(resetsAt),
    /// clamped to `>= 1.0` (bounded sentinel, not a fallback).
    public let daysRemainingUntilWeeklyReset: Double
    /// True when today's weekly reset has already fired today. Display /
    /// telemetry only (spec §8.1) — the accumulator re-locks the baseline at
    /// the reset, so the calculator no longer does cross-reset segment math.
    public let weeklyResetAlreadyFiredToday: Bool
    /// Transient Phase 23 reset provenance for the accepted sample that produced
    /// this Today value. Not persisted to `usage-daily.json`.
    public let resetProvenance: UsageResetProvenance
    public let resetMetadata: UsageResetSampleMetadata?

    public init(
        localDate: String,
        weeklyUsedAtDayStart: Double,
        weeklyUsedNow: Double,
        todayAllowanceOfWeek: Double,
        daysRemainingUntilWeeklyReset: Double,
        weeklyResetAlreadyFiredToday: Bool,
        resetProvenance: UsageResetProvenance = .ordinaryProgress,
        resetMetadata: UsageResetSampleMetadata? = nil
    ) {
        self.localDate = localDate
        self.weeklyUsedAtDayStart = weeklyUsedAtDayStart
        self.weeklyUsedNow = weeklyUsedNow
        self.todayAllowanceOfWeek = todayAllowanceOfWeek
        self.daysRemainingUntilWeeklyReset = daysRemainingUntilWeeklyReset
        self.weeklyResetAlreadyFiredToday = weeklyResetAlreadyFiredToday
        self.resetProvenance = resetProvenance
        self.resetMetadata = resetMetadata
    }
}

/// The Today daily-allowance forecast value rendered by Phase 5's UI surfaces
/// (TODAY-05, TODAY-06, TODAY-12, TODAY-13, TODAY-14, TODAY-15, TODAY-16).
///
/// `pct = ((todayAllowance - today_used) / todayAllowance) * 100`. Starts at 100
/// at the local-midnight snapshot, decreases as today_used accumulates, and
/// crosses zero into negative territory when today_used exceeds the locked
/// allowance — there is intentionally no clamp on either bound (TODAY-06).
public struct TodayValue: Equatable, Sendable {
    /// 100 at day-start, 0 when today_used == allowance, negative for overdraft.
    /// No clamp on either bound (TODAY-06 / D-05).
    public let pct: Double
    /// Allowance for today as a percentage of the weekly window — locked at
    /// the local-midnight snapshot (TODAY-05). Identical to `basis.todayAllowanceOfWeek`;
    /// surfaced as a top-level field for renderer convenience.
    public let todayAllowanceOfWeek: Double
    /// 5-case severity remap per D-05: healthy=pct>20, caution=5..20,
    /// depleted=0..<5, overdraft=pct<0. `.unknown` is only the `forecast == nil`
    /// / loading branch.
    public let severity: TodaySeverity
    /// Telemetry / smoke surface (D-10).
    public let basis: TodayBasis

    public init(
        pct: Double,
        todayAllowanceOfWeek: Double,
        severity: TodaySeverity,
        basis: TodayBasis
    ) {
        self.pct = pct
        self.todayAllowanceOfWeek = todayAllowanceOfWeek
        self.severity = severity
        self.basis = basis
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let tool: UsageTool
    public let planName: String?
    public let fiveHour: UsageWindowSlot
    public let weekly: UsageWindowSlot
    /// Today's daily-allowance forecast (D-10 — replaces the legacy
    /// `forecast: UsageForecast?` field whose `safe*` numerics are gone).
    public let today: TodayValue?
    public let availability: UsageAvailability
    public let lastRefresh: Date?

    public init(
        tool: UsageTool,
        planName: String?,
        fiveHour: UsageWindowSlot,
        weekly: UsageWindowSlot,
        today: TodayValue?,
        availability: UsageAvailability,
        lastRefresh: Date?
    ) {
        self.tool = tool
        self.planName = planName
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.today = today
        self.availability = availability
        self.lastRefresh = lastRefresh
    }

    public static func claudeUnavailable(now: Date) -> UsageSnapshot {
        let reason = "No reliable local quota source"
        return UsageSnapshot(
            tool: .claudeCode,
            planName: nil,
            fiveHour: .unavailable(reason: reason),
            weekly: .unavailable(reason: reason),
            today: nil,
            availability: .unavailable(reason: reason),
            lastRefresh: now
        )
    }
}

public extension UsageWindowSlot {
    func markingStale(reason: String) -> UsageWindowSlot {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return .stale(snapshot, reason: reason)
        case .loading, .unavailable:
            return self
        }
    }
}

public extension UsageSnapshot {
    func markingStale(reason: String) -> UsageSnapshot {
        UsageSnapshot(
            tool: tool,
            planName: planName,
            fiveHour: fiveHour.markingStale(reason: reason),
            weekly: weekly.markingStale(reason: reason),
            today: nil,
            availability: .stale(reason: reason),
            lastRefresh: lastRefresh
        )
    }
}

/// Shared weekly-reset detector (spec §8.1/§8.2). Used by both the calculator
/// (provenance annotation) and the accumulator (allowance re-lock).
public enum UsageResetEvaluator {
    public static let resetBucketSeconds: TimeInterval = 300
    public static let defaultTolerancePercent: Double = 2.0

    /// 5-minute bucket normalization (CodexBar parity) so server-side
    /// `resets_at` jitter cannot fake a moved boundary.
    public static func normalizedResetBucket(_ date: Date) -> Date {
        let bucket = (date.timeIntervalSince1970 / resetBucketSeconds).rounded(.down) * resetBucketSeconds
        return Date(timeIntervalSince1970: bucket)
    }

    /// Stable ID for one reset interval; used for re-lock idempotency.
    public static func resetIntervalID(for resetsAt: Date) -> String {
        String(Int(normalizedResetBucket(resetsAt).timeIntervalSince1970))
    }

    public static func evaluate(
        weekly: UsageWindowSnapshot,
        priorWeekly: UsageWindowSnapshot?,
        now: Date,
        tolerancePercent: Double = UsageResetEvaluator.defaultTolerancePercent
    ) -> (provenance: UsageResetProvenance, metadata: UsageResetSampleMetadata?) {
        guard let priorWeekly else { return (.ordinaryProgress, nil) }
        let drop = priorWeekly.usedPercent - weekly.usedPercent
        guard drop > 0 else { return (.ordinaryProgress, nil) }

        let metadata = UsageResetSampleMetadata(
            priorUsedPercent: priorWeekly.usedPercent,
            currentUsedPercent: weekly.usedPercent,
            priorResetsAt: priorWeekly.resetsAt,
            currentResetsAt: weekly.resetsAt,
            dropPercent: drop,
            tolerancePercent: tolerancePercent
        )
        let boundaryMovedForward =
            normalizedResetBucket(weekly.resetsAt) > normalizedResetBucket(priorWeekly.resetsAt)
        guard drop > tolerancePercent, boundaryMovedForward else {
            return (.correctionIgnored, metadata)
        }
        if priorWeekly.resetsAt <= now { return (.explicitReset, metadata) }
        return (.implicitReset, metadata)
    }
}

/// Pure computation of the A3' daily-allowance Today value (D-09).
///
/// The accumulator (plan 05-01) owns baseline lifecycle (cross-midnight, TZ
/// change, weekly-reset comment per D-05) and persistence; the calculator
/// reads a (validated) baseline plus the live `weekly` window and produces
/// the `TodayValue` the UI renders. Coverage:
///
/// - TODAY-05: `today_allowance` is locked at the local-midnight snapshot
///   (carried on `baseline.todayAllowanceOfWeek`).
/// - TODAY-06: `pct = 100` at day-start, decreasing to 0 at exhaustion and
///   negative for overdraft — no clamp on the upper or lower bound.
/// - TODAY-09 / spec §8.1: when the weekly reset fires today, the accumulator
///   re-locks the baseline against the NEW week budget, so `today_used` is
///   always the delta from the (possibly re-locked) baseline.
/// - TODAY-12: `pct` can be negative, e.g. `-40%`, with no clamp.
/// - TODAY-13: severity remap follows D-05's `healthy / caution / depleted /
///   overdraft` thresholds; `.unknown` is reserved for the `forecast == nil`
///   / loading branch returned by the early guard.
public enum UsageForecastCalculator {
    /// Compute `TodayValue` for the current tick.
    ///
    /// - Parameters:
    ///   - weekly: Live weekly window snapshot from the rate-limit feed.
    ///   - baseline: Today's baseline as captured by `UsageDailyAccumulator
    ///     .recordTick` BEFORE this call. Pass `nil` on the first tick of the
    ///     process; the calculator returns a `pct = 100` placeholder so the
    ///     UI never sees a half-initialized state.
    ///   - now: Wall-clock instant.
    ///   - calendar: Calendar used to compute local-day boundaries.
    ///   - timeZone: Timezone used for local-day boundary alignment.
    /// - Returns: A `TodayValue` describing today's allowance state, or `nil`
    ///   when the input is unusable (no future weekly reset).
    public static func forecast(
        weekly: UsageWindowSnapshot,
        baseline: DailyBaseline?,
        priorWeekly: UsageWindowSnapshot? = nil,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> TodayValue? {
        // Unchanged early-guard from the legacy implementation — a past or
        // missing weekly-reset means we have no valid budget surface.
        guard weekly.resetsAt > now else { return nil }

        let currentLocalDate = Self.formattedYYYYMMDD(now, calendar: calendar, timeZone: timeZone)
        let daysRemaining = Self.daysRemainingUntilWeeklyReset(
            weekly: weekly,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        )

        // First-tick / no-baseline branch (TODAY-06): the accumulator hasn't
        // recorded a baseline yet (typically because UsageStore is about to
        // call recordTick after this forecast call, or recordTick failed to
        // persist). Surface `pct = 100` so the UI does not render an unknown
        // state, but mark the basis with weeklyUsedAtDayStart = weekly.usedPercent
        // so the next tick (after the accumulator records) lines up.
        guard let baseline else {
            let todayAllowance = Self.todayAllowance(weekly: weekly, daysRemaining: daysRemaining)
            let basis = TodayBasis(
                localDate: currentLocalDate,
                weeklyUsedAtDayStart: weekly.usedPercent,
                weeklyUsedNow: weekly.usedPercent,
                todayAllowanceOfWeek: todayAllowance,
                daysRemainingUntilWeeklyReset: daysRemaining,
                weeklyResetAlreadyFiredToday: false
            )
            return TodayValue(
                pct: 100,
                todayAllowanceOfWeek: todayAllowance,
                severity: .healthy,
                basis: basis
            )
        }

        // The accumulator persists only valid baselines (correct localDate +
        // timeZoneIdentifier for the current tick). If by the time we run the
        // calculator the baseline has drifted (e.g., a TZ change between
        // recordTick and this call), trust the live `now` keying and treat
        // the baseline as nil. This is a bounded-sentinel input check, not a
        // fallback per CONVENTIONS — the accumulator's contract is to align
        // its persisted baseline before the calculator reads it.
        let baselineMatchesNow = (baseline.localDate == currentLocalDate)
            && (baseline.timeZoneIdentifier == timeZone.identifier)
        guard baselineMatchesNow else {
            let todayAllowance = Self.todayAllowance(weekly: weekly, daysRemaining: daysRemaining)
            let basis = TodayBasis(
                localDate: currentLocalDate,
                weeklyUsedAtDayStart: weekly.usedPercent,
                weeklyUsedNow: weekly.usedPercent,
                todayAllowanceOfWeek: todayAllowance,
                daysRemainingUntilWeeklyReset: daysRemaining,
                weeklyResetAlreadyFiredToday: false
            )
            return TodayValue(
                pct: 100,
                todayAllowanceOfWeek: todayAllowance,
                severity: .healthy,
                basis: basis
            )
        }

        let resetEvaluation = UsageResetEvaluator.evaluate(
            weekly: weekly,
            priorWeekly: priorWeekly,
            now: now
        )
        let weeklyResetAlreadyFired = resetEvaluation.provenance == .explicitReset
            || resetEvaluation.provenance == .implicitReset

        // Post-reset segment math is gone: the accumulator re-locks the baseline at
        // the reset (spec §8.1), so the delta from baseline IS today's usage.
        // weeklyResetAlreadyFired is kept on the basis purely as display/telemetry.
        let todayUsed = max(0, weekly.usedPercent - baseline.weeklyUsedAtDayStart)

        let todayAllowance = baseline.todayAllowanceOfWeek
        // Defensive: if the persisted allowance is zero (shouldn't happen — the
        // accumulator clamps daysRemaining to >= 1.0), avoid divide-by-zero by
        // falling back to a freshly computed allowance for this tick.
        let effectiveAllowance = todayAllowance > 0
            ? todayAllowance
            : Self.todayAllowance(weekly: weekly, daysRemaining: daysRemaining)

        // A fully exhausted weekly window can leave today's allowance at 0.
        // Keep the Today value finite so UI formatting never traps converting
        // NaN to Int; usage beyond a zero allowance is still overdraft.
        let pct = effectiveAllowance > 0
            ? ((effectiveAllowance - todayUsed) / effectiveAllowance) * 100.0
            : (todayUsed > 0 ? -100.0 : 0.0)
        let severity = Self.severityFor(pct: pct)

        let basis = TodayBasis(
            localDate: currentLocalDate,
            weeklyUsedAtDayStart: baseline.weeklyUsedAtDayStart,
            weeklyUsedNow: weekly.usedPercent,
            todayAllowanceOfWeek: effectiveAllowance,
            daysRemainingUntilWeeklyReset: daysRemaining,
            weeklyResetAlreadyFiredToday: weeklyResetAlreadyFired,
            resetProvenance: resetEvaluation.provenance,
            resetMetadata: resetEvaluation.metadata
        )

        return TodayValue(
            pct: pct,
            todayAllowanceOfWeek: effectiveAllowance,
            severity: severity,
            basis: basis
        )
    }

    /// Severity remap per D-05 / TODAY-13.
    ///
    /// `.unknown` is intentionally absent here — it is only the
    /// `forecast == nil` / loading branch returned by the early guard at the
    /// top of `forecast(...)`.
    private static func severityFor(pct: Double) -> TodaySeverity {
        if pct < 0 { return .overdraft }
        if pct < 5 { return .depleted }
        if pct <= 20 { return .caution }
        return .healthy
    }

    /// Canonical today-allowance formula. Identical to the formula
    /// `UsageDailyAccumulator.recordTick` uses when seeding a baseline;
    /// duplicated here for the no-baseline first-tick branch so the UI
    /// renders a sane `100%` placeholder before the accumulator has
    /// captured the baseline. The persisted value (baseline.todayAllowanceOfWeek)
    /// is the source of truth for any subsequent tick.
    private static func todayAllowance(
        weekly: UsageWindowSnapshot,
        daysRemaining: Double
    ) -> Double {
        let remaining = max(0.0, 100.0 - weekly.usedPercent)
        return remaining / daysRemaining
    }

    /// Mirror of `UsageDailyAccumulator.daysRemainingUntilWeeklyReset` (same
    /// bounded-sentinel `max(1.0, ...)` clamp). Kept private here so the
    /// calculator does not need to import the accumulator type — the two
    /// implementations are intentionally identical and trivially short.
    private static func daysRemainingUntilWeeklyReset(
        weekly: UsageWindowSnapshot,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Double {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let startOfNow = localCalendar.startOfDay(for: now)
        let startOfReset = localCalendar.startOfDay(for: weekly.resetsAt)
        let dayDelta = localCalendar.dateComponents([.day], from: startOfNow, to: startOfReset).day ?? 1
        return max(1.0, Double(dayDelta))
    }

    private static func formattedYYYYMMDD(
        _ date: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

public enum CodexRateLimitParser {
    public static func parse(message: CodexJSONRPCMessage, receivedAt: Date) -> UsageSnapshot? {
        guard let payload = payloadContainer(from: message),
              let selectedBucket = selectedRateLimits(for: payload) else {
            return nil
        }

        let parsed = parseWindows(from: selectedBucket, sourceLabel: "Codex", updatedAt: receivedAt)
        if parsed.fiveHour == nil && parsed.weekly == nil {
            return nil
        }

        let fiveHourSlot = parsed.fiveHour.map(UsageWindowSlot.available) ?? .unavailable(reason: "5-hour window unavailable")
        let weeklySlot = parsed.weekly.map(UsageWindowSlot.available) ?? .unavailable(reason: "Weekly window unavailable")
        let availability: UsageAvailability = {
            if parsed.fiveHour != nil && parsed.weekly != nil {
                return .available
            }
            if parsed.fiveHour != nil {
                return .partial(reason: "Weekly window unavailable")
            }
            if parsed.weekly != nil {
                return .partial(reason: "5-hour window unavailable")
            }
            return .unavailable(reason: "No recognizable rate windows")
        }()

        return UsageSnapshot(
            tool: .codex,
            planName: selectedBucket["planType"]?.asString,
            fiveHour: fiveHourSlot,
            weekly: weeklySlot,
            today: nil,
            availability: availability,
            lastRefresh: receivedAt
        )
    }
}

public enum ClaudeCodeRateLimitParser {
    public static func parse(data: Data, receivedAt: Date) -> UsageSnapshot? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = AnyCodableLike.from(raw).asObject else {
            return nil
        }
        return parse(payload: root, receivedAt: receivedAt)
    }

    public static func parse(payload: [String: AnyCodableLike], receivedAt: Date) -> UsageSnapshot? {
        guard let rateLimits = payload["rate_limits"]?.asObject else { return nil }

        let fiveHour = claudeWindow(
            from: rateLimits,
            keys: ["five_hour", "fiveHour", "primary"],
            kind: .fiveHour,
            defaultDuration: 300,
            updatedAt: receivedAt
        )
        let weekly = claudeWindow(
            from: rateLimits,
            keys: ["seven_day", "sevenDay", "weekly", "secondary"],
            kind: .weekly,
            defaultDuration: 10080,
            updatedAt: receivedAt
        )

        if fiveHour == nil && weekly == nil { return nil }

        let fiveHourSlot = fiveHour.map(UsageWindowSlot.available) ?? .unavailable(reason: "5-hour window unavailable")
        let weeklySlot = weekly.map(UsageWindowSlot.available) ?? .unavailable(reason: "Weekly window unavailable")
        let availability: UsageAvailability = {
            if fiveHour != nil && weekly != nil {
                return .available
            }
            if fiveHour != nil {
                return .partial(reason: "Weekly window unavailable")
            }
            if weekly != nil {
                return .partial(reason: "5-hour window unavailable")
            }
            return .unavailable(reason: "No recognizable rate windows")
        }()

        return UsageSnapshot(
            tool: .claudeCode,
            planName: claudeModelName(from: payload["model"]),
            fiveHour: fiveHourSlot,
            weekly: weeklySlot,
            today: nil,
            availability: availability,
            lastRefresh: receivedAt
        )
    }
}

private func payloadContainer(from message: CodexJSONRPCMessage) -> [String: AnyCodableLike]? {
    switch message.kind {
    case .response:
        return message.raw["result"]?.asObject
    case .notification(let method):
        guard method == "account/rateLimits/updated" else { return nil }
        return message.raw["params"]?.asObject
    default:
        return nil
    }
}

private func selectedRateLimits(for payload: [String: AnyCodableLike]) -> [String: AnyCodableLike]? {
    if let byLimit = payload["rateLimitsByLimitId"]?.asObject {
        let aggregateBucket = byLimit["codex"]?.asObject
        let codexBuckets = byLimit.compactMap { key, value -> (key: String, bucket: [String: AnyCodableLike])? in
            guard key.hasPrefix("codex"), let bucket = value.asObject else { return nil }
            return (key, bucket)
        }

        if let activeLimitId = activeLimitId(from: payload),
           activeLimitId.hasPrefix("codex") {
            if let activeBucket = byLimit[activeLimitId]?.asObject,
               hasCompleteRateWindows(activeBucket) {
                return activeBucket
            }
            if let aggregateBucket, hasCompleteRateWindows(aggregateBucket) {
                return aggregateBucket
            }
            if let activeBucket = byLimit[activeLimitId]?.asObject {
                return activeBucket
            }
            if let aggregateBucket {
                return aggregateBucket
            }
            return payload["rateLimits"]?.asObject
        }

        if let aggregateBucket, hasCompleteRateWindows(aggregateBucket) {
            return aggregateBucket
        }

        let completeModelBuckets = codexBuckets
            .filter { $0.key != "codex" && hasCompleteRateWindows($0.bucket) }

        if completeModelBuckets.count == 1,
           let modelBucket = completeModelBuckets.first?.bucket {
            return modelBucket
        }

        if let aggregateBucket, hasRecognizableRateWindow(aggregateBucket) {
            return aggregateBucket
        }

        let recognizableModelBuckets = codexBuckets
            .filter { $0.key != "codex" && hasRecognizableRateWindow($0.bucket) }

        if recognizableModelBuckets.count == 1,
           let modelBucket = recognizableModelBuckets.first?.bucket {
            return modelBucket
        }

        if let firstCodexBucket = codexBuckets
            .filter({ hasRecognizableRateWindow($0.bucket) })
            .sorted(by: { $0.key < $1.key })
            .first?.bucket {
            return firstCodexBucket
        }

        if let codex = aggregateBucket {
            return codex
        }
    }
    return payload["rateLimits"]?.asObject
}

private func activeLimitId(from payload: [String: AnyCodableLike]) -> String? {
    let keys = [
        "activeLimitId",
        "active_limit_id",
        "currentLimitId",
        "current_limit_id",
        "selectedLimitId",
        "selected_limit_id",
    ]
    return keys.lazy.compactMap { payload[$0]?.asString }.first
}

private func hasCompleteRateWindows(_ payload: [String: AnyCodableLike]) -> Bool {
    let parsed = parseWindows(from: payload, sourceLabel: "Codex", updatedAt: Date(timeIntervalSince1970: 0))
    return parsed.fiveHour != nil && parsed.weekly != nil
}

private func hasRecognizableRateWindow(_ payload: [String: AnyCodableLike]) -> Bool {
    let parsed = parseWindows(from: payload, sourceLabel: "Codex", updatedAt: Date(timeIntervalSince1970: 0))
    return parsed.fiveHour != nil || parsed.weekly != nil
}

private struct ParsedRateLimitWindows {
    let fiveHour: UsageWindowSnapshot?
    let weekly: UsageWindowSnapshot?
}

private func parseWindows(
    from payload: [String: AnyCodableLike],
    sourceLabel: String,
    updatedAt: Date
) -> ParsedRateLimitWindows {
    var fiveHour: UsageWindowSnapshot?
    var weekly: UsageWindowSnapshot?

    let buckets = payload.filter { key, _ in
        key == "primary" || key == "secondary"
    }

    for bucket in buckets.values {
        guard case .object(let values) = bucket else { continue }
        guard
            let usedPercent = values["usedPercent"]?.asDouble,
            let duration = values["windowDurationMins"]?.asInt,
            let resetsAtUnix = values["resetsAt"]?.asDouble
        else {
            continue
        }

        let bucketKind: UsageWindowKind?
        switch duration {
        case 295...305:
            bucketKind = .fiveHour
        case 10075...10085:
            bucketKind = .weekly
        default:
            bucketKind = nil
        }
        guard let kind = bucketKind else { continue }

        let snapshot = UsageWindowSnapshot(
            kind: kind,
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetsAtUnix),
            windowDurationMins: duration,
            sourceLabel: sourceLabel,
            updatedAt: updatedAt
        )

        switch kind {
        case .fiveHour:
            if fiveHour == nil { fiveHour = snapshot }
        case .weekly:
            if weekly == nil { weekly = snapshot }
        }
    }

    return ParsedRateLimitWindows(fiveHour: fiveHour, weekly: weekly)
}

private func claudeWindow(
    from rateLimits: [String: AnyCodableLike],
    keys: [String],
    kind: UsageWindowKind,
    defaultDuration: Int,
    updatedAt: Date
) -> UsageWindowSnapshot? {
    guard let bucket = keys.lazy.compactMap({ rateLimits[$0]?.asObject }).first else {
        return nil
    }
    guard let usedPercent = firstDouble(bucket, keys: ["used_percentage", "usedPercentage", "used_percent", "usedPercent", "used"]) else {
        return nil
    }
    let duration = firstInt(bucket, keys: ["window_duration_mins", "windowDurationMins", "duration_mins"]) ?? defaultDuration
    guard let resetsAt = claudeResetDate(from: bucket) else { return nil }

    return UsageWindowSnapshot(
        kind: kind,
        usedPercent: usedPercent,
        resetsAt: resetsAt,
        windowDurationMins: duration,
        sourceLabel: "Claude Code",
        updatedAt: updatedAt
    )
}

private func claudeResetDate(from bucket: [String: AnyCodableLike]) -> Date? {
    if let unix = firstDouble(bucket, keys: ["resets_at", "resetsAt", "reset_at", "resetAt"]) {
        return Date(timeIntervalSince1970: unix)
    }
    let formatter = ISO8601DateFormatter()
    for key in ["resets_at", "resetsAt", "reset_at", "resetAt"] {
        if let raw = bucket[key]?.asString,
           let date = formatter.date(from: raw) {
            return date
        }
    }
    return nil
}

private func claudeModelName(from value: AnyCodableLike?) -> String? {
    guard let value else { return nil }
    if let string = value.asString, !string.isEmpty {
        return string
    }
    guard let object = value.asObject else { return nil }
    return ["display_name", "displayName", "name", "id"].lazy
        .compactMap { object[$0]?.asString }
        .first { !$0.isEmpty }
}

private func firstDouble(_ object: [String: AnyCodableLike], keys: [String]) -> Double? {
    keys.lazy.compactMap { object[$0]?.asDouble }.first
}

private func firstInt(_ object: [String: AnyCodableLike], keys: [String]) -> Int? {
    keys.lazy.compactMap { object[$0]?.asInt }.first
}

private extension AnyCodableLike {
    var asDouble: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .bool, .string, .null, .array, .object:
            return nil
        }
    }

    var asInt: Int? {
        guard let number = asDouble else { return nil }
        return Int(number)
    }
}
