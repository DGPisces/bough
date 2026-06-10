import XCTest
@testable import Bough

final class RemoteHookSecurityTests: XCTestCase {
    func testRemoteSocketPathIsHostPrivate() {
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")

        XCTAssertNotEqual(host.remoteSocketPath, "/tmp/bough.sock")
        XCTAssertTrue(host.remoteSocketPath.contains(host.id))
        XCTAssertTrue(host.remoteSocketPath.hasPrefix("/tmp/bough-"))
        XCTAssertTrue(host.remoteSocketPath.hasSuffix("/hook.sock"))
    }

    func testSSHForwardingDoesNotExposeRemoteSocketToOtherUsers() throws {
        let source = try readRepoFile("Sources/Bough/SSHForwarder.swift")

        XCTAssertFalse(source.contains("StreamLocalBindMask=0000"))
        XCTAssertTrue(source.contains("StreamLocalBindMask=0177"))
    }

    func testRemoteHostRejectsSSHOptionLikeDestination() {
        let optionHost = RemoteHost(id: "host-1", name: "bad", host: "-oProxyCommand=touch /tmp/pwn")
        let optionUser = RemoteHost(id: "host-2", name: "bad-user", host: "example.com", user: "-lroot")
        let controlHost = RemoteHost(id: "host-3", name: "bad-control", host: "example.com\n-oProxyCommand=x")
        let good = RemoteHost(id: "host-4", name: "good", host: "example.com", user: "dev")

        XCTAssertNil(optionHost.validatedSSHTarget)
        XCTAssertNil(optionUser.validatedSSHTarget)
        XCTAssertNil(controlHost.validatedSSHTarget)
        XCTAssertEqual(good.validatedSSHTarget, "dev@example.com")
    }

