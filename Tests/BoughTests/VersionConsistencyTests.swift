import XCTest

/// Binds `Tools/Release/check-version-consistency.sh` into the `swift test`
/// gate so every test run asserts version SSOT (per REQUIREMENTS.md
/// UPDATE-05 / GOV-02 and 14-CONTEXT.md D-01 / D-04).
///
/// Three test methods:
///   1. `testCheckScriptStandaloneExits` — ALWAYS runs; invokes the
///      shell gate and asserts exit 0. This is the script-level gate.
///   2. `testVersionStringsAgreeAcrossAllArtifacts` — reads the source
///      `Platform/Apple/Info.plist` directly via `plutil -extract … raw` and
///      proves the read mechanism works. Asserts Apple-compatible numeric
///      three-component shape on CFBundleShortVersionString; prerelease labels
///      belong to manual-download release metadata, not bundle metadata.
    ///   3. `testSUFeedURLAndAutomaticChecks` — reads `SUFeedURL` and
    ///      `SUEnableAutomaticChecks` from the source plist and asserts the
    ///      public stable appcast feed plus automatic checks.
final class VersionConsistencyTests: XCTestCase {

    // MARK: - Test methods

    func testCheckScriptStandaloneExits() throws {
        let result = try Self.runCheckScript()
        XCTAssertEqual(
            result.exitCode, 0,
            """
            Version consistency check failed.
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            """
        )
    }

    func testVersionStringsAgreeAcrossAllArtifacts() throws {
        let short = try Self.plistExtract("CFBundleShortVersionString")
        let build = try Self.plistExtract("CFBundleVersion")

        XCTAssertTrue(
            try Self.isNumericBundleShortVersion(short),
            "CFBundleShortVersionString '\(short)' must be three numeric components; prerelease labels belong to manual-download release metadata."
        )
        XCTAssertFalse(
            build.isEmpty,
            "CFBundleVersion is empty — expected a non-empty build number."
        )
    }

    func testBundleShortVersionRejectsPrereleaseLabels() throws {
        XCTAssertFalse(
            try Self.isNumericBundleShortVersion("1.0.0-rc.1"),
            "CFBundleShortVersionString must reject prerelease labels; use manual-download release metadata instead."
        )
    }

    func testManualDownloadPrereleaseTagMapsToNumericBundleBaseVersion() throws {
        let fixture = try Self.makeVersionFixture(shortVersion: "1.0.0", build: "1")
        let script = fixture.appendingPathComponent("Tools/Release/check-version-consistency.sh").path
        let result = try Self.runCheckScript(
            scriptPath: script,
            environment: ["BOUGH_RELEASE_TAG": "v1.0.0-rc.1"]
        )
        XCTAssertEqual(
            result.exitCode, 0,
            """
            Expected manual-download prerelease tag v1.0.0-rc.1 to map to bundle base 1.0.0.
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            """
        )
        XCTAssertTrue(
            result.stderr.contains("BOUGH_RELEASE_TAG=v1.0.0-rc.1"),
            "Shell gate should report the explicit RC release tag instead of silently ignoring it."
        )
    }

    func testSUFeedURLAndAutomaticChecks() throws {
        let enabled = try Self.plistExtract("SUEnableAutomaticChecks")
        XCTAssertEqual(enabled, "true")

        let feedURL = try Self.plistExtract("SUFeedURL")
        let urlRegex = try NSRegularExpression(
            pattern: "^https://raw\\.githubusercontent\\.com/DGPisces/bough/appcast/appcast\\.xml$"
        )
        let urlRange = NSRange(feedURL.startIndex..<feedURL.endIndex, in: feedURL)
        XCTAssertNotNil(
            urlRegex.firstMatch(in: feedURL, range: urlRange),
            "SUFeedURL '\(feedURL)' must reference the public stable raw GitHub appcast feed."
        )
        XCTAssertEqual(
            enabled, "true",
            "SUEnableAutomaticChecks must be 'true'."
        )
    }

    func testReleaseLabelUsesStablePublicVersion() throws {
        XCTAssertEqual(try Self.plistExtract("BoughReleaseLabel"), "1.0.3")
    }

    // MARK: - Helpers

    private struct CheckRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Shells out to `Tools/Release/check-version-consistency.sh` via `/bin/bash`
    /// and captures stdout + stderr + exit code.
    private static func runCheckScript(
        _ extraArgs: [String] = [],
        scriptPath: String = repoRoot.appendingPathComponent("Tools/Release/check-version-consistency.sh").path,
        environment: [String: String] = [:]
    ) throws -> CheckRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + extraArgs
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CheckRun(
            exitCode: process.terminationStatus,
            stdout: stdoutString,
            stderr: stderrString
        )
    }

    private static func isNumericBundleShortVersion(_ short: String) throws -> Bool {
        let numericVersionRegex = try NSRegularExpression(
            pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$"
        )
        let shortRange = NSRange(short.startIndex..<short.endIndex, in: short)
        return numericVersionRegex.firstMatch(in: short, range: shortRange) != nil
    }

    private static func makeVersionFixture(shortVersion: String, build: String) throws -> URL {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughVersionConsistencyTests-\(UUID().uuidString)")
        let releaseDir = fixtureRoot.appendingPathComponent("Tools/Release")
        let appleDir = fixtureRoot.appendingPathComponent("Platform/Apple")
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appleDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Tools/Release/check-version-consistency.sh"),
            to: releaseDir.appendingPathComponent("check-version-consistency.sh")
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>\(shortVersion)</string>
            <key>CFBundleVersion</key>
            <string>\(build)</string>
        </dict>
        </plist>
        """
        try plist.write(
            to: appleDir.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let appcast = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Bough</title>
            <item>
              <sparkle:version>\(build)</sparkle:version>
              <sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString>
            </item>
          </channel>
        </rss>
        """
        try appcast.write(
            to: releaseDir.appendingPathComponent("appcast.xml"),
            atomically: true,
            encoding: .utf8
        )
        return fixtureRoot
    }

    /// Reads a top-level scalar from `Platform/Apple/Info.plist` via
    /// `plutil -extract <key> raw`. Returns the raw value as a string
    /// (trimmed of trailing newline). Throws an XCTest failure if
    /// `plutil` exits non-zero or the key is missing.
    private static func plistExtract(_ key: String) throws -> String {
        let plistPath = repoRoot.appendingPathComponent("Platform/Apple/Info.plist").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-extract", key, "raw", plistPath]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrString = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "VersionConsistencyTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "plutil -extract \(key) raw failed.\nstdout:\n\(stdoutString)\nstderr:\n\(stderrString)"
                ]
            )
        }
        return stdoutString
    }

    /// Repo-root derivation: this file lives at
    /// `Tests/BoughTests/VersionConsistencyTests.swift`; three
    /// `deletingLastPathComponent()` pops yield the repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BoughTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // repo root
}
