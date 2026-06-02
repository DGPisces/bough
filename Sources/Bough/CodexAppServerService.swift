import Foundation
import BoughCore

protocol CodexAppServerTransport: AnyObject {
    var onMessage: (@Sendable (CodexJSONRPCMessage) -> Void)? { get set }
    var onExit: (@Sendable (Int32) -> Void)? { get set }

    func start() throws
    func stop()
    func initializeHandshake(clientName: String, clientVersion: String) throws -> CodexRequestID
    func sendRequest(method: String, params: Any?) throws -> CodexRequestID
}

protocol CodexAppServerSleeping: AnyObject {
    func sleep(seconds: TimeInterval) async
}

final class TaskCodexAppServerSleeper: CodexAppServerSleeping {
    func sleep(seconds: TimeInterval) async {
        let nanos = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}

extension CodexAppServerClient: CodexAppServerTransport {}

@MainActor
final class CodexAppServerService: UsageRateLimitReading {
    enum Error: Swift.Error {
        case serviceStopped
        case requestTimedOut
        case appServerError(String)
    }

    var onThreadNotification: ((CodexJSONRPCMessage) -> Void)?
    var onRateLimitsUpdated: ((CodexJSONRPCMessage) -> Void)?
    var onExit: (() -> Void)?

    private let transport: CodexAppServerTransport
    private let timeoutSeconds: TimeInterval
    private let sleeper: CodexAppServerSleeping

    private var isStopped = false
    private var nextGeneration: Int = 0
    private var pendingRateLimitRead: PendingRateLimitRead?
    private var earlyRateLimitReadResponses: [CodexRequestID: Result<[String: AnyCodableLike], Swift.Error>] = [:]
    private var isSendingRateLimitReadRequest = false
    private var timeoutTask: Task<Void, Never>?

    private struct PendingRateLimitRead {
        let generation: Int
        let requestID: CodexRequestID
        var continuations: [CheckedContinuation<[String: AnyCodableLike], Swift.Error>]
    }

