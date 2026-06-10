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

    func testBuildAppCreateDmgUsesStagingParentDirectory() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/Build/build-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DMG_STAGING=\"$BUILD_DIR/dmg-staging\""))
        XCTAssertTrue(source.contains("ditto \"$APP_BUNDLE\" \"$DMG_STAGING/$APP_NAME.app\""))
        XCTAssertTrue(source.contains("\"$DMG_PATH\" \"$DMG_STAGING\""))
        XCTAssertFalse(source.contains("\"$DMG_PATH\" \"$APP_BUNDLE\""))
    }

    func testBuildDmgGuardsOptionalSparkleNestedComponentsBeforeSigning() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/Build/build-dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("[ -e \"$xpc\" ] || continue"))
        XCTAssertTrue(source.contains("if [ -e \"$SPARKLE_B/Autoupdate\" ]; then"))
        XCTAssertTrue(source.contains("if [ -d \"$SPARKLE_B/Updater.app\" ]; then"))
    }

    func testBuildDmgFailsWhenExplicitDeveloperIdIdentityIsMissing() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/Build/build-dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ERROR: Developer ID identity '$SIGN_IDENTITY' not found in keychain"))
        XCTAssertTrue(source.contains("SKIP_SIGN=1 SKIP_NOTARIZE=1 for local smoke"))
        XCTAssertFalse(source.contains("not in keychain — using ad-hoc bundle signature"))
    }

    func testSparkleUpgradeSmokeBuildsLaunchableInteractiveBundle() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/Smoke/sparkle-upgrade-smoke.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("embed_sparkle_runtime"))
        XCTAssertTrue(source.contains("Sparkle.framework"))
        XCTAssertTrue(source.contains(#"install_name_tool -add_rpath "@executable_path/../Frameworks""#))
        XCTAssertTrue(source.contains("interactive smoke requires a real .build/release/Bough executable"))
        XCTAssertTrue(source.contains(#"[[ "$SKIP_INTERACTIVE" != "1" ]]"#))
        XCTAssertTrue(source.contains("pipeline-only executable stub"))
    }

    func testUsageMonitorArgumentsFailClosedOnInvalidInput() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/BoughUsageMonitor/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("enum UsageMonitorArgumentError"))
        XCTAssertTrue(source.contains("case unknownOption(String)"))
        XCTAssertTrue(source.contains("case missingValue(option: String)"))
        XCTAssertTrue(source.contains("case invalidValue(option: String, value: String)"))
        XCTAssertTrue(source.contains("!values[valueIndex].hasPrefix(\"--\")"))
        XCTAssertTrue(source.contains("exit(2)"))
    }
}