    func testSSHArgumentsTerminateOptionsBeforeRemoteDestination() throws {
        let installer = try readRepoFile("Sources/Bough/RemoteInstaller.swift")
        let forwarder = try readRepoFile("Sources/Bough/SSHForwarder.swift")
        let manager = try readRepoFile("Sources/Bough/RemoteManager.swift")

        XCTAssertTrue(installer.contains(#"guard host.validatedSSHTarget != nil"#))
        XCTAssertTrue(installer.contains(#"args += ["--", target]"#))
        XCTAssertTrue(forwarder.contains(#"guard host.validatedSSHTarget != nil"#))
        XCTAssertTrue(forwarder.contains(#"args += ["--", target]"#))
        XCTAssertTrue(manager.contains(#"guard host.validatedSSHTarget != nil"#))
    }

    func testSSHForwarderDoesNotFailConnectingStateOnStderrWarnings() throws {
        let source = try readRepoFile("Sources/Bough/SSHForwarder.swift")
        let monitor = try XCTUnwrap(source.components(separatedBy: "private func startStderrMonitor").last)

        XCTAssertTrue(source.contains("pendingStderrMessage"))
        XCTAssertTrue(monitor.contains("self.pendingStderrMessage = message"))
        XCTAssertFalse(monitor.contains("self.status = .failed(message)"))
    }

    func testSSHForwarderDisconnectHasKillFallback() throws {
        let source = try readRepoFile("Sources/Bough/SSHForwarder.swift")

        XCTAssertTrue(source.contains("process.terminate()"))
        XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 1)"))
        XCTAssertTrue(source.contains("kill(processID, SIGKILL)"))
    }

    func testRemoteHookCommandShellQuotesHostMetadata() {
        let host = RemoteHost(
            id: "host-$(touch /tmp/id)",
            name: "dev`touch /tmp/name`box",
            host: "example.com"
        )

        let script = RemoteInstaller.configureRemoteHooksScript(host: host)

        XCTAssertTrue(script.contains("import shlex"))
        XCTAssertFalse(script.contains("BOUGH_REMOTE_HOST_NAME={json.dumps(host_name)}"))
        XCTAssertTrue(script.contains("shlex.quote(host_name)"))
        XCTAssertTrue(script.contains("shlex.quote(host_id)"))
    }

    func testBridgeGuardsUnixSocketPathLengthBeforeCopying() throws {
        let source = try readRepoFile("Sources/BoughBridge/main.swift")

        XCTAssertTrue(source.contains("MemoryLayout.size(ofValue: addr.sun_path)"))
        XCTAssertTrue(source.contains("utf8.count"))
        XCTAssertFalse(source.contains("strcpy(ptr, $0)"))
    }

    func testBridgeDebugLogUsesUserPrivateTempPath() throws {
        let source = try readRepoFile("Sources/BoughBridge/main.swift")

        XCTAssertFalse(source.contains(#""/tmp/bough-bridge.log""#))
        XCTAssertTrue(source.contains(#""/tmp/bough-bridge-\(getuid()).log""#))
        XCTAssertTrue(source.contains("O_NOFOLLOW"))
        XCTAssertTrue(source.contains("0o600"))
        XCTAssertTrue(source.contains("fchmod(fd, 0o600)"))
    }

    func testBridgeFallbackSessionIdUsesInferredSource() throws {
        let source = try readRepoFile("Sources/BoughBridge/main.swift")

        XCTAssertTrue(source.contains("let source = effectiveSource ?? sourceTag"))
        XCTAssertFalse(source.contains("let source = sourceTag"))
    }

    func testRemoteHookInstallPreservesExistingUserHooks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeSettings = root.appendingPathComponent(".claude/settings.json")
        let codexHooks = root.appendingPathComponent(".codex/hooks.json")
        let codebuddySettings = root.appendingPathComponent(".codebuddy/settings.json")
        try writeJSONHookFixture(to: claudeSettings, event: "UserPromptSubmit")
        try writeJSONHookFixture(to: codexHooks, event: "SessionStart")
        try writeJSONHookFixture(to: codebuddySettings, event: "Stop")

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        XCTAssertTrue(try jsonHookCommands(at: claudeSettings, event: "UserPromptSubmit").contains("echo user-hook"))
        XCTAssertTrue(try jsonHookCommands(at: codexHooks, event: "SessionStart").contains("echo user-hook"))
        XCTAssertTrue(try jsonHookCommands(at: codebuddySettings, event: "Stop").contains("echo user-hook"))
    }

    func testRemoteHookInstallParsesJSONCSettings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-hooks-jsonc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeSettings = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "model": "sonnet",
          // user hook must survive JSONC parsing
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo user-hook",
                    "timeout": 3
                  }
                ]
              }
            ]
          }
        }
        """.write(to: claudeSettings, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let commands = try jsonHookCommands(at: claudeSettings, event: "UserPromptSubmit")
        let updated = try String(contentsOf: claudeSettings, encoding: .utf8)
        XCTAssertTrue(updated.contains("// user hook must survive JSONC parsing"))
        XCTAssertLessThan(
            try XCTUnwrap(updated.range(of: #""model""#)?.lowerBound),
            try XCTUnwrap(updated.range(of: #""hooks""#)?.lowerBound)
        )
        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertTrue(commands.contains { $0.contains("bough-remote-hook.py") })
    }

    func testRemoteHookInstallTreatsNonObjectHooksAsEmpty() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-hooks-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeSettings = root.appendingPathComponent(".claude/settings.json")
        let codexHooks = root.appendingPathComponent(".codex/hooks.json")
        let codebuddySettings = root.appendingPathComponent(".codebuddy/settings.json")
        for (url, body) in [
            (claudeSettings, #"{"hooks":[]}"#),
            (codexHooks, #"{"hooks":"legacy"}"#),
            (codebuddySettings, #"{"hooks":[]}"#),
        ] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        XCTAssertFalse(try jsonHookCommands(at: claudeSettings, event: "UserPromptSubmit").isEmpty)
        XCTAssertFalse(try jsonHookCommands(at: codexHooks, event: "SessionStart").isEmpty)
        XCTAssertFalse(try jsonHookCommands(at: codebuddySettings, event: "UserPromptSubmit").isEmpty)
    }

    func testRemoteHookInstallWritesFullClaudeAndCodeBuddyEventSets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-claude-codebuddy-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeRoot = root.appendingPathComponent(".claude")
        let codebuddyRoot = root.appendingPathComponent(".codebuddy")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codebuddyRoot, withIntermediateDirectories: true)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let expectedEvents: Set<String> = [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PostToolUseFailure",
            "PermissionRequest",
            "Notification",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "SessionStart",
            "SessionEnd",
            "PreCompact",
        ]

        for settings in [
            claudeRoot.appendingPathComponent("settings.json"),
            codebuddyRoot.appendingPathComponent("settings.json"),
        ] {
            let hooks = try jsonHooks(at: settings)
            XCTAssertEqual(Set(hooks.keys), expectedEvents, settings.path)
            for event in expectedEvents {
                XCTAssertFalse(try jsonHookCommands(at: settings, event: event).isEmpty, event)
            }

            let permissionEntries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
            let permissionHook = try XCTUnwrap((permissionEntries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(permissionHook["timeout"] as? Int, 86400)
        }
    }

    func testRemotePythonHookIgnoresQuestionMarkTTY() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-remote-hook.py")

        XCTAssertTrue(source.contains(#"tty not in {"??", "?", "-"}"#))
    }

    func testRemoteHookJSONLPathEncodingMatchesLocalClients() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-jsonl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Claude Code encodes every non-alphanumeric character as "-",
        // including dots: /Users/me/foo.bar -> -Users-me-foo-bar.
        let claudeJSONL = root
            .appendingPathComponent(".claude/projects/-Users-me-foo-bar/session-1.jsonl")
        let codebuddyJSONL = root
            .appendingPathComponent(".codebuddy/projects/Users-me-project/session-2.jsonl")
        try FileManager.default.createDirectory(at: claudeJSONL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codebuddyJSONL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: claudeJSONL, atomically: true, encoding: .utf8)
        try "{}\n".write(to: codebuddyJSONL, atomically: true, encoding: .utf8)

        let hookPath = repoPath("Sources/Bough/Resources/bough-remote-hook.py")
        let output = try runPythonCapture(
            """
            import runpy
            ns = runpy.run_path(\(pythonStringLiteral(hookPath)))
            print(ns["_claude_jsonl_path"]("session-1", "/Users/me/foo.bar"))
            print(ns["_codebuddy_jsonl_path"]("session-2", "/Users/me/project"))
            """,
            home: root
        )
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertEqual(lines, [claudeJSONL.path, codebuddyJSONL.path])
    }

    func testRemoteHookWaitsForAckAndLongBlockingApproval() throws {
        let source = try readRepoFile("Sources/Bough/Resources/bough-remote-hook.py")

        XCTAssertTrue(source.contains("BLOCKING_RESPONSE_TIMEOUT_SECONDS = 86400"))
        XCTAssertTrue(source.contains("ACK_TIMEOUT_SECONDS = 3"))
        XCTAssertTrue(source.contains("sock.recv(65536)"))
    }

    func testRemoteInstallerDrainsSSHPipesBeforeWaitingForExit() throws {
        let source = try readRepoFile("Sources/Bough/RemoteInstaller.swift")
        let stdoutTaskRange = try XCTUnwrap(source.range(of: "let stdoutTask = Task.detached"))
        let waitRange = try XCTUnwrap(source.range(of: "ProcessRunner.waitUntilExitOrTerminate(process, timeout: timeout)"))

        XCTAssertLessThan(stdoutTaskRange.lowerBound, waitRange.lowerBound)
        XCTAssertTrue(source.contains("ssh timed out after"))
        XCTAssertTrue(source.contains("exitCode: exitedBeforeTimeout ? process.terminationStatus : -9"))
    }

    func testRemoteInstallerUsesHostAuthSocketEnvironment() throws {
        let source = try readRepoFile("Sources/Bough/RemoteInstaller.swift")

        XCTAssertTrue(source.contains("process.environment = sshEnvironment(host: host)"))
        XCTAssertTrue(source.contains(#"env["SSH_AUTH_SOCK"]"#))
        XCTAssertTrue(source.contains("expandingTildeInPath"))
    }

    func testRemoteHookInstallPreservesRemoteHookPrefixOnlyCommands() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-hooks-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeSettings = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "python3 ~/.bough/bough-remote-hook.py-old",
                    "timeout": 3
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "python3 /usr/local/bin/my-bough-remote-hook.py",
                    "timeout": 3
                  }
                ]
              }
            ]
          }
        }
        """.write(to: claudeSettings, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let commands = try jsonHookCommands(at: claudeSettings, event: "UserPromptSubmit")
        XCTAssertTrue(commands.contains("python3 ~/.bough/bough-remote-hook.py-old"))
        XCTAssertTrue(commands.contains("python3 /usr/local/bin/my-bough-remote-hook.py"))
    }

    func testRemoteHookInstallLeavesMalformedJSONConfigsByteIdentical() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-malformed-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeSettings = root.appendingPathComponent(".claude/settings.json")
        let codexHooks = root.appendingPathComponent(".codex/hooks.json")
        let codebuddySettings = root.appendingPathComponent(".codebuddy/settings.json")
        let malformed = #"{"hooks":"#
        for url in [claudeSettings, codexHooks, codebuddySettings] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try malformed.write(to: url, atomically: true, encoding: .utf8)
        }

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), malformed)
        XCTAssertEqual(try String(contentsOf: codexHooks, encoding: .utf8), malformed)
        XCTAssertEqual(try String(contentsOf: codebuddySettings, encoding: .utf8), malformed)
    }

    func testRemoteHookInstallWritesCurrentCodexHooksFeatureFlag() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features]\nhooks = true\n")
    }

