import XCTest

final class CodingSessionsRuntimeSourceTests: XCTestCase {
    func testAppDelegateGatesCodingRuntimeBehindProductMode() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/Bough/AppDelegate.swift"))

        XCTAssertTrue(source.contains("if CodingSessionsSettings.isEnabled() {\n            startCodingRuntime()"))
        XCTAssertTrue(source.contains("private func stopCodingRuntimeForDisabledMode()"))
        XCTAssertTrue(source.contains("hookServer?.stop(removeSocketAfterDelay: false)"))
        XCTAssertTrue(source.contains("UsageMonitorService().disableForCodingSessionsOff()"))
        XCTAssertTrue(source.contains("restoreUsageMonitorAfterCodingSessionsOnIfNeeded()"))
        XCTAssertTrue(source.contains("UsageMonitorService().restoreAfterCodingSessionsOnIfNeeded()"))
        XCTAssertTrue(source.contains("private func checkAndRepairHooks() {\n        guard CodingSessionsSettings.isEnabled() else { return }"))
        XCTAssertTrue(source.contains("guard CodingSessionsSettings.isEnabled(), !Task.isCancelled else { return }\n            if ConfigInstaller.install()"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
