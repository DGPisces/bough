import XCTest

final class BuildScriptPackagingTests: XCTestCase {
    private let repoRoot = TestHelpers.repoRoot(from: #filePath)

    func testBuildAppPackagesUsageMonitorHelperAndLaunchAgent() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/Build/build-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Contents/Helpers/bough-usage-monitor"))
        XCTAssertTrue(source.contains("Contents/Library/LaunchAgents"))
        XCTAssertTrue(source.contains("dev.dgpisces.bough.usage-monitor.plist"))
        XCTAssertTrue(source.contains("plutil -lint"))
        XCTAssertTrue(source.contains("codesign --force --options runtime --sign \"$SIGN_ID\" \"$APP_BUNDLE/Contents/Helpers/bough-usage-monitor\""))
    }
}
