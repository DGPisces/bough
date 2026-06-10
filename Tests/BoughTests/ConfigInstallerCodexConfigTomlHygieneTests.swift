import XCTest
import CryptoKit
@testable import Bough

/// Seed test file for Plan 15-04 (HOOK-03).
///
/// This file contains the 2 smallest behavioral tests for `cleanupBoughHooksFromCodexConfigToml`:
/// - `testCleanupRemovesMarkerBracketedBlock`: proves Pass-1 marker removal works.
/// - `testCleanupRefusesMalformedTomlAndSkipsFeaturesMigration`: proves the D-15 short-circuit
///   fidelity — a malformed config stays byte-identical and the `[features]` migration is skipped.
///
/// Plan 15-06 extends this same file with 6 additional behavioral tests.
final class ConfigInstallerCodexConfigTomlHygieneTests: XCTestCase {
    private var savedCodexHome: String?

    override func setUp() {
        super.setUp()
        TestHelpers.processEnvironmentLock.lock()
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    }

    override func tearDown() {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        TestHelpers.processEnvironmentLock.unlock()
        super.tearDown()
    }

    // MARK: - Helpers (verbatim from ConfigInstallerCodexHooksMigrationTests, lines 21-41)

    private func withTemporaryCodexHome(
        _ body: (_ home: URL, _ config: URL) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("bough-codex-home-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }
        defer { try? fm.removeItem(at: home) }
        setenv("CODEX_HOME", home.path, 1)
        try body(home, home.appendingPathComponent("config.toml"))
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the SHA-256 digest of the file at `url` as raw Data, or fails the test.
    private func sha256(_ url: URL) throws -> Data {
        let fileData = try Data(contentsOf: url)
        return Data(SHA256.hash(data: fileData))
    }

    // MARK: - Tests

    func testCodexConfigFailureIsPropagatedByInstallSetEnabledAndRepair() throws {
        let source = try sourceFile("Sources/Bough/ConfigInstaller.swift")

        XCTAssertTrue(source.contains("if !installCodexHooksIfEnabled(fm: fm, bridgeInstalled: bridgeInstalled) { ok = false }"))
        XCTAssertTrue(source.contains("guard enableCodexHooksConfig(fm: fm),"))
        XCTAssertTrue(source.contains("let configInstalled = enableCodexHooksConfig(fm: fm)"))
        XCTAssertTrue(source.contains("let configChanged = configBefore != configAfter"))
        XCTAssertTrue(source.contains("if configInstalled && configChanged {\n                        repaired.append(cli.name)\n                    }"))
        XCTAssertTrue(source.contains("configInstalled,\n                   isHooksInstalled(for: cli, fm: fm)"))
    }

    /// Behavior 1 (D-13 Pass-1): A config.toml containing a marker-bracketed `[[hooks]]` block
    /// has that entire range excised by Pass 1; all content outside the markers is preserved.
    func testCleanupRemovesMarkerBracketedBlock() throws {
        let fixture = """
            model = "gpt-5-codex"

            # bough-hook-v1-start
            [[hooks]]
            event = "PostToolUse"
            command = "/Users/x/.bough/bough-bridge --source codex"
            timeout = 30
            # bough-hook-v1-end

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            XCTAssertEqual(outcome, .cleaned, "Expected .cleaned when marker-bracketed block is present")

            let result = try read(config)

            // Surrounding content must be preserved.
            XCTAssertTrue(result.contains("model = \"gpt-5-codex\""),
                          "model key must survive cleanup")
            XCTAssertTrue(result.contains("[features]"),
                          "[features] section must survive cleanup")
            XCTAssertTrue(result.contains("hooks = true"),
                          "hooks = true must survive cleanup")

            // Marker pair and bough-bridge command must be gone.
            XCTAssertFalse(result.contains("# bough-hook-v1-start"),
                           "bough-hook-v1-start marker must be removed")
            XCTAssertFalse(result.contains("# bough-hook-v1-end"),
                           "bough-hook-v1-end marker must be removed")
            XCTAssertFalse(result.contains("bough-bridge"),
                           "bough-bridge command must be removed")
        }
    }

    /// Behavior 3 (D-13 Pass-2): An unmarked `[hooks.SessionStart]` block whose command contains
    /// the `bough-bridge` substring is removed. All other content is preserved.
    func testCleanupRemovesUnmarkedHooksBlockWithBoughBridgeCommand() throws {
        let fixture = """
            [hooks.SessionStart]
            command = "/Users/x/.bough/bough-bridge --source codex"
            timeout = 30

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            XCTAssertEqual(outcome, .cleaned, "Expected .cleaned when bough-bridge hook block is present")

            let result = try read(config)

            XCTAssertFalse(result.contains("[hooks.SessionStart]"),
                           "[hooks.SessionStart] block must be removed")
            XCTAssertFalse(result.contains("bough-bridge"),
                           "bough-bridge command must be removed")
            XCTAssertTrue(result.contains("[features]"),
                          "[features] section must be preserved")
            XCTAssertTrue(result.contains("hooks = true"),
                          "hooks = true must be preserved")
        }
    }

    /// Behavior 4 (D-13 Pass-2 negative): A hand-edited `[hooks.pre_tool_use]` block whose command
    /// does NOT contain `bough-bridge` must be preserved. The cleanup returns `.nothingToDo`,
    /// so the user-owned block should remain byte-for-byte untouched.
    func testCleanupPreservesHandEditedHooksBlock() throws {
        let originalContent = """
            [hooks.pre_tool_use]
            command = "/usr/local/bin/my-script --arg"
            timeout = 30

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(originalContent, to: config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            // Nothing to clean: no marker block, no bough-bridge command.
            XCTAssertEqual(outcome, .nothingToDo,
                           "Expected .nothingToDo when no Bough-owned hooks are present")

            let result = try read(config)

            XCTAssertTrue(result.contains("[hooks.pre_tool_use]"),
                          "Hand-edited hooks block must be preserved")
            XCTAssertTrue(result.contains("/usr/local/bin/my-script"),
                          "User command must be preserved")
        }
    }

    func testCleanupPreservesBridgePrefixOnlyHooksBlocks() throws {
        let originalContent = """
            [hooks.pre_tool_use]
            command = "/Users/x/.bough/bin/bough-bridge-old --source codex"
            timeout = 30

            [hooks.post_tool_use]
            command = "/usr/local/bin/my-bough-bridge --flag"
            timeout = 30

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(originalContent, to: config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            XCTAssertEqual(outcome, .nothingToDo)
            XCTAssertEqual(try read(config), originalContent)
        }
    }

    /// Behavior 5 (PITFALL-16 anti-regression): A config with multi-line strings, inline tables,
    /// and trailing-line comments in sections that have NO Bough-owned content must come through
    /// cleanup unchanged. Cleanup returns `.nothingToDo` (no file write), so bytes are trivially
    /// preserved — verified via SHA-256.
    func testCleanupPreservesMultiLineStringsAndInlineTablesUnchanged() throws {
        let fixture = """
            [profile]
            description = \"""
            A multi-line
            description.
            \"""
            settings = { theme = "dark", lang = "en" }

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            let preSHA = try sha256(config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            // No Bough-owned content → cleanup must not write the file.
            XCTAssertEqual(outcome, .nothingToDo,
                           "Expected .nothingToDo when no Bough-owned content is present")

            let postSHA = try sha256(config)
            XCTAssertEqual(preSHA, postSHA,
                           "File bytes must be byte-identical when cleanup has nothing to remove (PITFALL-16)")
        }
    }

    /// Behavior 6 (D-14 idempotency): Running cleanup twice on a fixture containing both a
    /// marker-bracketed block and an unmarked bough-bridge block produces the same output on
    /// both passes — second call returns `.nothingToDo` and leaves the file unchanged.
    func testCleanupIsIdempotent() throws {
        let fixture = """
            # bough-hook-v1-start
            [[hooks]]
            event = "SessionStart"
            command = "/Users/x/.bough/bough-bridge --source codex"
            timeout = 30
            # bough-hook-v1-end

            [hooks.UserPromptSubmit]
            command = "/Users/x/.bough/bough-bridge --source codex"
            timeout = 30

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            // First pass.
            let firstOutcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()
            XCTAssertEqual(firstOutcome, .cleaned, "First pass must return .cleaned")
            let afterFirst = try read(config)

            // Second pass.
            let secondOutcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()
            XCTAssertEqual(secondOutcome, .nothingToDo,
                           "Second pass must return .nothingToDo (idempotent, D-14)")
            let afterSecond = try read(config)

            XCTAssertEqual(afterFirst, afterSecond,
                           "Second cleanup pass must produce byte-identical output (D-14 idempotency)")
        }
    }

