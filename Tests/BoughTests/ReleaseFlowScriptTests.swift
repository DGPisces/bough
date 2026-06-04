import XCTest

final class ReleaseFlowScriptTests: XCTestCase {
    func testAssetAPIURLFlagIsRemoved() throws {
        let result = try Self.run([
            "update-appcast",
            "--tag", "v1.0.0",
            "--dmg", "/tmp/Bough.dmg",
            "--asset-api-url", "https://api.github.com/repos/example/not-public/releases/assets/1",
            "--dry-run"
        ])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("--asset-api-url is no longer supported; use --download-url"))
    }

    func testUpdateAppcastDryRunRejectsPrivateAssetURL() throws {
        let result = try Self.run([
            "update-appcast",
            "--tag", "v1.0.0",
            "--dmg", "/tmp/Bough.dmg",
            "--download-url", "https://api.github.com/repos/example/not-public/releases/assets/1",
            "--dry-run"
        ])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("--download-url must be a public GitHub Release download URL"))
    }

    func testUpdateAppcastDryRunAcceptsPublicDownloadURL() throws {
        let downloadURL = "https://github.com/DGPisces/bough/releases/download/v1.0.0/Bough-v1.0.0.dmg"
        let result = try Self.run([
            "update-appcast",
            "--tag", "v1.0.0",
            "--dmg", "/tmp/Bough.dmg",
            "--download-url", downloadURL,
            "--dry-run"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("BOUGH_DMG_DOWNLOAD_URL=\(downloadURL)"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/update-appcast.sh /tmp/Bough.dmg"))
        XCTAssertFalse(result.stdout.contains("BOUGH_DMG_ASSET_API_URL"))
        XCTAssertFalse(result.stdout.contains(Self.legacyRepoName))
    }

    func testPrepareAcceptsPublicRCMetadata() throws {
        let result = try Self.run([
            "prepare",
            "--version", "1.0.0",
            "--build", "1",
            "--tag", "v1.0.0-rc.1"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("export BOUGH_RELEASE_TAG=v1.0.0-rc.1"))
        XCTAssertTrue(result.stdout.contains("export BOUGH_RELEASE_LABEL=v1.0.0-rc.1"))
    }

    func testUpdateAppcastRejectsPrereleaseTags() throws {
        let result = try Self.run([
            "update-appcast",
            "--tag", "v1.0.0-rc.1",
            "--dmg", "/tmp/Bough.dmg",
            "--download-url", "https://github.com/DGPisces/bough/releases/download/v1.0.0-rc.1/Bough.dmg",
            "--dry-run"
        ])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("stable appcast updates only support stable tags"))
    }

    func testVerifyDryRunForStableChecksAppcastDownloadURL() throws {
        let downloadURL = "https://github.com/DGPisces/bough/releases/download/v1.0.0/Bough.dmg"
        let result = try Self.run([
            "verify",
            "--tag", "v1.0.0",
            "--dmg", "/tmp/Bough.dmg",
            "--download-url", downloadURL,
            "--dry-run"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("xmllint --noout Tools/Release/appcast.xml"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/release-flow.sh _assert-stable-appcast-url --download-url \(downloadURL)"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/release-flow.sh _assert-settings-entry --dmg /tmp/Bough.dmg"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/release-flow.sh _assert-macos-sdk --dmg /tmp/Bough.dmg --min-macos 14.0 --min-sdk 26.0"))
    }

    func testVerifyDryRunForRCDoesNotTouchDefaultAppcast() throws {
        let result = try Self.run([
            "verify",
            "--tag", "v1.0.0-rc.1",
            "--dmg", "/tmp/Bough.dmg",
            "--download-url", "https://github.com/DGPisces/bough/releases/download/v1.0.0-rc.1/Bough.dmg",
            "--dry-run"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Tools/Release/check-version-consistency.sh --with-dmg /tmp/Bough.dmg"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/release-flow.sh _assert-settings-entry --dmg /tmp/Bough.dmg"))
        XCTAssertTrue(result.stdout.contains("Tools/Release/release-flow.sh _assert-macos-sdk --dmg /tmp/Bough.dmg --min-macos 14.0 --min-sdk 26.0"))
        XCTAssertFalse(result.stdout.contains("xmllint"))
        XCTAssertFalse(result.stdout.contains("_assert-stable-appcast-url"))
    }

    func testReleaseWorkflowVerifiesPublishedGitHubAssetAfterUpload() throws {
        let workflow = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("- name: Verify published GitHub asset"))
        XCTAssertTrue(workflow.contains("gh release download \"$BOUGH_RELEASE_TAG\""))
        XCTAssertTrue(workflow.contains("[[ \"$PUBLISHED_SHA\" == \"$LOCAL_SHA\" ]]"))
        XCTAssertTrue(workflow.contains("Tools/Release/release-flow.sh verify"))
        XCTAssertTrue(workflow.range(of: "Publish GitHub Release")!.lowerBound < workflow.range(of: "Verify published GitHub asset")!.lowerBound)
        XCTAssertTrue(workflow.range(of: "Verify published GitHub asset")!.lowerBound < workflow.range(of: "Publish stable appcast branch")!.lowerBound)
    }

    func testPublishAssetDefaultsToPublicRepoAndDownloadURL() throws {
        let result = try Self.run([
            "publish-asset",
            "--tag", "v1.0.0-rc.1",
            "--asset", "/tmp/Bough.dmg",
            "--dry-run"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("--repo DGPisces/bough"))
        XCTAssertTrue(result.stdout.contains(".browserDownloadUrl"))
        XCTAssertFalse(result.stdout.contains("DGPisces/\(Self.legacyRepoName)"))
        XCTAssertFalse(result.stdout.contains(".apiUrl"))
    }

    func testCloseoutCommandRemoved() throws {
        let result = try Self.run(["closeout", "--dry-run"])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("unknown command 'closeout'"))
    }

    func testVerifyRemoteDryRunUsesPublicStableFeed() throws {
        let result = try Self.run([
            "verify-remote",
            "--tag", "v1.0.0",
            "--version", "1.0.0",
            "--build", "1",
            "--dry-run"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("feed=https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml"))
        XCTAssertFalse(result.stdout.contains(Self.legacyRepoName))
    }

    func testVerifyRemoteRCRequiresExplicitFeedURL() throws {
        let result = try Self.run([
            "verify-remote",
            "--tag", "v1.0.0-rc.1",
            "--version", "1.0.0",
            "--build", "1",
            "--dry-run"
        ])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("prerelease verify-remote requires --feed-url"))
    }

    func testVerifyRemoteRejectsUnsafeFeedURL() throws {
        let result = try Self.run([
            "verify-remote",
            "--tag", "v1.0.0",
            "--version", "1.0.0",
            "--build", "1",
            "--feed-url", "https://raw.githubusercontent.com/example/not-public/main/Tools/Release/appcast.xml",
            "--dry-run"
        ])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("remote feed URL is not allowed"))
    }

    func testVerifyRemoteUsesNoAuthHeadersForPublicFeedAndAsset() throws {
        let fakeCurl = try Self.makeFakeCurl()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeCurl.binDirectory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CURL_LOG"] = fakeCurl.logFile.path

        let result = try Self.run([
            "verify-remote",
            "--tag", "v1.0.0",
            "--version", "1.0.0",
            "--build", "1",
            "--asset-sha256", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "--asset-bytes", "5",
            "--attempts", "1",
            "--sleep", "0"
        ], environment: environment)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Remote update feed OK"))
        let curlLog = try String(contentsOf: fakeCurl.logFile, encoding: .utf8)
        XCTAssertFalse(curlLog.contains("Authorization"))
        XCTAssertFalse(curlLog.contains("Bearer"))
        XCTAssertFalse(curlLog.contains("--header"))
        XCTAssertFalse(curlLog.contains("-H"))
    }

    func testExtractChangelogRequiresBilingualReleaseNotes() throws {
        let result = try Self.runExtractChangelog(["v1.0.0"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("### English"))
        XCTAssertTrue(result.stdout.contains("### 简体中文"))
    }

    func testExtractChangelogRejectsSingleLanguageReleaseNotes() throws {
        let changelog = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughSingleLanguageChangelog-\(UUID().uuidString).md")
        try """
        # Changelog

        ## [v9.9.9] - 2026-06-03

        ### English

        - Only English release notes.
        """.write(to: changelog, atomically: true, encoding: .utf8)

        let result = try Self.runExtractChangelog(["v9.9.9", changelog.path])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("### 简体中文"))
    }

    func testBumpWritesNextBuildFromStableAppcast() throws {
        let fixture = try Self.makeReleaseFixture(shortVersion: "1.0.0", build: "1")
        let script = fixture.root.appendingPathComponent("Tools/Release/release-flow.sh")

        let result = try Self.run(
            ["bump", "--tag", "v1.0.1"],
            scriptPath: script.path,
            environment: Self.environment([
                "BOUGH_APPCAST_PATH": fixture.appcast.path
            ])
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try Self.plistExtract("CFBundleShortVersionString", in: fixture.plist), "1.0.1")
        XCTAssertEqual(try Self.plistExtract("CFBundleVersion", in: fixture.plist), "2")
        XCTAssertEqual(try Self.plistExtract("BoughReleaseLabel", in: fixture.plist), "1.0.1")
    }

    func testAssertNewBuildRejectsBuildAlreadyInStableAppcast() throws {
        let fixture = try Self.makeReleaseFixture(shortVersion: "1.0.0", build: "1")
        let script = fixture.root.appendingPathComponent("Tools/Release/release-flow.sh")

        let result = try Self.run(
            ["assert-new-build", "--build", "1"],
            scriptPath: script.path,
            environment: Self.environment([
                "BOUGH_APPCAST_PATH": fixture.appcast.path
            ])
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("release build 1 must be greater than current stable appcast build 1"))
    }

    func testAssertNewBuildAcceptsBuildNewerThanStableAppcast() throws {
        let fixture = try Self.makeReleaseFixture(shortVersion: "1.0.1", build: "2")
        let script = fixture.root.appendingPathComponent("Tools/Release/release-flow.sh")

        let result = try Self.run(
            ["assert-new-build", "--build", "2"],
            scriptPath: script.path,
            environment: Self.environment([
                "BOUGH_APPCAST_PATH": fixture.appcast.path
            ])
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Release build OK: 2 > current stable appcast build 1"))
    }

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct FakeCurl {
        let binDirectory: URL
        let logFile: URL
    }

    private struct ReleaseFixture {
        let root: URL
        let plist: URL
        let appcast: URL
    }

    private static var legacyRepoName: String {
        ["bough", "internal"].joined(separator: "-")
    }

    private static func run(
        _ args: [String],
        scriptPath: String = repoRoot.appendingPathComponent("Tools/Release/release-flow.sh").path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + args
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func environment(_ overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private static func makeReleaseFixture(shortVersion: String, build: String) throws -> ReleaseFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughReleaseFixture-\(UUID().uuidString)")
        let tools = root.appendingPathComponent("Tools/Release")
        let platform = root.appendingPathComponent("Platform/Apple")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)

        let script = tools.appendingPathComponent("release-flow.sh")
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Tools/Release/release-flow.sh"),
            to: script
        )

        let plist = platform.appendingPathComponent("Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>\(shortVersion)</string>
            <key>CFBundleVersion</key>
            <string>\(build)</string>
            <key>BoughReleaseLabel</key>
            <string>\(shortVersion)</string>
        </dict>
        </plist>
        """.write(to: plist, atomically: true, encoding: .utf8)

        let appcast = tools.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Bough</title>
            <item>
              <title>Version 1.0.0</title>
              <sparkle:version>1</sparkle:version>
              <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
            </item>
          </channel>
        </rss>
        """.write(to: appcast, atomically: true, encoding: .utf8)

        return ReleaseFixture(root: root, plist: plist, appcast: appcast)
    }

    private static func plistExtract(_ key: String, in plist: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-extract", key, "raw", plist.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "ReleaseFlowScriptTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "plutil failed: \(stderr)"]
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runExtractChangelog(_ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("Tools/Release/extract-changelog.sh").path] + args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func makeFakeCurl() throws -> FakeCurl {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughReleaseFlowCurl-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let curl = bin.appendingPathComponent("curl")
        let log = root.appendingPathComponent("curl.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: log, atomically: true, encoding: .utf8)

        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$*" >> "${CURL_LOG}"
        out=""
        url=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            --max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
          esac
        done
        if [[ -z "$out" ]]; then
          exit 22
        fi
        case "$url" in
          *appcast.xml)
            cat > "$out" <<'FEED'
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Bough</title>
            <item>
              <title>Version 1.0.0</title>
              <sparkle:version>1</sparkle:version>
              <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
              <enclosure
                url="https://github.com/DGPisces/bough/releases/download/v1.0.0/Bough.dmg"
                length="5"
                type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        FEED
            ;;
          *Bough.dmg)
            printf 'hello' > "$out"
            ;;
          *)
            exit 22
            ;;
        esac
        """
        try script.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        return FakeCurl(binDirectory: bin, logFile: log)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
