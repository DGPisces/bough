import XCTest

/// Runs Tools/Release/bump-version.sh against a staged copy of the real repo
/// files, so the script's match patterns are continuously checked against the
/// actual sources without ever mutating the working tree.
final class BumpVersionScriptTests: XCTestCase {
    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
    private var stagingRoot: URL!

    /// Files the script reads or rewrites, staged at identical relative paths.
    private static let stagedPaths = [
        "Tools/Release/bump-version.sh",
        "Tools/Release/check-version-consistency.sh",
        "Tools/Release/extract-changelog.sh",
        "Tools/Release/appcast.xml",
        "Platform/Apple/Info.plist",
        "Sources/Bough/Settings.swift",
        "Tests/BoughTests/VersionConsistencyTests.swift",
        "Tests/BoughTests/SparkleUpdaterConfigTests.swift",
        "CHANGELOG.md",
    ]

    override func setUpWithError() throws {
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bump-version-tests-\(UUID().uuidString)")
        for path in Self.stagedPaths {
            let source = Self.repoRoot.appendingPathComponent(path)
            let target = stagingRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    func testBumpRewritesAllSevenVersionLocations() throws {
        let oldBuild = try XCTUnwrap(Int(try plistValue("CFBundleVersion")))
        let expectedBuild = String(oldBuild + 1)

        let result = try runBump(["9.9.9"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)

        XCTAssertEqual(try plistValue("BoughReleaseLabel"), "9.9.9")
        XCTAssertEqual(try plistValue("CFBundleShortVersionString"), "9.9.9")
        XCTAssertEqual(try plistValue("CFBundleVersion"), expectedBuild)

        let settings = try stagedText("Sources/Bough/Settings.swift")
        XCTAssertTrue(settings.contains(#"static let fallback = "9.9.9""#))

        let versionTests = try stagedText("Tests/BoughTests/VersionConsistencyTests.swift")
        XCTAssertTrue(versionTests.contains(#"plistExtract("BoughReleaseLabel"), "9.9.9")"#))

        let sparkleTests = try stagedText("Tests/BoughTests/SparkleUpdaterConfigTests.swift")
        XCTAssertTrue(sparkleTests.contains(#"plistExtract("CFBundleShortVersionString"), "9.9.9")"#))
        XCTAssertTrue(sparkleTests.contains(#"plistExtract("CFBundleVersion"), "\#(expectedBuild)")"#))
        XCTAssertTrue(sparkleTests.contains(#"plistExtract("BoughReleaseLabel"), "9.9.9")"#))

        let changelog = try stagedText("CHANGELOG.md")
        XCTAssertTrue(changelog.contains("## [v9.9.9] - "))
        let newEntryIndex = try XCTUnwrap(changelog.range(of: "## [v9.9.9]")).lowerBound
        let previousEntryIndex = try XCTUnwrap(changelog.range(of: "## [v1.")).lowerBound
        XCTAssertLessThan(newEntryIndex, previousEntryIndex, "new entry must be inserted on top")
    }

    func testBumpedChangelogSkeletonPassesExtractChangelog() throws {
        _ = try runBump(["9.9.9"])
        let extract = try runStagedScript(
            "Tools/Release/extract-changelog.sh",
            arguments: ["v9.9.9", stagingRoot.appendingPathComponent("CHANGELOG.md").path]
        )
        XCTAssertEqual(extract.exitCode, 0, extract.stderr)
        XCTAssertTrue(extract.stdout.contains("### English"))
        XCTAssertTrue(extract.stdout.contains("### 简体中文"))
    }

    func testBumpRejectsDuplicateRun() throws {
        XCTAssertEqual(try runBump(["9.9.9"]).exitCode, 0)
        let second = try runBump(["9.9.9"])
        XCTAssertNotEqual(second.exitCode, 0)
        XCTAssertTrue(second.stderr.contains("equals current version"))
    }

    func testBumpRejectsExistingChangelogEntry() throws {
        XCTAssertEqual(try runBump(["9.9.9"]).exitCode, 0)
        // 9.9.8 differs from the now-current 9.9.9, so the version guard passes
        // and a second entry lands; bumping back to 9.9.9 must then trip the
        // changelog duplicate guard.
        XCTAssertEqual(try runBump(["9.9.8"]).exitCode, 0)
        let third = try runBump(["9.9.9"])
        XCTAssertNotEqual(third.exitCode, 0)
        XCTAssertTrue(third.stderr.contains("already has an entry"))
    }

    func testBumpRejectsMalformedVersion() throws {
        let result = try runBump(["1.0"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("three numeric components"))
    }

    func testBumpHonorsExplicitBuildOverride() throws {
        let result = try runBump(["9.9.9", "--build", "42"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try plistValue("CFBundleVersion"), "42")
        let sparkleTests = try stagedText("Tests/BoughTests/SparkleUpdaterConfigTests.swift")
        XCTAssertTrue(sparkleTests.contains(#"plistExtract("CFBundleVersion"), "42")"#))
    }

    // MARK: - Helpers

    private func runBump(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try runStagedScript("Tools/Release/bump-version.sh", arguments: arguments)
    }

    private func runStagedScript(
        _ relativePath: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [stagingRoot.appendingPathComponent(relativePath).path] + arguments
        process.currentDirectoryURL = stagingRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func stagedText(_ relativePath: String) throws -> String {
        try String(contentsOf: stagingRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func plistValue(_ key: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = [
            "-extract", key, "raw",
            stagingRoot.appendingPathComponent("Platform/Apple/Info.plist").path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        let value = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
