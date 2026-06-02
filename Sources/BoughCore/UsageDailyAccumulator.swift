import Foundation

/// Per-tool daily-allowance baseline persisted to `~/.bough/usage-daily.json` (D-01, D-03).
///
/// Stored as a `[String: DailyBaseline]` dictionary keyed by `UsageTool.rawValue`
/// so the JSON schema is a stable map keyed by string. The `[Tool: DailyBaseline]`
/// in-memory shape is reconstructed at the I/O boundary in `AtomicJSONStorage.live`.
/// Per D-03, Phase 6 can add the `.claudeCode` key without an on-disk schema migration.
public struct DailyBaseline: Codable, Equatable, Sendable {
    /// The tool this baseline belongs to (codex / claudeCode).
    public var tool: UsageTool
    /// `YYYY-MM-DD` in the baseline's local timezone at capture time.
    public var localDate: String
    /// `weekly.usedPercent` at the moment the baseline was captured. The accumulator
    /// uses this to derive `todayAllowanceOfWeek` and to detect cross-midnight rollovers.
    public var weeklyUsedAtDayStart: Double
    /// Allowance for today expressed as a percentage of the weekly window.
    /// Computed as `(100 - weeklyUsedAtDayStart) / daysRemainingUntilWeeklyReset`.
    public var todayAllowanceOfWeek: Double
    /// TZ identifier (e.g. `America/Los_Angeles`) at baseline capture, used by
    /// `recordTick` to detect mid-day timezone changes per D-10.
    public var timeZoneIdentifier: String
    /// Wall-clock instant the baseline was captured.
    public var capturedAt: Date

    public init(
        tool: UsageTool,
        localDate: String,
        weeklyUsedAtDayStart: Double,
        todayAllowanceOfWeek: Double,
        timeZoneIdentifier: String,
        capturedAt: Date
    ) {
        self.tool = tool
        self.localDate = localDate
        self.weeklyUsedAtDayStart = weeklyUsedAtDayStart
        self.todayAllowanceOfWeek = todayAllowanceOfWeek
        self.timeZoneIdentifier = timeZoneIdentifier
        self.capturedAt = capturedAt
    }
}

/// Test-and-production indirection over the on-disk store (D-04).
///
/// Production binds `.live` which delegates to `AtomicJSONStore.write/read` against
/// `~/.bough/usage-daily.json`. Plan 05-03's unit tests inject an in-memory closure
/// pair to exercise `UsageDailyAccumulator` without touching the user's `~/.bough`.
public struct AtomicJSONStorage: Sendable {
    public let write: @Sendable ([String: DailyBaseline]) throws -> Void
    public let read: @Sendable () -> [String: DailyBaseline]

    public init(
        write: @escaping @Sendable ([String: DailyBaseline]) throws -> Void,
        read: @escaping @Sendable () -> [String: DailyBaseline]
    ) {
        self.write = write
        self.read = read
    }

    public static let live = AtomicJSONStorage(
        write: { try AtomicJSONStore.write($0, to: "usage-daily.json") },
        read:  { AtomicJSONStore.read([String: DailyBaseline].self, from: "usage-daily.json") ?? [:] }
    )
}

/// Owns the per-tool daily-allowance baseline state across the UsageStore lifetime.
///
/// Single owner per process (class, not struct). UsageStore calls `recordTick(...)`
/// on every snapshot refresh; the accumulator decides whether the existing baseline
/// is still valid (same `localDate` + `timeZoneIdentifier`) or whether it must seed
/// a fresh one. Persistence happens at the boundary via the injected `AtomicJSONStorage`.
///
/// Boundary cases handled (see also plan 05-03 for full semantic test coverage):
/// - TODAY-07: per-tool baseline persisted across app restart.
/// - TODAY-08: cross-midnight rollover seeds a new baseline from the current
///   `weekly.usedPercent` and recomputes `todayAllowanceOfWeek`.
/// - TODAY-09: a mid-day weekly reset is left to plan 05-02's calculator to handle
///   via pre/post-reset segment math; the accumulator keeps the baseline keyed by
///   `localDate` and does NOT reseed on the reset alone (D-05).
/// - TODAY-10: a mid-day timezone change invalidates the existing baseline
///   (different `timeZoneIdentifier`) and seeds a fresh one for the new local date.
/// - TODAY-11 / D-13 / D-14: first launch with no on-disk baseline for today's
///   `localDate` flags `isFirstLaunchBaseline[tool] = true`. The flag is in-memory
///   only and is cleared on subsequent same-process midnight rollovers.
public final class UsageDailyAccumulator {
    public private(set) var baselines: [UsageTool: DailyBaseline]
    /// In-memory per D-14 / TODAY-11. Never persisted. True only when the baseline
    /// for the current `localDate` was seeded from `weekly.usedPercent` in this
    /// process AND no prior baseline existed for the tool on disk.
    public private(set) var isFirstLaunchBaseline: [UsageTool: Bool]

    private let store: AtomicJSONStorage

    public init(store: AtomicJSONStorage = .live) {
        self.store = store
        let raw = store.read()
        // Translate the on-disk `[String: DailyBaseline]` (keyed by `UsageTool.rawValue`
        // per D-03) into the in-memory `[UsageTool: DailyBaseline]` shape. Drop any
        // entries whose key does not parse as a known UsageTool — forward-compat for
        // unknown keys is intentional.
        var loaded: [UsageTool: DailyBaseline] = [:]
        for (key, value) in raw {
            if let tool = UsageTool(rawValue: key) {
                loaded[tool] = value
            }
        }
        self.baselines = loaded
        self.isFirstLaunchBaseline = [:]
    }

