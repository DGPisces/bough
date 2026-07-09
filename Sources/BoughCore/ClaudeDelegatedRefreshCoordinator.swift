import Foundation

public enum ClaudeCLITouchError: Error, Equatable {
    case claudeNotInstalled
    case launchFailed
}

/// Delegated token refresh (spec §3.4): when the CLI-owned token is expired
/// or rejected and the Keychain item hasn't changed, spawn the Claude CLI
/// ("touch") so IT refreshes its own credentials, then verify by watching the
/// item's mdat fingerprint. Never refreshes directly — the refresh token
/// belongs to the CLI (CodexBar's ownership model).
/// Adapted from steipete/CodexBar (MIT). See CREDITS.md.
public final class ClaudeDelegatedRefreshCoordinator: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case skippedByCooldown
        case cliUnavailable
        case succeeded
        case failed
    }

    public static let successCooldown: TimeInterval = 300
    public static let failureCooldown: TimeInterval = 20
    public static let fingerprintPollDelays: [TimeInterval] = [0.2, 0.5, 0.8]

    private let touch: () throws -> Void
    private let fingerprint: () -> Date?
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    /// Serializes attempts (single-flight): a second caller blocks here,
    /// then observes the first attempt's cooldown and returns skipped.
    private let attemptLock = NSLock()
    private var lastAttemptAt: Date?
    private var lastCooldown: TimeInterval = 0

    public init(
        touch: @escaping () throws -> Void,
        fingerprint: @escaping () -> Date?,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.touch = touch
        self.fingerprint = fingerprint
        self.now = now
        self.sleep = sleep
    }

    public func attempt() -> Outcome {
        attemptLock.lock()
        defer { attemptLock.unlock() }

        if let lastAttemptAt, now().timeIntervalSince(lastAttemptAt) < lastCooldown {
            return .skippedByCooldown
        }

        let baseline = fingerprint()
        do {
            try touch()
        } catch ClaudeCLITouchError.claudeNotInstalled {
            // No cooldown: availability is rechecked on every trigger.
            return .cliUnavailable
        } catch {
            // Touch failed, but the CLI may still have refreshed elsewhere —
            // the fingerprint check below decides.
        }

        var changed = fingerprint() != baseline
        if !changed {
            for delay in Self.fingerprintPollDelays {
                sleep(delay)
                if fingerprint() != baseline { changed = true; break }
            }
        }
        lastAttemptAt = now()
        lastCooldown = changed ? Self.successCooldown : Self.failureCooldown
        return changed ? .succeeded : .failed
    }
}
