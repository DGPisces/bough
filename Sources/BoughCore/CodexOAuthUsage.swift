import Foundation

// MARK: - Credentials (~/.codex/auth.json)

public struct CodexOAuthCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String?
    public let refreshToken: String?
    public let lastRefresh: Date?
    public let isAPIKey: Bool

    public static func parse(jsonData: Data) -> CodexOAuthCredentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexOAuthCredentials(
                accessToken: apiKey, accountId: nil, refreshToken: nil,
                lastRefresh: nil, isAPIKey: true
            )
        }
        guard let tokens = root["tokens"] as? [String: Any] else { return nil }
        guard let accessToken = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String),
              !accessToken.isEmpty else { return nil }
        let lastRefreshRaw = (root["last_refresh"] as? String) ?? (root["lastRefresh"] as? String)
        return CodexOAuthCredentials(
            accessToken: accessToken,
            accountId: (tokens["account_id"] as? String) ?? (tokens["accountId"] as? String),
            refreshToken: (tokens["refresh_token"] as? String) ?? (tokens["refreshToken"] as? String),
            lastRefresh: lastRefreshRaw.flatMap(parseISO8601),
            isAPIKey: false
        )
    }

    /// Codex may write `last_refresh` with or without fractional seconds
    /// (e.g. `2026-06-01T00:00:00.123Z`); accept both so a fractional
    /// timestamp does not silently disable the proactive refresh.
    private static func parseISO8601(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    public init(
        accessToken: String,
        accountId: String?,
        refreshToken: String?,
        lastRefresh: Date?,
        isAPIKey: Bool
    ) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.refreshToken = refreshToken
        self.lastRefresh = lastRefresh
        self.isAPIKey = isAPIKey
    }
}

// MARK: - Endpoint resolution

public enum CodexUsageEndpointResolver {
    public static let defaultBase = "https://chatgpt.com/backend-api"

    /// Lightweight single-line scan for `chatgpt_base_url = "…"` — deliberately
    /// NOT a TOML parser (BoughCore must stay dependency-free; the key is a
    /// simple top-level string in practice).
    public static func resolve(configTomlText: String?) -> URL {
        var base = defaultBase
        if let text = configTomlText {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
                guard let firstQuote = trimmed.firstIndex(of: "\"") else { continue }
                let afterQuote = trimmed.index(after: firstQuote)
                guard let endQuote = trimmed[afterQuote...].firstIndex(of: "\"") else { continue }
                let value = String(trimmed[afterQuote..<endQuote])
                if !value.isEmpty { base = value }
                break
            }
        }
        while base.hasSuffix("/") { base.removeLast() }
        let path = base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: base + path) ?? URL(string: defaultBase + "/wham/usage")!
    }
}

// MARK: - Mapper (wham → app-server rateLimits shape)

/// Maps the wham/usage response onto the app-server `rateLimits` shape so
/// `CodexRateLimitParser` is reused verbatim.
public enum CodexOAuthUsageMapper {
    public static func rateLimitsResult(fromWhamBody body: Data) -> [String: AnyCodableLike]? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return nil
        }
        var rateLimits: [String: AnyCodableLike] = [:]
        for (sourceKey, targetKey) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
            guard let window = rateLimit[sourceKey] as? [String: Any] else { continue }
            guard let usedPercent = doubleValue(window["used_percent"]),
                  let resetAt = doubleValue(window["reset_at"]),
                  let windowSeconds = doubleValue(window["limit_window_seconds"]) else { continue }
            rateLimits[targetKey] = .object([
                "usedPercent": .double(usedPercent),
                "windowDurationMins": .int(Int64(windowSeconds / 60)),
                "resetsAt": .double(resetAt),
            ])
        }
        guard !rateLimits.isEmpty else { return nil }
        if let planType = root["plan_type"] as? String {
            rateLimits["planType"] = .string(planType)
        }
        return ["rateLimits": .object(rateLimits)]
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Client

public protocol CodexUsageFetching: AnyObject {
    /// Returns the app-server-shaped result dict consumed by
    /// `UsageStore.applyCodexRateLimitResult` / `UsageMonitorRunner.acceptCodexRateLimitResult`.
    func fetchRateLimitsResult() throws -> [String: AnyCodableLike]
}

public final class CodexOAuthUsageClient: CodexUsageFetching, @unchecked Sendable {
    public static let refreshStalenessInterval: TimeInterval = 8 * 24 * 60 * 60
    public static let refreshClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    public static let unauthorizedCooldown: TimeInterval = 15 * 60
    public static let rateLimitCooldownFloor: TimeInterval = 300
    private static let unauthorizedKey = "codex.unauthorized"
    private static let rateLimitKey = "codex.rateLimited"
    private static let refreshFailureKey = "codex.refreshFailed"

    private let codexHomeURL: URL
    private let transport: OAuthHTTPTransport
    private let now: () -> Date
    private let gate: OAuthCooldownGate

    public static func defaultCodexHomeURL() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    public init(
        codexHomeURL: URL = CodexOAuthUsageClient.defaultCodexHomeURL(),
        transport: @escaping OAuthHTTPTransport = OAuthLiveTransport.make(),
        now: @escaping () -> Date = Date.init,
        gate: OAuthCooldownGate = .shared
    ) {
        self.codexHomeURL = codexHomeURL
        self.transport = transport
        self.now = now
        self.gate = gate
    }

