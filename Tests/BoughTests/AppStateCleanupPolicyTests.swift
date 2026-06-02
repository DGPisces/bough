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

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
