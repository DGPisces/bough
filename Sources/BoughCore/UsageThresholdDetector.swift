import Foundation

/// The three weekly-remaining thresholds Phase 29 fires notifications on
/// (D-02 / D-03). Single source of truth so the detector, dedup key, copy
/// selection, and Settings UI all read the same boundary instead of scattering
/// magic numbers. Storing `boundary` in the SQLite ledger as `REAL` is safe
/// because the values are exact (`20.0 / 5.0 / 0.0`) — see Phase 29 Pitfall 5.
public enum UsageThresholdLevel: CaseIterable, Equatable, Sendable {
    case warning20
    case warning5
    case exhausted0

    public var boundary: Double {
        switch self {
        case .warning20: return 20.0
        case .warning5: return 5.0
        case .exhausted0: return 0.0
        }
    }
}

public struct UsageThresholdCrossing: Equatable, Sendable {
    public let tool: UsageTool
    public let level: UsageThresholdLevel
    public let resetIntervalID: String
    public let detectedAt: Date
    public let previousRemaining: Double
    public let currentRemaining: Double

    public init(
        tool: UsageTool,
        level: UsageThresholdLevel,
        resetIntervalID: String,
        detectedAt: Date,
        previousRemaining: Double,
        currentRemaining: Double
    ) {
        self.tool = tool
        self.level = level
        self.resetIntervalID = resetIntervalID
        self.detectedAt = detectedAt
        self.previousRemaining = previousRemaining
        self.currentRemaining = currentRemaining
    }
}

/// Pure edge-detection between two accepted weekly samples (D-03 / D-06).
///
/// Returns one `UsageThresholdCrossing` per `UsageThresholdLevel` whose
/// `previousRemaining > boundary` strictly held and `currentRemaining
/// <= boundary` now holds. The first sample on a fresh install (previous
/// nil) is silent (D-06). The crossings carry `current.weekly`'s
/// `resetIntervalID` so the dedup key is anchored to the active weekly
/// window — when the window rolls (new `resetIntervalID`) all three
/// thresholds rearm naturally (D-05).
public enum UsageThresholdDetector {
    public static func detectCrossings(
        previous: UsageSnapshot?,
        current: UsageSnapshot,
        detectedAt: Date
    ) -> [UsageThresholdCrossing] {
        guard let previous else { return [] }
        guard let previousWeekly = previous.weekly.thresholdSourceSnapshot,
              let currentWeekly = current.weekly.thresholdSourceSnapshot else {
            return []
        }

        let previousRemaining = roundedToTenth(100.0 - previousWeekly.usedPercent)
        let currentRemaining = roundedToTenth(100.0 - currentWeekly.usedPercent)
        let resetIntervalID = UsageRecoveryPolicy.resetIntervalID(for: currentWeekly)

        return UsageThresholdLevel.allCases.compactMap { level in
            guard previousRemaining > level.boundary,
                  currentRemaining <= level.boundary else {
                return nil
            }
            return UsageThresholdCrossing(
                tool: current.tool,
                level: level,
                resetIntervalID: resetIntervalID,
                detectedAt: detectedAt,
                previousRemaining: previousRemaining,
                currentRemaining: currentRemaining
            )
        }
    }

    private static func roundedToTenth(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

private extension UsageWindowSlot {
    var thresholdSourceSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .unavailable:
            return nil
        }
    }
}
