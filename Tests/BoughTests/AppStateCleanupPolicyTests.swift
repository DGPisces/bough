import XCTest
@testable import Bough
import BoughCore

final class AppStateCleanupPolicyTests: XCTestCase {
    func testIdleCleanupFastPathChecksAllStateThatCanRequireCleanup() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/Bough/AppState.swift"))

        XCTAssertTrue(source.contains("guard hasIdleCleanupWork else { return }"))
        XCTAssertTrue(source.contains("private var hasIdleCleanupWork: Bool"))

        let requiredTerms = [
            "!sessions.isEmpty",
            "activeSessionId != nil",
            "rotatingSessionId != nil",
            "surface != .collapsed",
            "!processMonitors.isEmpty",
            "!exitingSessions.isEmpty",
            "!permissionQueue.isEmpty",
            "!questionQueue.isEmpty",
            "!pendingToolUses.isEmpty",
            "!completionQueue.isEmpty"
        ]

        for term in requiredTerms {
            XCTAssertTrue(source.contains(term), "Missing cleanup fast-path term: \\(term)")
        }
    }

    func testNativeAppCleanupBundleSetIgnoresIntegratedTerminalSessions() {
        var integratedTerminal = SessionSnapshot()
        integratedTerminal.source = "claude"
        integratedTerminal.termBundleId = "com.openai.codex"

        var nativeCodex = SessionSnapshot()
        nativeCodex.source = "codex"
        nativeCodex.termBundleId = "com.openai.codex"

        XCTAssertEqual(AppState.nativeAppBundleIdsPendingCleanup(sessions: [
            "terminal": integratedTerminal
        ]), [])
        XCTAssertEqual(AppState.nativeAppBundleIdsPendingCleanup(sessions: [
            "terminal": integratedTerminal,
            "native": nativeCodex
        ]), ["com.openai.codex"])
    }

    func testIdleCleanupDoesNotTerminateReparentedUserCLIProcesses() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/Bough/AppState.swift"))
        let cleanup = try XCTUnwrap(source.slice(from: "private func cleanupIdleSessions()", to: "private var hasIdleCleanupWork"))

        XCTAssertFalse(cleanup.contains("SIGTERM"))
        XCTAssertFalse(cleanup.contains("pbi_ppid <= 1"))
        XCTAssertFalse(cleanup.contains("shouldTerminateOrphanedProcess"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let lower = range(of: start)?.lowerBound,
              let upper = self[lower...].range(of: end)?.lowerBound else {
            return nil
        }
        return String(self[lower..<upper])
    }
}