    /// Behavior 7 (D-13 Pass-2 negative): `[[hooks]]` entries with a missing `command` field or
    /// a non-string `command` value must NOT be removed — they cannot match the bough-bridge
    /// heuristic. Both entries must be preserved in the output.
    func testCleanupPreservesHooksEntryWithMissingOrNonStringCommand() throws {
        let fixture = """
            [[hooks]]
            event = "PostToolUse"
            timeout = 30

            [[hooks]]
            event = "PreToolUse"
            command = 42

            [features]
            hooks = true
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            let outcome = ConfigInstaller.testCleanupBoughHooksFromCodexConfigToml()

            // No bough-bridge command present → nothing to remove.
            XCTAssertEqual(outcome, .nothingToDo,
                           "Expected .nothingToDo when no bough-bridge command is present")

            let result = try read(config)

            XCTAssertTrue(result.contains("PostToolUse"),
                          "[[hooks]] entry with missing command must be preserved")
            XCTAssertTrue(result.contains("PreToolUse"),
                          "[[hooks]] entry with non-string command must be preserved")
        }
    }

    /// HOOK-04 invariant (static-grep): Codex installer source must not contain
    /// `[hooks.` or `[[hooks]]` literal substrings anywhere on the Codex code path.
    func testHOOK04InvariantConfigInstallerHasNoHooksTomlLiteralsInCodexCodePath() throws {
        // Resolve repo root from this test file's location.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/BoughTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let codexTomlURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Bough")
            .appendingPathComponent("ConfigInstaller+CodexToml.swift")
        let configInstallerURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Bough")
            .appendingPathComponent("ConfigInstaller.swift")

        guard let codexScopedText = try? String(contentsOf: codexTomlURL, encoding: .utf8) else {
            XCTFail("Could not load Sources/Bough/ConfigInstaller+CodexToml.swift — check repo root resolution")
            return
        }
        guard let configInstallerSource = try? String(contentsOf: configInstallerURL, encoding: .utf8) else {
            XCTFail("Could not load Sources/Bough/ConfigInstaller.swift — check repo root resolution")
            return
        }

        // Filter out comment lines (// and ///) before scanning — the invariant is about
        // executable code paths that would WRITE [hooks.*] to config.toml, not about
        // documentation strings that describe the cleanup behavior. A comment that says
        // "removes [hooks.SessionStart]" is expected and harmless.
        let codexNonCommentLines = codexScopedText
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Exclude Swift line-comments (// and ///) and doc-comments (///).
                return !trimmed.hasPrefix("//")
            }
            .joined(separator: "\n")

        XCTAssertFalse(codexNonCommentLines.contains("[hooks."),
                       "HOOK-04: Codex code path in ConfigInstaller+CodexToml.swift must not contain '[hooks.' literal in executable code")
        XCTAssertFalse(codexNonCommentLines.contains("[[hooks]]"),
                       "HOOK-04: Codex code path in ConfigInstaller+CodexToml.swift must not contain '[[hooks]]' literal in executable code")

        XCTAssertTrue(configInstallerSource.contains("[[hooks]]"),
                      "Defensive anchor: Kimi installer in ConfigInstaller.swift must still contain '[[hooks]]'.")
    }

    /// Behavior 2 (D-15 short-circuit): A config.toml that passes `codexConfigHasValidTableHeaders`
    /// (table headers are syntactically well-formed) but fails local TOML validation
    /// (unclosed multi-line string inside a value) must:
    ///   1. Cause `enableCodexHooksConfig` (via `testEnableCodexHooksConfigWithDetectedVersion`) to
    ///      return `false` (the D-15 short-circuit signal).
    ///   2. Leave the file bytes on disk byte-identical before and after the call (SHA-256 verified).
    ///   3. NOT run the `[features]` migration (the malformed content must still be present).
    func testCleanupRefusesMalformedTomlAndSkipsFeaturesMigration() throws {
        // This fixture passes `codexConfigHasValidTableHeaders` because all `[...]` header lines
        // are syntactically well-formed. The validator rejects it because the multi-line string
        // value is never closed (the closing `"""` is absent).
        let fixture = """
            [features]
            codex_hooks = true

            [hooks.session_start]
            command = \"\"\"unclosed multi-line string rejected because the closing triple-quote is never reached
            timeout = 30
            """

        try withTemporaryCodexHome { _, config in
            try write(fixture, to: config)

            let preSHA = try sha256(config)

            // Exercise the full funnel dispatcher (version-guarded path, Plan 15-03 shim updated
            // in Plan 15-04 to include the cleanup + D-15 short-circuit).
            var dispatcherReturnValue: Bool = true
            XCTAssertNoThrow(
                dispatcherReturnValue = ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.130.0"),
                "Dispatcher must not throw on malformed config"
            )
            XCTAssertFalse(dispatcherReturnValue,
                           "D-15 short-circuit: dispatcher must return false on malformed config")

            let postSHA = try sha256(config)
            XCTAssertEqual(preSHA, postSHA,
                           "File bytes must be byte-identical before and after the call (D-15)")

            // Verify the exact original content is still on disk.
            let result = try read(config)
            XCTAssertTrue(result.contains("codex_hooks = true"),
                          "codex_hooks = true must be preserved (migration was skipped)")
            XCTAssertTrue(result.contains("[hooks.session_start]"),
                          "[hooks.session_start] header must be preserved")
            XCTAssertTrue(result.contains("unclosed multi-line string"),
                          "The malformed value text must be preserved byte-identically")
        }
    }
}
