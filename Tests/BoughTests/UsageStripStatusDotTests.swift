// Tests/BoughTests/UsageStripStatusDotTests.swift
import XCTest
@testable import Bough
@testable import BoughCore

final class UsageStripStatusDotClassifierTests: XCTestCase {
    typealias Severity = UsageStripModel.TodaySeverity

    func classify(
        severity: Severity,
        availability: UsageAvailability,
        isRefreshing: Bool = false,
        alarmActive: Bool = false,
        reduceMotion: Bool = false
    ) -> (state: DotState, animation: DotAnimation) {
        UsageStatusDotClassifier.classify(
            severity: severity,
            availability: availability,
            isRefreshing: isRefreshing,
            alarmActive: alarmActive,
            reduceMotion: reduceMotion
        )
    }

    // MARK: - State table cells

    func testHealthyAvailableMapsToGreenSteady() {
        let r = classify(severity: .healthy, availability: .available)
        XCTAssertEqual(r.state, .greenSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testHealthyAvailableRefreshingMapsToGreenBlink() {
        let r = classify(severity: .healthy, availability: .available, isRefreshing: true)
        XCTAssertEqual(r.state, .greenBlink)
        XCTAssertEqual(r.animation, .breathe)
    }

    func testCautionAvailableMapsToYellowSteady() {
        let r = classify(severity: .caution, availability: .available)
        XCTAssertEqual(r.state, .yellowSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testHealthyPartialMapsToYellowSteady() {
        let r = classify(severity: .healthy, availability: .partial(reason: "weekly missing"))
        XCTAssertEqual(r.state, .yellowSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testHealthyStaleMapsToYellowBlink() {
        let r = classify(severity: .healthy, availability: .stale(reason: "old"))
        XCTAssertEqual(r.state, .yellowBlink)
        XCTAssertEqual(r.animation, .breathe)
    }

    func testDepletedAvailableMapsToRedSteady() {
        let r = classify(severity: .depleted, availability: .available)
        XCTAssertEqual(r.state, .redSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testDepletedAlarmActiveMapsToRedBlink() {
        let r = classify(severity: .depleted, availability: .available, alarmActive: true)
        XCTAssertEqual(r.state, .redBlink)
        XCTAssertEqual(r.animation, .pulse)
    }

    func testUnavailableMapsToGraySteady() {
        let r = classify(severity: .unknown, availability: .unavailable(reason: "no source"))
        XCTAssertEqual(r.state, .graySteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testLoadingMapsToGrayBlink() {
        let r = classify(severity: .unknown, availability: .loading)
        XCTAssertEqual(r.state, .grayBlink)
        XCTAssertEqual(r.animation, .breathe)
    }

    // MARK: - Unknown severity rule

    func testUnknownSeverityWithAvailableMapsToGraySteady() {
        // Rare edge: weekly available but forecast nil.
        let r = classify(severity: .unknown, availability: .available)
        XCTAssertEqual(r.state, .graySteady)
        XCTAssertEqual(r.animation, .steady)
    }

    func testUnknownSeverityWithStaleMapsToYellowBlink() {
        let r = classify(severity: .unknown, availability: .stale(reason: "old"))
        XCTAssertEqual(r.state, .yellowBlink)
        XCTAssertEqual(r.animation, .breathe)
    }

    func testUnknownSeverityWithPartialMapsToYellowSteady() {
        let r = classify(severity: .unknown, availability: .partial(reason: "weekly missing"))
        XCTAssertEqual(r.state, .yellowSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    // MARK: - Priority overlaps

    func testDepletedBeatsRefreshing() {
        // Per spec: red wins over green-blink even if refresh is in flight.
        let r = classify(severity: .depleted, availability: .available, isRefreshing: true)
        XCTAssertEqual(r.state, .redSteady)
    }

    func testDepletedAlarmBeatsDepletedSteady() {
        // Per spec: red blink (alarm) > red steady.
        let r = classify(severity: .depleted, availability: .available, alarmActive: true)
        XCTAssertEqual(r.state, .redBlink)
    }

    func testStaleBeatsCaution() {
        // Per spec: yellow blink (stale) > yellow steady (caution).
        let r = classify(severity: .caution, availability: .stale(reason: "old"))
        XCTAssertEqual(r.state, .yellowBlink)
    }

    func testLoadingBeatsHealthy() {
        // Per spec: gray blink (loading) > green steady.
        let r = classify(severity: .healthy, availability: .loading)
        XCTAssertEqual(r.state, .grayBlink)
    }

    func testLoadingBeatsRefreshingGreen() {
        // Loading (no data yet) is more urgent than refresh-in-flight.
        let r = classify(severity: .healthy, availability: .loading, isRefreshing: true)
        XCTAssertEqual(r.state, .grayBlink)
    }

    // MARK: - Reduce Motion

    func testReduceMotionCollapsesBreatheToSteady() {
        let r = classify(severity: .healthy, availability: .available, isRefreshing: true, reduceMotion: true)
        XCTAssertEqual(r.state, .greenBlink)  // state preserved (color is signal)
        XCTAssertEqual(r.animation, .steady)   // animation collapsed
    }

    func testReduceMotionCollapsesPulseToSteady() {
        let r = classify(severity: .depleted, availability: .available, alarmActive: true, reduceMotion: true)
        XCTAssertEqual(r.state, .redBlink)
        XCTAssertEqual(r.animation, .steady)
    }

    func testReduceMotionLeavesSteadyAlone() {
        let r = classify(severity: .healthy, availability: .available, reduceMotion: true)
        XCTAssertEqual(r.state, .greenSteady)
        XCTAssertEqual(r.animation, .steady)
    }

    // MARK: - Accessibility labels

    func testEveryDotStateHasNonEmptyAccessibilityLabel() {
        let cases: [(DotState, UsageAvailability, Severity)] = [
            (.greenSteady, .available, .healthy),
            (.greenBlink,  .available, .healthy),
            (.yellowSteady, .available, .caution),
            (.yellowSteady, .partial(reason: "x"), .healthy),
            (.yellowBlink, .stale(reason: "x"), .healthy),
            (.redSteady,   .available, .depleted),
            (.redBlink,    .available, .depleted),
            (.graySteady,  .unavailable(reason: "x"), .unknown),
            (.grayBlink,   .loading, .unknown),
        ]
        for (state, availability, severity) in cases {
            let label = UsageStatusDotClassifier.accessibilityLabel(
                for: state, availability: availability, severity: severity
            )
            XCTAssertFalse(label.isEmpty, "label missing for \(state)")
            XCTAssertTrue(label.hasPrefix("Status:"), "expected 'Status:' prefix; got \(label)")
        }
    }

    func testYellowSteadyDistinguishesCautionFromPartial() {
        let cautionLabel = UsageStatusDotClassifier.accessibilityLabel(
            for: .yellowSteady, availability: .available, severity: .caution
        )
        let partialLabel = UsageStatusDotClassifier.accessibilityLabel(
            for: .yellowSteady, availability: .partial(reason: "x"), severity: .healthy
        )
        XCTAssertNotEqual(cautionLabel, partialLabel, "caution and partial must read differently for VO users")
    }
}

final class AlarmReducerTests: XCTestCase {
    typealias Severity = UsageStripModel.TodaySeverity

    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // 1. First render seeds, never fires.
    func testFirstRenderSeedsLastSeverityAndDoesNotFire() {
        let initial = AlarmState()  // lastSeverity = nil
        let r = AlarmReducer.step(previous: initial, currentSeverity: .depleted, now: t0)
        XCTAssertEqual(r.next.lastSeverity, .depleted)
        XCTAssertNil(r.next.alarmStartedAt)
        XCTAssertFalse(r.alarmActive)
    }

    // 2. caution → depleted fires.
    func testCautionToDepletedStartsAlarm() {
        let prev = AlarmState(lastSeverity: .caution)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: t0)
        XCTAssertEqual(r.next.lastSeverity, .depleted)
        XCTAssertEqual(r.next.alarmStartedAt, t0)
        XCTAssertTrue(r.alarmActive)
    }

    // 3. healthy → depleted fires.
    func testHealthyToDepletedStartsAlarm() {
        let prev = AlarmState(lastSeverity: .healthy)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: t0)
        XCTAssertEqual(r.next.alarmStartedAt, t0)
        XCTAssertTrue(r.alarmActive)
    }

    // 4. unknown → depleted fires.
    func testUnknownToDepletedStartsAlarm() {
        let prev = AlarmState(lastSeverity: .unknown)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: t0)
        XCTAssertEqual(r.next.alarmStartedAt, t0)
        XCTAssertTrue(r.alarmActive)
    }

    // 5. depleted → depleted preserves window, does not retrigger.
    func testDepletedToDepletedDoesNotRetrigger() {
        let started = t0
        let prev = AlarmState(lastSeverity: .depleted, alarmStartedAt: started)
        let later = t0.addingTimeInterval(0.5)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: later)
        XCTAssertEqual(r.next.alarmStartedAt, started, "alarmStartedAt should NOT advance")
        XCTAssertTrue(r.alarmActive, "still inside the 1.8s window")
    }

    // 6. depleted → caution clears the window early.
    func testDepletedToCautionClearsAlarmEarly() {
        let prev = AlarmState(lastSeverity: .depleted, alarmStartedAt: t0)
        let inWindow = t0.addingTimeInterval(0.5)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .caution, now: inWindow)
        XCTAssertNil(r.next.alarmStartedAt)
        XCTAssertFalse(r.alarmActive)
    }

    // 7. Window expires at exactly alarmDuration (strict <).
    func testWindowExpiresAtBoundary() {
        let prev = AlarmState(lastSeverity: .depleted, alarmStartedAt: t0)
        let atBoundary = t0.addingTimeInterval(1.8)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: atBoundary)
        XCTAssertFalse(r.alarmActive, "strict < boundary: 1.8 is NOT active")
    }

    // 8. Mid-window stays active.
    func testWindowMidFlightIsActive() {
        let prev = AlarmState(lastSeverity: .depleted, alarmStartedAt: t0)
        let mid = t0.addingTimeInterval(0.9)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: mid)
        XCTAssertTrue(r.alarmActive)
    }

    // 9. Custom alarmDuration parameterizes the boundary.
    func testCustomAlarmDuration() {
        let prev = AlarmState(lastSeverity: .caution)
        let r = AlarmReducer.step(previous: prev, currentSeverity: .depleted, now: t0, alarmDuration: 0.5)
        XCTAssertTrue(r.alarmActive)

        let prev2 = AlarmState(lastSeverity: .depleted, alarmStartedAt: t0)
        let atShortBoundary = t0.addingTimeInterval(0.5)
        let r2 = AlarmReducer.step(previous: prev2, currentSeverity: .depleted, now: atShortBoundary, alarmDuration: 0.5)
        XCTAssertFalse(r2.alarmActive, "0.5s duration should expire at exactly 0.5s")
    }

    // Bonus: re-entry after leaving depleted re-fires the alarm (acceptance #3).
    func testReentryAfterLeavingDepletedReFiresAlarm() {
        let started = t0
        let depletedState = AlarmState(lastSeverity: .depleted, alarmStartedAt: started)

        // Leave depleted.
        let leftAt = t0.addingTimeInterval(2.0)
        let leftR = AlarmReducer.step(previous: depletedState, currentSeverity: .caution, now: leftAt)
        XCTAssertNil(leftR.next.alarmStartedAt)

        // Re-enter depleted.
        let reentryAt = t0.addingTimeInterval(3.0)
        let reentryR = AlarmReducer.step(previous: leftR.next, currentSeverity: .depleted, now: reentryAt)
        XCTAssertEqual(reentryR.next.alarmStartedAt, reentryAt, "alarm must re-fire on re-entry")
        XCTAssertTrue(reentryR.alarmActive)
    }
}
