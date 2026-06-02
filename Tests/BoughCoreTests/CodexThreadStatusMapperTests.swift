import XCTest
@testable import BoughCore

final class CodexThreadStatusMapperTests: XCTestCase {
    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToRunningAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdleWithoutClearingToolFields() {
        var notLoaded = SessionSnapshot()
        notLoaded.status = .running
        notLoaded.currentTool = "Bash"
        CodexThreadStatusMapper.apply(&notLoaded, status: ["type": .string("notLoaded")])
        XCTAssertEqual(notLoaded.status, .idle)
        XCTAssertEqual(notLoaded.currentTool, "Bash")

        var systemError = SessionSnapshot()
        systemError.status = .running
        systemError.toolDescription = "pending"
        CodexThreadStatusMapper.apply(&systemError, status: ["type": .string("systemError")])
        XCTAssertEqual(systemError.status, .idle)
        XCTAssertEqual(systemError.toolDescription, "pending")
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running

        CodexThreadStatusMapper.apply(&snapshot, status: nil)

        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testMalformedActiveFlagsBehavesLikeNoFlags() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingQuestion
        snapshot.currentTool = "Read"

        CodexThreadStatusMapper.apply(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .string("waitingOnApproval")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
    }
}
