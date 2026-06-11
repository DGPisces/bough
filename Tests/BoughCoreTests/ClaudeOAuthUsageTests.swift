import XCTest
@testable import BoughCore

final class ClaudeOAuthUsageTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeOAuthUsageTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeCredentials(_ json: String, to name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! json.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: 凭据解析

    func testParseCredentialsFullShape() {
        let data = """
        {"claudeAiOauth":{"accessToken":"tok-1","expiresAt":2000000,"scopes":["user:profile","user:inference"],"subscriptionType":"max"}}
        """.data(using: .utf8)!
        let creds = ClaudeOAuthCredentials.parse(jsonData: data)
        XCTAssertEqual(creds?.accessToken, "tok-1")
        XCTAssertEqual(creds?.expiresAt, Date(timeIntervalSince1970: 2000)) // ms → s
        XCTAssertEqual(creds?.subscriptionType, "max")
        XCTAssertFalse(creds!.isExpired(now: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(creds!.isExpired(now: Date(timeIntervalSince1970: 1941))) // 60s leeway
    }

    func testParseCredentialsMissingClaudeAiOauthReturnsNil() {
        let data = #"{"mcpOAuth":{"foo":"bar"}}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeOAuthCredentials.parse(jsonData: data))
    }

    // MARK: 读取器优先级

    func testReaderPrefersFirstNonExpiredFile() throws {
        let expired = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#, to: "mirror.json")
        let fresh = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"new","expiresAt":9000000000000}}"#, to: "real.json")
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [expired, fresh],
            keychainRead: nil,
            now: { Date(timeIntervalSince1970: 5000) }
        )
        XCTAssertEqual(try reader.read().accessToken, "new")
    }

    func testReaderFallsBackToKeychainWhenFilesUnusable() throws {
        let noOauth = writeCredentials(#"{"mcpOAuth":{}}"#, to: "real.json")
        let keychainCalls = Counter()
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [noOauth],
            keychainRead: {
                keychainCalls.increment()
                return .success(#"{"claudeAiOauth":{"accessToken":"kc","expiresAt":9000000000000}}"#.data(using: .utf8)!)
            },
            now: { Date(timeIntervalSince1970: 5000) }
        )
        XCTAssertEqual(try reader.read().accessToken, "kc")
        XCTAssertEqual(keychainCalls.value, 1)
    }

    func testKeychainDenialSetsCooldownAndManualResetClearsIt() {
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 5000))
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [tempDir.appendingPathComponent("absent.json")],
            keychainRead: { keychainCalls.increment(); return .failure(.denied(status: -25293)) },
            now: { nowBox.value }
        )
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .keychainDenied)
        }
        // 冷却期内不再触碰 Keychain
        nowBox.value = nowBox.value.addingTimeInterval(60)
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 1)
        // 手动重置后允许重试
        reader.resetKeychainCooldown()
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testKeychainItemNotFoundDoesNotCooldown() {
        let keychainCalls = Counter()
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { keychainCalls.increment(); return .failure(.itemNotFound) },
            now: { Date(timeIntervalSince1970: 5000) }
        )
        XCTAssertThrowsError(try reader.read()) { error in
            guard case .credentialsUnavailable = error as? OAuthUsageError else {
                return XCTFail("expected credentialsUnavailable, got \(error)")
            }
        }
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testAllSourcesExpiredThrowsTokenExpired() {
        let expired = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#, to: "real.json")
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [expired], keychainRead: nil,
            now: { Date(timeIntervalSince1970: 5000) }
        )
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
    }

    // MARK: OAuth 响应映射 → 现有 parser

    func testMapperProducesParserCompatiblePayload() throws {
        let oauthBody = """
        {"five_hour":{"utilization":13.5,"resets_at":"2026-06-11T10:00:00Z"},
         "seven_day":{"utilization":43,"resets_at":"2026-06-13T18:00:00Z"},
         "seven_day_opus":{"utilization":2,"resets_at":"2026-06-13T18:00:00Z"},
         "extra_usage":{"is_enabled":false}}
        """.data(using: .utf8)!
        let payload = try XCTUnwrap(ClaudeOAuthUsageMapper.statusLinePayloadData(fromOAuthBody: oauthBody))
        let snapshot = try XCTUnwrap(ClaudeCodeRateLimitParser.parse(
            data: payload, receivedAt: Date(timeIntervalSince1970: 1_000)))
        guard case .available(let fiveHour) = snapshot.fiveHour,
              case .available(let weekly) = snapshot.weekly else {
            return XCTFail("expected both windows available")
        }
        XCTAssertEqual(fiveHour.usedPercent, 13.5, accuracy: 0.001)
        XCTAssertEqual(weekly.usedPercent, 43, accuracy: 0.001)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(fiveHour.resetsAt, iso.date(from: "2026-06-11T10:00:00Z"))
        XCTAssertEqual(weekly.resetsAt, iso.date(from: "2026-06-13T18:00:00Z"))
    }

    func testMapperReturnsNilWithoutRecognizableWindows() {
        let body = #"{"extra_usage":{"is_enabled":true}}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeOAuthUsageMapper.statusLinePayloadData(fromOAuthBody: body))
    }

    // MARK: 客户端状态机

    private func makeClient(
        transport: @escaping OAuthHTTPTransport,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> ClaudeOAuthUsageClient {
        let fresh = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9000000000000}}"#, to: "creds.json")
        return ClaudeOAuthUsageClient(
            credentialsReader: ClaudeOAuthCredentialsReader(fileURLs: [fresh], keychainRead: nil, now: now),
            transport: transport,
            userAgentVersion: { "9.9.9" },
            now: now
        )
    }

    func testFetchSuccessSendsExpectedHeadersAndMapsBody() throws {
        let capturedBox = MutableBox<URLRequest?>(nil)
        let client = makeClient(transport: { request in
            capturedBox.value = request
            return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
            {"five_hour":{"utilization":10,"resets_at":1781205600},
             "seven_day":{"utilization":40,"resets_at":1781406000}}
            """.data(using: .utf8)!)
        })
        let payload = try client.fetchStatusLinePayload()
        XCTAssertNotNil(ClaudeCodeRateLimitParser.parse(data: payload, receivedAt: Date()))
        XCTAssertEqual(capturedBox.value?.url, ClaudeOAuthUsageClient.endpoint)
        XCTAssertEqual(capturedBox.value?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(capturedBox.value?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(capturedBox.value?.value(forHTTPHeaderField: "User-Agent"), "claude-code/9.9.9")
    }

    func testFetch429SetsCooldownFromRetryAfterWithFloor() {
        let nowBox = MutableBox(Date(timeIntervalSince1970: 10_000))
        let calls = Counter()
        let client = makeClient(transport: { _ in
            calls.increment()
            return OAuthHTTPResponse(statusCode: 429, headers: ["Retry-After": "60"], body: Data())
        }, now: { nowBox.value })
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) {
            XCTAssertEqual($0 as? OAuthUsageError, .rateLimited(retryAfterSeconds: 60))
        }
        // floor 是 300s：60s Retry-After 仍冷却 300s
        nowBox.value = nowBox.value.addingTimeInterval(299)
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) {
            guard case .cooldownActive = $0 as? OAuthUsageError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(calls.value, 1)
        nowBox.value = nowBox.value.addingTimeInterval(2)
        _ = try? client.fetchStatusLinePayload()
        XCTAssertEqual(calls.value, 2)
    }

    func testFetch401SetsFifteenMinuteCooldown() {
        let nowBox = MutableBox(Date(timeIntervalSince1970: 10_000))
        let calls = Counter()
        let client = makeClient(transport: { _ in
            calls.increment()
            return OAuthHTTPResponse(statusCode: 401, headers: [:], body: Data())
        }, now: { nowBox.value })
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) {
            XCTAssertEqual($0 as? OAuthUsageError, .unauthorized(statusCode: 401))
        }
        nowBox.value = nowBox.value.addingTimeInterval(14 * 60)
        XCTAssertThrowsError(try client.fetchStatusLinePayload())
        XCTAssertEqual(calls.value, 1)
        nowBox.value = nowBox.value.addingTimeInterval(2 * 60)
        _ = try? client.fetchStatusLinePayload()
        XCTAssertEqual(calls.value, 2)
    }

    // MARK: CLI 版本探测

    func testVersionProbeParsesSemverFromScriptOutput() throws {
        let script = tempDir.appendingPathComponent("fake-claude")
        try "#!/bin/sh\necho \"2.1.173 (Claude Code)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(ClaudeCLIVersionProbe.detect(executableCandidates: [script.path]), "2.1.173")
    }

    func testVersionProbeReturnsNilForMissingExecutable() {
        let missing = tempDir.appendingPathComponent("no-such-claude").path
        XCTAssertNil(ClaudeCLIVersionProbe.detect(executableCandidates: [missing]))
    }

    // MARK: token 镜像

    func testTokenMirrorWriteAndDeleteRoundTrip() throws {
        setenv("HOME", tempDir.path, 1)
        defer { setenv("HOME", NSHomeDirectory(), 1) }
        let creds = ClaudeOAuthCredentials(
            accessToken: "mirror-tok",
            expiresAt: Date(timeIntervalSince1970: 4242),
            scopes: [], subscriptionType: nil
        )
        try ClaudeOAuthTokenMirror.write(creds)
        let mirrorURL = ClaudeOAuthTokenMirror.fileURL()
        let parsed = ClaudeOAuthCredentials.parse(jsonData: try Data(contentsOf: mirrorURL))
        XCTAssertEqual(parsed?.accessToken, "mirror-tok")
        XCTAssertEqual(parsed?.expiresAt, Date(timeIntervalSince1970: 4242))
        ClaudeOAuthTokenMirror.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorURL.path))
    }

    func testMirrorRewrittenWhenFileMissingEvenIfTokenUnchanged() throws {
        // mirrorIfNeeded 通过 $HOME 解析镜像路径——三次 fetch 都要重定向。
        setenv("HOME", tempDir.path, 1)
        defer { setenv("HOME", NSHomeDirectory(), 1) }
        let fresh = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9000000000000}}"#, to: "creds.json")
        let mirrored = MutableBox<[String]>([])
        let client = ClaudeOAuthUsageClient(
            credentialsReader: ClaudeOAuthCredentialsReader(
                fileURLs: [fresh], keychainRead: nil,
                now: { Date(timeIntervalSince1970: 10_000) }),
            transport: { _ in
                OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"five_hour":{"utilization":10,"resets_at":1781205600},
                 "seven_day":{"utilization":40,"resets_at":1781406000}}
                """.data(using: .utf8)!)
            },
            userAgentVersion: { "9.9.9" },
            now: { Date(timeIntervalSince1970: 10_000) },
            tokenMirrorWriter: { creds in
                mirrored.value = mirrored.value + [creds.accessToken]
                try? ClaudeOAuthTokenMirror.write(creds)
            }
        )
        _ = try client.fetchStatusLinePayload()
        XCTAssertEqual(mirrored.value, ["tok"])
        // 镜像文件存在且 token 未变 → 不重写。
        _ = try client.fetchStatusLinePayload()
        XCTAssertEqual(mirrored.value.count, 1)
        // 模拟监控关闭删除镜像：下一次轮询必须自愈重写。
        ClaudeOAuthTokenMirror.delete()
        _ = try client.fetchStatusLinePayload()
        XCTAssertEqual(mirrored.value, ["tok", "tok"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path))
    }
}
