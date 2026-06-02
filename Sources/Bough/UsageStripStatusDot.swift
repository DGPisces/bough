// Sources/Bough/UsageStripStatusDot.swift
import Foundation
import BoughCore

/// Terminal visual state of the notch usage strip's status dot.
/// Color encodes severity category; animation encodes
/// in-flight or attention-needed temporal information.
enum DotState: Equatable {
    case greenSteady
    case greenBlink
    case yellowSteady
    case yellowBlink
    case redSteady
    case redBlink
    case graySteady
    case grayBlink
}

/// Animation variant rendered for a `DotState`. Pure description; the
/// view applies it via opacity calculation.
enum DotAnimation: Equatable {
    case steady           // full opacity, no motion
    case breathe          // 1.5s sinusoidal, opacity 0.4 ↔ 1.0
    case pulse            // 3 cycles of 0.3s on/off, then steady
}

/// Persistent state for the just-transitioned-to-depleted alarm. Held
/// by the view as `@State`; mutated only via AlarmReducer.step.
struct AlarmState: Equatable {
    var lastSeverity: UsageStripModel.TodaySeverity?  // nil before first observation
    var alarmStartedAt: Date?                          // nil when no alarm active

    init(lastSeverity: UsageStripModel.TodaySeverity? = nil, alarmStartedAt: Date? = nil) {
        self.lastSeverity = lastSeverity
        self.alarmStartedAt = alarmStartedAt
    }
}

/// Pure reducer for alarm bookkeeping. Detects severity transitions into
/// `.depleted` and starts a 1.8s alarm window. First observation is a
/// seed that never fires the alarm (acceptance criterion #4).
enum AlarmReducer {
    static func step(
        previous: AlarmState,
        currentSeverity: UsageStripModel.TodaySeverity,
        now: Date,
        alarmDuration: TimeInterval = 1.8
    ) -> (next: AlarmState, alarmActive: Bool) {
        // First observation: seed lastSeverity, never fire.
        guard let last = previous.lastSeverity else {
            return (AlarmState(lastSeverity: currentSeverity, alarmStartedAt: nil), false)
        }

        var next = previous
        next.lastSeverity = currentSeverity

        // Transition into depleted from a non-depleted state → start alarm.
        let transitioned = (last != .depleted) && (currentSeverity == .depleted)
        if transitioned {
            next.alarmStartedAt = now
        } else if currentSeverity != .depleted {
            // Left depleted → clear any lingering alarm window early.
            next.alarmStartedAt = nil
        }
        // depleted → depleted preserves the existing alarmStartedAt.

        let active: Bool = {
            guard let started = next.alarmStartedAt else { return false }
            return now.timeIntervalSince(started) < alarmDuration
        }()

        return (next, active)
    }
}

/// Pure classifier mapping (severity, availability, isRefreshing,
/// alarmActive, reduceMotion) to a (DotState, DotAnimation) pair.
/// Total over its declared input domain — every combination has a
/// defined output, including `severity == .unknown`.
enum UsageStatusDotClassifier {
    static func classify(
        severity: UsageStripModel.TodaySeverity,
        availability: UsageAvailability,
        isRefreshing: Bool,
        alarmActive: Bool,
        reduceMotion: Bool = false
    ) -> (state: DotState, animation: DotAnimation) {
        let (state, baseAnimation) = stateAndAnimation(
            severity: severity,
            availability: availability,
            isRefreshing: isRefreshing,
            alarmActive: alarmActive
        )
        // Reduce Motion: collapse breathe + pulse to steady. Color stays.
        let animation: DotAnimation = reduceMotion ? .steady : baseAnimation
        return (state, animation)
    }

