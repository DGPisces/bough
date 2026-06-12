import Foundation

protocol MusicNowPlayingServicing: AnyObject {
    var isNowPlayingPollingLikelyUseful: Bool { get }
    func currentSnapshot() async throws -> MusicNowPlayingSnapshot?
    func currentSnapshot(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingSnapshot?
    func setPollingAvailabilityDidChangeHandler(_ handler: (@MainActor () -> Void)?)
    func send(_ command: MusicCommand) async throws
    func seek(to seconds: TimeInterval) async throws
}

extension MusicNowPlayingServicing {
    var isNowPlayingPollingLikelyUseful: Bool {
        true
    }

    func currentSnapshot(bypassingScriptBackoff _: Bool) async throws -> MusicNowPlayingSnapshot? {
        try await currentSnapshot()
    }

    func setPollingAvailabilityDidChangeHandler(_: (@MainActor () -> Void)?) {}

    func seek(to _: TimeInterval) async throws {
        throw MusicNowPlayingServiceError.commandUnavailable
    }
}

final class NoopMusicNowPlayingService: MusicNowPlayingServicing {
    func currentSnapshot() async throws -> MusicNowPlayingSnapshot? {
        nil
    }

    func send(_ command: MusicCommand) async throws {
        throw MusicNowPlayingServiceError.commandUnavailable
    }
}

enum MusicNowPlayingServiceError: LocalizedError, Equatable {
    case unavailable
    case commandUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Music service unavailable"
        case .commandUnavailable:
            return "Music command unavailable"
        }
    }
}
