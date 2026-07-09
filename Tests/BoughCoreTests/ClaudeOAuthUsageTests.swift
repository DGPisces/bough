import XCTest
@testable import BoughCore

/// Fixtures for the KeychainReadMode / delegated-refresh tests (this plan).
/// Expiry is relative to the REAL clock so they read correctly both under
/// injected fixed `now` values (epoch-era) and the default Date.init.
private enum DelegationFixtures {
    static func credentialsData(expiresIn: TimeInterval) -> Data {
        let millis = (Date().timeIntervalSince1970 + expiresIn) * 1000
        return Data(
            #"{"claudeAiOauth":{"accessToken":"tok-fixture","expiresAt":\#(millis)}}"#.utf8)
    }
    static var freshCredentialsData: Data { credentialsData(expiresIn: 3600) }
    static var expiredCredentialsData: Data { credentialsData(expiresIn: -3600) }
    static var usageOKResponse: OAuthHTTPResponse {
        OAuthHTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"five_hour":{"utilization":42.0,"resets_at":"2026-07-09T12:00:00Z"}}"#.utf8))
    }
    static var unauthorizedResponse: OAuthHTTPResponse {
        OAuthHTTPResponse(statusCode: 401, headers: [:], body: Data())
    }
}

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
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(#"{"claudeAiOauth":{"accessToken":"kc","expiresAt":9000000000000}}"#.data(using: .utf8)!)
            },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        XCTAssertEqual(try reader.read().accessToken, "kc")
        XCTAssertEqual(keychainCalls.value, 1)
    }

    func testKeychainDenialSetsCooldownAndManualResetClearsIt() {
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 5000))
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [tempDir.appendingPathComponent("absent.json")],
            keychainRead: { _ in keychainCalls.increment(); return .failure(.denied(status: -25293)) },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        // F3: cooldown only arms on interactive denial; arm before the first read.
        reader.allowInteractiveReadOnce()
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
            keychainRead: { _ in keychainCalls.increment(); return .failure(.itemNotFound) },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try reader.read()) { error in
            guard case .credentialsUnavailable = error as? OAuthUsageError else {
                return XCTFail("expected credentialsUnavailable, got \(error)")
            }
        }
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 2)
    }

    // MARK: Keychain 读取抑制（弹窗最小化）

    func testReaderCachesKeychainCredentialsUntilExpiry() throws {
        // expiresAt 8000s；60s leeway → 7940s 前有效。
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 5000))
        let mdatBox = MutableBox(Date(timeIntervalSince1970: 100))
        let tokenBox = MutableBox(#"{"claudeAiOauth":{"accessToken":"kc1","expiresAt":8000000}}"#)
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(tokenBox.value.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { mdatBox.value },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        XCTAssertEqual(try reader.read().accessToken, "kc1")
        // 缓存期内不再触碰 Keychain
        nowBox.value = Date(timeIntervalSince1970: 6000)
        XCTAssertEqual(try reader.read().accessToken, "kc1")
        XCTAssertEqual(keychainCalls.value, 1)
        // 缓存过期 + 条目已更新（mdat 变化）→ 重新读取
        nowBox.value = Date(timeIntervalSince1970: 7990)
        mdatBox.value = Date(timeIntervalSince1970: 200)
        tokenBox.value = #"{"claudeAiOauth":{"accessToken":"kc2","expiresAt":9000000000000}}"#
        XCTAssertEqual(try reader.read().accessToken, "kc2")
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testKeychainDataReadSkippedWhenModificationDateUnchanged() {
        // Keychain 里是过期 token 且条目未变（CLI 空闲）→ 不做需要授权的
        // 数据读取（否则每个轮询周期都会弹授权框）。
        let keychainCalls = Counter()
        let mdatBox = MutableBox(Date(timeIntervalSince1970: 100))
        let tokenBox = MutableBox(#"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#)
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(tokenBox.value.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { mdatBox.value },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
        XCTAssertEqual(keychainCalls.value, 1)
        // mdat 未变 → 跳过数据读取，仍报 tokenExpired
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
        XCTAssertEqual(keychainCalls.value, 1)
        // CLI 刷新了 token（mdat 变化）→ 恢复读取
        mdatBox.value = Date(timeIntervalSince1970: 200)
        tokenBox.value = #"{"claudeAiOauth":{"accessToken":"fresh","expiresAt":9000000000000}}"#
        XCTAssertEqual(try reader.read().accessToken, "fresh")
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testKeychainSuccessRecordsMdatAndSkipsRereadAfterCacheExpiry() {
        // 成功读取后缓存过期，但条目未变 → 重新读取只会拿到同一个过期
        // token，因此跳过数据读取直接报 tokenExpired。
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 5000))
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(#"{"claudeAiOauth":{"accessToken":"kc","expiresAt":8000000}}"#.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { Date(timeIntervalSince1970: 100) },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        XCTAssertEqual(try reader.read().accessToken, "kc")
        nowBox.value = Date(timeIntervalSince1970: 7990)  // 过了 leeway 边界
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
        XCTAssertEqual(keychainCalls.value, 1)
    }

    func testResetKeychainCooldownForcesDataReadDespiteUnchangedMdat() {
        // 手动刷新（force）清除抑制状态：即使条目未变也允许一次数据读取。
        let keychainCalls = Counter()
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(#"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { Date(timeIntervalSince1970: 100) },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try reader.read())
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 1)
        reader.resetKeychainCooldown()
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testConcurrentReadAfterDenialDoesNotTriggerSecondDataRead() {
        // 线程 A 的数据读取挂起（授权弹窗打开），用户点 Deny；此时排队
        // 等待的线程 B 必须看到刚设置的拒绝冷却，而不是紧接着再做一次
        // 数据读取（= 立刻再弹一个窗）。
        let keychainCalls = Counter()
        let readStarted = DispatchSemaphore(value: 0)
        let denyClicked = DispatchSemaphore(value: 0)
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                readStarted.signal()
                denyClicked.wait()
                return .failure(.denied(status: -128))
            },
            keychainProbeModificationDate: { Date(timeIntervalSince1970: 100) },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        let firstDone = expectation(description: "first read")
        let secondDone = expectation(description: "second read")
        let firstError = MutableBox<Error?>(nil)
        let secondError = MutableBox<Error?>(nil)
        // F3: arm interactive so the first (dialog-capable) denial arms the gate;
        // the second read observes keychainDenied via the gate without a second closure call.
        reader.allowInteractiveReadOnce()
        DispatchQueue.global().async {
            if case .failure(let error) = Result(catching: { try reader.read() }) {
                firstError.value = error
            }
            firstDone.fulfill()
        }
        readStarted.wait()
        DispatchQueue.global().async {
            if case .failure(let error) = Result(catching: { try reader.read() }) {
                secondError.value = error
            }
            secondDone.fulfill()
        }
        // 让 B 抵达 keychainLock 等待点，再"点 Deny"。
        Thread.sleep(forTimeInterval: 0.05)
        denyClicked.signal()
        wait(for: [firstDone, secondDone], timeout: 5)
        XCTAssertEqual(firstError.value as? OAuthUsageError, .keychainDenied)
        XCTAssertEqual(secondError.value as? OAuthUsageError, .keychainDenied)
        XCTAssertEqual(keychainCalls.value, 1)
    }

    func testUnauthorizedRetriesSameTokenThenPicksUpRotatedToken() {
        // 401 只把缓存标记为可疑，不清空：条目未变 → 用原 token 重试
        // （瞬时 401 必须能自愈，且不读 Keychain）；条目变化（CLI 重新
        // 登录写入新 token）→ 做一次数据读取换用新 token。
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 10_000))
        let mdatBox = MutableBox(Date(timeIntervalSince1970: 100))
        let tokenBox = MutableBox(#"{"claudeAiOauth":{"accessToken":"stale","expiresAt":9000000000000}}"#)
        let authHeaders = MutableBox<[String]>([])
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(tokenBox.value.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { mdatBox.value },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { request in
                let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
                authHeaders.value = authHeaders.value + [token]
                if token == "Bearer stale" {
                    return OAuthHTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"five_hour":{"utilization":10,"resets_at":1781205600},
                 "seven_day":{"utilization":40,"resets_at":1781406000}}
                """.data(using: .utf8)!)
            },
            userAgentVersion: { "9.9.9" },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) {
            XCTAssertEqual($0 as? OAuthUsageError, .unauthorized(statusCode: 401))
        }
        XCTAssertEqual(keychainCalls.value, 1)
        // 冷却过后、条目未变：重试同一 token（不读 Keychain）→ 仍 401
        nowBox.value = nowBox.value.addingTimeInterval(16 * 60)
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) {
            XCTAssertEqual($0 as? OAuthUsageError, .unauthorized(statusCode: 401))
        }
        XCTAssertEqual(keychainCalls.value, 1)
        XCTAssertEqual(authHeaders.value, ["Bearer stale", "Bearer stale"])
        // CLI 重新登录写入新 token（mdat 变化）→ 一次数据读取后恢复
        nowBox.value = nowBox.value.addingTimeInterval(16 * 60)
        mdatBox.value = Date(timeIntervalSince1970: 200)
        tokenBox.value = #"{"claudeAiOauth":{"accessToken":"fresh2","expiresAt":9000000000000}}"#
        XCTAssertNoThrow(try client.fetchStatusLinePayload())
        XCTAssertEqual(keychainCalls.value, 2)
        XCTAssertEqual(authHeaders.value.last, "Bearer fresh2")
    }

    func testTransient401RecoversAutomaticallyWithSameToken() {
        // 服务器抖动误报 401：token 实际仍有效。冷却过后必须自动恢复，
        // 不需要人工刷新、也不需要条目变化。
        let nowBox = MutableBox(Date(timeIntervalSince1970: 10_000))
        let responses = MutableBox([401, 200])
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                .success(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9000000000000}}"#.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { Date(timeIntervalSince1970: 100) },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { _ in
                let status = responses.value.removeFirst()
                if status == 401 {
                    return OAuthHTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return OAuthHTTPResponse(statusCode: 200, headers: [:], body: """
                {"five_hour":{"utilization":10,"resets_at":1781205600},
                 "seven_day":{"utilization":40,"resets_at":1781406000}}
                """.data(using: .utf8)!)
            },
            userAgentVersion: { "9.9.9" },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try client.fetchStatusLinePayload())
        nowBox.value = nowBox.value.addingTimeInterval(16 * 60)
        XCTAssertNoThrow(try client.fetchStatusLinePayload())
    }

    func testShortCircuitKeepsTokenExpiredWhenFileSourceSawExpired() {
        // 过期的文件 token + 无法解析的 Keychain 条目：第一次和后续轮询
        // 必须报同一种错误（tokenExpired），徽标不能在两种状态间跳变。
        let expired = writeCredentials(
            #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#, to: "real.json")
        let keychainCalls = Counter()
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [expired],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(#"{"not-oauth":{}}"#.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { Date(timeIntervalSince1970: 100) },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
        XCTAssertEqual(keychainCalls.value, 1)
    }

    func testFreshlyModifiedItemMdatIsNotRecordedForSuppression() {
        // Keychain 的 mdat 只有秒级精度：条目刚被写过（<2s）时同一秒内
        // 可能还有第二次写入，此时记录 mdat 会漏掉后续变化 —— 不记录，
        // 下次轮询重新读取。
        let keychainCalls = Counter()
        let nowBox = MutableBox(Date(timeIntervalSince1970: 5000))
        let mdatBox = MutableBox(Date(timeIntervalSince1970: 4999))  // 1s 前，热写
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in
                keychainCalls.increment()
                return .success(#"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#.data(using: .utf8)!)
            },
            keychainProbeModificationDate: { mdatBox.value },
            now: { nowBox.value },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try reader.read())
        // mdat 属于热写窗口 → 未记录 → 下次仍然做数据读取
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 2)
        // 条目冷却（mdat 距今 ≥2s）→ 记录后开始抑制
        nowBox.value = Date(timeIntervalSince1970: 5010)
        mdatBox.value = Date(timeIntervalSince1970: 5000)
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 3)
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(keychainCalls.value, 3)
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

    func testParserAcceptsFractionalSecondResetTimestamps() throws {
        // The live /api/oauth/usage returns resets_at with microsecond
        // fractional seconds, e.g. "2026-06-17T13:10:00.533198+00:00". A default
        // ISO8601 formatter rejects those, which dropped the reset time, failed
        // the window, and surfaced as "Claude Code parse-failure".
        let oauthBody = """
        {"five_hour":{"utilization":3.0,"resets_at":"2026-06-17T13:10:00.533198+00:00"},
         "seven_day":{"utilization":4.0,"resets_at":"2026-06-21T03:00:00.533221+00:00"}}
        """.data(using: .utf8)!
        let payload = try XCTUnwrap(ClaudeOAuthUsageMapper.statusLinePayloadData(fromOAuthBody: oauthBody))
        let snapshot = try XCTUnwrap(ClaudeCodeRateLimitParser.parse(
            data: payload, receivedAt: Date(timeIntervalSince1970: 1_000)))
        guard case .available(let fiveHour) = snapshot.fiveHour,
              case .available(let weekly) = snapshot.weekly else {
            return XCTFail("expected both windows available")
        }
        XCTAssertEqual(fiveHour.usedPercent, 3.0, accuracy: 0.001)
        XCTAssertEqual(weekly.usedPercent, 4.0, accuracy: 0.001)
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(fiveHour.resetsAt, frac.date(from: "2026-06-17T13:10:00.533198+00:00"))
        XCTAssertEqual(weekly.resetsAt, frac.date(from: "2026-06-21T03:00:00.533221+00:00"))
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
            now: now,
            gate: OAuthCooldownGate()
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

    // MARK: - KeychainReadMode plumbing

    func testKeychainReadDefaultsToSilentMode() throws {
        var seenModes: [KeychainReadMode] = []
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { mode in
                seenModes.append(mode)
                return .success(DelegationFixtures.freshCredentialsData)
            },
            gate: OAuthCooldownGate()
        )
        _ = try reader.read()
        XCTAssertEqual(seenModes, [.silent])
    }

    func testAllowInteractiveReadOnceArmsExactlyOneRead() throws {
        var seenModes: [KeychainReadMode] = []
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { mode in
                seenModes.append(mode)
                // 返回过期凭据，避免缓存吞掉后续读取。
                return .success(DelegationFixtures.expiredCredentialsData)
            },
            keychainProbeModificationDate: { nil },  // 无 mdat → 每次都真实读取
            gate: OAuthCooldownGate()
        )
        reader.allowInteractiveReadOnce()
        XCTAssertThrowsError(try reader.read())
        XCTAssertThrowsError(try reader.read())
        XCTAssertEqual(seenModes, [.interactiveAllowed, .silent])
    }

    // F1: arm consumed by the read() call it was intended for, even when that
    // call never reaches the keychain (file source satisfies it earlier).
    func testInteractiveArmSpentByFileSatisfiedRead() throws {
        var seenModes: [KeychainReadMode] = []
        let credFile = tempDir.appendingPathComponent("creds.json")
        try DelegationFixtures.freshCredentialsData.write(to: credFile)
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [credFile],
            keychainRead: { mode in
                seenModes.append(mode)
                // Return itemNotFound so the second read throws without caching,
                // allowing us to confirm the mode without complicating the assertion.
                return .failure(.itemNotFound)
            },
            gate: OAuthCooldownGate()
        )
        // First read: file source succeeds; keychain closure never called.
        reader.allowInteractiveReadOnce()
        _ = try reader.read()
        XCTAssertTrue(seenModes.isEmpty, "keychain should not have been called")
        // Second read: arm is spent; file is gone so keychain is reached → must be .silent.
        try FileManager.default.removeItem(at: credFile)
        XCTAssertThrowsError(try reader.read()) // credentialsUnavailable; we care about mode
        XCTAssertEqual(seenModes, [.silent], "spent arm must not carry over to later reads")
    }

    // F3: silent denial does not arm the 6h cooldown.
    func testSilentDenialDoesNotArmCooldown() {
        let keychainCalls = Counter()
        let gate = OAuthCooldownGate()
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in keychainCalls.increment(); return .failure(.denied(status: -25308)) },
            now: { Date(timeIntervalSince1970: 5000) },
            gate: gate
        )
        // Silent denial (no allowInteractiveReadOnce) throws keychainDenied but must NOT arm gate.
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .keychainDenied)
        }
        XCTAssertEqual(keychainCalls.value, 1)
        // Second read must also reach the closure (no cooldown blocked it).
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .keychainDenied)
        }
        XCTAssertEqual(keychainCalls.value, 2)
    }

    func testItemUnchangedSinceLastReadTracksProbe() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        var probeDate = fixedDate
        let now = fixedDate.addingTimeInterval(10) // settle interval 已过
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(DelegationFixtures.freshCredentialsData) },
            keychainProbeModificationDate: { probeDate },
            now: { now },
            gate: OAuthCooldownGate()
        )
        // 尚无记录 → 视为已变化（不确定 ≠ 未变）
        XCTAssertFalse(reader.keychainItemUnchangedSinceLastRead())
        _ = try reader.read() // 记录 mdat
        XCTAssertTrue(reader.keychainItemUnchangedSinceLastRead())
        probeDate = fixedDate.addingTimeInterval(60) // item 轮换
        XCTAssertFalse(reader.keychainItemUnchangedSinceLastRead())
    }

    // MARK: - Delegated refresh triggers

    /// 造一个 reader：文件源过期 → read() 抛 tokenExpired；委托刷新"成功"后
    /// keychain 闭包给出新鲜凭据。
    func testTokenExpiredTriggersDelegatedRefreshThenRetriesRead() throws {
        var keychainPayload = DelegationFixtures.expiredCredentialsData
        var refreshCalls = 0
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(keychainPayload) },
            keychainProbeModificationDate: { nil },
            gate: OAuthCooldownGate()
        )
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { _ in DelegationFixtures.usageOKResponse },
            gate: OAuthCooldownGate(),
            delegatedRefresh: {
                refreshCalls += 1
                keychainPayload = DelegationFixtures.freshCredentialsData
                return true
            }
        )
        let payload = try client.fetchStatusLinePayload()
        XCTAssertFalse(payload.isEmpty)
        XCTAssertEqual(refreshCalls, 1)
    }

    func testTokenExpiredWithoutDelegateRethrows() {
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(DelegationFixtures.expiredCredentialsData) },
            keychainProbeModificationDate: { nil },
            gate: OAuthCooldownGate()
        )
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { _ in DelegationFixtures.usageOKResponse },
            gate: OAuthCooldownGate()
        )
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .tokenExpired)
        }
    }

    private func credentialsData(accessToken: String, expiresIn: TimeInterval = 3600) -> Data {
        let millis = (Date().timeIntervalSince1970 + expiresIn) * 1000
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(accessToken)","expiresAt":\#(millis)}}"#.utf8)
    }

    func testUnauthorizedWithUnchangedItemDelegatesAndRetriesOnce() throws {
        // 第一次请求 401；委托刷新成功后重试返回 200。
        // F5: distinct tokens per phase so we can assert the retry used the rotated token.
        let fixedMdat = Date(timeIntervalSince1970: 3_000_000)
        var requests = 0
        var keychainPayload = credentialsData(accessToken: "tok-old")
        var refreshCalls = 0
        var capturedAuthHeaders: [String] = []
        let now = fixedMdat.addingTimeInterval(100)
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(keychainPayload) },
            keychainProbeModificationDate: { fixedMdat },  // 永不变 → itemUnchanged = true
            now: { now },
            gate: OAuthCooldownGate()
        )
        let gate = OAuthCooldownGate()
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { request in
                capturedAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                requests += 1
                return requests == 1 ? DelegationFixtures.unauthorizedResponse : DelegationFixtures.usageOKResponse
            },
            now: { now },
            gate: gate,
            delegatedRefresh: {
                refreshCalls += 1
                keychainPayload = self.credentialsData(accessToken: "tok-new")
                return true
            }
        )
        let payload = try client.fetchStatusLinePayload()
        XCTAssertFalse(payload.isEmpty)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(requests, 2)
        // F5: first request used tok-old, retry used the rotated tok-new.
        XCTAssertEqual(capturedAuthHeaders.first, "Bearer tok-old")
        XCTAssertEqual(capturedAuthHeaders.last, "Bearer tok-new")
        // 重试成功 → 不得武装 unauthorized 冷却。
        XCTAssertNil(gate.activeCooldown(key: "claude.unauthorized", now: now))
    }

    func testUnauthorizedRetryFailureArmsCooldownAndThrows() {
        let fixedMdat = Date(timeIntervalSince1970: 3_000_000)
        let now = fixedMdat.addingTimeInterval(100)
        var requests = 0
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(DelegationFixtures.freshCredentialsData) },
            keychainProbeModificationDate: { fixedMdat },
            now: { now },
            gate: OAuthCooldownGate()
        )
        let gate = OAuthCooldownGate()
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { _ in requests += 1; return DelegationFixtures.unauthorizedResponse },
            now: { now },
            gate: gate,
            delegatedRefresh: { true }
        )
        XCTAssertThrowsError(try client.fetchStatusLinePayload()) { error in
            XCTAssertEqual(error as? OAuthUsageError, .unauthorized(statusCode: 401))
        }
        XCTAssertEqual(requests, 2)  // 原始 + 单次重试，绝无第三次
        XCTAssertNotNil(gate.activeCooldown(key: "claude.unauthorized", now: now))
    }

    func testUnauthorizedWithChangedItemDoesNotDelegate() {
        // item 已变（探测返回新日期）→ 委托刷新不该被调用（下一轮 suspect 探测会拿新令牌）。
        var probeDate = Date(timeIntervalSince1970: 3_000_000)
        let now = probeDate.addingTimeInterval(100)
        var refreshCalls = 0
        let reader = ClaudeOAuthCredentialsReader(
            fileURLs: [],
            keychainRead: { _ in .success(DelegationFixtures.freshCredentialsData) },
            keychainProbeModificationDate: { probeDate },
            now: { now },
            gate: OAuthCooldownGate()
        )
        let client = ClaudeOAuthUsageClient(
            credentialsReader: reader,
            transport: { _ in
                probeDate = probeDate.addingTimeInterval(60)  // 请求后 item 轮换
                return DelegationFixtures.unauthorizedResponse
            },
            now: { now },
            gate: OAuthCooldownGate(),
            delegatedRefresh: { refreshCalls += 1; return true }
        )
        XCTAssertThrowsError(try client.fetchStatusLinePayload())
        XCTAssertEqual(refreshCalls, 0)
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
            gate: OAuthCooldownGate(),
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
