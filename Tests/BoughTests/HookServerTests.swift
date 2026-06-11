import XCTest
import Darwin

@testable import Bough
@testable import BoughCore

@MainActor
final class HookServerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var savedCodexHome: String?

    override func setUp() {
        super.setUp()
        TestHelpers.processEnvironmentLock.lock()
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        suiteName = "HookServerTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        TestHelpers.processEnvironmentLock.unlock()
        super.tearDown()
    }

    func testHandleQuotaEventAppliesClaudeCodePayloadToUsageStore() {
        let appState = AppState()
        appState.usageStore = UsageStore(
            defaults: defaults,
            scheduler: RecordingHookServerUsageRefreshScheduler(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let server = HookServer(appState: appState)

        XCTAssertTrue(server.handleQuotaEvent(payload: Self.claudePayload()))

        let snapshot = appState.usageStore.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 18)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 32)
        XCTAssertNotNil(snapshot.today)
    }

    func testCodexAutoReviewPermissionRequestsDeferToNativeReviewer() throws {
        try withTemporaryCodexHome { _, config in
            try write(
                """
                approval_policy = "on-request"
                approvals_reviewer = "auto_review"

                [features]
                hooks = true
                """,
                to: config
            )

            let event = try makePermissionRequestEvent(source: "codex", toolName: "Bash")

            XCTAssertTrue(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferDoesNotScanTranscriptByDefault() throws {
        try withTemporaryCodexHome { home, _ in
            let transcript = home.appendingPathComponent("thread.jsonl")
            try write(
                """
                {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"`approvals_reviewer` is `auto_review`: sandbox escalations are reviewed."}]}}
                """,
                to: transcript
            )
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["transcript_path": transcript.path]
            )

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferRequiresCodexSource() throws {
        try withTemporaryCodexHome { _, config in
            try write(
                """
                approval_policy = "on-request"
                approvals_reviewer = "auto_review"
                """,
                to: config
            )

            let event = try makePermissionRequestEvent(source: "claude", toolName: "Bash")

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferKeepsAskUserQuestionInBough() throws {
        try withTemporaryCodexHome { _, config in
            try write(
                """
                approval_policy = "on-request"
                approvals_reviewer = "auto_review"
                """,
                to: config
            )

            let event = try makePermissionRequestEvent(source: "codex", toolName: "AskUserQuestion")

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferDisabledWhenApprovalPolicyIsNever() throws {
        try withTemporaryCodexHome { _, config in
            try write(
                """
                approval_policy = "never"
                approvals_reviewer = "auto_review"
                """,
                to: config
            )

            let event = try makePermissionRequestEvent(source: "codex", toolName: "Bash")

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferRecognizesRuntimePayloadReviewer() throws {
        try withTemporaryCodexHome { _, _ in
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["approvals_reviewer": "auto_review"]
            )

            XCTAssertTrue(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexRuntimeApprovalPolicyNeverOverridesConfigAutoReview() throws {
        try withTemporaryCodexHome { _, config in
            try write(
                """
                approval_policy = "on-request"
                approvals_reviewer = "auto_review"
                """,
                to: config
            )

            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["approval_policy": "never"]
            )

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferRecognizesDeveloperTranscriptContext() throws {
        try withTemporaryCodexHome { home, _ in
            let transcript = home.appendingPathComponent("thread.jsonl")
            try write(
                """
                {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"`approvals_reviewer` is `auto_review`: sandbox escalations are reviewed."}]}}
                """,
                to: transcript
            )
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["transcript_path": transcript.path]
            )

            XCTAssertTrue(HookServer.shouldDeferCodexPermissionToAutoReview(event, allowTranscriptScan: true))
        }
    }

    func testCodexAutoReviewDeferRecognizesDeveloperTranscriptContextBeforeLargeTail() throws {
        try withTemporaryCodexHome { home, _ in
            let transcript = home.appendingPathComponent("thread.jsonl")
            let filler = String(
                repeating: """
                {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"filler"}]}}

                """,
                count: 12_000
            )
            try write(
                """
                {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"`approvals_reviewer` is `auto_review`: sandbox escalations are reviewed."}]}}
                \(filler)
                """,
                to: transcript
            )
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["transcript_path": transcript.path]
            )

            XCTAssertTrue(HookServer.shouldDeferCodexPermissionToAutoReview(event, allowTranscriptScan: true))
        }
    }

    func testCodexAutoReviewDeferIgnoresUserTranscriptMentions() throws {
        try withTemporaryCodexHome { home, _ in
            let transcript = home.appendingPathComponent("thread.jsonl")
            try write(
                """
                {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"approvals_reviewer auto_review"}]}}
                """,
                to: transcript
            )
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: ["transcript_path": transcript.path]
            )

            XCTAssertFalse(HookServer.shouldDeferCodexPermissionToAutoReview(event))
        }
    }

    func testCodexAutoReviewDeferFindsGuiThreadTranscriptByThreadId() throws {
        try withTemporaryCodexHome { home, _ in
            let wrongHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("bough-wrong-codex-home-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: wrongHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: wrongHome) }
            setenv("CODEX_HOME", wrongHome.path, 1)

            let threadId = "019e8a65-9e83-72d1-924d-c50cd3bad864"
            let date = Date()
            let calendar = Calendar.current
            let dir = home
                .appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: date)))
                .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: date)))
                .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: date)))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let transcript = dir.appendingPathComponent("rollout-2026-06-03T12-00-00-\(threadId).jsonl")
            try write(
                """
                {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"`approvals_reviewer` is `auto_review`"}]}}
                """,
                to: transcript
            )
            let event = try makePermissionRequestEvent(
                source: "codex",
                toolName: "Bash",
                extra: [
                    "_codex_thread_id": threadId,
                    "_codex_home": home.path
                ]
            )

            XCTAssertTrue(HookServer.shouldDeferCodexPermissionToAutoReview(event, allowTranscriptScan: true))
        }
    }

    func testBridgeCarriesCodexGuiThreadIdIntoHookPayload() throws {
        let bridgeSource = try sourceFile("Sources/BoughBridge/main.swift")

        XCTAssertTrue(bridgeSource.contains("CODEX_THREAD_ID"))
        XCTAssertTrue(bridgeSource.contains("\"_codex_thread_id\""))
    }

    func testHiddenPluginModeDoesNotAutoAllowPermissionRequests() throws {
        let source = try sourceFile("Sources/Bough/HookServer.swift")
        let start = try XCTUnwrap(source.range(of: "private static func hiddenPluginResponse"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "private static func pluginPpid"))
        let body = String(tail[..<end.lowerBound])

        XCTAssertTrue(body.contains("Data(\"{}\".utf8)"))
        XCTAssertFalse(body.contains("\"behavior\": \"allow\""))
        XCTAssertFalse(body.contains("\"behavior\":\"allow\""))
        XCTAssertFalse(body.contains("decision"))
    }

    func testSocketCleanupRefusesToDeleteRegularFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookServerTests-\(UUID().uuidString).txt")
        try Data("do not delete".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertFalse(HookServer.testRemoveSocketIfPresent(path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testSocketCleanupRefusesToDeleteCustomExistingSocket() throws {
        let path = "/tmp/bough-hookserver-\(UUID().uuidString).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            close(fd)
            unlink(path)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let pathBytes = Array(path.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            guard pathBytes.count < buffer.count else {
                throw NSError(domain: "HookServerTests", code: 3)
            }
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        XCTAssertFalse(HookServer.testRemoveSocketIfPresent(path))
        XCTAssertEqual(access(path, F_OK), 0)
    }

    private static func claudePayload() -> Data {
        Data(
            """
            {
              "version": 1,
              "model": {"display_name": "Claude Sonnet 4"},
              "rate_limits": {
                "five_hour": {"used_percent": 18, "resets_at": 2800, "window_duration_mins": 300},
                "seven_day": {"used_percent": 32, "resets_at": 100000, "window_duration_mins": 10080}
              }
            }
            """.utf8
        )
    }

    private func withTemporaryCodexHome(
        _ body: (_ home: URL, _ config: URL) throws -> Void
    ) rethrows {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("bough-codex-home-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }
        setenv("CODEX_HOME", home.path, 1)
        try body(home, home.appendingPathComponent("config.toml"))
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makePermissionRequestEvent(
        source: String,
        toolName: String,
        extra: [String: Any] = [:]
    ) throws -> HookEvent {
        var raw: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "codex-auto-review-test",
            "tool_name": toolName,
            "tool_input": [
                "command": "curl https://example.com"
            ],
            "_source": source
        ]
        for (key, value) in extra {
            raw[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class RecordingHookServerUsageRefreshScheduler: UsageRefreshScheduling {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func stop() {}
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }
}
