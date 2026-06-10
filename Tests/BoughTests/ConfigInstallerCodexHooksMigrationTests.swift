import XCTest
@testable import Bough

final class ConfigInstallerCodexHooksMigrationTests: XCTestCase {
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

    private var nestedArrayFeatureFixture: String {
        """
        [features]
        matrix = [
          ["a"]
        ]
        codex_hooks = false
        """
    }

    func testMigrationCreatesHooksTrueWhenConfigFileIsAbsent() throws {
        try withTemporaryCodexHome { _, config in
            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("[features]"))
            XCTAssertTrue(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationAppendsFeaturesTableWhenMissing() throws {
        try withTemporaryCodexHome { _, config in
            try write("model = \"gpt-5-codex\"\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("model = \"gpt-5-codex\""))
            XCTAssertTrue(migrated.contains("[features]"))
            XCTAssertTrue(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationReplacesCodexHooksTrueWithHooksTrue() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationPreservesCodexHooksFalseIntent() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = false\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("hooks = false"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationPreservesCodexHooksFalseIntentWithTightEqualsSpacing() throws {
        for assignment in ["codex_hooks=false", "codex_hooks= false", "codex_hooks =false"] {
            try withTemporaryCodexHome { _, config in
                try write("[features]\n\(assignment)\n", to: config)

                XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

                let migrated = try read(config)
                XCTAssertTrue(migrated.contains("hooks = false"), "Failed to preserve false for \(assignment)")
                XCTAssertFalse(migrated.contains("codex_hooks"))
            }
        }
    }

    func testMigrationKeepsExistingHooksValueWhenBothKeysArePresent() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\nhooks = false\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("hooks = false"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationPreservesExistingHooksLineFormattingWhenRemovingCodexHooks() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\nhooks = false # keep this comment\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertEqual(migrated, "[features]\nhooks = false # keep this comment\n")
        }
    }

    func testMigrationPreservesUnrelatedFeatureKeys() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\nfoo = \"bar\"\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("foo = \"bar\""))
            XCTAssertTrue(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationAcceptsQuotedPluginAndProjectTables() throws {
        try withTemporaryCodexHome { _, config in
            let original = """
                [plugins."gmail@openai-curated"]
                enabled = true

                [projects."/tmp/example-project"]
                trust_level = "trusted"

                [features]
                codex_hooks = true
                """
            try write(original, to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("[plugins.\"gmail@openai-curated\"]"))
            XCTAssertTrue(migrated.contains("[projects.\"/tmp/example-project\"]"))
            XCTAssertTrue(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationDoesNotTreatTableLocalHooksAsFeatureHooks() throws {
        try withTemporaryCodexHome { _, config in
            let original = """
                [features]
                codex_hooks = true

                [plugins."example"]
                hooks = false
                """
            try write(original, to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("[features]\nhooks = true"))
            XCTAssertTrue(migrated.contains("[plugins.\"example\"]\nhooks = false"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationAcceptsLiteralQuotedAndArrayTableHeadersWithComments() throws {
        try withTemporaryCodexHome { _, config in
            let original = """
                ['literal plugin'.settings] # legal quoted table
                value = true

                [[projects."/tmp/example-project".profiles]] # legal array table
                name = "default"

                [features]
                codex_hooks = false
                """
            try write(original, to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("['literal plugin'.settings] # legal quoted table"))
            XCTAssertTrue(migrated.contains("[[projects.\"/tmp/example-project\".profiles]] # legal array table"))
            XCTAssertTrue(migrated.contains("hooks = false"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationRecognizesFeaturesHeaderWithComment() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features] # user comment\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertEqual(migrated, "[features] # user comment\nhooks = true\n")
        }
    }

    func testMigrationRecognizesFeaturesHeaderWithWhitespaceAndComment() throws {
        try withTemporaryCodexHome { _, config in
            try write("[ features ] # user comment\ncodex_hooks = false\n", to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertEqual(migrated, "[ features ] # user comment\nhooks = false\n")
        }
    }

    func testMigrationDoesNotRejectMultilineArrayValuesThatStartWithBracket() throws {
        try withTemporaryCodexHome { _, config in
            let original = """
                matrix = [
                  [1, 2],
                  [3, 4],
                ]

                [features]
                codex_hooks = true
                """
            try write(original, to: config)

            XCTAssertTrue(ConfigInstaller.testMigrateCodexHooksKey())

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("matrix = [\n  [1, 2],\n  [3, 4],\n]"))
            XCTAssertTrue(migrated.contains("[features]\nhooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testMigrationRemovesCodexHooksAfterNestedArrayWhenVersionDetectionFails() throws {
        try withTemporaryCodexHome { _, config in
            try write(nestedArrayFeatureFixture, to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion(nil))

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("matrix = [\n  [\"a\"]\n]"))
            XCTAssertTrue(migrated.contains("hooks = false"))
            XCTAssertFalse(migrated.contains("hooks = true"))
            XCTAssertFalse(migrated.contains("codex_hooks"))
        }
    }

    func testPreserveBranchKeepsCodexHooksAfterNestedArrayOnOlderCodex() throws {
        try withTemporaryCodexHome { _, config in
            try write(nestedArrayFeatureFixture, to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.129.5"))

            let migrated = try read(config)
            XCTAssertTrue(migrated.contains("matrix = [\n  [\"a\"]\n]"))
            XCTAssertTrue(migrated.contains("hooks = false"))
            XCTAssertFalse(migrated.contains("hooks = true"))
            XCTAssertTrue(migrated.contains("codex_hooks = false"))
        }
    }

    func testCodexHooksFeatureDisabledRecognizesFeaturesHeaderWithComment() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features] # user comment\nhooks = false\n", to: config)

            XCTAssertTrue(ConfigInstaller.codexHooksFeatureDisabled(fm: FileManager.default))
        }
    }

    func testCodexHooksFeatureDisabledReadsCodexHooksFalseAfterNestedArray() throws {
        try withTemporaryCodexHome { _, config in
            try write(nestedArrayFeatureFixture, to: config)

            XCTAssertTrue(ConfigInstaller.codexHooksFeatureDisabled(fm: FileManager.default))
        }
    }

    func testCodexHooksFeatureDisabledPrefersHooksKeyOverDeprecatedKey() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\nhooks = true\ncodex_hooks = false\n", to: config)

            XCTAssertFalse(ConfigInstaller.codexHooksFeatureDisabled(fm: FileManager.default))
        }
    }

    func testMigrationRefusesMalformedTomlWithoutClobberingFile() throws {
        try withTemporaryCodexHome { _, config in
            let original = "[features\ncodex_hooks = true\n"
            try write(original, to: config)

            XCTAssertFalse(ConfigInstaller.testMigrateCodexHooksKey())
            XCTAssertEqual(try read(config), original)
        }
    }

    func testMigrationDoesNotLeaveTruncatedFileWhenWriteFails() throws {
        try withTemporaryCodexHome { home, config in
            try write("[features]\ncodex_hooks = true\n", to: config)
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            XCTAssertFalse(ConfigInstaller.testMigrateCodexHooksKey())
            XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        }
    }

    // MARK: - Version-guard tests (Plan 15-03)

    func testCodexVersionParserExtractsSemverFromCurrentCLIOutput() {
        XCTAssertEqual(
            ConfigInstaller.codexVersion(fromVersionOutput: "codex-cli 0.130.0\n"),
            "0.130.0"
        )
        XCTAssertEqual(
            ConfigInstaller.codexVersion(fromVersionOutput: "codex-cli 0.131.0-alpha.9\n"),
            "0.131.0"
        )
        XCTAssertEqual(
            ConfigInstaller.codexVersion(fromVersionOutput: "0.130.0 (Codex CLI)\n"),
            "0.130.0"
        )
        XCTAssertNil(ConfigInstaller.codexVersion(fromVersionOutput: "codex-cli unknown\n"))
    }

    func testMigrationPreservesCodexHooksKeyOnOlderCodexCLI() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.129.5"))

            let result = try read(config)
            XCTAssertTrue(result.contains("codex_hooks = true"), "codex_hooks must be preserved on older CLI")
            XCTAssertTrue(result.contains("hooks = true"), "hooks = true must be added alongside")
        }
    }

    func testMigrationRemovesCodexHooksKeyWhenVersionDetectionFails() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion(nil))

            let result = try read(config)
            XCTAssertFalse(result.contains("codex_hooks"), "codex_hooks must be removed when detection fails")
            XCTAssertTrue(result.contains("hooks = true"), "hooks = true must preserve the legacy value when detection fails")
        }
    }

    func testMigrationPreservesFalseIntentWhenVersionDetectionFails() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = false\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion(nil))

            let result = try read(config)
            XCTAssertFalse(result.contains("codex_hooks"), "codex_hooks must be removed when detection fails")
            XCTAssertTrue(result.contains("hooks = false"), "hooks = false must preserve the legacy value when detection fails")
        }
    }

    func testMigrationRemovesCodexHooksKeyWhenCodexVersionIsCurrent() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.130.0"))

            let result = try read(config)
            XCTAssertFalse(result.contains("codex_hooks"), "codex_hooks must be removed on >= 0.130.0 CLI")
            XCTAssertTrue(result.contains("hooks = true"), "hooks = true must be present on current CLI")
        }
    }

    func testMigrationRemovesCodexHooksKeyWhenCodexVersionIsCurrentRelease() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ngoals = true\ncodex_hooks = true\nmemories = true\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.133.0"))

            let result = try read(config)
            XCTAssertTrue(result.contains("hooks = true"), "hooks = true must be present on current CLI")
            XCTAssertTrue(result.contains("goals = true"), "unrelated feature keys must survive migration")
            XCTAssertTrue(result.contains("memories = true"), "unrelated feature keys must survive migration")
            XCTAssertFalse(result.contains("codex_hooks"), "codex_hooks must be removed on current release CLI")
        }
    }

    func testCodexAppServerRestartStatusFlagsProcessesOlderThanConfig() {
        let configDate = Date(timeIntervalSince1970: 1_800_000_000)
        let olderProcess = ConfigInstaller.CodexAppServerProcessStart(
            pid: 101,
            startDate: configDate.addingTimeInterval(-60)
        )
        let newerProcess = ConfigInstaller.CodexAppServerProcessStart(
            pid: 202,
            startDate: configDate.addingTimeInterval(60)
        )

        let status = ConfigInstaller.codexAppServerRestartStatus(
            configModificationDate: configDate,
            processStarts: [olderProcess, newerProcess]
        )

        XCTAssertEqual(status.runningPIDs, [101, 202])
        XCTAssertEqual(status.stalePIDs, [101])
        XCTAssertTrue(status.needsRestart)
    }

    func testMigrationPreservesCodexHooksFalseOnOlderCLI() throws {
        try withTemporaryCodexHome { _, config in
            try write("[features]\ncodex_hooks = false\n", to: config)

            XCTAssertTrue(ConfigInstaller.testEnableCodexHooksConfigWithDetectedVersion("0.129.5"))

            let result = try read(config)
            XCTAssertTrue(result.contains("codex_hooks = false"), "codex_hooks = false must be preserved on older CLI")
            XCTAssertTrue(result.contains("hooks = false"), "hooks must mirror the legacy false value on older CLI")
        }
    }

    func testPreserveBranchIsIdempotentWhenBothKeysPresent() throws {
        try withTemporaryCodexHome { _, config in
            let original = "[features]\nhooks = true\ncodex_hooks = true\n"
            try write(original, to: config)

            XCTAssertTrue(ConfigInstaller.testPreserveCodexHooksKeyAndAddHooks())

            let result = try read(config)
            XCTAssertEqual(result, original, "File must be byte-for-byte unchanged when both keys already present")
        }
    }
}
