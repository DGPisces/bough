import Foundation

/// CodexBar-parity linear pace (spec §8.3): expected = elapsed fraction of the
/// window × 100; delta drives a 7-stage classification; the average burn rate
/// projects an exhaustion ETA. Pure function — computed at render time.
public struct UsagePace: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case onTrack, slightlyAhead, ahead, farAhead, slightlyBehind, behind, farBehind
    }

    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let deltaPercent: Double
    public let stage: Stage
    /// Projected exhaustion instant at the current average rate; nil when the
    /// budget lasts to the reset.
    public let etaAt: Date?
    public let willLastToReset: Bool
}

public enum UsagePaceCalculator {
    public static func pace(for window: UsageWindowSnapshot, now: Date) -> UsagePace? {
        let duration = TimeInterval(window.windowDurationMins) * 60
        guard duration > 0 else { return nil }
        let timeUntilReset = window.resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = duration - timeUntilReset
        let expected = min(max((elapsed / duration) * 100, 0), 100)
        let actual = min(max(window.usedPercent, 0), 100)
        if elapsed == 0, actual > 0 { return nil }

        let delta = actual - expected
        let paceStage = stage(for: delta)
        var etaAt: Date?
        var willLastToReset = false
        // ETA is only projected when the user is materially ahead of pace (delta > 2).
        // onTrack and all behind-variants conservatively assume the budget lasts to reset.
        if elapsed > 0, actual > 0, delta > 2 {
            let rate = actual / elapsed // percent per second
            let remaining = max(0, 100 - actual)
            let secondsToExhaustion = remaining / rate
            if secondsToExhaustion >= timeUntilReset {
                willLastToReset = true
            } else {
                etaAt = now.addingTimeInterval(secondsToExhaustion)
            }
        } else {
            willLastToReset = true
        }

        return UsagePace(
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            deltaPercent: delta,
            stage: paceStage,
            etaAt: etaAt,
            willLastToReset: willLastToReset
        )
    }

    private static func stage(for delta: Double) -> UsagePace.Stage {
        let magnitude = abs(delta)
        if magnitude <= 2 { return .onTrack }
        if magnitude <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if magnitude <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
