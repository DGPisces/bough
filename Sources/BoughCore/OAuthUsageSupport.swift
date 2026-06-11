import Foundation

/// Typed failures for the OAuth usage channels (Claude / Codex). `isAuthFailure`
/// drives the Codex auth-failure-only CLI fallback (spec §5.3) and the Settings
/// badge reason mapping.
public enum OAuthUsageError: Error, Equatable {
    case credentialsUnavailable(reason: String)
    case tokenExpired
    case keychainDenied
    case unauthorized(statusCode: Int)
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case httpStatus(Int)
    case network(String)
    case parseFailed
    case cooldownActive(until: Date)

    public var isAuthFailure: Bool {
        switch self {
        case .credentialsUnavailable, .tokenExpired, .keychainDenied, .unauthorized:
            return true
        case .rateLimited, .httpStatus, .network, .parseFailed, .cooldownActive:
            return false
        }
    }
}

public struct OAuthHTTPResponse: Sendable {
    public let statusCode: Int
    /// Header names normalized to lowercase at init.
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        var normalized: [String: String] = [:]
        for (key, value) in headers { normalized[key.lowercased()] = value }
        self.headers = normalized
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Synchronous transport seam. Tests inject a stub; production uses
/// `OAuthLiveTransport.make()`. Synchronous so the helper's single-threaded
/// loop can call it directly; the app always wraps calls off the main actor.
public typealias OAuthHTTPTransport = @Sendable (URLRequest) throws -> OAuthHTTPResponse

public enum OAuthLiveTransport {
    public static func make(timeout: TimeInterval = 15) -> OAuthHTTPTransport {
        { request in
            var request = request
            request.timeoutInterval = timeout
            let semaphore = DispatchSemaphore(value: 0)
            let resultBox = OAuthTransportResultBox()
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    resultBox.set(.failure(OAuthUsageError.network(error.localizedDescription)))
                } else if let http = response as? HTTPURLResponse {
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let key = key as? String, let value = value as? String {
                            headers[key] = value
                        }
                    }
                    resultBox.set(.success(OAuthHTTPResponse(
                        statusCode: http.statusCode,
                        headers: headers,
                        body: data ?? Data()
                    )))
                } else {
                    resultBox.set(.failure(OAuthUsageError.network("non-HTTP response")))
                }
                semaphore.signal()
            }
            task.resume()
            guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
                task.cancel()
                throw OAuthUsageError.network("request timed out")
            }
            return try resultBox.get()
        }
    }
}

private final class OAuthTransportResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<OAuthHTTPResponse, Error> = .failure(OAuthUsageError.network("no response"))
    func set(_ value: Result<OAuthHTTPResponse, Error>) {
        lock.lock(); result = value; lock.unlock()
    }
    func get() throws -> OAuthHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        return try result.get()
    }
}

/// Process-wide cooldown registry shared by both OAuth clients (spec §4.3).
/// Keys are namespaced strings (e.g. "claude.rateLimited"). Thread-safe;
/// expired entries are pruned on read.
public final class OAuthCooldownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cooldowns: [String: Date] = [:]

    public init() {}

    public func activeCooldown(key: String, now: Date) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = cooldowns[key] else { return nil }
        if until <= now {
            cooldowns.removeValue(forKey: key)
            return nil
        }
        return until
    }

    public func setCooldown(key: String, until: Date) {
        lock.lock(); cooldowns[key] = until; lock.unlock()
    }

    public func clear(key: String) {
        lock.lock(); cooldowns.removeValue(forKey: key); lock.unlock()
    }

    public func clearAll() {
        lock.lock(); cooldowns.removeAll(); lock.unlock()
    }
}
