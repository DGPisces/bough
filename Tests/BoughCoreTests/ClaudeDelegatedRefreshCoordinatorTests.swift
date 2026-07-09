import XCTest
@testable import BoughCore

final class ClaudeDelegatedRefreshCoordinatorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)

    /// 可变时钟 + 零延迟 sleep 的协调器工厂。
    private func makeCoordinator(
        touch: @escaping () throws -> Void,
        fingerprints: @escaping () -> Date?,
        now: @escaping () -> Date
    ) -> ClaudeDelegatedRefreshCoordinator {
        ClaudeDelegatedRefreshCoordinator(
            touch: touch, fingerprint: fingerprints, now: now, sleep: { _ in })
    }

    func testFingerprintChangeAfterTouchSucceedsAndArmsLongCooldown() {
        var fingerprint = epoch
        var touched = false
        var clock = epoch
        let coordinator = makeCoordinator(
            // 累加而非置固定值：第二次 attempt 的 touch 也要产生变化。
            touch: { touched = true; fingerprint = fingerprint.addingTimeInterval(5) },
            fingerprints: { fingerprint },
            now: { clock })
        XCTAssertEqual(coordinator.attempt(), .succeeded)
        XCTAssertTrue(touched)
        // 成功冷却 300s：299s 后仍 skipped，301s 后放行。
        clock = epoch.addingTimeInterval(299)
        XCTAssertEqual(coordinator.attempt(), .skippedByCooldown)
        clock = epoch.addingTimeInterval(301)
        XCTAssertEqual(coordinator.attempt(), .succeeded)
    }

    func testNoFingerprintChangeFailsAndArmsShortCooldown() {
        var clock = epoch
        let coordinator = makeCoordinator(
            touch: {},
            fingerprints: { self.epoch },  // 永不变化
            now: { clock })
        XCTAssertEqual(coordinator.attempt(), .failed)
        clock = epoch.addingTimeInterval(19)
        XCTAssertEqual(coordinator.attempt(), .skippedByCooldown)
        clock = epoch.addingTimeInterval(21)
        XCTAssertEqual(coordinator.attempt(), .failed)
    }

    func testTouchThrowingStillChecksFingerprint() {
        // CLI touch 报错但 Keychain 实际已更新（CLI 自己在别处刷新了）→ 仍算成功。
        var fingerprint = epoch
        let coordinator = makeCoordinator(
            touch: { fingerprint = self.epoch.addingTimeInterval(5); throw ClaudeCLITouchError.launchFailed },
            fingerprints: { fingerprint },
            now: { self.epoch })
        XCTAssertEqual(coordinator.attempt(), .succeeded)
    }

    func testClaudeNotInstalledReturnsCLIUnavailableWithoutCooldown() {
        let coordinator = makeCoordinator(
            touch: { throw ClaudeCLITouchError.claudeNotInstalled },
            fingerprints: { self.epoch },
            now: { self.epoch })
        XCTAssertEqual(coordinator.attempt(), .cliUnavailable)
        // 不记录冷却：立刻重试仍是 cliUnavailable（而非 skipped）。
        XCTAssertEqual(coordinator.attempt(), .cliUnavailable)
    }

    func testNilBaselineWithLaterFingerprintCountsAsChanged() {
        var fingerprint: Date? = nil
        let coordinator = makeCoordinator(
            touch: { fingerprint = self.epoch },
            fingerprints: { fingerprint },
            now: { self.epoch })
        XCTAssertEqual(coordinator.attempt(), .succeeded)
    }

    func testConcurrentAttemptsSingleFlight() {
        // 第一个 attempt 在 touch 中阻塞时，第二个线程的 attempt 必须
        // 串行等待并命中第一个记录的冷却（skippedByCooldown），
        // 而不是并发再 touch 一次。
        let touchStarted = DispatchSemaphore(value: 0)
        let releaseTouch = DispatchSemaphore(value: 0)
        var touchCount = 0
        let coordinator = makeCoordinator(
            touch: {
                touchCount += 1
                touchStarted.signal()
                releaseTouch.wait()
            },
            fingerprints: { self.epoch },
            now: { self.epoch })

        let first = Thread { _ = coordinator.attempt() }
        first.start()
        XCTAssertEqual(touchStarted.wait(timeout: .now() + 2), .success)

        var secondOutcome: ClaudeDelegatedRefreshCoordinator.Outcome?
        let secondDone = DispatchSemaphore(value: 0)
        let second = Thread {
            secondOutcome = coordinator.attempt()
            secondDone.signal()
        }
        second.start()
        releaseTouch.signal()
        XCTAssertEqual(secondDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondOutcome, .skippedByCooldown)
        XCTAssertEqual(touchCount, 1)
    }
}