    public func fetchRateLimitsResult() throws -> [String: AnyCodableLike] {
        for key in [Self.rateLimitKey, Self.unauthorizedKey] {
            if let until = gate.activeCooldown(key: key, now: now()) {
                throw OAuthUsageError.cooldownActive(until: until)
            }
        }
        let authURL = codexHomeURL.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let parsed = CodexOAuthCredentials.parse(jsonData: data) else {
            throw OAuthUsageError.credentialsUnavailable(reason: "~/.codex/auth.json missing or unreadable")
        }
        let credentials = refreshIfStale(parsed, authURL: authURL) ?? parsed

        let configText = try? String(
            contentsOf: codexHomeURL.appendingPathComponent("config.toml"), encoding: .utf8)
        var request = URLRequest(url: CodexUsageEndpointResolver.resolve(configTomlText: configText))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bough", forHTTPHeaderField: "User-Agent")

        let response = try transport(request)
        switch response.statusCode {
        case 200:
            guard let result = CodexOAuthUsageMapper.rateLimitsResult(fromWhamBody: response.body) else {
                throw OAuthUsageError.parseFailed
            }
            return result
        case 401, 403:
            gate.setCooldown(key: Self.unauthorizedKey, until: now().addingTimeInterval(Self.unauthorizedCooldown))
            throw OAuthUsageError.unauthorized(statusCode: response.statusCode)
        case 429:
            let retryAfter = response.header("retry-after").flatMap(TimeInterval.init)
            let cooldown = max(retryAfter ?? Self.rateLimitCooldownFloor, Self.rateLimitCooldownFloor)
            gate.setCooldown(key: Self.rateLimitKey, until: now().addingTimeInterval(cooldown))
            throw OAuthUsageError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw OAuthUsageError.httpStatus(response.statusCode)
        }
    }

    /// CodexBar-parity staleness refresh. Best-effort: any failure returns nil and
    /// the fetch proceeds with the existing token (a stale token then surfaces as
    /// 401 with its own cooldown). Pre-flight re-read + atomic write keep concurrent
    /// app/helper refreshes benign. Failed attempts arm a 401-tier cooldown
    /// (spec §5.1) so a persistently stale `last_refresh` does not re-POST to
    /// auth.openai.com on every fetch tick — the cooldown gates only the refresh
    /// attempt, never the usage fetch itself.
    private func refreshIfStale(
        _ credentials: CodexOAuthCredentials,
        authURL: URL
    ) -> CodexOAuthCredentials? {
        guard !credentials.isAPIKey,
              let refreshToken = credentials.refreshToken,
              let lastRefresh = credentials.lastRefresh,
              now().timeIntervalSince(lastRefresh) > Self.refreshStalenessInterval else {
            return nil
        }
        // Failed-refresh cooldown: skip the attempt, proceed with the old token.
        if gate.activeCooldown(key: Self.refreshFailureKey, now: now()) != nil {
            return nil
        }
        // Pre-flight re-read: another process may have refreshed already.
        if let freshData = try? Data(contentsOf: authURL),
           let fresh = CodexOAuthCredentials.parse(jsonData: freshData),
           let freshLast = fresh.lastRefresh,
           now().timeIntervalSince(freshLast) <= Self.refreshStalenessInterval {
            return fresh
        }

        var tokenRequest = URLRequest(url: Self.refreshEndpoint)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Self.refreshClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])
        guard let response = try? transport(tokenRequest), response.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let newAccess = body["access_token"] as? String, !newAccess.isEmpty else {
            armRefreshFailureCooldown()
            return nil
        }

        // Merge into the raw dict preserving unknown keys, then atomic write.
        // Write-back failures also arm the cooldown: the refresh itself
        // succeeded (and may have rotated the refresh token), so re-attempting
        // it every tick would rotate tokens against an unwritable file.
        guard let rawData = try? Data(contentsOf: authURL),
              var root = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] else {
            armRefreshFailureCooldown()
            return nil
        }
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = newAccess
        if let newRefresh = body["refresh_token"] as? String { tokens["refresh_token"] = newRefresh }
        if let newID = body["id_token"] as? String { tokens["id_token"] = newID }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: now())
        guard let updated = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            armRefreshFailureCooldown()
            return nil
        }
        // Atomic replace resets POSIX permissions to umask defaults (0644),
        // which would downgrade codex's 0600 token file to world-readable.
        // Capture the original mode and re-apply it (defaulting to 0600).
        let originalMode = (try? FileManager.default
            .attributesOfItem(atPath: authURL.path))?[.posixPermissions] as? NSNumber
        do {
            try updated.write(to: authURL, options: .atomic)
        } catch {
            // The refreshed token is valid in memory — use it for this fetch,
            // but arm the cooldown so we don't re-refresh (and rotate the
            // refresh token again) on every tick against an unwritable file.
            armRefreshFailureCooldown()
            return CodexOAuthCredentials.parse(jsonData: updated)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: originalMode ?? NSNumber(value: 0o600)],
            ofItemAtPath: authURL.path
        )
        return CodexOAuthCredentials.parse(jsonData: updated)
    }

    private func armRefreshFailureCooldown() {
        gate.setCooldown(
            key: Self.refreshFailureKey,
            until: now().addingTimeInterval(Self.unauthorizedCooldown)
        )
    }
}
