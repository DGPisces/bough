import XCTest
@testable import Bough

/// Asserts that Platform/Apple/Info.plist contains the correct Sparkle configuration
/// keys required by Phase 18 (UPDATE-01, UPDATE-04, DIAG-03).
///
/// Uses `plutil -extract` to read the source plist directly — the same
/// pattern as VersionConsistencyTests — because `Bundle.main.infoDictionary`
/// in `swift test` (SPM) resolves to the test runner's bundle, not the
/// app bundle, and the Sparkle keys would not be present there.
final class SparkleUpdaterConfigTests: XCTestCase {

    // MARK: - Info.plist key assertions (UPDATE-01, UPDATE-04)

    func testSUFeedURLIsPublicStableAppcast() throws {
        let url = try plistExtract("SUFeedURL")
        XCTAssertTrue(
            url == "https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml",
            "SUFeedURL must point to the public stable GitHub appcast feed, got: \(url)"
        )
    }

    func testStableVersionMetadata() throws {
        XCTAssertEqual(try plistExtract("CFBundleShortVersionString"), "1.0.0")
        XCTAssertEqual(try plistExtract("CFBundleVersion"), "1")
        XCTAssertEqual(try plistExtract("BoughReleaseLabel"), "1.0.0")
    }

    func testSUPublicEDKeyIsRealKey() throws {
        let key = try plistExtract("SUPublicEDKey")
        XCTAssertEqual(
            key.count, 44,
            "SUPublicEDKey must be 44 characters (base64 ed25519 public key), got length \(key.count)"
        )
        // Validate base64 character set (allows single trailing =)
        let base64Regex = try NSRegularExpression(pattern: "^[A-Za-z0-9+/]+=?$")
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        XCTAssertNotNil(
            base64Regex.firstMatch(in: key, range: range),
            "SUPublicEDKey must be valid base64, got: \(key)"
        )
    }

    func testSUScheduledCheckIntervalIs86400() throws {
        let raw = try plistExtract("SUScheduledCheckInterval")
        let interval = Int(raw)
        XCTAssertEqual(
            interval, 86400,
            "SUScheduledCheckInterval must be 86400 (24 h per D-05), got \(raw)"
        )
    }

    // MARK: - UpdateState isUpdateAvailable logic (DIAG-03)

    func testUpdateStateIsUpdateAvailableLogic() {
        // Positive cases
        XCTAssertTrue(UpdateState.available(version: "1.0").isUpdateAvailable)
        XCTAssertTrue(UpdateState.available(version: "1.1.0").isUpdateAvailable)
        // Negative cases
        XCTAssertFalse(UpdateState.idle.isUpdateAvailable)
        XCTAssertFalse(UpdateState.checking.isUpdateAvailable)
        XCTAssertFalse(UpdateState.upToDate.isUpdateAvailable)
        XCTAssertFalse(UpdateState.failed("network error").isUpdateAvailable)
    }

    func testAppcastFeedURLDefaultsToStableMainFeed() {
        XCTAssertEqual(
            UpdateChecker.appcastFeedURLString(bundleInfo: [:]),
            "https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml"
        )
        XCTAssertEqual(
            UpdateChecker.appcastFeedURLString(bundleInfo: [
                "SUFeedURL": "https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml"
            ]),
            "https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml"
        )
    }

    func testDeprecatedUpdateChannelSelectionIsCleared() {
        let suiteName = "SparkleUpdaterConfigTests.deprecatedUpdateChannel"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("dev", forKey: SettingsKey.deprecatedUpdateChannel)
        UpdateChecker.clearDeprecatedUpdateChannelSelection(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: SettingsKey.deprecatedUpdateChannel))
    }

    func testNoUpdateAbortMapsToUpToDateState() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1001)
        XCTAssertEqual(UpdateChecker.stateForAbortedUpdate(error: error), .upToDate)
    }

    func testUnexpectedAbortMapsToFailedState() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "download failed"]
        )
        XCTAssertEqual(UpdateChecker.stateForAbortedUpdate(error: error), .failed("download failed"))
    }

    #if DEBUG
    func testDebugPreviewLaunchesSkipSparkleStart() {
        XCTAssertTrue(UpdateChecker.shouldSkipSparkleForDebugLaunch(
            arguments: ["Bough", "--preview", "airdrop-file-ready"],
            bundlePath: "/Applications/Bough.app",
            bundleIdentifier: "com.dgpisces.bough"
        ))
        XCTAssertTrue(UpdateChecker.shouldSkipSparkleForDebugLaunch(
            arguments: ["Bough"],
            bundlePath: "/tmp/Bough-Debug.app",
            bundleIdentifier: "com.dgpisces.bough"
        ))
        XCTAssertTrue(UpdateChecker.shouldSkipSparkleForDebugLaunch(
            arguments: ["Bough"],
            bundlePath: "/tmp/Bough",
            bundleIdentifier: nil
        ))
        XCTAssertFalse(UpdateChecker.shouldSkipSparkleForDebugLaunch(
            arguments: ["Bough"],
            bundlePath: "/Applications/Bough.app",
            bundleIdentifier: "com.dgpisces.bough"
        ))
    }
    #endif

    // MARK: - Helpers

    /// Reads a top-level scalar from `Platform/Apple/Info.plist` via `plutil -extract <key> raw`.
    /// Mirrors the pattern in VersionConsistencyTests.plistExtract.
    private func plistExtract(_ key: String) throws -> String {
        let plistPath = Self.repoRoot.appendingPathComponent("Platform/Apple/Info.plist").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-extract", key, "raw", plistPath]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "SparkleUpdaterConfigTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "plutil -extract \(key) raw failed.\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
                ]
            )
        }
        return stdout
    }

    /// Repo root derived from this file's location:
    /// Tests/BoughTests/SparkleUpdaterConfigTests.swift → three pops → repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BoughTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // repo root
}
