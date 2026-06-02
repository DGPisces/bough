import XCTest
@testable import Bough

/// Tests for `evaluateClaudeCodeStatusLineConnectivity`. The data-source row's
/// "Connected" indicator now reflects
/// whether Bough's statusLine pipeline is installed and has produced a
/// parseable `~/.bough/claude-usage.json` payload.
@MainActor
final class ClaudeCodeStatusLineConnectivityTests: XCTestCase {

    private var tempDir: URL!
    private var path: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bough-statusline-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        path = tempDir.appendingPathComponent("claude-usage.json").path
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeFile(_ contents: String, mtime: Date? = nil) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: path
            )
        }
    }

    // MARK: - .absent

    func testMissingFileIsAbsent() {
        // Pre-condition: setUp never wrote the file.
        let result = evaluateClaudeCodeStatusLineConnectivity(path: path, statusLineInstalled: true)
        XCTAssertEqual(result.state, .absent)
        XCTAssertFalse(result.fileExists)
    }

    func testNotInstalledIsAbsentEvenWithFreshFile() throws {
        // Regression guard: if Bough's statusLine command is not
        // installed in settings.json, the data-source row must show .absent
        // regardless of any leftover ~/.bough/claude-usage.json. This is
        // what causes the "Connected stays lit after uninstall" UX bug —
        // freshness window kept the green dot lit during the 10-minute
        // freshness budget. The fix collapses to .absent before checking
        // the file when statusLineInstalled is false.
        try writeFile(
            #"{"rate_limits": {"five_hour": {"used_percentage": 42}}}"#,
            mtime: Date()
        )
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600,
            now: Date(),
            statusLineInstalled: false
        )
        XCTAssertEqual(result.state, .absent)
        XCTAssertFalse(result.fileExists)
    }

    // MARK: - .warning (parse failure / unrecognized shape)

    func testNonJSONIsWarning() throws {
        try writeFile("this is not json")
        let result = evaluateClaudeCodeStatusLineConnectivity(path: path, statusLineInstalled: true)
        XCTAssertEqual(result.state, .warning)
        XCTAssertTrue(result.fileExists)
        XCTAssertFalse(result.payloadValid)
    }

    func testMissingRateLimitsIsWarning() throws {
        try writeFile(#"{"version": 1, "model": "claude-sonnet-4"}"#)
        let result = evaluateClaudeCodeStatusLineConnectivity(path: path, statusLineInstalled: true)
        XCTAssertEqual(result.state, .warning)
    }

    func testRateLimitsWithoutUsedPercentageIsWarning() throws {
        try writeFile(#"{"rate_limits": {"five_hour": {"resets_at": "2026-01-01T00:00:00Z"}}}"#)
        let result = evaluateClaudeCodeStatusLineConnectivity(path: path, statusLineInstalled: true)
        XCTAssertEqual(result.state, .warning)
        XCTAssertFalse(result.payloadValid)
    }

    func testStalePayloadStillConnectedWhenReadable() throws {
        let oldMtime = Date(timeIntervalSinceNow: -3600) // 1h old
        try writeFile(#"{"rate_limits": {"five_hour": {"used_percentage": 12.5}}}"#, mtime: oldMtime)
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600, // 10 minutes
            now: Date()
        , statusLineInstalled: true)
        XCTAssertEqual(result.state, .connected, "Idle Claude Code sessions must not read as disconnected just because the last payload is stale.")
        XCTAssertTrue(result.payloadValid)
        XCTAssertEqual(result.isFresh, false)
    }

    // MARK: - .connected

    func testFiveHourUsedPercentageIsConnected() throws {
        try writeFile(
            #"{"rate_limits": {"five_hour": {"used_percentage": 42}}}"#,
            mtime: Date()
        )
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600,
            now: Date()
        , statusLineInstalled: true)
        XCTAssertEqual(result.state, .connected)
        XCTAssertTrue(result.payloadValid)
        XCTAssertEqual(result.isFresh, true)
    }

    func testSevenDayUsedPercentageIsConnected() throws {
        // Real Anthropic payloads sometimes carry seven_day without five_hour;
        // either window is sufficient to count as "data flowing".
        try writeFile(
            #"{"rate_limits": {"seven_day": {"used_percentage": 8.4}}}"#,
            mtime: Date()
        )
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600,
            now: Date()
        , statusLineInstalled: true)
        XCTAssertEqual(result.state, .connected)
    }

    func testCamelCaseKeysAlsoCount() throws {
        // Defensive parsing matches UsageModels.parse which accepts camelCase
        // variants. The connectivity probe shouldn't reject a payload that
        // would otherwise parse successfully downstream.
        try writeFile(
            #"{"rate_limits": {"fiveHour": {"usedPercentage": 5}}}"#,
            mtime: Date()
        )
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600,
            now: Date()
        , statusLineInstalled: true)
        XCTAssertEqual(result.state, .connected)
    }

    func testFreshnessBoundary() throws {
        // mtime exactly at window edge counts as fresh (<=, not <).
        let now = Date()
        let edgeMtime = now.addingTimeInterval(-600)
        try writeFile(
            #"{"rate_limits": {"five_hour": {"used_percentage": 50}}}"#,
            mtime: edgeMtime
        )
        let result = evaluateClaudeCodeStatusLineConnectivity(
            path: path,
            freshnessWindow: 600,
            now: now
        , statusLineInstalled: true)
        XCTAssertEqual(result.state, .connected, "mtime at exactly freshnessWindow seconds old must still count as fresh")
    }
}
