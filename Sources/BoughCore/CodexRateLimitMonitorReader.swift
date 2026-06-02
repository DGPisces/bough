import Foundation

public protocol CodexRateLimitMonitorReading: AnyObject {
    func readRateLimits() throws -> [String: AnyCodableLike]
}

public enum CodexRateLimitMonitorReaderError: Error, Equatable {
    case serviceStopped
    case requestTimedOut
    case invalidRateLimitResponse
    case appServerError(String)
}

public final class CodexAppServerRateLimitMonitorReader: CodexRateLimitMonitorReading {
    private let executableURL: URL
    private let timeoutSeconds: TimeInterval
    private let clientVersion: String
    private let callbackQueue: DispatchQueue

    public init(
        executableURL: URL = URL(fileURLWithPath: CodexAppServerClient.defaultExecutablePath),
        timeoutSeconds: TimeInterval = 10,
        clientVersion: String = "BoughUsageMonitor",
        callbackQueue: DispatchQueue = DispatchQueue(label: "dev.dgpisces.bough.codex-rate-limit-monitor")
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
        self.clientVersion = clientVersion
        self.callbackQueue = callbackQueue
    }

    public func readRateLimits() throws -> [String: AnyCodableLike] {
        let state = CodexRateLimitReadState()
        let client = CodexAppServerClient(
            executableURL: executableURL,
            callbackQueue: callbackQueue
        )
        client.onMessage = { message in
            state.receive(message)
        }
        client.onExit = { _ in
            state.finish(.failure(CodexRateLimitMonitorReaderError.serviceStopped))
        }

        try client.start()
        defer { client.stop() }

        _ = try client.initializeHandshake(clientName: "Bough", clientVersion: clientVersion)
        let requestID = try client.sendRequest(method: "account/rateLimits/read", params: nil)
        state.setRequestID(requestID)

        guard state.wait(timeoutSeconds: timeoutSeconds) else {
            throw CodexRateLimitMonitorReaderError.requestTimedOut
        }
        return try state.resolvedResult()
    }
}

private final class CodexRateLimitReadState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var requestID: CodexRequestID?
    private var bufferedMessages: [CodexJSONRPCMessage] = []
    private var result: Result<[String: AnyCodableLike], Error>?

    func setRequestID(_ requestID: CodexRequestID) {
        let messages: [CodexJSONRPCMessage]
        lock.lock()
        self.requestID = requestID
        messages = bufferedMessages
        bufferedMessages.removeAll()
        lock.unlock()

        for message in messages {
            receive(message)
        }
    }

    func receive(_ message: CodexJSONRPCMessage) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }

        guard let requestID else {
            bufferedMessages.append(message)
            lock.unlock()
            return
        }

        let resolved: Result<[String: AnyCodableLike], Error>?
        switch message.kind {
        case .response(let responseID) where responseID == requestID:
            if let payload = message.raw["result"]?.asObject {
                resolved = .success(payload)
            } else {
                resolved = .failure(CodexRateLimitMonitorReaderError.invalidRateLimitResponse)
            }
        case .error(let responseID, let code, let messageText) where responseID == requestID:
            resolved = .failure(CodexRateLimitMonitorReaderError.appServerError("code=\(code) message=\(messageText)"))
        default:
            resolved = nil
        }

        guard let resolved else {
            lock.unlock()
            return
        }

        result = resolved
        lock.unlock()
        semaphore.signal()
    }

    func finish(_ result: Result<[String: AnyCodableLike], Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeoutSeconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }

    func resolvedResult() throws -> [String: AnyCodableLike] {
        lock.lock()
        let value = result
        lock.unlock()
        guard let value else {
            throw CodexRateLimitMonitorReaderError.serviceStopped
        }
        return try value.get()
    }
}
