#if DEBUG
import Foundation
import BoughCore

/// In-memory snapshot presets used by the Settings → Usage debug picker
/// to verify every visual state of the notch usage strip without waiting
/// for real Codex rate-limit events. DEBUG-only — never compiled into
/// Release binaries.
///
/// Phase 5 rebuild (plan 05-03 / D-12) added the five A3' presets that
/// exercise the new severity bands plus the first-launch baseline-gap
/// notice, and removed the obsolete `crossResetWithinToday` case
/// (cross-reset math is now covered by `TodayValueCalculatorTests` and
/// surfaced live by the runtime accumulator + calculator).
enum UsageDebugPresets {
    enum Preset: String, CaseIterable, Identifiable, Hashable {
        // Pre-Phase-5 presets that test composite UI states unrelated to the
        // A3' Today value (5h slot, weekly slot, availability transitions,
        // alarm pulse). The today field on these is populated with a
        // TodayValue mapped from the legacy `forecastSafePct` knob so the
        // existing severity colors continue to render during manual smoke.
        case healthy
        case caution
        case depleted
        case partial
        case stale
        case unavailable
        case loading
        case refreshing
        case justDepleted
        case claudeCodeActive

        // Phase 5 / D-12: five A3' presets that surface the new TodayValue
        // surface, including the .overdraft severity band and the in-memory
        // first-launch baseline notice.
        case todayHealthy             // today_pct > 20%
        case todayCaution             // today_pct in 5..20
        case todayDepleted            // today_pct in 0..5
        case todayOverdraft           // today_pct < 0 (e.g. -40%)
        case firstLaunchBaselineGap   // today populated + isFirstLaunchBaseline = true

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .healthy: return "Healthy (today > 20%)"
            case .caution: return "Caution (today 5–20%)"
            case .depleted: return "Depleted (today ≤ 5%)"
            case .partial: return "Partial (5h or weekly missing)"
            case .stale: return "Stale (data expired)"
            case .unavailable: return "Unavailable (no source)"
            case .loading: return "Loading (initial)"
            case .refreshing: return "Refreshing (green blink)"
            case .justDepleted: return "Just depleted (red alarm)"
            case .claudeCodeActive: return "Claude Code active (statusLine payload)"
            case .todayHealthy: return "Today healthy (today > 20%)"
            case .todayCaution: return "Today caution (today 5–20%)"
            case .todayDepleted: return "Today depleted (today 0–5%)"
            case .todayOverdraft: return "Today overdraft (today < 0%)"
            case .firstLaunchBaselineGap: return "First-launch baseline gap (post-launch usage notice)"
            }
        }
    }

    static func snapshot(for preset: Preset, tool: UsageTool, now: Date) -> UsageSnapshot {
        switch preset {
        case .healthy:
            // Legacy preset: maps forecastSafePct=65 → pct=65 → .healthy. The
            // forecastSafePct semantic was discarded per D-09; the helper now
            // just feeds the value straight into TodayValue.pct so the
            // resulting severity band is stable.
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 18,
                fiveHourResetIn: 3 * 3600 + 25 * 60,
                weeklyUsedPct: 22,
                weeklyResetIn: 5 * 24 * 3600,
                today: makeToday(pct: 65, allowance: 14.0, weeklyUsedAtDayStart: 8, weeklyUsedNow: 22),
                availability: .available,
                now: now
            )
        case .caution:
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 62,
                fiveHourResetIn: 1 * 3600 + 12 * 60,
                weeklyUsedPct: 78,
                weeklyResetIn: 2 * 24 * 3600 + 4 * 3600,
                today: makeToday(pct: 12, allowance: 11.0, weeklyUsedAtDayStart: 69, weeklyUsedNow: 78, severity: .caution),
                availability: .available,
                now: now
            )
        case .depleted:
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 88,
                fiveHourResetIn: 35 * 60,
                weeklyUsedPct: 91,
                weeklyResetIn: 1 * 24 * 3600 + 6 * 3600,
                today: makeToday(pct: 2, allowance: 4.5, weeklyUsedAtDayStart: 87, weeklyUsedNow: 91, severity: .depleted),
                availability: .available,
                now: now
            )
        case .partial:
            return UsageSnapshot(
                tool: tool,
                planName: "Plus",
                fiveHour: .available(makeWindow(kind: .fiveHour, usedPct: 40, resetIn: 2 * 3600 + 15 * 60, now: now)),
                weekly: .unavailable(reason: "Weekly window unavailable"),
                today: nil,
                availability: .partial(reason: "Weekly window unavailable"),
                lastRefresh: now
            )
        case .stale:
            let staleFive = makeWindow(kind: .fiveHour, usedPct: 55, resetIn: 4 * 3600, now: now)
            let staleWeek = makeWindow(kind: .weekly, usedPct: 70, resetIn: 3 * 24 * 3600, now: now)
            return UsageSnapshot(
                tool: tool,
                planName: "Plus",
                fiveHour: .stale(staleFive, reason: "Usage data is stale"),
                weekly: .stale(staleWeek, reason: "Usage data is stale"),
                today: nil,
                availability: .stale(reason: "Usage data is stale"),
                lastRefresh: now.addingTimeInterval(-30 * 60)
            )
        case .unavailable:
            return UsageSnapshot.claudeUnavailable(now: now)
        case .loading:
            return UsageSnapshot(
                tool: tool,
                planName: nil,
                fiveHour: .loading,
                weekly: .loading,
                today: nil,
                availability: .loading,
                lastRefresh: nil
            )
        case .refreshing:
            // Healthy snapshot; the dot's green-blink comes from
            // debugForceIsRefreshing being toggled by applyRefreshing(...).
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 35,
                fiveHourResetIn: 2 * 3600 + 40 * 60,
                weeklyUsedPct: 30,
                weeklyResetIn: 4 * 24 * 3600,
                today: makeToday(pct: 55, allowance: 14.0, weeklyUsedAtDayStart: 24, weeklyUsedNow: 30),
                availability: .available,
                now: now
            )
        case .justDepleted:
            // Static snapshot is depleted; the alarm fires only because
            // applyJustDepletedSequence(...) drove caution → depleted.
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 88,
                fiveHourResetIn: 35 * 60,
                weeklyUsedPct: 91,
                weeklyResetIn: 1 * 24 * 3600 + 6 * 3600,
                today: makeToday(pct: 2, allowance: 4.5, weeklyUsedAtDayStart: 87, weeklyUsedNow: 91, severity: .depleted),
                availability: .available,
                now: now
            )
        case .claudeCodeActive:
            return makeSnapshot(
                tool: .claudeCode,
                fiveHourUsedPct: 32,
                fiveHourResetIn: 2 * 3600 + 30 * 60,
                weeklyUsedPct: 44,
                weeklyResetIn: 4 * 24 * 3600,
                today: makeToday(pct: 58, allowance: 14.0, weeklyUsedAtDayStart: 36, weeklyUsedNow: 44),
                availability: .available,
                now: now
            )

        // --- Phase 5 / D-12 A3' presets ---

        case .todayHealthy:
            // pct = 75 → .healthy
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 18,
                fiveHourResetIn: 3 * 3600 + 25 * 60,
                weeklyUsedPct: 22,
                weeklyResetIn: 5 * 24 * 3600,
                today: makeToday(pct: 75, allowance: 14.3, weeklyUsedAtDayStart: 18, weeklyUsedNow: 22),
                availability: .available,
                now: now
            )
        case .todayCaution:
            // pct = 12 → .caution
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 62,
                fiveHourResetIn: 1 * 3600 + 12 * 60,
                weeklyUsedPct: 78,
                weeklyResetIn: 2 * 24 * 3600 + 4 * 3600,
                today: makeToday(pct: 12, allowance: 11.0, weeklyUsedAtDayStart: 69, weeklyUsedNow: 78, severity: .caution),
                availability: .available,
                now: now
            )
        case .todayDepleted:
            // pct = 2 → .depleted (0 ≤ pct < 5)
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 88,
                fiveHourResetIn: 35 * 60,
                weeklyUsedPct: 91,
                weeklyResetIn: 1 * 24 * 3600 + 6 * 3600,
                today: makeToday(pct: 2, allowance: 4.5, weeklyUsedAtDayStart: 87, weeklyUsedNow: 91, severity: .depleted),
                availability: .available,
                now: now
            )
        case .todayOverdraft:
            // pct = -40 → .overdraft (TODAY-12 / D-07)
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 70,
                fiveHourResetIn: 2 * 3600,
                weeklyUsedPct: 88,
                weeklyResetIn: 1 * 24 * 3600,
                today: makeToday(pct: -40, allowance: 10.0, weeklyUsedAtDayStart: 74, weeklyUsedNow: 88, severity: .overdraft),
                availability: .available,
                now: now
            )
        case .firstLaunchBaselineGap:
            // A normal healthy snapshot — but the Settings notice fires only
            // when `usageStore.isFirstLaunchBaseline(for:)` returns true. The
            // wiring lives on UsageStore.debugForceFirstLaunchNotice (DEBUG-
            // only property added in plan 05-03 / D-14); applyFirstLaunch-
            // BaselineGap(...) sets that flag alongside the preset.
            return makeSnapshot(
                tool: tool,
                fiveHourUsedPct: 18,
                fiveHourResetIn: 3 * 3600 + 25 * 60,
                weeklyUsedPct: 22,
                weeklyResetIn: 5 * 24 * 3600,
                today: makeToday(pct: 65, allowance: 14.0, weeklyUsedAtDayStart: 8, weeklyUsedNow: 22),
                availability: .available,
                now: now
            )
        }
    }

    /// Apply the `refreshing` preset's side effect: toggle the store's
    /// debug-only refresh override AND set the static snapshot to
    /// `.refreshing`. Idempotent.
    @MainActor
    static func applyRefreshing(store: UsageStore) {
        store.debugForceIsRefreshing = true
        store.debugPreset = .refreshing
    }

    /// Apply the `justDepleted` preset's side effect: drive a real
    /// `caution → depleted` snapshot transition over two render ticks so
    /// the dot's AlarmReducer observes the transition naturally and
    /// fires the alarm pulse. No private-state seeding required.
    ///
    /// **Sleep duration:** 150 ms is chosen to exceed the dot's
    /// `TimelineView(.animation(minimumInterval: 0.1))` 100 ms tick
    /// budget by 1.5×. Shorter delays risk SwiftUI coalescing the
    /// caution and depleted snapshot writes into a single render commit,
    /// which would skip the lastSeverity = .caution observation and
    /// cause the alarm to fire from a healthy → depleted (or
    /// nil → depleted) transition instead — still correct end behavior
    /// per AlarmReducer test #3, but the preset would no longer
    /// specifically exercise the caution→depleted path the spec calls out.
    @MainActor
    static func applyJustDepletedSequence(store: UsageStore) async {
        store.debugPreset = .caution
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))
        store.debugPreset = .justDepleted
    }

    /// Apply the `firstLaunchBaselineGap` preset: drive a healthy snapshot
    /// AND force `usageStore.isFirstLaunchBaseline(for:)` to return true so
    /// the Settings inline notice ("Today reflects post-launch usage")
    /// renders without requiring an actual `rm ~/.bough/usage-daily.json`
    /// step (D-14 / TODAY-11). The wiring is intentionally narrow — the
    /// override is DEBUG-only and is cleared via `clearOverrides(...)`.
    @MainActor
    static func applyFirstLaunchBaselineGap(store: UsageStore) {
        store.debugForceFirstLaunchNotice = true
        store.debugPreset = .firstLaunchBaselineGap
    }

    /// Clear all debug overrides set by the helpers above. Called when
    /// the picker switches to "Off (live data)" or to a non-side-effect
    /// preset.
    @MainActor
    static func clearOverrides(store: UsageStore) {
        store.debugForceIsRefreshing = false
        store.debugForceFirstLaunchNotice = false
    }

    private static func makeWindow(kind: UsageWindowKind, usedPct: Double, resetIn: TimeInterval, now: Date) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: kind,
            usedPercent: usedPct,
            resetsAt: now.addingTimeInterval(resetIn),
            windowDurationMins: kind == .fiveHour ? 300 : 7 * 24 * 60,
            sourceLabel: "Debug",
            updatedAt: now
        )
    }

    /// Build a TodayValue with the requested pct + severity. When `severity`
    /// is nil the helper derives it from pct via the canonical D-05 remap
    /// (matches `UsageForecastCalculator.severityFor` exactly).
    private static func makeToday(
        pct: Double,
        allowance: Double,
        weeklyUsedAtDayStart: Double,
        weeklyUsedNow: Double,
        severity: TodaySeverity? = nil,
        weeklyResetAlreadyFiredToday: Bool = false
    ) -> TodayValue {
        let resolvedSeverity: TodaySeverity = severity ?? {
            if pct < 0 { return .overdraft }
            if pct < 5 { return .depleted }
            if pct <= 20 { return .caution }
            return .healthy
        }()
        let basis = TodayBasis(
            localDate: "2026-05-14",
            weeklyUsedAtDayStart: weeklyUsedAtDayStart,
            weeklyUsedNow: weeklyUsedNow,
            todayAllowanceOfWeek: allowance,
            daysRemainingUntilWeeklyReset: 5,
            weeklyResetAlreadyFiredToday: weeklyResetAlreadyFiredToday
        )
        return TodayValue(
            pct: pct,
            todayAllowanceOfWeek: allowance,
            severity: resolvedSeverity,
            basis: basis
        )
    }

    private static func makeSnapshot(
        tool: UsageTool,
        fiveHourUsedPct: Double,
        fiveHourResetIn: TimeInterval,
        weeklyUsedPct: Double,
        weeklyResetIn: TimeInterval,
        today: TodayValue?,
        availability: UsageAvailability,
        now: Date
    ) -> UsageSnapshot {
        let weeklyWindow = makeWindow(kind: .weekly, usedPct: weeklyUsedPct, resetIn: weeklyResetIn, now: now)
        return UsageSnapshot(
            tool: tool,
            planName: "Plus",
            fiveHour: .available(makeWindow(kind: .fiveHour, usedPct: fiveHourUsedPct, resetIn: fiveHourResetIn, now: now)),
            weekly: .available(weeklyWindow),
            today: today,
            availability: availability,
            lastRefresh: now
        )
    }
}
#endif
