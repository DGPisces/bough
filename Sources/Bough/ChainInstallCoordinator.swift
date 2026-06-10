import Foundation

/// Phase 21 / WR-03 serialization seam for Claude Code statusLine install.
///
/// `AppDelegate.applicationDidFinishLaunching` dispatches a `Task.detached`
/// that calls `ConfigInstaller.installClaudeCodeStatusLine(replaceExisting:)`
/// asynchronously. If the user opens Settings before that detached task
/// finishes and clicks Install, `handleClaudeStatusLineInstall(...)` calls
/// the SAME static helper concurrently. The chain-aware install path writes
/// two files (wrapper + settings.json) and is not internally locked, so two
/// overlapping invocations can interleave at the granularity of those writes
/// — last-writer-wins per file, possibly with a mismatched sentinel/settings
/// pairing.
///
/// This actor is the single serialization point both call sites must go
/// through. Because Swift actors guarantee non-reentrant exclusive access
/// to their state, only one `install(replaceExisting:)` call can be
/// in-flight at a time across the whole process. The second caller awaits
/// the first's completion and then observes a consistent on-disk state
/// before its own evaluation (chain re-install case 3 in
/// `installClaudeCodeStatusLineChainAware` is idempotent over an already-
/// installed wrapper, so the second call is a safe no-op).
///
/// Design notes:
/// - Chosen over `@MainActor` because the install is disk-bound and would
///   otherwise stutter the UI thread on slower volumes.
/// - Chosen over a `DispatchQueue` because the call sites are already
///   `async` (Task.detached / SwiftUI action handlers wrapped in Task) —
///   `await coordinator.install(...)` is idiomatic and avoids bridging
///   GCD callbacks back into Swift concurrency.
/// - The actor holds no mutable state beyond the implicit one-at-a-time
///   queue; it is intentionally a thin lock. The decision tree
///   (`installClaudeCodeStatusLineChainAware`) inside `ConfigInstaller`
///   keeps every other invariant.
actor ChainInstallCoordinator {
    static let shared = ChainInstallCoordinator()

    /// Serialized entry to `ConfigInstaller.installClaudeCodeStatusLine`.
    /// `replaceExisting: false` is the default chain-aware path; pass `true`
    /// only from the explicit Settings → conflict-sheet "Replace" UX where
    /// the user has consciously chosen to override their prev tool.
    func install(replaceExisting: Bool) -> ConfigInstaller.ClaudeCodeStatusLineInstallResult {
        ConfigInstaller.installClaudeCodeStatusLine(replaceExisting: replaceExisting)
    }

    func installClaudeIntegration(replaceExisting: Bool) -> ConfigInstaller.ClaudeCodeStatusLineInstallResult {
        let result = ConfigInstaller.installClaudeCodeStatusLine(replaceExisting: replaceExisting)
        switch result {
        case .installed, .chained:
            guard ConfigInstaller.setEnabled(source: "claude", enabled: true) else {
                return .failed("Could not install Claude Code hooks")
            }
            return result
        case .conflict, .failed:
            return result
        }
    }

    func uninstallClaudeIntegration() -> Bool {
        _ = ConfigInstaller.uninstallClaudeCodeStatusLine()
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
    /// being asserted: `install(replaceExisting:)` itself contains no
    /// `await`, so its body holds exclusive actor access end-to-end and
    /// no second caller can interleave.
    ///
    /// Swift actors ARE reentrant on `await` suspension points; that is
    /// why this test deliberately avoids `Task.sleep`. The production
    /// `install` function has the same shape (sync body), and that is
    /// what makes the WR-03 serialization guarantee real.
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
