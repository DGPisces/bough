import XCTest
@testable import BoughCore

final class OAuthUsageSupportTests: XCTestCase {
    func testCooldownGateBlocksUntilExpiryAndCleansUp() {
        let gate = OAuthCooldownGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(gate.activeCooldown(key: "a", now: t0))
        gate.setCooldown(key: "a", until: t0.addingTimeInterval(300))
        XCTAssertEqual(gate.activeCooldown(key: "a", now: t0), t0.addingTimeInterval(300))
        XCTAssertEqual(gate.activeCooldown(key: "a", now: t0.addingTimeInterval(299)), t0.addingTimeInterval(300))
        XCTAssertNil(gate.activeCooldown(key: "a", now: t0.addingTimeInterval(300)))
        XCTAssertNil(gate.activeCooldown(key: "a", now: t0)) // expired entry was removed
    }

    func testCooldownGateClear() {
        let gate = OAuthCooldownGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        gate.setCooldown(key: "a", until: t0.addingTimeInterval(300))
        gate.setCooldown(key: "b", until: t0.addingTimeInterval(300))
        gate.clear(key: "a")
        XCTAssertNil(gate.activeCooldown(key: "a", now: t0))
        XCTAssertNotNil(gate.activeCooldown(key: "b", now: t0))
        gate.clearAll()
        XCTAssertNil(gate.activeCooldown(key: "b", now: t0))
    }

    func testHTTPResponseHeaderIsCaseInsensitive() {
        let response = OAuthHTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data())
        XCTAssertEqual(response.header("retry-after"), "120")
        XCTAssertEqual(response.header("RETRY-AFTER"), "120")
    }

    func testAuthFailureClassification() {
        XCTAssertTrue(OAuthUsageError.tokenExpired.isAuthFailure)
        XCTAssertTrue(OAuthUsageError.unauthorized(statusCode: 401).isAuthFailure)
        XCTAssertTrue(OAuthUsageError.credentialsUnavailable(reason: "x").isAuthFailure)
        XCTAssertTrue(OAuthUsageError.keychainDenied.isAuthFailure)
        XCTAssertFalse(OAuthUsageError.rateLimited(retryAfterSeconds: 60).isAuthFailure)
        XCTAssertFalse(OAuthUsageError.network("boom").isAuthFailure)
    }
}