    func testRemoteHookInstallWritesFullCodexEventSet() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexRoot = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let hooksURL = codexRoot.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: hooksURL)
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(rootJSON["hooks"] as? [String: Any])
        let expectedEvents: Set<String> = [
            "SessionStart",
            "SessionEnd",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
        ]

        XCTAssertEqual(Set(hooks.keys), expectedEvents)
        for event in expectedEvents {
            XCTAssertFalse(try jsonHookCommands(at: hooksURL, event: event).isEmpty, event)
        }

        let permissionEntries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let permissionHook = try XCTUnwrap((permissionEntries.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(permissionHook["timeout"] as? Int, 86400)
    }

    func testRemoteHookInstallMigratesDeprecatedCodexHooksFalseWhenVersionDetectionFails() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model = "gpt-5"

        [features]
        unrelated = true
        codex_hooks=false # user disabled this explicitly
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(
            migrated,
            """
            model = "gpt-5"

            [features]
            hooks = false
            unrelated = true

            """
        )
    }

    func testRemoteHookInstallParsesCodexCLINamePrefixedVersionOutput() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = true
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try """
        #!/bin/sh
        echo "codex-cli 0.130.0"
        """.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root, pathPrefix: bin)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features]\nhooks = true\n")
    }

    func testRemoteHookInstallPreservesDeprecatedCodexHooksOnOldNvmCodex() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let codex = root.appendingPathComponent(".nvm/versions/node/v20.0.0/bin/codex")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo "codex-cli 0.129.5"
        """.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(
            RemoteInstaller.configureRemoteHooksScript(host: host),
            home: root,
            environment: [
                "BOUGH_CODEX_APP_RESOURCES_PATH": root.appendingPathComponent("missing-app-resource-codex").path,
            ]
        )

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features]\nhooks = false\ncodex_hooks = false\n")
    }

    func testRemoteHookInstallStripsDeprecatedCodexHooksWhenOldNvmAndCurrentAppResourceExist() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = true
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let oldNvmCodex = root.appendingPathComponent(".nvm/versions/node/v20.0.0/bin/codex")
        try FileManager.default.createDirectory(at: oldNvmCodex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo "codex-cli 0.129.5"
        """.write(to: oldNvmCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldNvmCodex.path)

        let currentAppResourceCodex = root.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
        try FileManager.default.createDirectory(at: currentAppResourceCodex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo "codex-cli 0.130.0"
        """.write(to: currentAppResourceCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: currentAppResourceCodex.path)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(
            RemoteInstaller.configureRemoteHooksScript(host: host),
            home: root,
            environment: [
                "BOUGH_CODEX_APP_RESOURCES_PATH": currentAppResourceCodex.path,
            ]
        )

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features]\nhooks = true\n")
    }

    func testRemoteHookInstallLeavesMalformedCodexTomlByteIdentical() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        [features
        codex_hooks = true
        """
        try original.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        let output = try runPythonCapture(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, original)
        XCTAssertTrue(output.contains("Codex skipped: config.toml not enabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/hooks.json").path))
    }

    func testRemoteHookInstallLeavesMalformedTraecliYAMLByteIdentical() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-traecli-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let traecliConfig = root.appendingPathComponent(".trae/traecli.yaml")
        try FileManager.default.createDirectory(
            at: traecliConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "model: [\nhooks: []"
        try original.write(to: traecliConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        let output = try runPythonCapture(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        XCTAssertEqual(try String(contentsOf: traecliConfig, encoding: .utf8), original)
        XCTAssertTrue(output.contains("Traecli skipped: invalid YAML"))
    }

    func testRemoteHookScansNestedMessageJSONLContentParts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-jsonl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jsonl = root.appendingPathComponent("session.jsonl")
        try """
        {"type":"summary","message":{"content":[{"type":"text","text":"Nested session title"}]}}
        {"type":"message","message":{"role":"user","content":[{"type":"input_text","text":"Nested user prompt"}]}}
        {"type":"message","message":{"role":"assistant","content":[{"type":"output_text","text":"Nested assistant reply"}]}}
        """.write(to: jsonl, atomically: true, encoding: .utf8)

        let hookPath = repoPath("Sources/Bough/Resources/bough-remote-hook.py")
        let output = try runPythonCapture(
            """
            import importlib.util, json
            spec = importlib.util.spec_from_file_location("bough_remote_hook", \(pythonStringLiteral(hookPath)))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            print(json.dumps(mod._scan_session_jsonl(\(pythonStringLiteral(jsonl.path))), sort_keys=True))
            """,
            home: root
        )
        let data = try XCTUnwrap(output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(result["session_title"], "Nested session title")
        XCTAssertEqual(result["last_user_message"], "Nested user prompt")
        XCTAssertEqual(result["last_assistant_message"], "Nested assistant reply")
    }

    func testRemoteHookInstallKeepsExistingCodexHooksValueOverDeprecatedKey() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        hooks = false
        codex_hooks = true
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features]\nhooks = false\n")
    }

    func testRemoteHookInstallRecognizesFeaturesHeaderWithComment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features] # user comment
        codex_hooks = true
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[features] # user comment\nhooks = true\n")
    }

    func testRemoteHookInstallRecognizesFeaturesHeaderWithWhitespaceAndComment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [ features ] # user comment
        codex_hooks = false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, "[ features ] # user comment\nhooks = false\n")
    }

    func testRemoteHookInstallStopsParsingFeaturesAtArrayTableBoundary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = true

        [[profiles]]
        hooks = false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(
            migrated,
            """
            [features]
            hooks = true

            [[profiles]]
            hooks = false

            """
        )
    }

    func testRemoteHookInstallStopsParsingFeaturesAtQuotedProjectTableWithHash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = true

        [projects."/tmp/a#b"]
        hooks = false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        // The project-local hooks = false must not be mistaken for [features].hooks.
        XCTAssertEqual(
            migrated,
            """
            [features]
            hooks = true

            [projects."/tmp/a#b"]
            hooks = false

            """
        )
    }

    func testRemoteHookInstallStopsParsingFeaturesAtQuotedArrayTableWithComment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        codex_hooks = true

        [[projects."/tmp/example-profile".profiles]] # user comment
        hooks = false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(
            migrated,
            """
            [features]
            hooks = true

            [[projects."/tmp/example-profile".profiles]] # user comment
            hooks = false

            """
        )
    }

    func testRemoteHookInstallDoesNotTreatNestedArrayValuesAsFeatureSectionHeaders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bough-remote-codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [features]
        matrix = [
          [1, 2],
          [3, 4]
        ]
        codex_hooks=false
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(
            migrated,
            """
            [features]
            hooks = false
            matrix = [
              [1, 2],
              [3, 4]
            ]

            """
        )
    }

    private func readRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOfFile: repoPath(relativePath), encoding: .utf8)
    }

    private func repoPath(_ relativePath: String) -> String {
        TestHelpers.repoRoot(from: #filePath)
            .appendingPathComponent(relativePath)
            .path
    }

    private func writeJSONHookFixture(to url: URL, event: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture: [String: Any] = [
            "hooks": [
                event: [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": "echo user-hook",
                                "timeout": 3,
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func jsonHookCommands(at url: URL, event: String) throws -> [String] {
        let hooks = try jsonHooks(at: url)
        let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
        return entries.flatMap { entry -> [String] in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return [] }
            return nested.compactMap { $0["command"] as? String }
        }
    }

    private func jsonHooks(at url: URL) throws -> [String: Any] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let stripped = stripJSONComments(text)
        let data = try XCTUnwrap(stripped.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hooks"] as? [String: Any])
    }

    private func stripJSONComments(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let ch = chars[i]
            if inString {
                result.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if ch == "\"" {
                inString = true
                result.append(ch)
                i += 1
                continue
            }
            if ch == "/", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i = min(i + 2, chars.count)
                    continue
                }
            }
            result.append(ch)
            i += 1
        }
        return result
    }

    private func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func runPythonCapture(
        _ script: String,
        home: URL,
        pathPrefix: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let path = pathPrefix.map { "\($0.path):\(defaultPath)" } ?? defaultPath
        var processEnvironment = [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "PATH": path,
        ]
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
        return output
    }

    private func runPython(
        _ script: String,
        home: URL,
        pathPrefix: URL? = nil,
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let path = pathPrefix.map { "\($0.path):\(defaultPath)" } ?? defaultPath
        var processEnvironment = [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "PATH": path,
        ]
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
    }
}
