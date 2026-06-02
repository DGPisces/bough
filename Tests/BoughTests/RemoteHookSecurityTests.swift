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
        try runPython(RemoteInstaller.configureRemoteHooksScript(host: host), home: root)

        let migrated = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertEqual(migrated, original)
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
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
        return entries.flatMap { entry -> [String] in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return [] }
            return nested.compactMap { $0["command"] as? String }
        }
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
