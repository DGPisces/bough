import Foundation

// MARK: - Credentials

public struct ClaudeOAuthCredentials: Equatable, Sendable {
    public let accessToken: String
    /// Decoded from `expiresAt` milliseconds.
    public let expiresAt: Date?
    public let scopes: [String]
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, scopes: [String], subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
    }

    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// Parses the `{"claudeAiOauth": {...}}` shape shared by
    /// `~/.claude/.credentials.json`, the Keychain item, and Bough's token mirror.
    public static func parse(jsonData: Data) -> ClaudeOAuthCredentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            expiresAt = nil
        }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: (oauth["scopes"] as? [String]) ?? [],
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}

public enum KeychainReadFailure: Error, Equatable {
    case itemNotFound
    case denied(status: Int32)
}

/// Ordered credential resolution (spec §4.1): file URLs first (app:
/// `.credentials.json`; helper: token mirror → `.credentials.json`), then the
/// injected Keychain closure. The Keychain implementation lives in the app
/// target (Security import is forbidden in BoughCore); the helper passes nil.
public final class ClaudeOAuthCredentialsReader: @unchecked Sendable {
    public static let keychainDenialCooldown: TimeInterval = 6 * 60 * 60
    private static let cooldownKey = "claude.keychainDenied"

    private let fileURLs: [URL]
    private let keychainRead: (() -> Result<Data, KeychainReadFailure>)?
    private let now: () -> Date
    private let gate: OAuthCooldownGate

    public static func defaultCredentialsFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
    }

    public init(
        fileURLs: [URL] = [ClaudeOAuthCredentialsReader.defaultCredentialsFileURL()],
        keychainRead: (() -> Result<Data, KeychainReadFailure>)?,
        now: @escaping () -> Date = Date.init,
        gate: OAuthCooldownGate = .shared
    ) {
        self.fileURLs = fileURLs
        self.keychainRead = keychainRead
        self.now = now
        self.gate = gate
    }

    public func resetKeychainCooldown() {
        gate.clear(key: Self.cooldownKey)
    }

    /// - Throws: `OAuthUsageError.tokenExpired` when at least one source parsed
    ///   but every parsed token is expired; `.keychainDenied` on ACL denial
    ///   (with a 6h gate); `.credentialsUnavailable` otherwise.
    public func read() throws -> ClaudeOAuthCredentials {
        var sawExpired = false
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url),
                  let creds = ClaudeOAuthCredentials.parse(jsonData: data) else { continue }
            if creds.isExpired(now: now()) { sawExpired = true; continue }
            return creds
        }

        if let keychainRead {
            if gate.activeCooldown(key: Self.cooldownKey, now: now()) == nil {
                switch keychainRead() {
                case .success(let data):
                    if let creds = ClaudeOAuthCredentials.parse(jsonData: data) {
                        if !creds.isExpired(now: now()) { return creds }
                        sawExpired = true
                    }
                case .failure(.itemNotFound):
                    break
                case .failure(.denied):
                    gate.setCooldown(
                        key: Self.cooldownKey,
                        until: now().addingTimeInterval(Self.keychainDenialCooldown)
                    )
                    throw OAuthUsageError.keychainDenied
                }
            } else {
                throw OAuthUsageError.keychainDenied
            }
        }

        if sawExpired { throw OAuthUsageError.tokenExpired }
        throw OAuthUsageError.credentialsUnavailable(reason: "No Claude Code OAuth credentials found")
    }
}

// MARK: - Mapper

/// Maps the `/api/oauth/usage` response onto the statusline payload shape so
/// `ClaudeCodeRateLimitParser` is reused verbatim (spec §4.2). Lossy: unknown
/// fields and extra windows are ignored.
public enum ClaudeOAuthUsageMapper {
    public static func statusLinePayloadData(fromOAuthBody body: Data) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        var rateLimits: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let bucket = root[key] as? [String: Any] else { continue }
            var window: [String: Any] = [:]
            if let used = bucket["utilization"] as? Double {
                window["used_percentage"] = used
            } else if let used = bucket["utilization"] as? Int {
                window["used_percentage"] = Double(used)
            }
            if let resetsAt = bucket["resets_at"] { window["resets_at"] = resetsAt }
            if window["used_percentage"] != nil, window["resets_at"] != nil {
                rateLimits[key] = window
            }
        }
        guard !rateLimits.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["rate_limits": rateLimits])
    }
}

// MARK: - Token mirror (spec §6.1)

