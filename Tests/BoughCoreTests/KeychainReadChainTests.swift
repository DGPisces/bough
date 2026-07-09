import XCTest
@testable import BoughCore

final class KeychainReadChainTests: XCTestCase {
    private let data = Data("payload".utf8)

    func testNoUISuccessShortCircuits() {
        var cliCalled = false
        let result = KeychainReadChain.run(
            mode: .silent,
            noUIRead: { .success(self.data) },
            cliRead: { cliCalled = true; return .failure(.denied(status: -1)) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .success(data))
        XCTAssertFalse(cliCalled)
    }

    func testNoUIItemNotFoundSkipsCLI() {
        var cliCalled = false
        let result = KeychainReadChain.run(
            mode: .silent,
            noUIRead: { .failure(.itemNotFound) },
            cliRead: { cliCalled = true; return .success(self.data) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .failure(.itemNotFound))
        XCTAssertFalse(cliCalled)
    }

    func testNoUIDeniedFallsBackToCLISuccess() {
        let result = KeychainReadChain.run(
            mode: .silent,
            noUIRead: { .failure(.denied(status: -25308)) },
            cliRead: { .success(self.data) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .success(data))
    }

    func testCLIItemNotFoundWins() {
        let result = KeychainReadChain.run(
            mode: .silent,
            noUIRead: { .failure(.denied(status: -25308)) },
            cliRead: { .failure(.itemNotFound) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .failure(.itemNotFound))
    }

    func testSilentModeNeverRunsInteractiveAndKeepsNoUIStatus() {
        let result = KeychainReadChain.run(
            mode: .silent,
            noUIRead: { .failure(.denied(status: -25308)) },
            cliRead: { .failure(.denied(status: 51)) },
            interactiveRead: { XCTFail("must not run"); return .success(self.data) })
        XCTAssertEqual(result, .failure(.denied(status: -25308)))
    }

    func testInteractiveAllowedRunsInteractiveAsLastResort() {
        var order: [String] = []
        let result = KeychainReadChain.run(
            mode: .interactiveAllowed,
            noUIRead: { order.append("noUI"); return .failure(.denied(status: -25308)) },
            cliRead: { order.append("cli"); return .failure(.denied(status: 51)) },
            interactiveRead: { order.append("interactive"); return .success(self.data) })
        XCTAssertEqual(result, .success(data))
        XCTAssertEqual(order, ["noUI", "cli", "interactive"])
    }

    func testInteractiveDenialPropagates() {
        let result = KeychainReadChain.run(
            mode: .interactiveAllowed,
            noUIRead: { .failure(.denied(status: -25308)) },
            cliRead: { .failure(.denied(status: 51)) },
            interactiveRead: { .failure(.denied(status: -128)) })
        XCTAssertEqual(result, .failure(.denied(status: -128)))
    }
}
