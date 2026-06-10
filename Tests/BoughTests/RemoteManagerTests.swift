import XCTest
@testable import Bough

@MainActor
final class RemoteManagerTests: XCTestCase {
    func testReconnectDelayFollowsExpectedBackoff() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 1), 5)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 2), 15)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 3), 45)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 4), 120)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 5), 300)
    }

    func testReconnectDelayClampsBeyondTable() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 6), 300)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 100), 300)
    }

    func testReconnectDelayNeverReturnsLessThanFirstStepForBogusInput() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 0), 5)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: -1), 5)
    }

    func testInstallFailurePathCleansTunnelAndSchedulesReconnect() throws {
        let source = try String(
            contentsOf: TestHelpers.repoRoot(from: #filePath)
                .appendingPathComponent("Sources/Bough/RemoteManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("handleInstallFailure(result.message, for: host)"))
        XCTAssertTrue(source.contains("forwarders[host.id] = nil"))
        XCTAssertTrue(source.contains("forwarder?.disconnect()"))
        XCTAssertTrue(source.contains("scheduleReconnect(for: host)"))
    }
}
