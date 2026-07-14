import XCTest
@testable import BoughCore

final class KeychainReadChainTests: XCTestCase {
    private let data = Data("payload".utf8)

    func testSilentSuccessShortCircuits() {
        let result = KeychainReadChain.run(
            mode: .silent,
            silentRead: { .success(self.data) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .success(data))
    }

    func testSilentItemNotFoundNeverEscalates() {
        let result = KeychainReadChain.run(
            mode: .interactiveAllowed,
            silentRead: { .failure(.itemNotFound) },
            interactiveRead: { XCTFail("must not run"); return .failure(.denied(status: -1)) })
        XCTAssertEqual(result, .failure(.itemNotFound))
    }

    func testSilentModeNeverRunsInteractiveOnDenial() {
        let result = KeychainReadChain.run(
            mode: .silent,
            silentRead: { .failure(.denied(status: -25308)) },
            interactiveRead: { XCTFail("must not run"); return .success(self.data) })
        XCTAssertEqual(result, .failure(.denied(status: -25308)))
    }

    func testInteractiveAllowedEscalatesOnlyOnDenial() {
        var order: [String] = []
        let result = KeychainReadChain.run(
            mode: .interactiveAllowed,
            silentRead: { order.append("silent"); return .failure(.denied(status: -25308)) },
            interactiveRead: { order.append("interactive"); return .success(self.data) })
        XCTAssertEqual(result, .success(data))
        XCTAssertEqual(order, ["silent", "interactive"])
    }

    func testInteractiveDenialPropagates() {
        let result = KeychainReadChain.run(
            mode: .interactiveAllowed,
            silentRead: { .failure(.denied(status: -25308)) },
            interactiveRead: { .failure(.denied(status: -128)) })
        XCTAssertEqual(result, .failure(.denied(status: -128)))
    }
}
