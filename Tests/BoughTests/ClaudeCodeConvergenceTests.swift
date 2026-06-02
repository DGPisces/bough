import XCTest
import BoughCore

@testable import Bough

/// Tests for QUOTA-02 and QUOTA-03: mutual exclusion between the statusLine path and hook path.
///
/// D-03 decision: installClaudeHooks calls uninstallClaudeCodeStatusLine as its FIRST statement
/// so both paths can never simultaneously target ~/.bough/claude-usage.json.
#if DEBUG
final class ClaudeCodeConvergenceTests: XCTestCase {

    // MARK: - QUOTA-02: install atomically removes statusLine (testInstallRemovesStatusLine)

    /// Seeds a Bough-managed statusLine command, installs Claude hooks, then asserts
    /// the statusLine is gone.
    ///
    /// Phase 21-01 note: this test previously seeded `/tmp/fake-bridge.sh` and relied
    /// on the Phase 17 `Bundle.main` bug — `bundledClaudeCodeStatusLineBridgePath()`
    /// returned `nil`, which caused `uninstallClaudeCodeStatusLine`'s user-protection
    /// guard at ConfigInstaller.swift:2491-2495 (only removes a statusLine when it
    /// is `nil`-proposed OR matches the proposed Bough bridge OR matches the old
    /// Bough.app pattern) to be bypassed. With the bridge resolvable post-fix, the
    /// guard correctly engages and refuses to yank an arbitrary user statusLine.
    /// QUOTA-02's invariant is "Bough's hook path and Bough's statusLine path can
    /// never simultaneously target ~/.bough/claude-usage.json" — i.e. we must
    /// remove a **Bough-installed** statusLine when installing hooks. We therefore
    /// seed the statusLine with the resolved bridge path so the guard recognises
    /// it as Bough-managed and removes it. (Plan 21-02 generalises this via the
    /// chain-safe wrapper that preserves third-party statusLines.)
    func testInstallRemovesStatusLine() throws {
        let paths = Self.paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Precondition: create a settings.json whose statusLine points at the
        // actual bundled Bough bridge (so the user-protection guard recognises it).
        let bridgePath = try XCTUnwrap(
            ConfigInstaller.proposedClaudeCodeStatusLineCommand(),
            "Bundled Claude Code statusLine bridge must resolve via Bundle.appModule (Phase 21-01 / D-01)."
        )
        let settingsJSON = #"{"statusLine":{"command":"\#(bridgePath)"}}"#
        try Self.writeJSON(settingsJSON, to: paths.settings)
        let before = ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path)
        XCTAssertEqual(before, bridgePath, "Precondition: Bough statusLine command should be set before install")

        // Run install hooks against the temp settings file.
        ConfigInstaller.testInstallClaudeCodeHooks(settingsPath: paths.settings.path)

