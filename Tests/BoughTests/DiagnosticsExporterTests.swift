import XCTest
@testable import Bough
import BoughCore

@MainActor
final class DiagnosticsExporterTests: XCTestCase {
    func testSessionSnapshotsUseProvidedAppState() {
        let appState = AppState()
        var session = SessionSnapshot(startTime: Date(timeIntervalSince1970: 1_800_000_000))
        session.status = .running
        session.source = "codex"
        session.cwd = "/tmp/bough-diagnostics-test"
        session.currentTool = "Bash"
        session.lastActivity = Date(timeIntervalSince1970: 1_800_000_030)
        appState.sessions["diagnostic-session"] = session

        let snapshots = DiagnosticsExporter.sessionSnapshots(from: appState)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?["id"] as? String, "diagnost")
        XCTAssertEqual(snapshots.first?["source"] as? String, "codex")
        XCTAssertEqual(snapshots.first?["currentTool"] as? String, "Bash")
        XCTAssertEqual(snapshots.first?["cwd"] as? String, "/tmp/bough-diagnostics-test")
    }

    func testRecentHookEventsUseProvidedAppState() {
        let appState = AppState()
        appState.recordHookEvent(
            source: "codex",
            sessionId: "diagnostic-session",
            eventName: "UserPromptSubmit",
            toolName: nil,
            viaPlugin: false,
            payloadKeys: ["hook_event_name", "prompt", "session_id"],
            promptPreview: "diagnostics export marker"
        )

        let events = DiagnosticsExporter.recentHookEvents(from: appState)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["eventName"] as? String, "UserPromptSubmit")
        XCTAssertEqual(events.first?["source"] as? String, "codex")
        XCTAssertEqual(events.first?["sessionId"] as? String, "diagnostic-s")
        XCTAssertEqual(events.first?["promptPreview"] as? String, "diagnostics export marker")
    }

    // MARK: - DIAG-04 Tests
    //
    // These tests stage fixture .claude/ and .codex/ trees inside a per-test
    // temp directory and inject it as `home:` into the DIAG-04 helpers, so
    // assertions reflect the staged fixtures rather than live `~/.claude/`
    // / `~/.codex/` state (WR-02 hermetic fix). For the codex-config.toml
    // wiring test (WR-01), we drive the production `copyIfExists` helper
    // directly — the previous version manually called `fm.copyItem` and
    // would have passed even if DiagnosticsExporter never copied the file.

    /// Creates a per-test temp directory and registers cleanup as a teardown
    /// block. Returns the URL so the test can stage fixtures inside it.
    private func makeTempHome(function: StaticString = #function) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("DiagnosticsExporterTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return tmp
    }

    /// Writes `content` to `home/relativePath`, creating intermediate dirs.
    private func stageFile(_ relativePath: String, content: String, under home: URL) throws {
        let fm = FileManager.default
        let url = home.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // --- testHookConfigSnapshotKeys: cover both "present" and "absent" branches
    //     of the [features] parser, the contains("bough") check, and the hooks
    //     block extraction — none of which the previous test exercised.

    func testHookConfigSnapshotKeys_presentFixtures() throws {
        let home = try makeTempHome()
        try stageFile(".claude/settings.json",
                      content: #"{"hooks":{"UserPromptSubmit":[{"command":"echo hi"}]}}"#,
                      under: home)
        try stageFile(".codex/hooks.json",
                      content: #"{"hooks":[{"command":"bough","event":"UserPromptSubmit"}]}"#,
                      under: home)
        try stageFile(".codex/config.toml",
                      content: "[other]\nx = 1\n\n[features]\nbough = true\nfoo = \"bar\"\n\n[next]\ny = 2\n",
                      under: home)

        let snapshot = DiagnosticsExporter.hookConfigSnapshot(home: home.path)

        // Schema: all four keys present
        XCTAssertTrue(snapshot.keys.contains("claudeCodeStatusLine"))
        XCTAssertTrue(snapshot.keys.contains("claudeCodeHooksBlock"))
        XCTAssertTrue(snapshot.keys.contains("codexHooksInstalled"))
        XCTAssertTrue(snapshot.keys.contains("codexFeaturesSection"))

        // codexHooksInstalled — contains("bough") must be true for staged fixture
        XCTAssertEqual(snapshot["codexHooksInstalled"] as? Bool, true,
                       "codexHooksInstalled must be true when ~/.codex/hooks.json contains 'bough'")

        // codexFeaturesSection — parser must extract only the [features] block,
        // stopping at the next [section] heading.
        let features = snapshot["codexFeaturesSection"] as? String ?? ""
        XCTAssertTrue(features.contains("bough = true"),
                      "[features] block must include 'bough = true', got: \(features)")
        XCTAssertTrue(features.contains("foo = \"bar\""),
                      "[features] block must include 'foo = \"bar\"', got: \(features)")
        XCTAssertFalse(features.contains("[next]"),
                       "[features] parser must stop at next [section] heading, got: \(features)")
        XCTAssertFalse(features.contains("x = 1"),
                       "[features] parser must not bleed [other] entries, got: \(features)")

        // claudeCodeHooksBlock — must be the dict extracted from settings.json,
        // not NSNull.
        XCTAssertFalse(snapshot["claudeCodeHooksBlock"] is NSNull,
                       "claudeCodeHooksBlock must be populated when settings.json has a hooks key")
    }

    func testHookConfigSnapshotKeys_absentFixtures() throws {
        // Empty temp home — no .claude/, no .codex/. Covers the CI / fresh-runner
        // branches of the parser (missing-file paths).
        let home = try makeTempHome()

        let snapshot = DiagnosticsExporter.hookConfigSnapshot(home: home.path)

        // Schema still complete
        XCTAssertTrue(snapshot.keys.contains("claudeCodeStatusLine"))
        XCTAssertTrue(snapshot.keys.contains("claudeCodeHooksBlock"))
        XCTAssertTrue(snapshot.keys.contains("codexHooksInstalled"))
        XCTAssertTrue(snapshot.keys.contains("codexFeaturesSection"))

        // codexHooksInstalled — false when ~/.codex/hooks.json is missing
        XCTAssertEqual(snapshot["codexHooksInstalled"] as? Bool, false,
                       "codexHooksInstalled must be false when hooks.json is absent")

        // codexFeaturesSection — empty string when config.toml is missing
        XCTAssertEqual(snapshot["codexFeaturesSection"] as? String, "",
                       "codexFeaturesSection must be empty when config.toml is absent")

        // claudeCodeHooksBlock — NSNull when settings.json is missing
        XCTAssertTrue(snapshot["claudeCodeHooksBlock"] is NSNull,
                      "claudeCodeHooksBlock must be NSNull when settings.json is absent")
    }

    // --- testMigrationLogSynthesized: assert the helper reflects the staged
    //     temp-home state, not the developer's real ~/.claude/ ~/.codex/.

    func testMigrationLogSynthesized_reflectsInjectedHome() throws {
        let home = try makeTempHome()
        try stageFile(".claude/settings.json", content: "{}", under: home)
        // .codex/hooks.json deliberately absent

        let entry = DiagnosticsExporter.migrationLogEntry(
            home: home.path,
            codexAppServerProcessStarts: []
        )

        // Schema + note unchanged
        let note = entry["note"] as? String ?? ""
        XCTAssertTrue(note.contains("Synthesized at export time"),
                      "migration-log note must contain 'Synthesized at export time', got: \(note)")
        let exportedAt = entry["exportedAt"] as? String ?? ""
        XCTAssertFalse(exportedAt.isEmpty, "migration-log exportedAt must be non-empty")
        XCTAssertTrue(entry["statusLinePresent"] is Bool)

        // Existence flags must reflect the staged temp home, not the real $HOME.
        XCTAssertEqual(entry["claudeSettingsExists"] as? Bool, true,
                       "claudeSettingsExists must reflect staged fixture (.claude/settings.json present)")
        XCTAssertEqual(entry["codexHooksJsonExists"] as? Bool, false,
                       "codexHooksJsonExists must reflect staged fixture (.codex/hooks.json absent)")
    }

    func testMigrationLogReportsStaleCodexAppServerAfterDeprecatedKeyRepair() throws {
        let home = try makeTempHome()
        try stageFile(".codex/config.toml",
                      content: "[features]\ncodex_hooks = true\n",
                      under: home)
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let configDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: configDate],
            ofItemAtPath: configURL.path
        )
        let olderAppServer = ConfigInstaller.CodexAppServerProcessStart(
            pid: 4242,
            startDate: configDate.addingTimeInterval(-120)
        )

        let entry = DiagnosticsExporter.migrationLogEntry(
            home: home.path,
            codexAppServerProcessStarts: [olderAppServer]
        )

        XCTAssertEqual(entry["codexDeprecatedHooksKeyPresent"] as? Bool, true)
        XCTAssertEqual(entry["codexAppServerNeedsRestart"] as? Bool, true)
        XCTAssertEqual(entry["codexAppServerRunningPIDs"] as? [Int], [4242])
        XCTAssertEqual(entry["codexAppServerStalePIDs"] as? [Int], [4242])
        XCTAssertFalse(entry["codexConfigModifiedAt"] is NSNull)
    }

    // --- testCodexConfigTomlCopied: drive the production `copyIfExists`
    //     helper end-to-end, covering both "source present" and "source absent"
    //     branches. The previous test re-implemented the copy via fm.copyItem
    //     and would have passed even if DiagnosticsExporter's wiring were
    //     deleted (WR-01).

    func testCopyIfExists_copiesWhenSourcePresent() throws {
        let fm = FileManager.default
        let tmp = try makeTempHome()
        let src = tmp.appendingPathComponent("config.toml")
        try "[features]\nbough = true\n".write(to: src, atomically: true, encoding: .utf8)

        let dest = tmp.appendingPathComponent("configs/codex-config.toml")
        DiagnosticsExporter.copyIfExists(from: src.path, to: dest)

        XCTAssertTrue(fm.fileExists(atPath: dest.path),
                      "copyIfExists must copy file when source exists")
        let copied = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertEqual(copied, "[features]\nbough = true\n",
                       "copied file must preserve source contents")
    }

    func testCopyIfExistsRedactsSensitiveConfigText() throws {
        let fm = FileManager.default
        let tmp = try makeTempHome()
        let legacyRepoName = ["bough", "internal"].joined(separator: "-")
        let src = tmp.appendingPathComponent("config.toml")
        try """
        [features]
        bough = true
        token = "github_pat_exampleSECRET"
        authorization = "Bearer abc.def.ghi"
        source = "\(legacyRepoName)"
        """.write(to: src, atomically: true, encoding: .utf8)

        let dest = tmp.appendingPathComponent("configs/codex-config.toml")
        DiagnosticsExporter.copyIfExists(from: src.path, to: dest)

        XCTAssertTrue(fm.fileExists(atPath: dest.path))
        let copied = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(copied.contains("bough = true"))
        XCTAssertTrue(copied.contains("<redacted>"))
        XCTAssertFalse(copied.contains("github_pat_exampleSECRET"))
        XCTAssertFalse(copied.contains("Bearer abc.def.ghi"))
        XCTAssertFalse(copied.contains(legacyRepoName))
    }

    func testCopyIfExists_noopWhenSourceAbsent() throws {
        let fm = FileManager.default
        let tmp = try makeTempHome()
        // src deliberately not created
        let src = tmp.appendingPathComponent("missing.toml")
        let dest = tmp.appendingPathComponent("configs/codex-config.toml")

        DiagnosticsExporter.copyIfExists(from: src.path, to: dest)

        XCTAssertFalse(fm.fileExists(atPath: dest.path),
                       "copyIfExists must be a no-op when source is absent")
    }
}