/// App → helper access-token mirror. Stores ONLY the access token + expiry —
/// never the refresh token. Lifetime is bound to the background monitor being
/// enabled; `UsageMonitorService` deletes it on disable/uninstall.
public enum ClaudeOAuthTokenMirror {
    public static let relativePath = "claude-oauth-credentials.json"

    private struct MirrorPayload: Codable {
        struct OAuth: Codable {
            let accessToken: String
            /// Milliseconds, matching the `.credentials.json` shape so
            /// `ClaudeOAuthCredentials.parse` reads the mirror unchanged.
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    public static func fileURL() -> URL {
        AtomicJSONStore.baseDirectoryURL().appendingPathComponent(relativePath)
    }

    public static func write(_ credentials: ClaudeOAuthCredentials) throws {
        let payload = MirrorPayload(claudeAiOauth: .init(
            accessToken: credentials.accessToken,
            expiresAt: credentials.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
        ))
        try AtomicJSONStore.write(payload, to: relativePath)
    }

    public static func delete() {
        try? AtomicJSONStore.delete(relativePath)
    }
}

// MARK: - Client

public protocol ClaudeUsageFetching: AnyObject {
    /// Synchronous fetch returning a statusline-shaped payload Data. The app
    /// wraps this off the main actor; the helper calls it directly.
    func fetchStatusLinePayload() throws -> Data
    /// Manual-refresh hook: clears the Keychain denial gate so the user can
    /// retry after an accidental "Deny".
    func resetTransientGates()
}

public final class ClaudeOAuthUsageClient: ClaudeUsageFetching, @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let rateLimitCooldownFloor: TimeInterval = 300
    public static let unauthorizedCooldown: TimeInterval = 15 * 60
    private static let rateLimitKey = "claude.rateLimited"
    private static let unauthorizedKey = "claude.unauthorized"

    private let credentialsReader: ClaudeOAuthCredentialsReader
    private let transport: OAuthHTTPTransport
    private let userAgentVersion: () -> String
    private let now: () -> Date
    private let gate: OAuthCooldownGate
    /// Optional spec §6.1 mirror hook. Called after every successful credential
    /// read; the closure decides whether mirroring is currently enabled.
    private let tokenMirrorWriter: ((ClaudeOAuthCredentials) -> Void)?
    private let mirrorLock = NSLock()
    private var lastMirroredToken: String?

    public init(
        credentialsReader: ClaudeOAuthCredentialsReader,
        transport: @escaping OAuthHTTPTransport = OAuthLiveTransport.make(),
        userAgentVersion: @escaping () -> String = { ClaudeCLIVersionProbe.cachedVersion() },
        now: @escaping () -> Date = Date.init,
        gate: OAuthCooldownGate = .shared,
        tokenMirrorWriter: ((ClaudeOAuthCredentials) -> Void)? = nil
    ) {
        self.credentialsReader = credentialsReader
        self.transport = transport
        self.userAgentVersion = userAgentVersion
        self.now = now
        self.gate = gate
        self.tokenMirrorWriter = tokenMirrorWriter
    }

    public func resetTransientGates() {
        credentialsReader.resetKeychainCooldown()
        gate.clear(key: Self.unauthorizedKey)
    }

    public func fetchStatusLinePayload() throws -> Data {
        for key in [Self.rateLimitKey, Self.unauthorizedKey] {
            if let until = gate.activeCooldown(key: key, now: now()) {
                throw OAuthUsageError.cooldownActive(until: until)
            }
        }
        let credentials = try credentialsReader.read()
        mirrorIfNeeded(credentials)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(userAgentVersion())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try transport(request)
        switch response.statusCode {
        case 200:
            guard let payload = ClaudeOAuthUsageMapper.statusLinePayloadData(fromOAuthBody: response.body) else {
                throw OAuthUsageError.parseFailed
            }
            return payload
        case 401, 403:
            gate.setCooldown(
                key: Self.unauthorizedKey,
                until: now().addingTimeInterval(Self.unauthorizedCooldown)
            )
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

    private func mirrorIfNeeded(_ credentials: ClaudeOAuthCredentials) {
        guard let tokenMirrorWriter else { return }
        // Self-heal: the monitor lifecycle deletes the mirror on disable; a
        // missing file must be rewritten on the next poll even when the token
        // itself has not rotated (spec §6.3).
        let mirrorMissing = !FileManager.default.fileExists(atPath: ClaudeOAuthTokenMirror.fileURL().path)
        mirrorLock.lock()
        let changed = lastMirroredToken != credentials.accessToken
        if changed || mirrorMissing { lastMirroredToken = credentials.accessToken }
        mirrorLock.unlock()
        if changed || mirrorMissing { tokenMirrorWriter(credentials) }
    }
}
