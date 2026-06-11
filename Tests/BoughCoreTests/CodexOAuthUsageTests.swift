import XCTest
@testable import BoughCore

final class CodexOAuthUsageTests: XCTestCase {
    private var codexHome: URL!

    override func setUp() {
        super.setUp()
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOAuthUsageTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: codexHome)
        super.tearDown()
    }

    private func writeAuthJSON(_ json: String) {
        try! json.data(using: .utf8)!.write(to: codexHome.appendingPathComponent("auth.json"))
    }

    func testParseAuthJSONSnakeAndCamelCase() {
        let snake = #"{"tokens":{"access_token":"a1","refresh_token":"r1","account_id":"acc"},"last_refresh":"2026-06-01T00:00:00Z"}"#
        let creds1 = CodexOAuthCredentials.parse(jsonData: snake.data(using: .utf8)!)
        XCTAssertEqual(creds1?.accessToken, "a1")
        XCTAssertEqual(creds1?.accountId, "acc")
        XCTAssertEqual(creds1?.refreshToken, "r1")
        XCTAssertEqual(creds1?.lastRefresh, ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z"))

        let camel = #"{"tokens":{"accessToken":"a2","accountId":"acc2"},"lastRefresh":"2026-06-01T00:00:00Z"}"#
        XCTAssertEqual(CodexOAuthCredentials.parse(jsonData: camel.data(using: .utf8)!)?.accessToken, "a2")
    }

    func testParseAuthJSONAPIKeyPassthrough() {
        let creds = CodexOAuthCredentials.parse(jsonData: #"{"OPENAI_API_KEY":"sk-test"}"#.data(using: .utf8)!)
        XCTAssertEqual(creds?.accessToken, "sk-test")
        XCTAssertTrue(creds?.isAPIKey == true)
    }

    func testEndpointResolverDefaultAndOverride() {
        XCTAssertEqual(
            CodexUsageEndpointResolver.resolve(configTomlText: nil).absoluteString,
            "https://chatgpt.com/backend-api/wham/usage"
        )
        XCTAssertEqual(
            CodexUsageEndpointResolver.resolve(configTomlText: "chatgpt_base_url = \"https://proxy.corp/backend-api\"\n").absoluteString,
            "https://proxy.corp/backend-api/wham/usage"
        )
        // base 不含 /backend-api → /api/codex/usage（CodexBar 同款）
        XCTAssertEqual(
            CodexUsageEndpointResolver.resolve(configTomlText: "chatgpt_base_url = \"https://proxy.corp\"").absoluteString,
            "https://proxy.corp/api/codex/usage"
        )
    }

    func testMapperProducesParserCompatibleResult() throws {
        let body = """
        {"plan_type":"pro","rate_limit":{
          "primary_window":{"used_percent":12,"reset_at":1781205600,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":55.5,"reset_at":1781406000,"limit_window_seconds":604800}}}
        """.data(using: .utf8)!
        let result = try XCTUnwrap(CodexOAuthUsageMapper.rateLimitsResult(fromWhamBody: body))
        let message = CodexJSONRPCMessage(raw: ["result": .object(result)], kind: .response(id: .string("t")))
        let snapshot = try XCTUnwrap(CodexRateLimitParser.parse(message: message, receivedAt: Date()))
        XCTAssertEqual(snapshot.planName, "pro")
        guard case .available(let fiveHour) = snapshot.fiveHour,
              case .available(let weekly) = snapshot.weekly else {
            return XCTFail("expected both windows")
        }
        XCTAssertEqual(fiveHour.usedPercent, 12, accuracy: 0.001)
        XCTAssertEqual(fiveHour.windowDurationMins, 300)
        XCTAssertEqual(weekly.usedPercent, 55.5, accuracy: 0.001)
        XCTAssertEqual(weekly.windowDurationMins, 10080)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_781_406_000))
    }

    func testRefreshSkippedWhenLastRefreshFresh() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recentISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        writeAuthJSON(#"{"tokens":{"access_token":"a","refresh_token":"r"},"last_refresh":"\#(recentISO)"}"#)
        let refreshCalls = Counter()
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { request in
                if request.url?.host == "auth.openai.com" { refreshCalls.increment() }
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"rate_limit":{"primary_window":{"used_percent":1,"reset_at":2100000,"limit_window_seconds":18000},
                "secondary_window":{"used_percent":2,"reset_at":2600000,"limit_window_seconds":604800}}}
                """.data(using: .utf8)!)
            },
            now: { now }
        )
        _ = try client.fetchRateLimitsResult()
        XCTAssertEqual(refreshCalls.value, 0)
    }

    func testRefreshFiresWhenStaleAndWritesBackPreservingUnknownKeys() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 24 * 3600))
        writeAuthJSON(#"{"tokens":{"access_token":"old","refresh_token":"r1","account_id":"acc"},"last_refresh":"\#(staleISO)","custom_key":"keep-me"}"#)
        let sawRefresh = MutableBox<URLRequest?>(nil)
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { request in
                if request.url?.host == "auth.openai.com" {
                    sawRefresh.set(request)
                    return OAuthHTTPResponse(statusCode: 200, headers: [:], body:
                        #"{"access_token":"new-tok","refresh_token":"r2","id_token":"id2"}"#.data(using: .utf8)!)
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-tok")
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"rate_limit":{"primary_window":{"used_percent":1,"reset_at":2100000,"limit_window_seconds":18000},
                "secondary_window":{"used_percent":2,"reset_at":2600000,"limit_window_seconds":604800}}}
                """.data(using: .utf8)!)
            },
            now: { now }
        )
        _ = try client.fetchRateLimitsResult()
        XCTAssertNotNil(sawRefresh.get())
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        ) as! [String: Any]
        XCTAssertEqual(written["custom_key"] as? String, "keep-me")
        let tokens = written["tokens"] as! [String: Any]
        XCTAssertEqual(tokens["access_token"] as? String, "new-tok")
        XCTAssertEqual(tokens["refresh_token"] as? String, "r2")
        XCTAssertEqual(tokens["account_id"] as? String, "acc")
        XCTAssertNotNil(written["last_refresh"])
    }

    func testRefreshWithoutNewRefreshTokenPreservesOldOne() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 24 * 3600))
        writeAuthJSON(#"{"tokens":{"access_token":"old","refresh_token":"r1"},"last_refresh":"\#(staleISO)"}"#)
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { request in
                if request.url?.host == "auth.openai.com" {
                    return OAuthHTTPResponse(statusCode: 200, headers: [:], body:
                        #"{"access_token":"new-tok"}"#.data(using: .utf8)!)
                }
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"rate_limit":{"primary_window":{"used_percent":1,"reset_at":2100000,"limit_window_seconds":18000},
                "secondary_window":{"used_percent":2,"reset_at":2600000,"limit_window_seconds":604800}}}
                """.data(using: .utf8)!)
            },
            now: { now }
        )
        _ = try client.fetchRateLimitsResult()
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        ) as! [String: Any]
        let tokens = written["tokens"] as! [String: Any]
        XCTAssertEqual(tokens["access_token"] as? String, "new-tok")
        XCTAssertEqual(tokens["refresh_token"] as? String, "r1")
    }

    func testRefreshWriteBackPreservesFilePermissions() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 24 * 3600))
        writeAuthJSON(#"{"tokens":{"access_token":"old","refresh_token":"r1"},"last_refresh":"\#(staleISO)"}"#)
        let authPath = codexHome.appendingPathComponent("auth.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { request in
                if request.url?.host == "auth.openai.com" {
                    return OAuthHTTPResponse(statusCode: 200, headers: [:], body:
                        #"{"access_token":"new-tok","refresh_token":"r2"}"#.data(using: .utf8)!)
                }
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"rate_limit":{"primary_window":{"used_percent":1,"reset_at":2100000,"limit_window_seconds":18000},
                "secondary_window":{"used_percent":2,"reset_at":2600000,"limit_window_seconds":604800}}}
                """.data(using: .utf8)!)
            },
            now: { now }
        )
        _ = try client.fetchRateLimitsResult()
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: authPath)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value, 0o600)
        // Write-back actually happened (not skipped).
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        ) as! [String: Any]
        XCTAssertEqual((written["tokens"] as! [String: Any])["access_token"] as? String, "new-tok")
    }

    func test401ThrowsUnauthorizedWithCooldown() {
        let nowBox = MutableBox<Date>(Date(timeIntervalSince1970: 2_000_000))
        writeAuthJSON(#"{"tokens":{"access_token":"a","refresh_token":"r"},"last_refresh":"2026-06-11T00:00:00Z"}"#)
        let calls = Counter()
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { _ in calls.increment(); return OAuthHTTPResponse(statusCode: 401, headers: [:], body: Data()) },
            now: { nowBox.get() }
        )
        XCTAssertThrowsError(try client.fetchRateLimitsResult()) {
            XCTAssertEqual(($0 as? OAuthUsageError)?.isAuthFailure, true)
        }
        nowBox.set(nowBox.get().addingTimeInterval(60))
        XCTAssertThrowsError(try client.fetchRateLimitsResult()) {
            guard case .cooldownActive = $0 as? OAuthUsageError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testMissingAuthJSONThrowsCredentialsUnavailable() {
        let client = CodexOAuthUsageClient(
            codexHomeURL: codexHome,
            transport: { _ in XCTFail("no request expected"); throw OAuthUsageError.network("x") },
            now: { Date() }
        )
        XCTAssertThrowsError(try client.fetchRateLimitsResult()) {
            XCTAssertEqual(($0 as? OAuthUsageError)?.isAuthFailure, true)
        }
    }

    // Fix 4: last_refresh with fractional seconds must parse to the correct Date.
    func testParseFractionalSecondLastRefresh() {
        let fractionalISO = "2026-06-01T00:00:00.123Z"
        let json = #"{"tokens":{"access_token":"a1","refresh_token":"r1"},"last_refresh":"\#(fractionalISO)"}"#
        let creds = CodexOAuthCredentials.parse(jsonData: json.data(using: .utf8)!)
        XCTAssertNotNil(creds?.lastRefresh, "lastRefresh must parse from fractional-seconds ISO8601")
        let fractionalFmt = ISO8601DateFormatter()
        fractionalFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = fractionalFmt.date(from: fractionalISO)
        XCTAssertEqual(creds?.lastRefresh, expected)
    }
}
