import XCTest
@testable import Bough
@testable import BoughCore

final class HookOwnershipTests: XCTestCase {
    private var previousProductLower: String { ["code", "island"].joined() }
    private var previousVibeNoDash: String { ["vibe", "notch"].joined() }
    private var previousVibeDash: String { ["vibe", "island"].joined(separator: "-") }
    private var previousVibeTitle: String { ["Vibe", "Island"].joined() }
    private var previousHookPath: String {
        "~/.\(previousProductLower)/\(previousProductLower)-hook.sh"
    }

    func testIsOurs_doesNotMatchPreviousProductStrings() {
        for s in [
            "\(previousProductLower)-bridge",
            "/tmp/\(previousProductLower)-501.sock",
            previousHookPath,
            "\(previousVibeNoDash)-helper",
            previousVibeDash,
            "\(previousVibeTitle)_v2",
            "\(previousProductLower)-managed-start",
        ] {
            XCTAssertFalse(
                ConfigInstaller.testHookIdIsOurs(s),
                "Bough predicate must NOT match '\(s)'"
            )
        }
    }

    func testIsOurs_matchesBoughStrings() {
        for s in [
            "bough-bridge",
            "/tmp/bough-501.sock",
            "~/.bough/bough-hook.sh",
            "bough-hook-v1-start",
            "bough-hook-v1-end",
            "BOUGH_HOOK_V1",
        ] {
            XCTAssertTrue(
                ConfigInstaller.testHookIdIsOurs(s),
                "Bough predicate must match '\(s)'"
            )
        }
    }

    func testInstall_writesBoughHookV1Marker_traecli() throws {
        let tempPath = NSTemporaryDirectory() + "bough-marker-traecli-\(UUID().uuidString)"
        try "".write(toFile: tempPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        guard let format = HookFormat(storageValue: "traecli") else {
            XCTFail("traecli format missing")
            return
        }
        let cli = ConfigInstaller.testMakeCLI(format: format, configPath: tempPath)
        try ConfigInstaller.testInstallHooksForCLI(cli)

        let after = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(after.contains("# bough-hook-v1-start"))
        XCTAssertTrue(after.contains("# bough-hook-v1-end"))
    }

    func testInstall_writesBoughHookV1Marker_kimi() throws {
        let tempPath = NSTemporaryDirectory() + "bough-marker-kimi-\(UUID().uuidString)"
        try "".write(toFile: tempPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        guard let format = HookFormat(storageValue: "kimi") else {
            XCTFail("kimi format missing")
            return
        }
        let cli = ConfigInstaller.testMakeCLI(format: format, configPath: tempPath)
        try ConfigInstaller.testInstallHooksForCLI(cli)

        let after = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(after.contains("# bough-hook-v1-start"))
        XCTAssertTrue(after.contains("# bough-hook-v1-end"))
    }

    func testSharedHookScriptCarriesBoughHookV1MarkerBlock() {
        let script = ConfigInstaller.testSharedHookScriptTemplate

        XCTAssertEqual(script.components(separatedBy: "# bough-hook-v1-start").count - 1, 1)
        XCTAssertEqual(script.components(separatedBy: "# bough-hook-v1-end").count - 1, 1)
        XCTAssertLessThan(
            script.range(of: "# bough-hook-v1-start")!.lowerBound,
            script.range(of: "# bough-hook-v1-end")!.lowerBound
        )
    }

    func uninstallLeavesPreviousProductUntouched(in fixture: String, formatStorageValue: String) throws {
        guard let format = HookFormat(storageValue: formatStorageValue) else {
            XCTFail("Test bug: \(formatStorageValue) is not a valid HookFormat storageValue.")
            return
        }
        let tempPath = NSTemporaryDirectory() + "bough-test-\(formatStorageValue)-\(UUID().uuidString)"
        try fixture.write(toFile: tempPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let cli = ConfigInstaller.testMakeCLI(format: format, configPath: tempPath)
        try ConfigInstaller.testUninstallHooksForCLI(cli)

        let after = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertEqual(after, fixture)
    }

    func testClaudeFormat_uninstallLeavesPreviousProductUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            {
              "hooks": {
                "PreToolUse": [
                  { "matcher": "*", "hooks": [
                      {"type": "command", "command": "\(previousHookPath)", "timeout": 5}
                  ]}
                ]
              }
            }
            """, formatStorageValue: "claude")
    }

    func testNestedFormat_uninstallLeavesPreviousProductUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            {
              "hooks": {
                "PreToolUse": [
                  { "hooks": [
                      {"type": "command", "command": "\(previousHookPath)", "timeout": 5}
                  ]}
                ]
              }
            }
            """, formatStorageValue: "nested")
    }

    func testFlatFormat_uninstallLeavesPreviousProductUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            { "hooks": { "PreToolUse": [ {"command": "\(previousHookPath)"} ] } }
            """, formatStorageValue: "flat")
    }

    func testTraecliFormat_uninstallLeavesPreviousProductManagedBlockUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            # \(previousProductLower)-managed-start
            hooks:
              - type: command
                command: \(previousHookPath)
                timeout: 5s
            # \(previousProductLower)-managed-end

            other:
              unrelated: value
            """, formatStorageValue: "traecli")
    }

    func testCopilotFormat_uninstallLeavesPreviousProductUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            { "version": 1, "hooks": { "PreToolUse": [
                {"type": "command", "bash": "\(previousHookPath)", "timeoutSec": 5}
            ] } }
            """, formatStorageValue: "copilot")
    }

    func testKimiFormat_uninstallLeavesPreviousProductTomlBlockUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            # \(previousProductLower)-managed-start
            [[hooks]]
            event = "PostTool"
            command = "\(previousHookPath)"
            # \(previousProductLower)-managed-end
            """, formatStorageValue: "kimi")
    }

    func testKiroAgentFormat_uninstallLeavesPreviousProductUntouched() throws {
        try uninstallLeavesPreviousProductUntouched(in: """
            { "hooks": { "afterToolUse": [
                {"command": "\(previousHookPath)", "timeout_ms": 5000}
            ] } }
            """, formatStorageValue: "kiroAgent")
    }

    func testOpencodePluginFilenamesAreDisjoint() {
        XCTAssertEqual(ConfigInstaller.testBoughOpencodePluginFilename, "bough-opencode.js")
        XCTAssertNotEqual(ConfigInstaller.testBoughOpencodePluginFilename, "\(previousProductLower)-opencode.js")
    }
}
