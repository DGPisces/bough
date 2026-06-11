import Foundation

/// Phase 21 / WR-03 serialization seam for the Claude Code integration toggle.
///
/// Both the Settings Hooks-tab toggle and the Welcome Guide onboarding path
/// mutate ~/.claude/settings.json through this actor. Swift actors guarantee
/// non-reentrant exclusive access, so only one install/uninstall call is
/// in-flight at a time across the whole process and overlapping callers can
/// never interleave at the granularity of individual file writes.
///
/// Design notes:
/// - Chosen over `@MainActor` because the work is disk-bound and would
///   otherwise stutter the UI thread on slower volumes.
/// - Chosen over a `DispatchQueue` because the call sites are already
///   `async` (SwiftUI action handlers wrapped in Task) — awaiting the
///   actor is idiomatic and avoids bridging GCD callbacks back into
///   Swift concurrency.
/// - The actor holds no mutable state beyond the implicit one-at-a-time
///   queue; it is intentionally a thin lock.
actor ChainInstallCoordinator {
    static let shared = ChainInstallCoordinator()

    func installClaudeIntegration(replaceExisting: Bool) -> ConfigInstaller.ClaudeCodeStatusLineInstallResult {
        // statusLine retired (spec §7): the integration toggle now only manages
        // the session-monitoring hook. Result type kept for call-site stability.
        guard ConfigInstaller.setEnabled(source: "claude", enabled: true) else {
            return .failed("Could not install Claude Code hooks")
        }
        return .installed
    }

    func uninstallClaudeIntegration() -> Bool {
        _ = ConfigInstaller.retireClaudeCodeStatusLineIfInstalled() // sweep historical leftovers
        return ConfigInstaller.setEnabled(source: "claude", enabled: false)
    }

    // MARK: - Test seam (WR-03 race-condition smoke test)

    /// Counter used by the race-condition smoke test to assert that two
    /// concurrent callers serialize. Lives on the actor so reads/writes
    /// are guaranteed exclusive — exactly the property under test.
    private var testCriticalSectionCounter: Int = 0

    /// Resets the test counter to zero. Routed through the actor so the
    /// reset itself is serialized against any in-flight critical section.
    func resetTestCounters() {
        testCriticalSectionCounter = 0
    }

    /// Increments the counter, busy-waits for `busyMicros` microseconds, then
    /// reads the counter back. The critical section is intentionally
    /// SYNCHRONOUS (no `await`) — this matches the production property
    /// being asserted: `installClaudeIntegration` / `uninstallClaudeIntegration`
    /// contain no `await`, so their bodies hold exclusive actor access
    /// end-to-end and no second caller can interleave.
    ///
    /// Swift actors ARE reentrant on `await` suspension points; that is
    /// why this test deliberately avoids `Task.sleep`. The production
    /// entries have the same shape (sync body), and that is what makes
    /// the WR-03 serialization guarantee real.
    ///
    /// Returns `(preCount, postCount)` so the caller can assert both
    /// per-call consistency and cross-call ordering. The smoke test
    /// exercises this from `Tests/BoughTests/ConfigInstallerClaudeCodeTests.swift`.
    func runSerializedCriticalSectionForTest(busyMicros: UInt64) -> (Int, Int) {
        testCriticalSectionCounter += 1
        let pre = testCriticalSectionCounter
        // Busy-wait to widen the window during which an unserialized
        // caller could have interleaved. Use a wall-clock loop instead
        // of Task.sleep so the actor's exclusive access is never released.
        let deadline = Date().addingTimeInterval(Double(busyMicros) / 1_000_000.0)
        while Date() < deadline {
            // Spin. Tight enough to exercise the scheduler, short enough
            // to keep the test under a few hundred ms.
        }
        let post = testCriticalSectionCounter
        return (pre, post)
    }
}