    init(
        transport: CodexAppServerTransport,
        timeoutSeconds: TimeInterval = 10,
        sleeper: CodexAppServerSleeping = TaskCodexAppServerSleeper()
    ) {
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
        self.sleeper = sleeper

        transport.onMessage = { [weak self] message in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleTransportMessage(message)
            }
        }
        transport.onExit = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleTransportExit()
            }
        }
    }

    func start(clientVersion: String, clientName: String = "Bough") throws {
        guard !isStopped else { throw Error.serviceStopped }
        var transportStarted = false
        do {
            try transport.start()
            transportStarted = true
            _ = try transport.initializeHandshake(clientName: clientName, clientVersion: clientVersion)
        } catch {
            isStopped = true
            if transportStarted {
                transport.stop()
            }
            throw error
        }
    }

    func stop() {
        guard !isStopped else {
            if !hasActivePendingRead() { return }
            failPendingReads(with: Error.serviceStopped)
            onExit?()
            return
        }

        isStopped = true
        nextGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        earlyRateLimitReadResponses.removeAll()
        isSendingRateLimitReadRequest = false
        failPendingReads(with: Error.serviceStopped)
        transport.onMessage = nil
        transport.onExit = nil
        transport.stop()
        onExit?()
    }

    func readRateLimits() async throws -> [String: AnyCodableLike] {
        guard !isStopped else { throw Error.serviceStopped }

        if var pending = pendingRateLimitRead {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: AnyCodableLike], Swift.Error>) in
                pending.continuations.append(continuation)
                pendingRateLimitRead = pending
            }
        }

        let requestID: CodexRequestID
        do {
            isSendingRateLimitReadRequest = true
            defer { isSendingRateLimitReadRequest = false }
            requestID = try transport.sendRequest(method: "account/rateLimits/read", params: nil)
        } catch {
            earlyRateLimitReadResponses.removeAll()
            throw Error.appServerError("\(error)")
        }
        if let earlyResponse = earlyRateLimitReadResponses.removeValue(forKey: requestID) {
            earlyRateLimitReadResponses.removeAll()
            return try earlyResponse.get()
        }
        earlyRateLimitReadResponses.removeAll()
        let generation = nextGeneration
        let request = PendingRateLimitRead(
            generation: generation,
            requestID: requestID,
            continuations: []
        )
        pendingRateLimitRead = request
        scheduleTimeout(for: request)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: AnyCodableLike], Swift.Error>) in
            guard var request = pendingRateLimitRead,
                  request.requestID == requestID
            else { continuation.resume(throwing: Error.serviceStopped); return }
            request.continuations.append(continuation)
            pendingRateLimitRead = request
        }
    }

    private func handleTransportMessage(_ message: CodexJSONRPCMessage) {
        guard !isStopped else { return }
        switch message.kind {
        case .notification:
            routeNotification(message)
        case .response(let responseID):
            guard let pending = pendingRateLimitRead else {
                bufferEarlyRateLimitResponse(responseID, message: message)
                return
            }
            guard responseID == pending.requestID else { return }
            guard pending.generation == nextGeneration else { return }
            guard let result = message.raw["result"]?.asObject else {
                failPendingReads(with: Error.appServerError("Invalid rate limit response"))
                return
            }
            completePendingReads(with: result)

        case .error(let responseID, let code, let messageText):
            guard let responseID else { return }
            let error = Error.appServerError("code=\(code) message=\(messageText)")
            guard let pending = pendingRateLimitRead else {
                bufferEarlyRateLimitFailure(responseID, error: error)
                return
            }
            guard responseID == pending.requestID else { return }
            guard pending.generation == nextGeneration else { return }
            failPendingReads(with: error)

        default:
            break
        }
    }

    private func bufferEarlyRateLimitResponse(_ responseID: CodexRequestID, message: CodexJSONRPCMessage) {
        guard isSendingRateLimitReadRequest else { return }
        guard let result = message.raw["result"]?.asObject else {
            earlyRateLimitReadResponses[responseID] = .failure(Error.appServerError("Invalid rate limit response"))
            return
        }
        earlyRateLimitReadResponses[responseID] = .success(result)
    }

    private func bufferEarlyRateLimitFailure(_ responseID: CodexRequestID, error: Swift.Error) {
        guard isSendingRateLimitReadRequest else { return }
        earlyRateLimitReadResponses[responseID] = .failure(error)
    }

    private func routeNotification(_ message: CodexJSONRPCMessage) {
        guard case .notification(let method) = message.kind else { return }
        if method.hasPrefix("thread/") {
            onThreadNotification?(message)
        }
        if method == "account/rateLimits/updated" {
            onRateLimitsUpdated?(message)
        }
    }

    private func completePendingReads(with result: [String: AnyCodableLike]) {
        guard let pending = pendingRateLimitRead else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingRateLimitRead = nil
        for continuation in pending.continuations {
            continuation.resume(returning: result)
        }
    }

    private func failPendingReads(with error: Error) {
        guard let pending = pendingRateLimitRead else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingRateLimitRead = nil
        for continuation in pending.continuations {
            continuation.resume(throwing: error)
        }
    }

    private func scheduleTimeout(for request: PendingRateLimitRead) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            await self.sleeper.sleep(seconds: timeoutSeconds)
            guard !Task.isCancelled else { return }
            guard let pending = self.pendingRateLimitRead,
                  pending.requestID == request.requestID,
                  pending.generation == request.generation else { return }
            self.failPendingReads(with: .requestTimedOut)
        }
    }

    private func handleTransportExit() {
        guard !isStopped else {
            if hasActivePendingRead() {
                failPendingReads(with: Error.serviceStopped)
            }
            return
        }

        isStopped = true
        nextGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        earlyRateLimitReadResponses.removeAll()
        isSendingRateLimitReadRequest = false
        failPendingReads(with: Error.serviceStopped)
        transport.onMessage = nil
        transport.onExit = nil
        onExit?()
    }

    private func hasActivePendingRead() -> Bool {
        pendingRateLimitRead != nil
    }
}