    /// Internal: pure state-machine resolution before the Reduce Motion
    /// collapse. Priority order matches the Phase 5 / 05-UI-SPEC Priority
    /// Resolution table (post-A3' redesign — adds .overdraft at priority 2):
    ///   1. red blink (alarm) — alarmActive && severity == .depleted
    ///   2. red breathe (overdraft) — severity == .overdraft (D-07 / TODAY-12)
    ///   3. red steady (depleted, no alarm)
    ///   4. yellow blink (stale)
    ///   5. yellow steady (caution / partial)
    ///   6. gray blink (loading)
    ///   7. gray steady (unavailable)
    ///   8. green blink (refresh)
    ///   9. green steady (healthy)
    private static func stateAndAnimation(
        severity: UsageStripModel.TodaySeverity,
        availability: UsageAvailability,
        isRefreshing: Bool,
        alarmActive: Bool
    ) -> (DotState, DotAnimation) {
        // 1. Red blink (alarm) — highest priority, even over depleted steady.
        //    Note: alarm fires only on .depleted entry; .overdraft does NOT
        //    re-trigger the alarm (D-07 — overdraft uses the softer breathe).
        if alarmActive && severity == .depleted {
            return (.redBlink, .pulse)
        }
        // 2. Red breathe (overdraft) — pct < 0 (D-07 / TODAY-12). Opacity
        //    oscillates 1.0 ↔ 0.4 over 1.5s; dot never fully hides.
        if severity == .overdraft {
            return (.redSteady, .breathe)
        }
        // 3. Red steady — depleted (no alarm or alarm expired).
        if severity == .depleted {
            return (.redSteady, .steady)
        }
        // 3. Yellow blink — stale data.
        if case .stale = availability {
            return (.yellowBlink, .breathe)
        }
        // 4. Yellow steady — caution OR partial.
        if severity == .caution {
            return (.yellowSteady, .steady)
        }
        if case .partial = availability {
            return (.yellowSteady, .steady)
        }
        // 5. Gray blink — loading (no data yet).
        if case .loading = availability {
            return (.grayBlink, .breathe)
        }
        // 6. Gray steady — unavailable (no source).
        if case .unavailable = availability {
            return (.graySteady, .steady)
        }
        // Severity is .unknown but availability is .available: rare —
        // weekly window valid but forecast nil (e.g., resetsAt slipped
        // into the past). No severity to color, no temporal signal.
        if severity == .unknown {
            return (.graySteady, .steady)
        }
        // 7. Green blink — refresh in flight while otherwise normal.
        if isRefreshing {
            return (.greenBlink, .breathe)
        }
        // 8. Green steady — normal (healthy + available).
        return (.greenSteady, .steady)
    }

    /// VoiceOver label for each state, resolved through `L10n.shared` so
    /// every locale renders the dot's status natively.
    /// Caution/partial collapse on the same DotState (.yellowSteady); the
    /// view passes the discriminator separately if it wants to distinguish.
    static func accessibilityLabel(
        for state: DotState,
        availability: UsageAvailability,
        severity: UsageStripModel.TodaySeverity
    ) -> String {
        switch state {
        case .greenSteady: return L10n.shared["accessibility_status_normal"]
        case .greenBlink:  return L10n.shared["accessibility_status_normal_refreshing"]
        case .yellowSteady:
            // Distinguish caution-from-severity vs partial-from-availability.
            if severity == .caution { return L10n.shared["accessibility_status_today_quota_low"] }
            return L10n.shared["accessibility_status_data_partial"]
        case .yellowBlink: return L10n.shared["accessibility_status_data_stale"]
        case .redSteady:
            // Distinguish .overdraft (pct < 0) from .depleted (0 ≤ pct < 5) —
            // both render as .redSteady but with different animations and need
            // distinct VoiceOver labels per 05-UI-SPEC Copywriting Contract.
            if severity == .overdraft { return L10n.shared["accessibility_status_today_quota_overdrawn"] }
            return L10n.shared["accessibility_status_today_quota_depleted"]
        case .redBlink:    return L10n.shared["accessibility_status_today_quota_just_depleted"]
        case .graySteady:  return L10n.shared["accessibility_status_data_unavailable"]
        case .grayBlink:   return L10n.shared["accessibility_status_loading"]
        }
    }
}