    /// Single entry point UsageStore calls on every snapshot refresh.
    ///
    /// - Requirement coverage: TODAY-07 (persistence), TODAY-08 (cross-midnight),
    ///   TODAY-09 (weekly-reset comment — see implementation note below),
    ///   TODAY-10 (timezone change), TODAY-11 (first-launch flag).
    /// - The accumulator is the sole writer of `~/.bough/usage-daily.json`; persist
    ///   is best-effort here (swallow the error) because dropping a tick should not
    ///   crash the app. Test paths inject a storage that re-throws to exercise the
    ///   error path explicitly.
    public func recordTick(
        weekly: UsageWindowSnapshot,
        tool: UsageTool,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) {
        let currentLocalDate = Self.formattedYYYYMMDD(now, calendar: calendar, timeZone: timeZone)
        let existing = baselines[tool]

        let needsReseed: Bool
        if let existing {
            // TODAY-08: different localDate triggers a cross-midnight rollover reseed.
            // TODAY-10: different timeZoneIdentifier (mid-day TZ change) triggers a reseed
            //           keyed to the new local date.
            // TODAY-09 note: a weekly reset alone does NOT cause a reseed — the accumulator
            //                stays keyed by localDate; the calculator handles pre/post-reset
            //                segment math (D-05). We comment this case explicitly so future
            //                readers do not introduce a usedPercent-drop-based reseed.
            needsReseed = (existing.localDate != currentLocalDate)
                || (existing.timeZoneIdentifier != timeZone.identifier)
        } else {
            needsReseed = true
        }

        if needsReseed {
            let isFirstLaunchSeed = (existing == nil)
            let daysRemaining = Self.daysRemainingUntilWeeklyReset(
                weekly: weekly,
                now: now,
                calendar: calendar,
                timeZone: timeZone
            )
            let remainingBudget = max(0.0, 100.0 - weekly.usedPercent)
            let todayAllowance = remainingBudget / daysRemaining

            let fresh = DailyBaseline(
                tool: tool,
                localDate: currentLocalDate,
                weeklyUsedAtDayStart: weekly.usedPercent,
                todayAllowanceOfWeek: todayAllowance,
                timeZoneIdentifier: timeZone.identifier,
                capturedAt: now
            )
            baselines[tool] = fresh
            isFirstLaunchBaseline[tool] = isFirstLaunchSeed
            persist()
        }
        // else: baseline is still valid for the current (tool, localDate, timeZone) —
        // preserve it unchanged and avoid an unnecessary disk write.
    }

    /// Reader for the current baseline of a tool (nil if none has been seeded yet).
    public func baseline(for tool: UsageTool) -> DailyBaseline? {
        baselines[tool]
    }

    /// Cold-start hook used by `UsageStore.restoreContinuityStateIfAvailable` and
    /// `UsageMonitorRunner.init` to seed the in-memory baseline from the SQLite
    /// continuity store when `usage-daily.json` is absent or stale for today's
    /// local date.
    ///
    /// Without this hook, the cold-start path fell back to a first-`recordTick`
    /// reseed at the current `weekly.usedPercent`, which made `todayUsed = 0` and
    /// forced `UsageForecastCalculator.forecast(...)` into its `pct = 100`
    /// placeholder branch (V040-QUAL-01). The SQLite `daily_state.weekly_start`
    /// row is the authoritative day-start baseline kept by Phase 24's continuity
    /// store; this method routes it back into the accumulator without disturbing
    /// the JSON->SQLite migration marker and without firing a synthetic reseed.
    ///
    /// Persists the restored baseline back to `usage-daily.json` so the next
    /// process also boots with a non-stale baseline. The post-Phase-24 contract
    /// keeps SQLite as the source of truth; this write self-heals the JSON cache.
    public func restoreBaseline(_ baseline: DailyBaseline, for tool: UsageTool) {
        baselines[tool] = baseline
        isFirstLaunchBaseline[tool] = false
        persist()
    }

    /// Reader for the first-launch in-memory flag (TODAY-11).
    public func isFirstLaunch(for tool: UsageTool) -> Bool {
        isFirstLaunchBaseline[tool] ?? false
    }

    // MARK: - Private helpers

    private func persist() {
        // On-disk schema is keyed by UsageTool.rawValue per D-03.
        let payload: [String: DailyBaseline] = Dictionary(
            uniqueKeysWithValues: baselines.map { ($0.key.rawValue, $0.value) }
        )
        // Best-effort persistence: ticks happen every snapshot refresh, so we swallow
        // transient disk errors here rather than crash the app. The live store
        // surfaces errors via the throwing AtomicJSONStorage signature so tests can
        // pin them down explicitly.
        try? store.write(payload)
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
            // Defensive bound: a missing component should never happen for a valid
            // Date + Gregorian Calendar, but fall back to a stable sentinel rather
            // than crashing so a corrupted clock state cannot wedge the accumulator.
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Days remaining until the weekly window resets, measured from the local-day
    /// start of `now` to the local-day start of `weekly.resetsAt`.
    ///
    /// Clamped to `>= 1.0` (project no-fallback rule's bounded sentinel) so the
    /// `todayAllowanceOfWeek` division below never divides by zero or yields a
    /// negative budget when the reset is imminent or already past.
    static func daysRemainingUntilWeeklyReset(
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
}