        // Assert: statusLine is gone after hooks are installed.
        let after = ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path)
        XCTAssertNil(after, "Bough-managed statusLine should be removed when hooks are installed (D-03 / QUOTA-02)")
    }

    // MARK: - QUOTA-03: explicit mutual exclusion assertion (testMutualExclusion)

    /// Verifies the invariant: after installClaudeHooks runs, currentClaudeCodeStatusLineCommand()
    /// returns nil — both paths can never co-exist.
    func testMutualExclusion() throws {
        let paths = Self.paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Seed statusLine via the debug test entry point.
        let installResult = ConfigInstaller.testInstallClaudeCodeStatusLine(
            settingsPath: paths.settings.path,
            proposedBridgePath: paths.bridge.path
        )
        XCTAssertEqual(installResult, .installed, "Precondition: statusLine install should succeed")
        XCTAssertNotNil(
            ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path),
            "Precondition: statusLine command should be present"
        )

        // Install hooks — this must atomically remove the statusLine as its first step.
        ConfigInstaller.testInstallClaudeCodeHooks(settingsPath: paths.settings.path)

        // Mutual exclusion invariant: statusLine must be nil after hooks are installed.
        let command = ConfigInstaller.testCurrentClaudeCodeStatusLineCommand(settingsPath: paths.settings.path)
        XCTAssertNil(command, "Mutual exclusion violated: statusLine command is non-nil after installClaudeHooks (D-03 / QUOTA-03)")
    }

    // MARK: - DIAG-01: socket-absent path returns false (testHealthCheckSocketAbsent)

    /// Verifies claudeCodeHookHealthCheck() returns false when the bough-bridge socket is absent.
    ///
    /// Uses testClaudeCodeHookHealthCheck(socketPath:) to inject a guaranteed non-existent
    /// socket path so the test is deterministic regardless of whether Bough.app is running.
    func testHealthCheckSocketAbsent() {
        // Inject a guaranteed non-existent socket path — avoids false positive when
        // Bough.app is running in the test environment (real socket would exist).
        let absentSocket = "/tmp/bough-test-missing-\(UUID().uuidString).sock"
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: absentSocket),
            "Precondition: injected socket path must not exist")
        // With socket absent, the health check must return false (DIAG-01).
        XCTAssertFalse(ConfigInstaller.testClaudeCodeHookHealthCheck(socketPath: absentSocket),
            "claudeCodeHookHealthCheck() should return false when bough-bridge socket is absent (DIAG-01)")
    }

    // MARK: - QUOTA-06: payload-schema fork test (testPayloadSchemaFork)

    /// Proves that Claude Code and Codex payload schemas do not cross-pollinate
    /// each other's parsing path.
    ///
    /// Test strategy (parser-level): ClaudeCodeRateLimitParser succeeds on a
    /// Claude-shaped payload and fails on a Codex-shaped one; CodexRateLimitParser
    /// succeeds on a Codex-shaped payload and fails on a Claude-shaped one.
    ///
    /// Satisfies QUOTA-06: separate parsers, no cross-pollination.
    func testPayloadSchemaFork() {
        let fixedNow = Date(timeIntervalSince1970: 100_000)

        // ── Claude parser: succeeds on Claude-shaped data ──────────────────────
        let claudeData = Data(
            """
            {
              "version": 1,
              "model": {"display_name": "Claude Sonnet 4"},
              "rate_limits": {
                "five_hour": {
                  "used_percent": 15,
                  "resets_at": 200000,
                  "window_duration_mins": 300
                },
                "seven_day": {
                  "used_percent": 30,
                  "resets_at": 1000000,
                  "window_duration_mins": 10080
                }
              }
            }
            """.utf8
        )
        let claudeResult = ClaudeCodeRateLimitParser.parse(data: claudeData, receivedAt: fixedNow)
        XCTAssertNotNil(claudeResult,
            "ClaudeCodeRateLimitParser must parse a valid Claude-shaped payload (QUOTA-06)")
        XCTAssertEqual(claudeResult?.tool, .claudeCode,
            "ClaudeCodeRateLimitParser must produce a .claudeCode snapshot (separate keys, QUOTA-06)")

        // ── Claude parser: fails on Codex-shaped data ──────────────────────────
        // A Codex payload has "rateLimitsByLimitId" but not "rate_limits" (object).
        let codexShapeData = Data(
            #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":200000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1000000},"planType":"prolite"}}}"#.utf8
        )
        let claudeParserOnCodexShape = ClaudeCodeRateLimitParser.parse(data: codexShapeData, receivedAt: fixedNow)
        XCTAssertNil(claudeParserOnCodexShape,
            "ClaudeCodeRateLimitParser must not parse a Codex-shaped payload (separate parsers, QUOTA-06)")

        // ── Codex parser: succeeds on Codex-shaped message ─────────────────────
        let codexMessage = CodexJSONRPCMessage(
            raw: ["result": .object([
                "rateLimitsByLimitId": .object([
                    "codex": .object([
                        "limitId": .string("codex"),
                        "primary": .object([
                            "usedPercent": .int(10),
                            "windowDurationMins": .int(300),
                            "resetsAt": .int(200_000)
                        ]),
                        "secondary": .object([
                            "usedPercent": .int(20),
                            "windowDurationMins": .int(10_080),
                            "resetsAt": .int(1_000_000)
                        ]),
                        "planType": .string("prolite")
                    ])
                ])
            ])],
            kind: .response(id: .string("test"))
        )
        let codexResult = CodexRateLimitParser.parse(message: codexMessage, receivedAt: fixedNow)
        XCTAssertNotNil(codexResult,
            "CodexRateLimitParser must parse a valid Codex-shaped message (QUOTA-06)")
        XCTAssertEqual(codexResult?.tool, .codex,
            "CodexRateLimitParser must produce a .codex snapshot (separate keys, QUOTA-06)")

        // ── Codex parser: fails on Claude-shaped message ───────────────────────
        // A Claude payload has "rate_limits" but not "rateLimitsByLimitId".
        let claudeAsCodexMessage = CodexJSONRPCMessage(
            raw: ["result": .object([
                "rate_limits": .object([
                    "five_hour": .object([
                        "used_percent": .int(15),
                        "resets_at": .int(200_000),
                        "window_duration_mins": .int(300)
                    ]),
                    "seven_day": .object([
                        "used_percent": .int(30),
                        "resets_at": .int(1_000_000),
                        "window_duration_mins": .int(10_080)
                    ])
                ])
            ])],
            kind: .response(id: .string("test"))
        )
        let codexParserOnClaudeShape = CodexRateLimitParser.parse(message: claudeAsCodexMessage, receivedAt: fixedNow)
        XCTAssertNil(codexParserOnClaudeShape,
            "CodexRateLimitParser must not parse a Claude-shaped payload (separate parsers, QUOTA-06)")

        // ── Cross-key isolation: parsers produce distinct tool keys ─────────────
        // This directly verifies that the two parsers are wired to different
        // UsageTool enum cases and cannot contaminate each other's key space.
        XCTAssertNotEqual(claudeResult?.tool, codexResult?.tool,
            "Claude and Codex parsers must produce different UsageTool snapshot keys (separate accumulator keys, QUOTA-06)")
    }


    // MARK: - QUOTA-06 Regression: real Anthropic statusLine payload

    /// Regression test for the used_percentage payload bug. Anthropic's actual Claude
    /// Code statusLine payload uses "used_percentage" (with the -age suffix),
    /// not "used_percent". Before this fix ClaudeCodeRateLimitParser only
    /// accepted ["used_percent", "usedPercent", "used"] so every real-world
    /// payload silently returned nil and the UI displayed "不可用" despite
    /// ~/.bough/claude-usage.json containing valid rate-limit data.
    ///
    /// This test pins the exact byte shape captured from a real
    /// claude-code@2.1.143 statusLine cycle on 2026-05-18 so any future
    /// alias-list regression fails loudly.
    func testRealAnthropicStatusLinePayloadParses() {
        let receivedAt = Date(timeIntervalSince1970: 1_779_100_000)
        let payload = Data("""
            {
              "version": "2.1.143",
              "rate_limits": {
                "five_hour": {"used_percentage": 25, "resets_at": 1779166200},
                "seven_day": {"used_percentage": 16, "resets_at": 1779591600}
              },
              "output_style": {"name": "default"},
              "model": {"id": "claude-opus-4-7[1m]", "display_name": "Opus 4.7 (1M context)"}
            }
            """.utf8)

        let snapshot = ClaudeCodeRateLimitParser.parse(data: payload, receivedAt: receivedAt)
        XCTAssertNotNil(snapshot,
            "Parser must accept Anthropic's real 'used_percentage' field name")
        guard let snapshot else { return }
        XCTAssertEqual(snapshot.tool, .claudeCode)
        guard case .available(let fiveHour) = snapshot.fiveHour else {
            XCTFail("five_hour window must parse as .available"); return
        }
        XCTAssertEqual(fiveHour.usedPercent, 25, accuracy: 0.001)
        guard case .available(let weekly) = snapshot.weekly else {
            XCTFail("seven_day window must parse as .available"); return
        }
        XCTAssertEqual(weekly.usedPercent, 16, accuracy: 0.001)
        XCTAssertEqual(snapshot.planName, "Opus 4.7 (1M context)",
            "planName must resolve from model.display_name when model is an object")
    }

    private static func paths() -> (root: URL, settings: URL, bridge: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeConvergenceTests-\(UUID().uuidString)")
        return (
            root,
            root.appendingPathComponent(".claude/settings.json"),
            root.appendingPathComponent("Bough.app/Contents/Resources/bough-statusline-bridge.sh")
        )
    }

    private static func writeJSON(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

#endif
