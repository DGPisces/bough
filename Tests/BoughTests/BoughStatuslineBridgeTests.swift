import XCTest

final class BoughStatuslineBridgeTests: XCTestCase {
    private var temporaryHomes: [URL] = []

    override func tearDownWithError() throws {
        for home in temporaryHomes {
            try? FileManager.default.removeItem(at: home)
        }
        temporaryHomes.removeAll()
        try super.tearDownWithError()
    }

    func testDropsExtraPayloadFieldsAndWritesOnlyClosedFieldSet() throws {
        let result = try runBridge(
            """
            {"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"output_style":"default","model":"sonnet","transcript_path":"/secret","cwd":"/private/project"}
            """
        )

        XCTAssertEqual(result.stdout, " \n")
        XCTAssertEqual(result.stderr, "")
        let json = try Self.jsonObject(at: result.usageFile)
        XCTAssertEqual(Set(json.keys), ["version", "rate_limits", "output_style", "model"])
        XCTAssertNil(json["transcript_path"])
        XCTAssertNil(json["cwd"])
    }

    func testMissingRateLimitsPersistsOnlyClosedFieldsWithNullRateLimits() throws {
        let result = try runBridge(#"{"version":1,"output_style":"default","model":"sonnet","cwd":"/private/project"}"#)

        let json = try Self.jsonObject(at: result.usageFile)
        XCTAssertEqual(Set(json.keys), ["version", "rate_limits", "output_style", "model"])
        XCTAssertTrue(json["rate_limits"] is NSNull)
    }

    func testMalformedJSONDoesNotWriteUsageFile() throws {
        let result = try runBridge(#"{"rate_limits":"#)

        XCTAssertEqual(result.stdout, " \n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.usageFile.path))
    }

    func testOnlyFiveHourAndOnlySevenDayPayloadsAreAccepted() throws {
        let fiveHour = try runBridge(#"{"rate_limits":{"five_hour":{"used_percent":20,"resets_at":2000}}}"#)
        XCTAssertNotNil(try Self.jsonObject(at: fiveHour.usageFile)["rate_limits"])

        let sevenDay = try runBridge(#"{"rate_limits":{"seven_day":{"used_percent":40,"resets_at":100000}}}"#)
        XCTAssertNotNil(try Self.jsonObject(at: sevenDay.usageFile)["rate_limits"])
    }

    func testDebounceFloodDoesNotRewritePayloadButTouchesMTimeWhenClosedPayloadIsUnchanged() throws {
        let first = try runBridge(#"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"model":"sonnet"}"#)
        let original = try String(contentsOf: first.usageFile, encoding: .utf8)
        let oldMtime = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: oldMtime],
            ofItemAtPath: first.usageFile.path
        )

        let second = try runBridge(
            #"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"model":"sonnet"}"#,
            home: first.home
        )

        XCTAssertEqual(second.usageFile, first.usageFile)
        XCTAssertEqual(try String(contentsOf: second.usageFile, encoding: .utf8), original)
        let touchedMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: second.usageFile.path)[.modificationDate] as? Date
        )
        XCTAssertGreaterThan(touchedMtime, oldMtime)
    }

    func testSameRateLimitsRewriteWhenModelChanges() throws {
        let first = try runBridge(#"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"model":"sonnet"}"#)
        let original = try String(contentsOf: first.usageFile, encoding: .utf8)
        let oldMtime = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: oldMtime],
            ofItemAtPath: first.usageFile.path
        )

        let second = try runBridge(
            #"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"model":"opus"}"#,
            home: first.home
        )

        XCTAssertEqual(second.usageFile, first.usageFile)
        let rewritten = try String(contentsOf: second.usageFile, encoding: .utf8)
        XCTAssertNotEqual(rewritten, original)
        let json = try Self.jsonObject(at: second.usageFile)
        XCTAssertEqual(json["model"] as? String, "opus")
    }

    func testBridgeDoesNotRequireJQOnPath() throws {
        let result = try runBridge(
            #"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}},"model":"sonnet"}"#,
            path: "/bin:/usr/bin:/usr/sbin:/sbin"
        )

        XCTAssertEqual(result.stdout, " \n")
        XCTAssertEqual(result.stderr, "")
        let json = try Self.jsonObject(at: result.usageFile)
        XCTAssertNotNil(json["rate_limits"])
    }

    func testHookServerDownStillWritesFlatFileOnly() throws {
        let result = try runBridge(#"{"version":1,"rate_limits":{"seven_day":{"used_percent":40,"resets_at":100000}}}"#)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.usageFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.home.appendingPathComponent(".bough/hook-server.json").path))
    }

    func testUsageFileAndDirectoryAreUserPrivate() throws {
        let result = try runBridge(#"{"version":1,"rate_limits":{"five_hour":{"used_percent":12}}}"#)
        let directory = result.usageFile.deletingLastPathComponent()
        let fm = FileManager.default

        let directoryMode = try XCTUnwrap(fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(fm.attributesOfItem(atPath: result.usageFile.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testStatusLineWrapperPureBashFallbackKillsProcessGroup() throws {
        let template = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Bough/Resources/bough-statusline-wrapper.sh.template"),
            encoding: .utf8
        )

        XCTAssertTrue(template.contains("set -m"))
        XCTAssertTrue(template.contains(#"kill -TERM "-$prev_pid""#))
    }

    private struct BridgeRun {
        let home: URL
        let usageFile: URL
        let stdout: String
        let stderr: String
    }

    private func runBridge(
        _ input: String,
        home existingHome: URL? = nil,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) throws -> BridgeRun {
        let home: URL
        if let existingHome {
            home = existingHome
        } else {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("BoughStatuslineBridgeTests-\(UUID().uuidString)")
            temporaryHomes.append(home)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = Self.repoRoot
            .appendingPathComponent("Sources/Bough/Resources/bough-statusline-bridge.sh")
        process.environment = ["HOME": home.path, "PATH": path]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        return BridgeRun(
            home: home,
            usageFile: home.appendingPathComponent(".bough/claude-usage.json"),
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
}
