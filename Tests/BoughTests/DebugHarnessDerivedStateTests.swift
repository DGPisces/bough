import XCTest
@testable import Bough
import BoughCore

@MainActor
final class DebugHarnessDerivedStateTests: XCTestCase {
    func testWorkingPreviewRefreshesDerivedSessionCounts() {
        let state = AppState()

        DebugHarness.apply(.working, to: state)

        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.activeSessionId, "preview-working")
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.totalSessionCount, 1)
    }

    func testAirDropApprovalPreviewRefreshesDerivedSessionCountsWhenInvokedDirectly() {
        let state = AppState()

        DebugHarness.applyAirDropDemo(.approvalBlocked, to: state)

        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.activeSessionId, "preview-approval")
        XCTAssertEqual(state.status, .waitingApproval)
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.totalSessionCount, 1)
    }
}
