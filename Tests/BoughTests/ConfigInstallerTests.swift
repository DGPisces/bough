import XCTest
@testable import Bough
import BoughCore
import Yams

final class ConfigInstallerTests: XCTestCase {
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

    private func yamlRootDict(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let any = try XCTUnwrap(try Yams.load(yaml: yaml), file: file, line: line)
        if let d = any as? [String: Any] { return d }
        if let d = any as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d {
                guard let ks = k as? String else { continue }
                out[ks] = v
            }
            return out
        }
        XCTFail("YAML root is not a mapping", file: file, line: line)
        return [:]
    }

    private func yamlHooks(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let root = try yamlRootDict(yaml, file: file, line: line)
        let hooksAny = try XCTUnwrap(root["hooks"], file: file, line: line)
        let hooks = try XCTUnwrap(hooksAny as? [Any], file: file, line: line)
        return hooks.compactMap { $0 as? [String: Any] }
    }

    private func withTemporaryCodexHome(
        _ body: (URL, URL) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("ConfigInstallerTests-CodexHome-\(UUID().uuidString)")
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

    private func writeExecutable(_ contents: String = "#!/bin/sh\n", to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let afterStart = source[startRange.lowerBound...]
        let endRange = try XCTUnwrap(afterStart.range(of: end))
        return String(afterStart[..<endRange.lowerBound])
    }

    func testPreserveCodexHooksDoesNotTreatArrayCloseAsFeatureSectionEnd() throws {
        try withTemporaryCodexHome { _, config in
            try """
            [features]
            experimental = [
              "one",
              "two",
            ]
            hooks = false
            codex_hooks = true

            [tools]
            enabled = true
            """.write(to: config, atomically: true, encoding: .utf8)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.129.5"))

            let result = try String(contentsOf: config, encoding: .utf8)
            let lines = result.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(lines.filter { $0 == "hooks = false" }.count, 1)
            XCTAssertTrue(lines.contains("codex_hooks = true"))
            XCTAssertFalse(lines.contains("hooks = true"))
        }
    }

    func testCodexVersionCandidatesIncludeShellNvmAndAppResourceButExcludeGuiBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerTests-CodexCandidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let shellCodex = root.appendingPathComponent("bin/codex")
        let nvmCodex = root.appendingPathComponent(".nvm/versions/node/v22.11.0/bin/codex")
        let appResourceCodex = root.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
        let appGuiBinary = root.appendingPathComponent("Applications/Codex.app/Contents/MacOS/Codex")

        try writeExecutable(to: shellCodex)
        try writeExecutable(to: nvmCodex)
        try writeExecutable(to: appResourceCodex)
        try writeExecutable(to: appGuiBinary)

        let candidates = ConfigInstaller.testCodexVersionCandidatePaths(
            homeDirectory: root.path,
            shellResolvedPath: shellCodex.path,
            appResourcesCodexPath: appResourceCodex.path
        )

        XCTAssertTrue(candidates.contains(shellCodex.path))
        XCTAssertTrue(candidates.contains(nvmCodex.path))
        XCTAssertTrue(candidates.contains(appResourceCodex.path))
        XCTAssertFalse(candidates.contains(appGuiBinary.path))
        XCTAssertEqual(candidates.filter { $0 == shellCodex.path }.count, 1)
    }

    func testCodexVersionCandidatesExcludeGuiBinaryEvenWhenShellResolvesIt() throws {
        let guiPath = "/Applications/Codex.app/Contents/MacOS/Codex"
        let candidates = ConfigInstaller.testCodexVersionCandidatePaths(
            homeDirectory: NSTemporaryDirectory(),
            shellResolvedPath: guiPath,
            appResourcesCodexPath: guiPath
        )

        XCTAssertFalse(candidates.contains(guiPath))
    }

    func testCodexVersionCandidatesExcludeSymlinkToGuiBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerTests-CodexGuiSymlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let shellCodex = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: shellCodex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: shellCodex.path,
            withDestinationPath: "/Applications/Codex.app/Contents/MacOS/Codex"
        )

        XCTAssertTrue(ConfigInstaller.testIsCodexGUIAppBinary(shellCodex.path))

        let candidates = ConfigInstaller.testCodexVersionCandidatePaths(
            homeDirectory: root.path,
            shellResolvedPath: shellCodex.path,
            appResourcesCodexPath: root.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path
        )

        XCTAssertFalse(candidates.contains(shellCodex.path))
        XCTAssertFalse(candidates.contains("/Applications/Codex.app/Contents/MacOS/Codex"))
    }

    func testCodexVersionDetectionPrefersCurrentCandidateOverOldNvmCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigInstallerTests-CodexVersions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldNvmCodex = root.appendingPathComponent(".nvm/versions/node/v20.0.0/bin/codex")
        let currentAppResourceCodex = root.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")

        try writeExecutable("#!/bin/sh\necho 'codex-cli 0.129.5'\n", to: oldNvmCodex)
        try writeExecutable("#!/bin/sh\necho 'codex-cli 0.130.0'\n", to: currentAppResourceCodex)

        XCTAssertEqual(
            ConfigInstaller.testDetectCodexVersion(candidatePaths: [oldNvmCodex.path, currentAppResourceCodex.path]),
            "0.130.0"
        )
    }

    func testClaudeVersionDetectionIncludesAppleSiliconHomebrewPath() throws {
        let source = try sourceFile("Sources/Bough/ConfigInstaller.swift")
        let body = try sourceSlice(
            source,
            from: "private static func detectClaudeVersion",
            to: "/// Compare semver strings"
        )

        XCTAssertTrue(body.contains(#""/opt/homebrew/bin/claude""#))
        XCTAssertTrue(body.contains("timeout: 5"))
    }

    func testCustomCLIRejectsMissingConfigDirectory() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/settings.json")
            .path

        let result = ConfigInstaller.addCustomCLI(
            name: "Missing",
            source: "missing-\(UUID().uuidString)",
            configPath: missingPath,
            format: .nested
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Config directory does not exist")
    }

    func testCustomCLIAcceptsHomeResolvedConfigDirectories() throws {
        let fm = FileManager.default
        let dirName = ".bough-custom-cli-test-\(UUID().uuidString)"
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let paths = [
            "~/\(dirName)/settings.json",
            "\(dirName)/settings.json"
        ]
        for (index, path) in paths.enumerated() {
            let source = "homepath-\(index)-\(UUID().uuidString.lowercased())"
            defer { _ = ConfigInstaller.removeCustomCLI(source: source) }

            let result = ConfigInstaller.addCustomCLI(
                name: "Home Path \(index)",
                source: source,
                configPath: path,
                format: .nested
            )

            XCTAssertTrue(result.ok, result.message)
        }
    }

    func testCustomCLIEnableFailureRollsBackEnabledPreference() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ConfigInstallerTests-CustomCLI-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = "custom-\(UUID().uuidString.lowercased())"
        let config = root.appendingPathComponent("settings.json")
        try "{".write(to: config, atomically: true, encoding: .utf8)
        defer {
            _ = ConfigInstaller.removeCustomCLI(source: source)
        }

        // Isolated suite: keeps the cli_enabled_* write out of `.standard`,
        // which is shared across `swift test --parallel` worker processes.
        let suiteName = "ConfigInstallerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = ConfigInstaller.addCustomCLI(
            name: "Custom",
            source: source,
            configPath: config.path,
            format: .nested
        )

        XCTAssertTrue(result.ok)
        XCTAssertFalse(ConfigInstaller.setEnabled(source: source, enabled: true, defaults: defaults))
        XCTAssertFalse(ConfigInstaller.isEnabled(source: source, defaults: defaults))
    }

    func testRemoveManagedHookEntriesAlsoPrunesLegacyManagedHooks() throws {
        let hooks: [String: Any] = [
            "SessionEnd": [
                [
                    "hooks": [
                        [
                            "command": "/Users/test/.bough/bin/bough-bridge --source claude",
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.claude/hooks/bough-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "async": true,
                            "command": "~/.claude/hooks/bark-notify.sh",
                            "timeout": 10,
                            "type": "command",
                        ],
                    ],
                ],
            ],
        ]

        let cleaned = ConfigInstaller.removeManagedHookEntries(from: hooks)
        let sessionEnd = try XCTUnwrap(cleaned["SessionEnd"] as? [[String: Any]])

        XCTAssertEqual(sessionEnd.count, 1)
        let remainingHooks = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "~/.claude/hooks/bark-notify.sh")
    }

    // MARK: - Kimi Code CLI TOML hooks

    func testRemoveKimiHooksPreservesNonBoughBlocks() {
        let toml = """
        default_model = "kimi-k2-5"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.bough/bough-bridge --source kimi"
        timeout = 5

        [[mcpServers]]
        name = "test"
        command = "npx"

        [[hooks]]
        event = "UserPromptSubmit"
        command = "echo hello"
        timeout = 1
        """

        let cleaned = ConfigInstaller.removeKimiHooks(from: toml)
        XCTAssertFalse(cleaned.contains("bough-bridge"))
        XCTAssertTrue(cleaned.contains("[[mcpServers]]"))
        XCTAssertTrue(cleaned.contains("echo hello"))
        XCTAssertTrue(cleaned.contains("default_model"))
    }

    func testRemoveKimiHooksPreservesBridgePrefixOnlyCommands() {
        let toml = """
        [[hooks]]
        event = "Stop"
        command = "/Users/test/.bough/bin/bough-bridge-old --source kimi"
        timeout = 5

        [[hooks]]
        event = "UserPromptSubmit"
        command = "/usr/local/bin/my-bough-bridge"
        timeout = 1
        """

        let cleaned = ConfigInstaller.removeKimiHooks(from: toml)

        XCTAssertTrue(cleaned.contains("bough-bridge-old"))
        XCTAssertTrue(cleaned.contains("my-bough-bridge"))
    }

    func testContentsContainsKimiHookDetectsInstalledEvent() {
        let toml = """
        [[hooks]]
        event = "PreToolUse"
        command = "/Users/test/.bough/bough-bridge --source kimi"
        timeout = 5
        matcher = ".*"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.bough/bough-bridge --source kimi"
        timeout = 5
        """

        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "PreToolUse"))
        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "Stop"))
        XCTAssertFalse(ConfigInstaller.contentsContainsKimiHook(toml, event: "SessionStart"))
    }

    func testKimiHookFormatEvents() {
        let events = ConfigInstaller.defaultEvents(for: .kimi)
        let eventNames = events.map { $0.0 }
        XCTAssertTrue(eventNames.contains("UserPromptSubmit"))
        XCTAssertTrue(eventNames.contains("PreToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUseFailure"))
        XCTAssertFalse(eventNames.contains("PermissionRequest"), "Kimi does not support PermissionRequest")
        XCTAssertTrue(eventNames.contains("Stop"))
        XCTAssertTrue(eventNames.contains("SessionStart"))
        XCTAssertTrue(eventNames.contains("SessionEnd"))
        XCTAssertTrue(eventNames.contains("Notification"))
        XCTAssertTrue(eventNames.contains("PreCompact"))

        let notificationTimeout = events.first { $0.0 == "Notification" }?.1
        XCTAssertEqual(notificationTimeout, 600, "Kimi max timeout is 600")
    }

    func testClaudeForkDefaultEventsIncludeBlockingPermissionAndFailureHooks() {
        let events = ConfigInstaller.defaultEvents(for: .claude)
        let eventNames = Set(events.map { $0.0 })

        XCTAssertTrue(eventNames.contains("PermissionRequest"))
        XCTAssertEqual(events.first { $0.0 == "PermissionRequest" }?.1, 86400)
        XCTAssertTrue(eventNames.contains("PostToolUseFailure"))
    }

    func testCodexSetEnabledDoesNotCreateHooksWhenConfigTomlIsMalformed() throws {
        try withTemporaryCodexHome { home, config in
            // Isolated suite: keeps the cli_enabled_codex write out of `.standard`,
            // which is shared across `swift test --parallel` worker processes.
            let suiteName = "ConfigInstallerTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            try """
            [features
            codex_hooks = true
            """.write(to: config, atomically: true, encoding: .utf8)

            XCTAssertFalse(ConfigInstaller.setEnabled(source: "codex", enabled: true, defaults: defaults))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks.json").path))
        }
    }

    func testCodexInstallCreatesCodexHomeWhenMissing() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("ConfigInstallerTests-MissingCodexHome-\(UUID().uuidString)")
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
            try? fm.removeItem(at: home)
        }

        // Isolated suite: keeps the cli_enabled_codex write out of `.standard`,
        // which is shared across `swift test --parallel` worker processes.
        let suiteName = "ConfigInstallerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        setenv("CODEX_HOME", home.path, 1)
        defaults.set(true, forKey: "cli_enabled_codex")

        XCTAssertFalse(fm.fileExists(atPath: home.path))
        XCTAssertTrue(ConfigInstaller.testInstallCodexHooksIfEnabled(defaults: defaults))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("config.toml").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("hooks.json").path))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8).contains("hooks = true"))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("hooks.json"), encoding: .utf8).contains("PermissionRequest"))
    }

    func testBuiltInClaudeForksUseFullClaudeEventSet() throws {
        let forkSources = [
            "qoder",
            "droid",
            "codebuddy",
            "codybuddycn",
            "stepfun",
            "antigravity",
            "workbuddy",
            "hermes",
        ]

        for source in forkSources {
            let cli = try XCTUnwrap(
                ConfigInstaller.allCLIs.first { $0.source == source },
                "\(source) should be registered"
            )
            let events = Set(cli.events.map { $0.0 })
            XCTAssertTrue(events.contains("PermissionRequest"), "\(source) should install approval hooks")
            XCTAssertTrue(events.contains("PostToolUseFailure"), "\(source) should install failure hooks")
        }
    }

    /// Hermetic integration test: uses a temporary directory instead of touching ~/.kimi/config.toml.
    func testInstallKimiHooksIntegration() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml").path
        let originalScalar = "hooks = [\"UserPromptSubmit\"]\n"
        fm.createFile(atPath: configPath, contents: originalScalar.data(using: .utf8))

        let cli = CLIConfig(
            name: "Kimi Code CLI",
            source: "kimi",
            configPath: configPath,
            configKey: "hooks",
            format: .kimi,
            events: ConfigInstaller.defaultEvents(for: .kimi)
        )

        // Install hooks
        XCTAssertTrue(ConfigInstaller.installKimiHooks(cli: cli, fm: fm))

        // Verify file contents
        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let installed = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(installed.contains("[[hooks]]"))
        XCTAssertTrue(installed.contains("event = \"PreToolUse\""))
        XCTAssertTrue(installed.contains("event = \"Stop\""))
        XCTAssertTrue(installed.contains("bough-bridge --source kimi"))
        XCTAssertFalse(installed.contains("\nhooks = "), "Scalar hooks key should be commented out to avoid TOML duplicate key error")
        XCTAssertTrue(installed.contains("# hooks ="), "Legacy scalar hooks should be preserved as comments")

        // Uninstall and verify legacy hooks are restored
        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)
        let uninstalledData = try XCTUnwrap(fm.contents(atPath: configPath))
        let uninstalled = try XCTUnwrap(String(data: uninstalledData, encoding: .utf8))

        XCTAssertTrue(uninstalled.contains("hooks = [\"UserPromptSubmit\"]"), "Legacy scalar hooks should be restored after uninstall")
        XCTAssertFalse(uninstalled.contains("bough-bridge"), "Bough hooks should be removed after uninstall")
    }

    func testInstallKimiHooksDoesNotOverwriteNonUTF8Config() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml").path
        let original = Data([0x68, 0x6f, 0x6f, 0x6b, 0x73, 0x20, 0xff, 0xfe])
        XCTAssertTrue(fm.createFile(atPath: configPath, contents: original))

        let cli = CLIConfig(
            name: "Kimi Code CLI",
            source: "kimi",
            configPath: configPath,
            configKey: "hooks",
            format: .kimi,
            events: ConfigInstaller.defaultEvents(for: .kimi)
        )

        XCTAssertFalse(ConfigInstaller.installKimiHooks(cli: cli, fm: fm))
        XCTAssertEqual(fm.contents(atPath: configPath), original)
    }

    func testKimiLegacyScalarCommentingOnlyTouchesTopLevelHooks() {
        let toml = """
        hooks=[\"UserPromptSubmit\"]
        hooks\t= false

        [features]
        hooks = true

        [[hooks]]
        event = "UserPromptSubmit"
        command = "echo user"
        """

        let commented = ConfigInstaller.commentOutTopLevelKimiHooksScalar(in: toml)

        XCTAssertTrue(commented.contains("# [Bough] commented out legacy scalar hooks to avoid TOML conflict\n# hooks=[\"UserPromptSubmit\"]"))
        XCTAssertTrue(commented.contains("# [Bough] commented out legacy scalar hooks to avoid TOML conflict\n# hooks\t= false"))
        XCTAssertTrue(commented.contains("[features]\nhooks = true"))
        XCTAssertTrue(commented.contains("[[hooks]]\nevent = \"UserPromptSubmit\""))
    }

    func testKimiLegacyScalarRestoreOnlyUsesBoughMarker() {
        let toml = """
        # hooks = user-commented
        # [Bough] commented out legacy scalar hooks to avoid TOML conflict
        # hooks = false

        [features]
        # hooks = nested-comment
        hooks = true
        """

        let restored = ConfigInstaller.restoreKimiCommentedLegacyScalars(in: toml)

        XCTAssertTrue(restored.contains("# hooks = user-commented"))
        XCTAssertTrue(restored.contains("\nhooks = false\n"))
        XCTAssertTrue(restored.contains("[features]\n# hooks = nested-comment\nhooks = true"))
        XCTAssertFalse(restored.contains("# [Bough] commented out legacy scalar hooks"))
    }

    func testKimiTomlEscapesBridgeCommandWithWhitespace() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml").path
        let cli = CLIConfig(
            name: "Kimi Code CLI",
            source: "kimi",
            configPath: configPath,
            configKey: "hooks",
            format: .kimi,
            events: [("UserPromptSubmit", 5, true)]
        )

        XCTAssertTrue(ConfigInstaller.installKimiHooks(
            cli: cli,
            fm: fm,
            bridgeCommand: "/Users/$Some User/.bough/bough-bridge"
        ))

        let installed = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(
            installed.contains(#"command = "\"/Users/\\$Some User/.bough/bough-bridge\" --source kimi""#),
            installed
        )
    }

    func testUninstallRemovesBoughOwnedCopilotHookFile() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".copilot/hooks/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Copilot",
            source: "copilot",
            configPath: ".copilot/hooks/bough.json",
            configKey: "hooks",
            format: .copilot,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bough-bridge --source copilot --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertFalse(fm.fileExists(atPath: configPath.path), "Copilot's bough.json is Bough-owned and should be removed on uninstall")
    }

    func testUninstallRemovesBoughOwnedCopilotHookFileUsingLegacyBinBridgePath() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".copilot/hooks/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Copilot",
            source: "copilot",
            configPath: ".copilot/hooks/bough.json",
            configKey: "hooks",
            format: .copilot,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bin/bough-bridge --source copilot --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertFalse(fm.fileExists(atPath: configPath.path), "Legacy bin bridge path should still mark the whole file as Bough-owned")
    }

    func testUninstallPreservesCopilotHookFileWhenBridgePathOnlySharesPrefix() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".copilot/hooks/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Copilot",
            source: "copilot",
            configPath: ".copilot/hooks/bough.json",
            configKey: "hooks",
            format: .copilot,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bin/bough-bridge-old --source copilot --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertTrue(fm.fileExists(atPath: configPath.path), "Prefix-only bridge paths are user-owned and must not delete the whole file")
        let after = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(after.contains("bough-bridge-old"))
    }

    func testUninstallPreservesCopilotHookFileWhenSourceOnlySharesPrefix() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".copilot/hooks/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Copilot",
            source: "copilot",
            configPath: ".copilot/hooks/bough.json",
            configKey: "hooks",
            format: .copilot,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bough-bridge --source copilot-old --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertTrue(fm.fileExists(atPath: configPath.path), "Prefix-only source tags are user-owned and must not delete the whole file")
        let after = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(after.contains("--source copilot-old"))
    }

    func testUninstallPreservesCopilotHookFileWhenEqualsSourceOnlySharesPrefix() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".copilot/hooks/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Copilot",
            source: "copilot",
            configPath: ".copilot/hooks/bough.json",
            configKey: "hooks",
            format: .copilot,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bough-bridge --source=copilotx --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertTrue(fm.fileExists(atPath: configPath.path), "Equals-form prefix source tags are user-owned and must not delete the whole file")
        let after = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(after.contains("--source=copilotx"))
    }

    func testUninstallRemovesBoughOwnedKiroAgentFile() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".kiro/agents/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Kiro",
            source: "kiro",
            configPath: ".kiro/agents/bough.json",
            configKey: "hooks",
            format: .kiroAgent,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "name": "bough",
          "description": "Auto-generated by Bough",
          "hooks": {
            "PostToolUse": [
              {
                "command": "/Users/test/.bough/bough-bridge --source kiro",
                "matcher": "*",
                "timeout_ms": 5000
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        XCTAssertFalse(fm.fileExists(atPath: configPath.path), "Kiro's bough.json is Bough-owned and should be removed on uninstall")
    }

    func testUninstallPreservesCustomCopilotConfigFile() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("custom-copilot.json").path
        let cli = ConfigInstaller.testMakeCLI(format: .copilot, configPath: configPath)
        let original = """
        {
          "version": 1,
          "hooks": {
            "PostToolUse": [
              {
                "type": "command",
                "bash": "/Users/test/.bough/bough-bridge --source custom --event PostToolUse",
                "timeoutSec": 5
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        let after = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(after.contains("bough-bridge"))
        XCTAssertTrue(after.contains("\"version\""))
    }

    func testUninstallPreservesMixedKiroAgentFile() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".kiro/agents/bough.json")
        try fm.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cli = CLIConfig(
            name: "Kiro",
            source: "kiro",
            configPath: ".kiro/agents/bough.json",
            configKey: "hooks",
            format: .kiroAgent,
            events: [("PostToolUse", 5, false)]
        )
        cli.rootOverride = { tempDir.path }
        let original = """
        {
          "name": "bough",
          "description": "Auto-generated by Bough",
          "hooks": {
            "PostToolUse": [
              {
                "command": "/Users/test/.bough/bough-bridge --source kiro",
                "matcher": "*",
                "timeout_ms": 5000
              },
              {
                "command": "/Users/test/bin/user-hook",
                "matcher": "*",
                "timeout_ms": 5000
              }
            ]
          }
        }
        """

        fm.createFile(atPath: configPath.path, contents: Data(original.utf8))

        try ConfigInstaller.testUninstallHooksForCLI(cli)

        let after = try String(contentsOfFile: configPath.path, encoding: .utf8)
        XCTAssertFalse(after.contains("bough-bridge"))
        XCTAssertTrue(after.contains("user-hook"))
    }

    func testMergeCocoHooksAppendsHooksSectionWhenMissing() throws {
        let original = "model:\n    name: GPT-5.4\n"

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        let hooks = try yamlHooks(merged)
        XCTAssertEqual(hooks.count, 1)
        let cmd = hooks.first?["command"] as? String
        XCTAssertTrue(cmd?.contains("bough-bridge --source traecli") ?? false)

        // Managed block should be a SINGLE hook with multiple matchers. TraeCli may de-dup by
        // (type + command), so emitting one hook per event can drop most events.
        let matchers = hooks.first?["matchers"] as? [Any]
        let events = (matchers ?? []).compactMap { ($0 as? [String: Any])?["event"] as? String }
        XCTAssertTrue(events.contains("permission_request"))
        XCTAssertTrue(events.contains("pre_tool_use"))
        XCTAssertTrue(events.contains("post_tool_use"))
        XCTAssertTrue(events.contains("stop"))
    }

    func testMergeCocoHooksReplacesExistingManagedBlockWithoutTouchingUserHooks() throws {
        let original = """
hooks:
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
  - type: command
    command: '\(NSHomeDirectory())/.bough/bough-bridge --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("echo user-hook"))

        // New managed block should still contain a traecli bridge command.
        XCTAssertEqual(commands.filter { $0.contains("bough-bridge") && $0.contains("--source traecli") }.count, 1)
        XCTAssertEqual(hooks.count, 2)
    }

    func testMergeTraecliHooksRemovesQuotedBridgeCommandToAvoidDuplicates() throws {
        let bridge = "\(NSHomeDirectory())/.bough/bough-bridge"
        let original = """
hooks:
  - type: command
    command: '\"\(bridge)\" --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertEqual(commands.filter { $0.contains("bough-bridge") }.count, 1)
        XCTAssertEqual(commands.filter { $0.contains("--source traecli") }.count, 1)
    }

    func testMergeTraecliHooksHandlesHooksFlowSequenceWithoutBreakingYAML() throws {
        let original = "model: GPT-5.4\nhooks: []\n"
        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        // Should rewrite hooks into a list and inject our managed hook.
        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertEqual(commands.filter { $0.contains("--source traecli") }.count, 1)
    }

    func testMergeTraecliHooksNormalizesMixedIndentationToValidYAML() throws {
        // Simulate a user file with 4-space indented list items, which previously could
        // become invalid YAML when we injected a 2-space indented managed block.
        let original = """
model:
    name: GPT-5.4
hooks:
    - type: command
      command: echo user-hook
      matchers:
        - event: stop
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)
        // Must be parseable and must contain both user + managed hook.
        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertEqual(commands.filter { $0.contains("bough-bridge") && $0.contains("--source traecli") }.count, 1)
        XCTAssertEqual(hooks.count, 2)
    }

    func testMergeTraecliHooksIsIdempotent() {
        let original = "model: GPT-5.4\n"
        let once = ConfigInstaller.mergeTraecliHooks(into: original)
        let twice = ConfigInstaller.mergeTraecliHooks(into: once)
        XCTAssertEqual(once, twice)
    }

    func testMergeTraecliHooksLeavesMalformedYAMLByteIdentical() {
        let original = "model: [\nhooks: []"

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        XCTAssertEqual(merged, original)
    }

    func testInstallTraecliHooksRefusesMalformedYAMLWithoutRewrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughConfigInstallerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let configURL = tempDir.appendingPathComponent("traecli.yaml")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let original = "model: [\nhooks: []"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        var cli = ConfigInstaller.testMakeCLI(format: .traecli, configPath: "traecli.yaml")
        cli.rootOverride = { tempDir.path }

        XCTAssertThrowsError(try ConfigInstaller.testInstallHooksForCLI(cli))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    func testMergeTraecliHooksPreservesUserCommentsAndKeyOrder() throws {
        let original = """
        # top-level comment about my config
        model: GPT-5.4
        # comment before hooks
        hooks:
          - type: command
            command: 'echo my-hook'  # inline comment
            matchers:
              - event: stop
        # trailing comment

        """

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        // Surgical path must keep all three comments verbatim.
        XCTAssertTrue(merged.contains("# top-level comment about my config"),
                      "Top-level comment was stripped — surgical path likely fell through to Yams round-trip")
        XCTAssertTrue(merged.contains("# comment before hooks"))
        XCTAssertTrue(merged.contains("# inline comment"))
        XCTAssertTrue(merged.contains("# trailing comment"))

        // Original key `model:` must come before `hooks:` (Yams.dump would sort alphabetically).
        let modelIdx = try XCTUnwrap(merged.range(of: "model:")?.lowerBound)
        let hooksIdx = try XCTUnwrap(merged.range(of: "hooks:")?.lowerBound)
        XCTAssertLessThan(modelIdx, hooksIdx)

        // And both the user hook and the managed hook must be present + valid YAML.
        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("echo my-hook"))
        XCTAssertEqual(commands.filter { $0.contains("--source traecli") }.count, 1)
    }

    func testMergeTraecliHooksRemovesManagedBlockEvenWithTrailingComments() throws {
        let original = """
hooks:
  - type: command # keep
    command: '\(NSHomeDirectory())/.bough/bough-bridge --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        let hooks = try yamlHooks(merged)
        let commands = hooks.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertEqual(commands.filter { $0.contains("--source traecli") }.count, 1)
    }

    func testRemoveManagedTraecliHooksDeletesHookWhenCommandMatches() {
        let original = """
hooks:
  # any legacy marker/comment line should be removed with the hook
  # BOUGH_MANAGED_TRAECLI_HOOK_BEGIN
  - type: command
    command: '\(NSHomeDirectory())/.bough/bough-bridge --source traecli'
    matchers:
      - event: stop
  # BOUGH_MANAGED_TRAECLI_HOOK_END
  # trailing comment should also be removed
"""

        let cleaned = ConfigInstaller.removeManagedTraecliHooks(from: original)

        XCTAssertFalse(cleaned.contains("bough-bridge --source traecli"))
        XCTAssertFalse(cleaned.contains("BOUGH_MANAGED_TRAECLI_HOOK"))
        XCTAssertFalse(cleaned.contains("trailing comment"))
    }

    func testRemoveManagedTraecliHooksPreservesCommentsAndKeyOrder() throws {
        let original = """
# top-level comment about my config
model: gpt-5
# comment before hooks
hooks:
  - type: command
    command: '\(NSHomeDirectory())/.bough/bough-bridge --source traecli'
    matchers:
      - event: stop
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: session_start
# trailing comment
"""

        let cleaned = ConfigInstaller.removeManagedTraecliHooks(from: original)

        XCTAssertTrue(cleaned.contains("# top-level comment about my config"))
        XCTAssertTrue(cleaned.contains("# comment before hooks"))
        XCTAssertTrue(cleaned.contains("# trailing comment"))
        XCTAssertFalse(cleaned.contains("bough-bridge --source traecli"))
        XCTAssertTrue(cleaned.contains("echo user-hook"))

        let modelIdx = try XCTUnwrap(cleaned.range(of: "model:")?.lowerBound)
        let hooksIdx = try XCTUnwrap(cleaned.range(of: "hooks:")?.lowerBound)
        XCTAssertLessThan(modelIdx, hooksIdx)

        let commands = try yamlHooks(cleaned).compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["echo user-hook"])
    }

    func testRemoveManagedTraecliHooksDoesNotDeleteOtherCommands() {
        let original = """
hooks:
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
"""

        let cleaned = ConfigInstaller.removeManagedTraecliHooks(from: original)
        XCTAssertEqual(cleaned, original)
    }

    func testRemoteInstallerConfigureScriptDoesNotContainTraecliTypos() {
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")

        let script = RemoteInstaller.configureRemoteHooksScript(host: host)

        // Ensure the Trae CLI hook block is present and contains session lifecycle events.
        XCTAssertTrue(script.contains("TRAECLI_EVENTS"))
        XCTAssertTrue(script.contains("\"session_start\""))
        XCTAssertTrue(script.contains("\"session_end\""))
        // Ensure remote TraeCli YAML merge has indentation repair to avoid invalid YAML.
        XCTAssertTrue(script.contains("def _normalize_traecli_hooks_list_indentation"))
    }

    func testRemoteTraecliPermissionRequestRoutesAsPermissionAndUsesRemoteSessionNamespace() async throws {
        let payload: [String: Any] = [
            "hook_event_name": "permission_request",
            "session_id": "sess-123",
            "_source": "traecli",
            "_remote_host_id": "host-1",
            "_remote_host_name": "devbox",
            "tool_name": "Bash",
            "tool_input": [
                "command": "ls",
                "description": "List files"
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        XCTAssertEqual(event.sessionId, "remote:host-1:sess-123")
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .permission)
    }

    func testRemoteInstallerConfigureScriptKeepsPythonNewlineEscapesAndCompiles() throws {
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")

        let script = RemoteInstaller.configureRemoteHooksScript(host: host)

        XCTAssertTrue(script.contains("return \"\\n\".join(lines)"))
        XCTAssertTrue(script.contains("normalized = contents.replace(\"\\r\\n\", \"\\n\")"))
        XCTAssertTrue(script.contains("if not merged.endswith(\"\\n\"):"))
        try assertPythonCompiles(script)
    }

    private func assertPythonCompiles(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; compile(sys.stdin.read(), '<stdin>', 'exec')"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput, file: file, line: line)
    }

    // MARK: - Opencode config merge (issue #89 — do not clobber user-authored config)

    func testMergeOpencodePluginRefCreatesMinimalConfigWhenFileAbsent() throws {
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: nil,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        XCTAssertEqual(json["$schema"] as? String, "https://opencode.ai/config.json")
        XCTAssertEqual(json["plugin"] as? [String], ["file:///tmp/bough-opencode.js"])
    }

    func testMergeOpencodePluginRefPreservesUnrelatedKeysAndOtherPlugins() throws {
        let original = """
        {
          "model": "anthropic/claude-sonnet-4",
          "theme": "tokyonight",
          "plugin": ["file:///user/other-plugin.js"],
          "autoshare": false
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet-4")
        XCTAssertEqual(json["theme"] as? String, "tokyonight")
        XCTAssertEqual(json["autoshare"] as? Bool, false)
        let plugins = try XCTUnwrap(json["plugin"] as? [String])
        XCTAssertTrue(plugins.contains("file:///user/other-plugin.js"))
        XCTAssertTrue(plugins.contains("file:///tmp/bough-opencode.js"))
    }

    func testMergeOpencodePluginRefDeduplicatesOurOwnRefs() throws {
        let previousPlugin = "file:///user/\(["code", "island"].joined())-opencode.js"
        let original = """
        {
          "plugin": [
            "file:///old/bough-opencode.js",
            "file:///some/bough.js",
            "\(previousPlugin)",
            "file:///user/my-bough-plugin.js",
            "file:///user/other.js"
          ]
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///new/bough-opencode.js",
                identifier: "bough"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(json["plugin"] as? [String])
        XCTAssertFalse(plugins.contains("file:///old/bough-opencode.js"))
        XCTAssertTrue(plugins.contains("file:///some/bough.js"))
        XCTAssertTrue(plugins.contains("file:///user/my-bough-plugin.js"))
        XCTAssertTrue(plugins.contains(previousPlugin))
        XCTAssertTrue(plugins.contains("file:///user/other.js"))
        XCTAssertTrue(plugins.contains("file:///new/bough-opencode.js"))
    }

    func testMergeOpencodePluginRefReturnsNilOnMalformedJSON() {
        // Unterminated object — installer MUST refuse to overwrite instead of
        // nuking the user's config.
        let malformed = "{\n  \"model\": \"sonnet\",\n  \"plugin\": [\n"
        XCTAssertNil(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: malformed,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
    }

    func testMergeOpencodePluginRefReturnsNilWhenRootIsNotAnObject() {
        // User accidentally wrote a top-level array instead of object.
        let array = "[\"not\", \"an\", \"object\"]"
        XCTAssertNil(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: array,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
    }

    func testRemoveOpencodePluginRefKeepsUserKeysAndOtherPlugins() throws {
        let original = """
        {
          "model": "sonnet",
          "plugin": ["file:///tmp/bough-opencode.js", "file:///user/my-bough-plugin.js", "file:///user/other.js"]
        }
        """
        let cleaned = try XCTUnwrap(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: original,
                identifier: "bough"
            )
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "sonnet")
        XCTAssertEqual(json["plugin"] as? [String], ["file:///user/my-bough-plugin.js", "file:///user/other.js"])
    }

    func testRemoveOpencodePluginRefReturnsNilOnMalformedJSON() {
        XCTAssertNil(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: "{ not valid json",
                identifier: "bough"
            )
        )
    }

    func testRemoveOpencodePluginRefReturnsNilWhenFileAbsent() {
        XCTAssertNil(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: nil,
                identifier: "bough"
            )
        )
    }

    // MARK: - Minimal-diff merge preserves user formatting (#105 / #106 / #119)

    func testMergeOpencodePluginRefPreservesJSONCCommentsAndKeyOrder() throws {
        let original = """
        {
          // Default model
          "model": "github-copilot/gpt-5.4",
          "permission": {
            "bash": "allow"
          },
          "plugin": ["file:///old/other-plugin.js"]
        }

        """ // trailing blank line emulates user's EOF newline
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
        // Comment survives.
        XCTAssertTrue(merged.contains("// Default model"), "JSONC comment must survive minimal-diff merge")
        // Slashes not escaped.
        XCTAssertFalse(merged.contains("\\/"), "Slashes must not be escaped as \\/")
        // Key order: model → permission → plugin (unchanged from original)
        let modelIdx = try XCTUnwrap(merged.range(of: "\"model\""))
        let permIdx = try XCTUnwrap(merged.range(of: "\"permission\""))
        let pluginIdx = try XCTUnwrap(merged.range(of: "\"plugin\""))
        XCTAssertTrue(modelIdx.lowerBound < permIdx.lowerBound)
        XCTAssertTrue(permIdx.lowerBound < pluginIdx.lowerBound)
        // New plugin ref added, old other-plugin kept.
        XCTAssertTrue(merged.contains("file:///tmp/bough-opencode.js"))
        XCTAssertTrue(merged.contains("file:///old/other-plugin.js"))
    }

    func testMergeOpencodePluginRefPreservesUnrelatedEnvAndApiKey() throws {
        // #119: ANTHROPIC_API_KEY and other env entries must NOT vanish across an install.
        let original = """
        {
          "env": {
            "ANTHROPIC_API_KEY": "sk-super-secret",
            "MAX_MCP_OUTPUT_TOKENS": "200000"
          },
          "autoMemoryEnabled": false,
          "plugin": []
        }
        """
        let merged = try XCTUnwrap(
            ConfigInstaller.mergeOpencodePluginRef(
                originalContents: original,
                pluginRef: "file:///tmp/bough-opencode.js",
                identifier: "bough"
            )
        )
        XCTAssertTrue(merged.contains("\"ANTHROPIC_API_KEY\": \"sk-super-secret\""),
                      "User's API key must survive the install")
        XCTAssertTrue(merged.contains("\"MAX_MCP_OUTPUT_TOKENS\": \"200000\""))
        XCTAssertTrue(merged.contains("\"autoMemoryEnabled\": false"))
        XCTAssertTrue(merged.contains("file:///tmp/bough-opencode.js"))
    }

    func testRemoveOpencodePluginRefPreservesOriginalFormatting() throws {
        let original = """
        {
          "model": "sonnet",
          "plugin": ["file:///tmp/bough-opencode.js", "file:///user/other.js"],
          "autoshare": false
        }

        """
        let cleaned = try XCTUnwrap(
            ConfigInstaller.removeOpencodePluginRef(
                originalContents: original,
                identifier: "bough"
            )
        )
        XCTAssertTrue(cleaned.contains("\"model\": \"sonnet\""))
        XCTAssertTrue(cleaned.contains("file:///user/other.js"))
        XCTAssertFalse(cleaned.contains("file:///tmp/bough-opencode.js"))
        XCTAssertFalse(cleaned.contains("\\/"), "No slash escaping")
    }

    func testOpencodeEffectiveConfigPathPrefersJsoncThenJsonThenLegacyConfig() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConfigInstallerOpencode-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertEqual(
            ConfigInstaller.opencodeEffectiveConfigPath(configDir: dir.path, fm: fm),
            dir.appendingPathComponent("opencode.json").path
        )

        let legacy = dir.appendingPathComponent("config.json")
        fm.createFile(atPath: legacy.path, contents: Data("{}".utf8))
        XCTAssertEqual(ConfigInstaller.opencodeEffectiveConfigPath(configDir: dir.path, fm: fm), legacy.path)

        let json = dir.appendingPathComponent("opencode.json")
        fm.createFile(atPath: json.path, contents: Data("{}".utf8))
        XCTAssertEqual(ConfigInstaller.opencodeEffectiveConfigPath(configDir: dir.path, fm: fm), json.path)

        let jsonc = dir.appendingPathComponent("opencode.jsonc")
        fm.createFile(atPath: jsonc.path, contents: Data("{} // comment".utf8))
        XCTAssertEqual(ConfigInstaller.opencodeEffectiveConfigPath(configDir: dir.path, fm: fm), jsonc.path)
    }

    func testInstallOpencodePluginUsesLocalAutoloadOnly() throws {
        let source = try sourceFile("Sources/Bough/ConfigInstaller.swift")
        let body = try sourceSlice(
            source,
            from: "private static func installOpencodePlugin",
            to: "private static func uninstallOpencodePlugin"
        )

        XCTAssertTrue(body.contains("OpenCode auto-loads local plugins"))
        XCTAssertTrue(body.contains("removeOpencodePluginRef"))
        XCTAssertFalse(body.contains("mergeOpencodePluginRef("))
        XCTAssertFalse(body.contains("pluginRef"))
    }

    func testOpencodeInstalledStateUsesLocalAutoloadPluginFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConfigInstallerOpencodeInstalled-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let plugin = dir.appendingPathComponent("plugins/bough-opencode.js")
        let config = dir.appendingPathComponent("opencode.json")
        try fm.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// version: v4\nexport default {}\n".utf8).write(to: plugin)
        try Data(#"{"model":"anthropic/claude-sonnet-4"}"#.utf8).write(to: config)

        XCTAssertTrue(ConfigInstaller.testIsOpencodePluginInstalled(
            pluginPath: plugin.path,
            configPaths: [config.path],
            fm: fm
        ))
    }

    func testOpencodeInstalledStateStillAcceptsLegacyConfigRefWhenPluginIsCurrent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConfigInstallerOpencodeLegacyInstalled-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let plugin = dir.appendingPathComponent("plugins/bough-opencode.js")
        let config = dir.appendingPathComponent("opencode.json")
        try fm.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// version: v4\nexport default {}\n".utf8).write(to: plugin)
        try Data(#"{"plugin":["file:///tmp/bough-opencode.js"]}"#.utf8).write(to: config)

        XCTAssertTrue(ConfigInstaller.testIsOpencodePluginInstalled(
            pluginPath: plugin.path,
            configPaths: [config.path],
            fm: fm
        ))
    }

    func testOpencodeInstalledStateRejectsOutdatedLocalPlugin() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ConfigInstallerOpencodeOutdated-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let plugin = dir.appendingPathComponent("plugins/bough-opencode.js")
        let config = dir.appendingPathComponent("opencode.json")
        try fm.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// version: v3\nexport default {}\n".utf8).write(to: plugin)
        try Data(#"{"plugin":["file:///tmp/bough-opencode.js"]}"#.utf8).write(to: config)

        XCTAssertFalse(ConfigInstaller.testIsOpencodePluginInstalled(
            pluginPath: plugin.path,
            configPaths: [config.path],
            fm: fm
        ))
    }

    func testOpencodeBundledPluginIsESM() throws {
        let source = try sourceFile("Sources/Bough/Resources/bough-opencode.js")

        XCTAssertTrue(source.contains("import { execFile, execSync } from \"child_process\";"))
        XCTAssertTrue(source.contains("import { connect } from \"net\";"))
        XCTAssertFalse(source.contains("require("))
    }

    func testHookScriptAndBridgeInstallEnsureBoughDirectory() throws {
        let source = try sourceFile("Sources/Bough/ConfigInstaller.swift")
        let hookScriptBody = try sourceSlice(
            source,
            from: "private static func installHookScript",
            to: "private static func installBridgeBinary"
        )
        let bridgeBody = try sourceSlice(
            source,
            from: "private static func installBridgeBinary",
            to: "private static func stripQuarantine"
        )

        XCTAssertTrue(hookScriptBody.contains("BoughPrivateStorage.ensurePrivateDirectory"))
        XCTAssertTrue(bridgeBody.contains("BoughPrivateStorage.ensurePrivateDirectory"))
    }
}
