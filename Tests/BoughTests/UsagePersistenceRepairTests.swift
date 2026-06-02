// UsagePersistenceRepairTests.swift
// BoughTests
//
// PERSIST-04: Verifies that ConfigInstaller.verifyClaudeCodeStatusLinePathDrift()
// repairs a stale bundle-container path in a settings.json file.
//
// This test uses the #if DEBUG entry points on ConfigInstaller — those are the
// stable public test seam for the installer and are intentionally not guarded away
// in test builds. No real ~/.claude/settings.json is read or written; all I/O goes
// to a UUID-namespaced temp directory that is removed in tearDown.

import XCTest
@testable import Bough

final class UsagePersistenceRepairTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        super.tearDown()
    }

    /// Write a JSON string to tempDir/settings.json and return the path string.
    private func writeTempSettings(_ json: String) -> String {
        let url = tempDir.appendingPathComponent("settings.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - PERSIST-04

    /// verifyClaudeCodeStatusLinePathDrift must detect and repair a settings.json whose
    /// statusLine command ends with the stale bundle-container suffix
    /// "/Bough.app/Contents/Resources/bough-statusline-bridge.sh".
    func testVerifyAndRepairFixesStaleBundlePath() {
        // 1. Start with an empty settings.json.
        let settingsPath = writeTempSettings("{}")

        // Stale path: ends with the exact suffix that isOldBoughStatusLineBridgePath detects.
        // The predicate checks hasSuffix("/Bough.app/Contents/Resources/bough-statusline-bridge.sh"),
        // so the path must contain a slash-separated "Bough.app" component.
        let stalePath = "/tmp/Bough.app/Contents/Resources/bough-statusline-bridge.sh"
        // New path: lives outside any bundle container.
        let newPath = "/Users/testuser/.local/share/bough-statusline-bridge.sh"

        // 2. Install the stale command via the production installer path (replaceExisting: false
        //    since the settings.json starts empty — no prior entry to replace).
        ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: settingsPath,
            proposedBridgePath: stalePath
        )

        // 3. Confirm the stale path was written.
        let installedCommand = ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: settingsPath)
        XCTAssertNotNil(installedCommand, "PERSIST-04: testInstallClaudeCodeStatusLine should have written a command")
        XCTAssertTrue(
            installedCommand?.contains(".app/Contents/Resources/bough-statusline-bridge.sh") ?? false,
            "PERSIST-04: installed command should contain the stale bundle-container suffix"
        )

        // 4. Run the repair.
        let repaired = ConfigInstaller.testVerifyClaudeCodeStatusLinePathDrift(
            settingsPath: settingsPath,
            proposedBridgePath: newPath
        )
        XCTAssertTrue(repaired, "PERSIST-04: verifyClaudeCodeStatusLinePathDrift should return true when a stale path is repaired")

        // 5. Read the updated command.
        let repairedCommand = ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: settingsPath)

        // 6. Stale bundle-container path must be gone.
        XCTAssertFalse(
            repairedCommand?.contains(".app/Contents") ?? false,
            "PERSIST-04: stale bundle path must be repaired by verifyClaudeCodeStatusLinePathDrift"
        )

        // 7. New bridge script reference must be present.
        XCTAssertTrue(
            repairedCommand?.contains("bough-statusline-bridge.sh") ?? false,
            "PERSIST-04: repaired command must reference the new proposed bridge path"
        )
    }
}
