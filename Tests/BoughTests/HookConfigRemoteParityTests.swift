import XCTest
@testable import Bough

final class HookConfigRemoteParityTests: XCTestCase {
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

    func testLocalAndRemoteCodexHooksMutationStayEquivalentForApprovedFixtures() throws {
        let fixtures: [CodexConfigParityFixture] = [
            .init(
                name: "absent config with detection failure",
                original: nil,
                detectedVersion: nil
            ),
            .init(
                name: "detection failure strips deprecated false while preserving unrelated keys",
                original: """
                model = "gpt-5"

                [features]
                unrelated = true
                codex_hooks=false # user disabled this explicitly
                """,
                detectedVersion: nil
            ),
            .init(
                name: "old Codex preserves deprecated key alongside hooks",
                original: "[features]\ncodex_hooks = false\n",
                detectedVersion: "0.129.5"
            ),
            .init(
                name: "existing hooks wins over deprecated key",
                original: "[features]\nhooks = false\ncodex_hooks = true\n",
                detectedVersion: nil
            ),
            .init(
                name: "malformed TOML remains byte-identical",
                original: "[features\ncodex_hooks = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML with valid header remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken =\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML numeric value remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 1x\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML unterminated array remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = [\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML trailing decimal remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 1.\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML trailing numeric underscore remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 1_\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML leading zero integer remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 01\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML leading zero float remains byte-identical",
                original: "[features]\ncodex_hooks = true\nnum = 01.0\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML leading zero exponent float remains byte-identical",
                original: "[features]\ncodex_hooks = true\nnum = 01e2\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML signed leading zero float remains byte-identical",
                original: "[features]\ncodex_hooks = true\nnum = +01.0\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML empty hexadecimal remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 0x_\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML signed hexadecimal remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = +0x1\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML invalid date remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = 2026-99-99\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML invalid string escape remains byte-identical",
                original: #"[features]\ncodex_hooks = true\nbroken = "\q"\n"#.replacingOccurrences(of: "\\n", with: "\n"),
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML surrogate unicode escape remains byte-identical",
                original: "[features]\ncodex_hooks = true\ndescription = \"\\uD800\"\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML multiline string invalid escape after hash remains byte-identical",
                original: #"""
                [features]
                description = """
                # \q
                """
                codex_hooks = true
                """#,
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML duplicate key remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = false\nbroken = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML inline table duplicate key remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = { key = true, key = false }\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML inline table dotted key conflict remains byte-identical",
                original: "[features]\ncodex_hooks = true\nbroken = { a = { b = 1 }, a.b = 2 }\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML dotted key implicit table redeclaration remains byte-identical",
                original: "a.b = 1\n[a]\nc = 2\n[features]\ncodex_hooks = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML dotted key table overwrite remains byte-identical",
                original: "a.b = 1\n[a]\nb = 2\n[features]\ncodex_hooks = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "valid parent table after child table stays editable",
                original: """
                [a.b]
                c = 1

                [a]
                d = 2

                [features]
                codex_hooks = true
                """,
                detectedVersion: nil
            ),
            .init(
                name: "malformed TOML array table then normal table redeclaration remains byte-identical",
                original: "[[a]]\nb = 1\n[a]\nc = 2\n[features]\ncodex_hooks = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "malformed TOML normal table then array table redeclaration remains byte-identical",
                original: "[a]\nb = 1\n[[a]]\nc = 2\n[features]\ncodex_hooks = true\n",
                detectedVersion: nil,
                comparison: .exact
            ),
            .init(
                name: "valid repeated array table stays editable",
                original: """
                [[a]]
                b = 1

                [[a]]
                b = 2

                [features]
                codex_hooks = true
                """,
                detectedVersion: nil
            ),
            .init(
                name: "valid multiline basic string stays editable",
                original: #"""
                [features]
                description = """
                line
                """
                codex_hooks = true
                """#,
                detectedVersion: nil
            ),
            .init(
                name: "valid multiline basic string continuation stays editable",
                original: "[features]\ndescription = \"\"\"a\\\n  b\"\"\"\ncodex_hooks = true\n",
                detectedVersion: nil
            ),
            .init(
                name: "valid multiline literal string stays editable",
                original: """
                [features]
                description = '''
                line
                '''
                codex_hooks = true
                """,
                detectedVersion: nil
            ),
            .init(
                name: "valid multiline string inside array stays editable",
                original: #"""
                [features]
                values = [
                  """
                  line, still one value
                  """,
                  "tail"
                ]
                codex_hooks = true
                """#,
                detectedVersion: nil
            ),
            .init(
                name: "valid multiline basic string continuation inside array stays editable",
                original: "[features]\nvalues = [\"\"\"a\\\n  b\"\"\", \"tail\"]\ncodex_hooks = true\n",
                detectedVersion: nil
            ),
            .init(
                name: "nested array values stay inside features table",
                original: """
                [features]
                matrix = [
                  ["a"]
                ]
                codex_hooks = false
                """,
                detectedVersion: nil
            ),
            .init(
                name: "valid scalar and container values stay editable",
                original: #"""
                # comment with """ and ''' delimiter-looking text
                [features]
                count = 1_000
                hex = 0x1
                scalar = "\\uE000"
                escaped = "a \\\"quoted\\\" label"
                basic_delimiter = "'''"
                literal_delimiter = '"""'
                ratio = 1.5
                signed_ratio = -1.5
                started_at = 2026-05-22T10:30:45Z
                local_time = 10:30:45.123
                day = 2026-05-22
                label = "line\\n"
                alpha.beta = true
                values = [1, "two", { key = true }]
                codex_hooks = true
                """#,
                detectedVersion: nil
            ),
            .init(
                name: "missing features table appends current hooks flag",
                original: "model = \"gpt-5-codex\"\n",
                detectedVersion: "0.130.0"
            ),
        ]

        for fixture in fixtures {
            let local = try localCodexConfig(after: fixture.original, detectedVersion: fixture.detectedVersion)
            let remote = try remoteCodexConfig(after: fixture.original, detectedVersion: fixture.detectedVersion)
            switch fixture.comparison {
            case .exact:
                XCTAssertEqual(local, remote, fixture.name)
            case .ignoringOuterNewlines:
                XCTAssertEqual(
                    local.normalizedOuterNewlinesForParity,
                    remote.normalizedOuterNewlinesForParity,
                    fixture.name
                )
            }
        }
    }

    private func localCodexConfig(after original: String?, detectedVersion: String?) throws -> String {
        let root = temporaryRoot(named: "local")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        if let original {
            try original.write(to: config, atomically: true, encoding: .utf8)
        }

        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }
        setenv("CODEX_HOME", root.path, 1)
        _ = ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion(detectedVersion)

        return try String(contentsOf: config, encoding: .utf8)
    }

    private func remoteCodexConfig(after original: String?, detectedVersion: String?) throws -> String {
        let root = temporaryRoot(named: "remote")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let config = codexHome.appendingPathComponent("config.toml")
        if let original {
            try original.write(to: config, atomically: true, encoding: .utf8)
        }

        var pathPrefix: URL?
        var codexCandidatePaths = ""
        if let detectedVersion {
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let codex = bin.appendingPathComponent("codex")
            try """
            #!/bin/sh
            echo "codex-cli \(detectedVersion)"
            """.write(to: codex, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
            pathPrefix = bin
            codexCandidatePaths = codex.path
        }

        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        try runPython(
            RemoteInstaller.configureRemoteHooksScript(host: host),
            home: root,
            pathPrefix: pathPrefix,
            environment: [
                "BOUGH_CODEX_CANDIDATE_PATHS": codexCandidatePaths,
                "BOUGH_CODEX_APP_RESOURCES_PATH": root.appendingPathComponent("missing-app-resource-codex").path,
            ]
        )

        return try String(contentsOf: config, encoding: .utf8)
    }

    private func temporaryRoot(named suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bough-codex-parity-\(suffix)-\(UUID().uuidString)", isDirectory: true)
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

private struct CodexConfigParityFixture {
    let name: String
    let original: String?
    let detectedVersion: String?
    var comparison: CodexConfigParityComparison = .ignoringOuterNewlines
}

private enum CodexConfigParityComparison {
    case exact
    case ignoringOuterNewlines
}

private extension String {
    var normalizedOuterNewlinesForParity: String {
        trimmingCharacters(in: CharacterSet.newlines)
    }
}
