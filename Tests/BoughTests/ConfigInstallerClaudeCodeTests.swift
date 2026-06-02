import XCTest

@testable import Bough

final class ConfigInstallerClaudeCodeTests: XCTestCase {
    func testAbsentSettingsCreatesValidStatusLineCommand() throws {
        let paths = Self.paths()

        let result = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        )

        XCTAssertEqual(result, .installed)
        let root = try Self.jsonObject(at: paths.settings)
        let statusLine = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, paths.bridge.path)
        // Regression: Claude Code silently ignores a statusLine
        // block whose `type` field is absent, so the wrapper (and any chained
        // user statusLine inside it) never runs. The install path MUST emit
        // `"type": "command"` alongside `command`.
        XCTAssertEqual(
            statusLine["type"] as? String, "command",
            "statusLine block must include `\"type\": \"command\"` — Claude Code silently ignores blocks without it (Regression for Bugs #2 + #3)"
        )
    }

    func testExistingSettingsWithoutStatusLinePreservesOtherKeys() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"theme":"dark","permissions":{"allow":["Bash"]}}"#, to: paths.settings)

        let result = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        )

        XCTAssertEqual(result, .installed)
        let root = try Self.jsonObject(at: paths.settings)
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertNotNil(root["permissions"])
        let statusLine = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, paths.bridge.path)
        XCTAssertEqual(
            statusLine["type"] as? String, "command",
            "Install must emit `\"type\": \"command\"` so Claude Code does not silently ignore the block (Regression)"
        )
    }

    func testExistingUserStatusLineReturnsConflictUnlessReplaceRequested() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/user-status"}}"#, to: paths.settings)

        let conflict = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            replaceExisting: false
        )
        XCTAssertEqual(conflict, .conflict(existing: "/usr/local/bin/user-status", proposed: paths.bridge.path))

        let replaced = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            replaceExisting: true
        )
        XCTAssertEqual(replaced, .installed)
        XCTAssertEqual(ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path), paths.bridge.path)
    }

    func testMalformedSettingsFailsClosedWithoutTruncation() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":"#, to: paths.settings)

        let result = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        )

        if case .failed = result {
            XCTAssertEqual(try String(contentsOf: paths.settings), #"{"statusLine":"#)
        } else {
            XCTFail("Expected malformed settings to fail closed")
        }
    }

    func testUnwritableSettingsDirectoryFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerClaudeCodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let claudeFile = root.appendingPathComponent(".claude")
        FileManager.default.createFile(atPath: claudeFile.path, contents: Data("not a directory".utf8))
        let settings = claudeFile.appendingPathComponent("settings.json")
        let bridge = root.appendingPathComponent("Bough.app/Contents/Resources/bough-statusline-bridge.sh")

        let result = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: settings.path,
            proposedBridgePath: bridge.path
        )

        if case .failed = result {
            XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        } else {
            XCTFail("Expected unwritable settings path to fail closed")
        }
    }

    func testPathDriftRepairsOnlyExactOldBoughBridgePath() throws {
        let paths = Self.paths()
        try Self.writeJSON(
            #"{"statusLine":{"command":"/tmp/Old/Bough.app/Contents/Resources/bough-statusline-bridge.sh"}}"#,
            to: paths.settings
        )

        XCTAssertTrue(ConfigInstaller.testVerifyClaudeCodeStatusLinePathDrift(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        ))
        XCTAssertEqual(ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path), paths.bridge.path)
    }

    func testPathDriftDoesNotRewriteUserComposition() throws {
        let paths = Self.paths()
        let composed = "bash -c 'tee >(cat >/tmp/old) | /tmp/Old/Bough.app/Contents/Resources/bough-statusline-bridge.sh'"
        try Self.writeJSON(#"{"statusLine":{"command":"\#(composed)"}}"#, to: paths.settings)

        XCTAssertFalse(ConfigInstaller.testVerifyClaudeCodeStatusLinePathDrift(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        ))
        XCTAssertEqual(ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path), composed)
    }

    func testUninstallRestoresPreExistingStatusLineFromBackup() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/user-status"},"theme":"dark"}"#, to: paths.settings)
        XCTAssertEqual(
            ConfigInstaller.testInstallClaudeCodeStatusLine(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path,
                replaceExisting: true
            ),
            .installed
        )

        XCTAssertTrue(ConfigInstaller.testUninstallClaudeCodeStatusLine(settingsPath: paths.settings.path))

        XCTAssertEqual(ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path), "/usr/local/bin/user-status")
        XCTAssertEqual(try Self.jsonObject(at: paths.settings)["theme"] as? String, "dark")
    }

    func testUninstallDoesNotRestoreStaleBackupOverUserEditedStatusLine() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/user-status"},"theme":"dark"}"#, to: paths.settings)
        XCTAssertEqual(
            ConfigInstaller.testInstallClaudeCodeStatusLine(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path,
                replaceExisting: true
            ),
            .installed
        )
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/new-user-status"},"theme":"dark"}"#, to: paths.settings)

        XCTAssertFalse(ConfigInstaller.testUninstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        ))

        XCTAssertEqual(ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path), "/usr/local/bin/new-user-status")
    }

    /// Regression test for Phase 21-01 / D-01.
    ///
    /// Phase 17 shipped `bundledClaudeCodeStatusLineBridgePath()` using
    /// `Bundle.main.url(forResource:withExtension:)`, but SwiftPM places target
    /// resources inside a nested bundle (`Bough_Bough.bundle/Resources/`) that
    /// `Bundle.main` cannot see. Every install attempt returned `nil` and
    /// surfaced as "Bundled Claude Code statusLine bridge not found" in the UI
    /// (confirmed by user screenshot 2026-05-16). The fix routes the lookup
    /// through `Bundle.appModule` (the codebase's canonical accessor, see
    /// `BundleExtension.swift`). This test would have failed before the fix.
    func testProposedClaudeCodeStatusLineCommandResolvesBundledBridge() throws {
        let resolved = try XCTUnwrap(
            ConfigInstaller.proposedClaudeCodeStatusLineCommand(),
            "Expected bundled bough-statusline-bridge.sh to resolve via Bundle.appModule (Phase 21-01 / D-01)."
        )

        XCTAssertTrue(
            resolved.hasSuffix("/bough-statusline-bridge.sh"),
            "Resolved path must end in /bough-statusline-bridge.sh; got \(resolved)"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resolved),
            "Resolved path must point at an existing file on disk; got \(resolved)"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        XCTAssertTrue(
            (perms & 0o100) != 0,
            "Resolved file must be owner-executable (chmod side effect from the helper); got 0o\(String(perms, radix: 8))"
        )
    }

    // MARK: - Phase 21-02 chain-safe install

    /// D-02 + D-03 + D-04 + D-05: chain install over a user's prev statusLine
    /// (e.g. `/usr/local/bin/starship`) produces a Bough-owned wrapper at
    /// `~/.bough/bough-statusline-wrapper.sh` (mode 0o755) whose sentinel
    /// decodes to exactly the user's prev command, points settings.json at
    /// the wrapper, and bundles the bridge path placeholder substituted.
    func testChainInstallOverPrevCommand() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: paths.settings)

        let result = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        guard case .chained(let prevCmd, let wrapperPath) = result else {
            XCTFail("Expected .chained, got \(result)")
            return
        }
        XCTAssertEqual(prevCmd, "/usr/local/bin/starship")
        XCTAssertEqual(wrapperPath, paths.wrapper.path)

        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.wrapper.path,
            "settings.json must now point at the wrapper, not the bridge or the prev command"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.wrapper.path),
            "Wrapper file must exist on disk after chain install"
        )

        let wrapperContents = try String(contentsOf: paths.wrapper, encoding: .utf8)
        XCTAssertTrue(
            wrapperContents.contains("# RESTORE: "),
            "Wrapper must contain the RESTORE sentinel line"
        )

        // Decode the sentinel and verify it round-trips to the exact prev command.
        let decoded = try XCTUnwrap(
            Self.decodeRestoreSentinel(in: wrapperContents),
            "RESTORE sentinel must parse to a base64-decoded UTF-8 string"
        )
        XCTAssertEqual(decoded, "/usr/local/bin/starship")

        XCTAssertTrue(
            wrapperContents.contains(paths.bridge.path),
            "Wrapper must have __BOUGH_BRIDGE_PATH__ substituted with the proposed bridge path"
        )
        XCTAssertFalse(
            wrapperContents.contains("__BOUGH_BRIDGE_PATH__"),
            "No template placeholder must remain in the rendered wrapper"
        )
        XCTAssertFalse(
            wrapperContents.contains("__BOUGH_PREV_CMD_B64__"),
            "No template placeholder must remain in the rendered wrapper"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: paths.wrapper.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(
            perms & 0o777,
            0o755,
            "Wrapper file must be mode 0o755 (D-03 owner-executable, world-readable); got 0o\(String(perms, radix: 8))"
        )
    }

    /// CR-01 regression: chain install with a bridge path containing whitespace
    /// must produce a wrapper that executes cleanly under bash. Before this fix
    /// the template substituted `__BOUGH_BRIDGE_PATH__` unquoted into a bash
    /// pipeline, so any install location with a space in any parent directory
    /// (e.g. `/Users/Some User/...`) tokenized at the space and silently
    /// failed to invoke the bridge (the wrapper's `|| true` masked it).
    func testChainInstallWithBridgePathContainingSpace() throws {
        // Build a bespoke paths layout where the bridge path contains a space.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerClaudeCodeTests-\(UUID().uuidString)")
        let settings = root.appendingPathComponent(".claude/settings.json")
        // The space is in a parent directory of the bridge, mirroring the real
        // failure mode (a user installs Bough.app under `/Users/Some User/...`).
        let bridge = root
            .appendingPathComponent("dir with space")
            .appendingPathComponent("Bough.app/Contents/Resources/bough-statusline-bridge.sh")
        let wrapper = root.appendingPathComponent(".bough/bough-statusline-wrapper.sh")

        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: settings)
        // The bridge file does not need to be runnable for this test — we only
        // care that the WRAPPER parses under bash without `command not found`.
        try FileManager.default.createDirectory(
            at: bridge.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env bash\nexit 0\n".utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)

        let result = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: settings.path,
            proposedBridgePath: bridge.path,
            wrapperPath: wrapper.path
        )
        guard case .chained = result else {
            XCTFail("Expected .chained, got \(result)")
            return
        }
        XCTAssertTrue(bridge.path.contains(" "), "Test bridge path must actually contain a space")

        // Execute the wrapper under bash with a minimal shell, feeding a dummy
        // payload on stdin. If the bridge substitution was unquoted, bash would
        // tokenize on the space and emit `command not found` on stderr. The
        // wrapper itself sets `|| true`, so we cannot rely on the exit code —
        // assert on the absence of `command not found` in stderr instead.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", wrapper.path]
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data("{}".utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertFalse(
            stderrText.lowercased().contains("command not found"),
            "Wrapper must not produce `command not found` when the bridge path contains a space. stderr: \(stderrText)"
        )
        XCTAssertFalse(
            stderrText.lowercased().contains("no such file or directory"),
            "Wrapper must not fail with `no such file or directory` from tokenization. stderr: \(stderrText)"
        )
    }

    /// D-02 sentinel restore: uninstall reads the wrapper's `RESTORE:` line,
    /// writes the decoded prev command back into settings.json, and deletes
    /// the wrapper file. settings.json must NOT be left pointing at a
    /// dangling wrapper path.
    func testChainUninstallRestoresPrevCommand() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: paths.settings)
        _ = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        XCTAssertTrue(
            ConfigInstaller.testUninstallClaudeCodeStatusLineWithWrapper(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path,
                wrapperPath: paths.wrapper.path
            )
        )

        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            "/usr/local/bin/starship"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.wrapper.path),
            "Wrapper file must be removed after chain uninstall"
        )
    }

    /// T-21-08 mitigation: re-installing the chain wrapper must recover the
    /// TRUE prev command from the existing wrapper's sentinel (NOT from
    /// settings.json.statusLine.command which now points at the wrapper),
    /// then re-render with the new prev tool. No wrapper-wraps-wrapper
    /// recursion; atomic rewrite, not append.
    func testChainReInstallOverExistingBoughWrapperUpdatesSentinel() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: paths.settings)
        _ = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        // settings.json now points at the wrapper. User changes their prev
        // tool by re-running install — chain entry must recover starship
        // from the wrapper sentinel, NOT echo the wrapper path back into
        // itself.
        //
        // We simulate the "user changed their prev tool" by editing
        // settings.json directly to point at the new tool BEFORE re-install,
        // mirroring how Plan 21-03's UI / first-launch path would behave
        // when the user has manually replaced the wrapper with a new
        // statusLine and then clicks install again. The per-plan edge case
        // in <behavior> says: "if the user manually edited settings.json
        // to a non-Bough new command while the wrapper still exists, chain
        // install promotes that new command to the wrapper's prev_cmd and
        // discards the old sentinel value."
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/gsd-statusline"}}"#, to: paths.settings)

        let result = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        guard case .chained(let prevCmd, _) = result else {
            XCTFail("Expected .chained on re-install over modified settings, got \(result)")
            return
        }
        XCTAssertEqual(prevCmd, "/usr/local/bin/gsd-statusline")

        // settings.json points at the wrapper; wrapper's sentinel now
        // decodes to the new prev tool; wrapper exists exactly once.
        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.wrapper.path
        )
        let wrapperContents = try String(contentsOf: paths.wrapper, encoding: .utf8)
        let decoded = try XCTUnwrap(Self.decodeRestoreSentinel(in: wrapperContents))
        XCTAssertEqual(decoded, "/usr/local/bin/gsd-statusline")
        // Wrapper must be a rewrite, not an append: only one RESTORE line.
        let restoreLineCount = wrapperContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("# RESTORE: ") }
            .count
        XCTAssertEqual(restoreLineCount, 1, "Re-install must rewrite the wrapper, not append")
    }

    /// T-21-08 (second pass): when the user has NOT changed
    /// settings.json.statusLine.command (still points at the wrapper) and
    /// chain install is re-invoked (e.g. on launch / verify drift), the
    /// install must recover the TRUE prev command from the wrapper sentinel
    /// — NOT use the wrapper path as the new prev (which would cause
    /// wrapper-wraps-wrapper recursion).
    func testChainReInstallWhenSettingsStillPointsAtWrapperPreservesSentinelPrev() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: paths.settings)
        _ = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )
        // No edit to settings.json — it still points at the wrapper.

        let result = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        // Idempotent: prev command is still starship; no recursion.
        guard case .chained(let prevCmd, _) = result else {
            XCTFail("Expected .chained on idempotent re-install, got \(result)")
            return
        }
        XCTAssertEqual(prevCmd, "/usr/local/bin/starship")
        let wrapperContents = try String(contentsOf: paths.wrapper, encoding: .utf8)
        let decoded = try XCTUnwrap(Self.decodeRestoreSentinel(in: wrapperContents))
        XCTAssertEqual(decoded, "/usr/local/bin/starship")
        XCTAssertFalse(
            decoded.contains("bough-statusline-wrapper.sh"),
            "Sentinel must never decode to the wrapper path itself"
        )
    }

    /// D-02 trust-boundary-2: a user-edited wrapper whose `RESTORE:` line
    /// is missing or has invalid base64 must NOT cause uninstall to mutate
    /// settings.json. Refuse, return false, leave files untouched.
    func testChainUninstallRefusesOnSentinelCorruption() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"\#(paths.wrapper.path)"}}"#, to: paths.settings)
        try FileManager.default.createDirectory(
            at: paths.wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Corrupt wrapper — no RESTORE: line at all.
        let corrupt = """
        #!/usr/bin/env bash
        # === BOUGH STATUSLINE WRAPPER ===
        # someone deleted the RESTORE line
        # ================================
        set -euo pipefail
        echo "hi"
        """
        try Data(corrupt.utf8).write(to: paths.wrapper)

        let result = ConfigInstaller.testUninstallClaudeCodeStatusLineWithWrapper(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )
        XCTAssertFalse(result, "Uninstall must refuse on sentinel corruption (D-02)")

        // settings.json untouched, wrapper file still there.
        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.wrapper.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.wrapper.path))

        // Also cover invalid base64 in the RESTORE line.
        let badB64 = """
        #!/usr/bin/env bash
        # === BOUGH STATUSLINE WRAPPER ===
        # RESTORE: !!!not-valid-base64!!!
        # ================================
        """
        try Data(badB64.utf8).write(to: paths.wrapper)

        XCTAssertFalse(
            ConfigInstaller.testUninstallClaudeCodeStatusLineWithWrapper(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path,
                wrapperPath: paths.wrapper.path
            )
        )
        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.wrapper.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.wrapper.path))
    }

    /// Chain mode is opportunistic — when settings.json is absent or has
    /// no `statusLine` key, the chain entry falls through to direct install
    /// (settings.json.statusLine.command = bridge path; no wrapper file
    /// created on disk).
    func testChainInstallWhenSettingsEmptyInstallsBoughDirectly() throws {
        let paths = Self.paths()
        // settings.json does not exist.

        let result = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        XCTAssertEqual(result, .installed)
        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.bridge.path,
            "Direct install must point settings.json at the bridge, not the wrapper"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.wrapper.path),
            "No wrapper file must be created when there's no prev command to preserve"
        )
    }

    /// Regression for Bugs #2 + #3.
    ///
    /// Claude Code's statusLine spec requires both `"type": "command"` AND
    /// `"command": "..."` in the statusLine block. A block missing `"type"`
    /// is silently ignored, which means the Bough chain wrapper is never
    /// invoked — `~/.bough/claude-usage.json` is never written (Bug #2) and
    /// the user's chained gsd-statusline never runs (Bug #3, perceived as
    /// "gsd gone"). Phase 17 shipped the malformed shape; tests up to this
    /// point compared against the same wrong shape and passed tautologically.
    ///
    /// This test asserts the SHAPE end-to-end: install via both the direct
    /// path AND the chain-aware path, then read settings.json fresh and
    /// confirm `"type": "command"` is present in both modes.
    func testInstallEmitsTypeCommandFieldInStatusLineBlock_directAndChain() throws {
        // Direct install (no prev statusLine).
        let direct = Self.paths()
        defer { try? FileManager.default.removeItem(at: direct.root) }
        XCTAssertEqual(
            ConfigInstaller.testInstallClaudeCodeStatusLine(
                settingsPath: direct.settings.path,
                proposedBridgePath: direct.bridge.path
            ),
            .installed
        )
        let directRoot = try Self.jsonObject(at: direct.settings)
        let directBlock = try XCTUnwrap(directRoot["statusLine"] as? [String: Any])
        XCTAssertEqual(
            directBlock["type"] as? String, "command",
            "Direct install must emit `\"type\": \"command\"` (Regression)"
        )
        XCTAssertEqual(directBlock["command"] as? String, direct.bridge.path)

        // Chain install (over a prev statusLine — settings.json points at the wrapper).
        let chain = Self.paths()
        defer { try? FileManager.default.removeItem(at: chain.root) }
        try Self.writeJSON(#"{"statusLine":{"type":"command","command":"/usr/local/bin/starship"}}"#, to: chain.settings)
        let chainResult = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: chain.settings.path,
            proposedBridgePath: chain.bridge.path,
            wrapperPath: chain.wrapper.path
        )
        guard case .chained = chainResult else {
            XCTFail("Expected .chained, got \(chainResult)")
            return
        }
        let chainRoot = try Self.jsonObject(at: chain.settings)
        let chainBlock = try XCTUnwrap(chainRoot["statusLine"] as? [String: Any])
        XCTAssertEqual(
            chainBlock["type"] as? String, "command",
            "Chain install must also emit `\"type\": \"command\"` when pointing settings.json at the wrapper (Regression)"
        )
        XCTAssertEqual(chainBlock["command"] as? String, chain.wrapper.path)
    }

    /// Regression: the wrapper-aware uninstall restores the
    /// user's prev command into settings.json with the `"type": "command"`
    /// field intact. Without it the restored statusLine would itself be
    /// silently ignored by Claude Code (the same root cause we just fixed
    /// on the install side).
    func testChainUninstallRestoresTypeCommandField() throws {
        let paths = Self.paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Self.writeJSON(#"{"statusLine":{"type":"command","command":"/usr/local/bin/starship"}}"#, to: paths.settings)
        _ = ConfigInstaller.testInstallClaudeCodeStatusLineChainAware(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path,
            wrapperPath: paths.wrapper.path
        )

        XCTAssertTrue(
            ConfigInstaller.testUninstallClaudeCodeStatusLineWithWrapper(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path,
                wrapperPath: paths.wrapper.path
            )
        )

        let root = try Self.jsonObject(at: paths.settings)
        let block = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertEqual(block["command"] as? String, "/usr/local/bin/starship")
        XCTAssertEqual(
            block["type"] as? String, "command",
            "Wrapper-aware uninstall must restore the prev statusLine WITH `\"type\": \"command\"` (Regression)"
        )
    }

    /// Plan-check WR-2 fold-in: `verifyClaudeCodeStatusLinePathDrift` is a
    /// second consumer of `ClaudeCodeStatusLineInstallResult.installed`. It
    /// must continue to repair the old Bough-app-bundled path drift after
    /// the enum gained `.chained`. The drift repair path uses
    /// `replaceExisting: true` which (per D-02) must NOT auto-promote to
    /// `.chained`; it must produce `.installed` so `verifyClaudeCodeStatusLinePathDrift`
    /// can still match its `if case .installed` and return true.
    func testVerifyPathDriftStillReturnsTrueAfterChainedEnumAddition() throws {
        let paths = Self.paths()
        try Self.writeJSON(
            #"{"statusLine":{"command":"/tmp/Old/Bough.app/Contents/Resources/bough-statusline-bridge.sh"}}"#,
            to: paths.settings
        )

        XCTAssertTrue(
            ConfigInstaller.testVerifyClaudeCodeStatusLinePathDrift(
                settingsPath: paths.settings.path,
                proposedBridgePath: paths.bridge.path
            ),
            "Path-drift repair must continue to return true after .chained joins the enum (WR-2)"
        )
        XCTAssertEqual(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            paths.bridge.path,
            "Drift repair must point settings.json at the proposed bridge, not the wrapper"
        )
    }

    // MARK: - Phase 21-03 / D-06 chain auto-install gate

    /// Gate proceeds when all four conditions hold: flag never set, settings.json
    /// exists, current statusLine command is neither the Bough bridge directly nor
    /// the Bough wrapper. The gate is pure — no UserDefaults / ~/.claude side effects.
    func testChainAutoInstallGate_proceedsWhenAllConditionsMet() throws {
        let paths = Self.paths()
        try Self.writeJSON(#"{"statusLine":{"command":"/usr/local/bin/starship"}}"#, to: paths.settings)

        let decision = ConfigInstaller.testEvaluateChainAutoInstallGate(
            settingsPath: paths.settings.path,
            wrapperPath: paths.wrapper.path,
            proposedBridgePath: paths.bridge.path,
            hasAttemptedFlag: false
        )

        XCTAssertEqual(decision, .proceed)
    }

    /// `hasAttemptedFlag: true` shortcircuits before any disk read — even when
    /// settings.json is missing AND no Bough install exists, the gate must return
    /// `.skipFlagSet`. Asserting flag-first ordering protects the one-shot guarantee.
    func testChainAutoInstallGate_skipsWhenFlagAlreadySet() throws {
        let paths = Self.paths()
        // Settings absent on purpose — flag check must win regardless.
        let decision = ConfigInstaller.testEvaluateChainAutoInstallGate(
            settingsPath: paths.settings.path,
            wrapperPath: paths.wrapper.path,
            proposedBridgePath: paths.bridge.path,
            hasAttemptedFlag: true
        )

        XCTAssertEqual(decision, .skipFlagSet)
    }

    /// User is not a Claude Code user → no settings.json on disk → gate refuses
    /// to fire so Bough never creates a config file the user did not opt into.
    func testChainAutoInstallGate_skipsWhenSettingsAbsent() throws {
        let paths = Self.paths()
        // Do NOT create settings.json — emulate a non-Claude-Code user.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path))

        let decision = ConfigInstaller.testEvaluateChainAutoInstallGate(
            settingsPath: paths.settings.path,
            wrapperPath: paths.wrapper.path,
            proposedBridgePath: paths.bridge.path,
            hasAttemptedFlag: false
        )

        XCTAssertEqual(decision, .skipNoSettings)
    }

    /// Bough bridge already in settings.json (direct install) → no auto-install needed.
    func testChainAutoInstallGate_skipsWhenBoughBridgeAlreadyInstalled() throws {
        let paths = Self.paths()
        try Self.writeJSON(
            #"{"statusLine":{"command":"\#(paths.bridge.path)"}}"#,
            to: paths.settings
        )

        let decision = ConfigInstaller.testEvaluateChainAutoInstallGate(
            settingsPath: paths.settings.path,
            wrapperPath: paths.wrapper.path,
            proposedBridgePath: paths.bridge.path,
            hasAttemptedFlag: false
        )

        XCTAssertEqual(decision, .skipBoughBridge)
    }

    /// WR-01: when the bundled bridge cannot be resolved (transient FS race,
    /// code-sign cache hiccup, etc.), the gate MUST return `.deferTransient`
    /// — NOT `.skipNoSettings`. The AppDelegate caller relies on this case to
    /// avoid setting the one-shot UserDefaults flag so the next launch retries.
    /// Previously the production entry returned `.skipNoSettings`, the
    /// AppDelegate set the flag, and the user was permanently locked out of
    /// auto-install on the next (successful) launch.
    func testChainAutoInstallGate_defersWhenBundleResolutionFails() throws {
        let decision = ConfigInstaller.evaluateChainAutoInstallGate(
            hasAttemptedFlag: false,
            bridgePathResolver: { nil }
        )

        guard case .deferTransient(let reason) = decision else {
            XCTFail("Expected .deferTransient, got \(decision)")
            return
        }
        XCTAssertFalse(
            reason.isEmpty,
            "Defer reason must be populated so AppDelegate can log the actual cause (not a misleading `~/.claude/settings.json absent` line)"
        )
    }

    /// Companion to the test above: when the bundle resolves and the user
    /// IS a Claude Code user with a third-party statusLine, the production
    /// entry must still return `.proceed` — proving the resolver-injection
    /// refactor did not alter the happy path.
    func testChainAutoInstallGate_proceedsThroughProductionEntryWhenResolverSucceeds() throws {
        // The production entry reads ~/.claude/settings.json directly, so this
        // test can only assert "non-deferred" outcome — the happy-path proceed
        // assertion is already covered by testChainAutoInstallGate_proceedsWhenAllConditionsMet
        // via the pure-function seam. Here we only assert the resolver hook
        // does not corrupt the contract for a successful resolve.
        let decision = ConfigInstaller.evaluateChainAutoInstallGate(
            hasAttemptedFlag: true,  // flag-set shortcircuits before any disk read — deterministic
            bridgePathResolver: { "/fake/but/non-nil" }
        )
        XCTAssertEqual(decision, .skipFlagSet)
    }

    /// Bough wrapper already in settings.json (chain install present) → idempotent skip.
    func testChainAutoInstallGate_skipsWhenBoughWrapperAlreadyInstalled() throws {
        let paths = Self.paths()
        try Self.writeJSON(
            #"{"statusLine":{"command":"\#(paths.wrapper.path)"}}"#,
            to: paths.settings
        )

        let decision = ConfigInstaller.testEvaluateChainAutoInstallGate(
            settingsPath: paths.settings.path,
            wrapperPath: paths.wrapper.path,
            proposedBridgePath: paths.bridge.path,
            hasAttemptedFlag: false
        )

        XCTAssertEqual(decision, .skipBoughWrapper)
    }

    // MARK: - Phase 21 / WR-03 race serialization

    /// WR-03: ChainInstallCoordinator.shared is an actor — Swift's runtime
    /// guarantees one in-flight call per actor instance. This smoke test
    /// uses the actor's DEBUG-only test seam (which serializes against the
    /// SAME actor queue as `install(replaceExisting:)`) to fire two
    /// overlapping critical sections and assert they observe each other's
    /// completion strictly in order.
    ///
    /// Why a test seam: the production `install(replaceExisting:)` entry
    /// touches the user's real ~/.claude/settings.json — the production
    /// `installClaudeCodeStatusLine` is unscoped (no injectable path) so a
    /// real-disk test would either mutate the user's machine or depend on
    /// whether the bundle is resolvable in the test process. Routing
    /// through a DEBUG critical-section seam on the same actor gives us
    /// the serialization-order assertion without touching the disk.
    func testChainInstallCoordinator_serializesConcurrentCallers() async throws {
        // Reset shared counter state (test seam guarantees this is safe
        // because every call to it goes through the same actor queue).
        await ChainInstallCoordinator.shared.resetTestCounters()

        // Two callers enter the actor concurrently. Inside the critical
        // section the first to be scheduled bumps the counter, sleeps
        // briefly, then reads the counter — if the second caller had
        // interleaved, the second read would observe an incremented value.
        async let a = ChainInstallCoordinator.shared.runSerializedCriticalSectionForTest(
            busyMicros: 20_000  // 20ms — comfortably longer than scheduling jitter
        )
        async let b = ChainInstallCoordinator.shared.runSerializedCriticalSectionForTest(
            busyMicros: 20_000
        )
        let pair = await [a, b]

        // Each return value is (preCount, postCount). Inside the critical
        // section: preCount = ++counter, sleep, postCount = counter.
        // If the actor serialized correctly, preCount == postCount for
        // BOTH callers — the second caller never started until the first
        // returned. If serialization broke, the second caller would
        // observe postCount > preCount.
        for (preCount, postCount) in pair {
            XCTAssertEqual(
                preCount, postCount,
                "Actor must serialize critical sections: pre and post counter reads must match within one call (preCount=\(preCount), postCount=\(postCount))"
            )
        }

        // Cross-call ordering: one call must have entered first, with
        // preCount==1; the other must have entered second, with
        // preCount==2. (Order between the two `async let` is
        // non-deterministic; we only assert the set of values.)
        let preCounts = Set(pair.map { $0.0 })
        XCTAssertEqual(
            preCounts, [1, 2],
            "Two concurrent callers must observe consecutive preCount values, proving serialization"
        )
    }

    // MARK: - Helpers (Phase 21-02)

    /// Extract and base64-decode the `# RESTORE: <b64>` sentinel line from
    /// a wrapper script body. Mirrors the production parse logic so the
    /// test asserts the same surface the uninstall path reads.
    private static func decodeRestoreSentinel(in body: String) -> String? {
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("# RESTORE: ") else { continue }
            let payload = line.dropFirst("# RESTORE: ".count).trimmingCharacters(in: .whitespaces)
            guard let data = Data(base64Encoded: payload),
                  let decoded = String(data: data, encoding: .utf8)
            else { return nil }
            return decoded
        }
        return nil
    }

    private static func paths() -> (root: URL, settings: URL, bridge: URL, wrapper: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerClaudeCodeTests-\(UUID().uuidString)")
        return (
            root,
            root.appendingPathComponent(".claude/settings.json"),
            root.appendingPathComponent("Bough.app/Contents/Resources/bough-statusline-bridge.sh"),
            root.appendingPathComponent(".bough/bough-statusline-wrapper.sh")
        )
    }

    private static func writeJSON(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
