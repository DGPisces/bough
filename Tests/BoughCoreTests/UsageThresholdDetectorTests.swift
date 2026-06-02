import XCTest
@testable import BoughCore

final class UsageThresholdDetectorTests: XCTestCase {
    private let detectedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstSampleSilenceReturnsNoCrossings() {
        let current = makeSnapshot(weeklyUsed: 99.0)
        XCTAssertTrue(UsageThresholdDetector.detectCrossings(
            previous: nil,
            current: current,
            detectedAt: detectedAt
        ).isEmpty)
    }

    func testCrossingAt20Fires() {
        let previous = makeSnapshot(weeklyUsed: 75.0) // remaining 25.0
        let current = makeSnapshot(weeklyUsed: 81.0)  // remaining 19.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning20])
        XCTAssertEqual(crossings.first?.previousRemaining, 25.0)
        XCTAssertEqual(crossings.first?.currentRemaining, 19.0)
    }

    func testCrossingAt5Fires() {
        let previous = makeSnapshot(weeklyUsed: 90.0) // remaining 10.0
        let current = makeSnapshot(weeklyUsed: 96.0)  // remaining 4.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning5])
    }

    func testCrossingAt0FiresOnExhaustion() {
        let previous = makeSnapshot(weeklyUsed: 99.0) // remaining 1.0
        let current = makeSnapshot(weeklyUsed: 100.0) // remaining 0.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.exhausted0])
    }

    func testMultipleCrossingsInOneStep() {
        let previous = makeSnapshot(weeklyUsed: 79.0) // remaining 21.0
        let current = makeSnapshot(weeklyUsed: 100.0) // remaining 0.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning20, .warning5, .exhausted0])
    }

    func testNoRefireWhenAlreadyBelowThreshold() {
        let previous = makeSnapshot(weeklyUsed: 96.0) // remaining 4.0
        let current = makeSnapshot(weeklyUsed: 97.0)  // remaining 3.0
        XCTAssertTrue(UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        ).isEmpty)
    }

    func testEqualBoundaryDoesNotFire() {
        // Boundary equality on previous = 20.0 violates the strict `> boundary`
        // contract, so the crossing must not fire even though current sits on
        // the boundary.
        let previous = makeSnapshot(weeklyUsed: 80.0) // remaining 20.0
        let current = makeSnapshot(weeklyUsed: 80.0)  // remaining 20.0
        XCTAssertTrue(UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        ).isEmpty)
    }

    func testExactBoundaryEqualityFiresOnCurrent() {
        let previous = makeSnapshot(weeklyUsed: 79.9) // remaining 20.1
        let current = makeSnapshot(weeklyUsed: 80.0)  // remaining 20.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning20])
    }

    func testResetIntervalRearmEmitsCrossingForNewWindow() {
        let previous = makeSnapshot(weeklyUsed: 79.0, resetsAt: Date(timeIntervalSince1970: 1_801_000_000))
        let current = makeSnapshot(weeklyUsed: 81.0, resetsAt: Date(timeIntervalSince1970: 1_802_000_000))
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning20])
        XCTAssertEqual(crossings.first?.resetIntervalID, "weekly:10080:1802000000")
    }

    func testRoundingAtComparisonSite() {
        let previous = makeSnapshot(weeklyUsed: 79.94) // remaining rounds to 20.1
        let current = makeSnapshot(weeklyUsed: 80.04)  // remaining rounds to 20.0
        let crossings = UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        )
        XCTAssertEqual(crossings.map(\.level), [.warning20])
    }

    func testMissingWeeklyWindowReturnsNoCrossings() {
        let previous = makeSnapshot(weeklyUsed: 50.0)
        let current = UsageSnapshot(
            tool: .codex,
            planName: nil,
            fiveHour: .loading,
            weekly: .unavailable(reason: "no data"),
            today: nil,
            availability: .unavailable(reason: "no data"),
            lastRefresh: nil
        )
        XCTAssertTrue(UsageThresholdDetector.detectCrossings(
            previous: previous,
            current: current,
            detectedAt: detectedAt
        ).isEmpty)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        weeklyUsed: Double,
        tool: UsageTool = .codex,
        resetsAt: Date = Date(timeIntervalSince1970: 1_801_000_000)
    ) -> UsageSnapshot {
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: weeklyUsed,
            resetsAt: resetsAt,
            windowDurationMins: 10_080,
            sourceLabel: "test",
            updatedAt: detectedAt
        )
        let fiveHour = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 10,
            resetsAt: resetsAt,
            windowDurationMins: 300,
            sourceLabel: "test",
            updatedAt: detectedAt
        )
        return UsageSnapshot(
            tool: tool,
            planName: "prolite",
            fiveHour: .available(fiveHour),
            weekly: .available(weekly),
            today: nil,
            availability: .available,
            lastRefresh: detectedAt
        )
    }
}
