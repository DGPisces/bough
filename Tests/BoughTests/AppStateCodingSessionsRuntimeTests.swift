import XCTest
@testable import Bough
import BoughCore

@MainActor
final class AppStateCodingSessionsRuntimeTests: XCTestCase {
    func testSuspendCodingSessionsClearsVisibleStateAndDeniesPendingPermission() async throws {
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateCodingSessionsRuntimeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-monitor-command.json")
        defer { try? FileManager.default.removeItem(at: commandURL.deletingLastPathComponent()) }
        let appState = AppState()
        appState.usageStore = UsageStore(
            defaults: isolatedDefaults(name),
            scheduler: RecordingRuntimeUsageRefreshScheduler(),
            usageMonitorCommandPath: commandURL.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        appState.sessions["manual-session"] = {
            var snapshot = SessionSnapshot(startTime: Date(timeIntervalSince1970: 900))
            snapshot.status = .running
            snapshot.source = "codex"
            snapshot.transcriptPath = "/tmp/manual-session.jsonl"
            return snapshot
        }()
        appState.activeSessionId = "manual-session"
        appState.surface = .collapsed
        appState.attachedTranscriptPaths["manual-session"] = "/tmp/manual-session.jsonl"
        appState.pendingToolUses["tool-1"] = PreToolUseRecord(
            sessionId: "manual-session",
            toolName: "Bash",
            toolDescription: "echo test",
            toolInput: ["command": "echo test"],
            receivedAt: Date()
        )
        appState.usageStore.applyCodexRateLimitResult(codexResult(weeklyReset: 100_000))

        let event = try makePermissionRequestEvent(sessionId: "manual-session", toolName: "Bash")
        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "manual-session"))

        appState.suspendCodingSessionsForDisabledMode()
        let response = await responseTask.value

        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertTrue(appState.questionQueue.isEmpty)
        XCTAssertTrue(appState.pendingToolUses.isEmpty)
        XCTAssertTrue(appState.attachedTranscriptPaths.isEmpty)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertNil(appState.usageStore.snapshots[.codex])

        let command = try JSONDecoder().decode(UsageMonitorCommand.self, from: Data(contentsOf: commandURL))
        XCTAssertEqual(command.enabledTools, [])
    }

    func testDisabledProviderRejectsNewPermissionWithoutCreatingSession() async throws {
        let appState = AppState()
        appState.codingSessionsEnabledProvider = { false }
        let event = try makePermissionRequestEvent(sessionId: "disabled-session", toolName: "Write")

        let response = await withCheckedContinuation { continuation in
            appState.handlePermissionRequest(event, continuation: continuation)
        }

        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    private func isolatedDefaults(_ testName: String) -> UserDefaults {
        let suiteName = "AppStateCodingSessionsRuntimeTests-\(testName)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makePermissionRequestEvent(sessionId: String, toolName: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": ["command": "echo test"],
            "_source": "codex"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func codexResult(weeklyReset: TimeInterval) -> [String: AnyCodableLike] {
        [
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "primary": .object([
                        "usedPercent": .double(10),
                        "windowDurationMins": .int(300),
                        "resetsAt": .int(Int64(weeklyReset))
                    ]),
                    "secondary": .object([
                        "usedPercent": .double(20),
                        "windowDurationMins": .int(10_080),
                        "resetsAt": .int(Int64(weeklyReset))
                    ]),
                    "planType": .string("pro")
                ])
            ])
        ]
    }
}

private final class RecordingRuntimeUsageRefreshScheduler: UsageRefreshScheduling {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func stop() {}
}
