import Foundation
import XCTest
@testable import Bough

final class MusicMediaRemoteAdapterTests: XCTestCase {
    func testAdapterDoesNotLoadRuntimeUntilUsed() {
        var loadCount = 0
        _ = MediaRemoteNowPlayingService(runtimeLoader: {
            loadCount += 1
            return FakeMediaRemoteRuntime()
        })

        XCTAssertEqual(loadCount, 0)
    }

    func testAdapterReturnsUnavailableWhenPrivateFrameworkCannotLoad() async {
        let service = MediaRemoteNowPlayingService(runtimeLoader: {
            throw MusicNowPlayingServiceError.unavailable
        }, allowedPlayerMonitor: FakeAllowedPlayerMonitor())

        do {
            _ = try await service.currentSnapshot()
            XCTFail("Expected unavailable error")
        } catch let error as MusicNowPlayingServiceError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterParsesCurrentSnapshotThroughRuntime() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.tencent.QQMusicMac",
            displayName: "QQ Music",
            title: "Runtime Track",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: 1,
            playbackRate: nil
        )
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            now: { Date(timeIntervalSince1970: 99) }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertEqual(snapshot?.track?.title, "Runtime Track")
        XCTAssertEqual(snapshot?.capturedAt, Date(timeIntervalSince1970: 99))
    }

    func testAdapterForwardsScriptBackoffBypassToRuntime() async throws {
        let runtime = FakeMediaRemoteRuntime()
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor()
        )

        _ = try await service.currentSnapshot(bypassingScriptBackoff: true)

        XCTAssertEqual(runtime.scriptBackoffBypassRequests, [true])
    }

    func testAdapterSourceBacksOffEmptyScriptFallbackButAllowsBypass() throws {
        let source = try sourceFile("Sources/Bough/Music/MediaRemoteNowPlayingService.swift")
        let reader = try sourceFile("Sources/Bough/Music/OSAScriptNowPlayingPayloadReader.swift")

        XCTAssertTrue(reader.contains("private static let emptyOrFailureBackoffIntervals: [TimeInterval] = [10, 30, 60]"))
        XCTAssertTrue(reader.contains("private static let activePlaybackProbeInterval: TimeInterval = 2"))
        XCTAssertTrue(reader.contains("emptyOrFailureBackoffUntil"))
        XCTAssertTrue(reader.contains("activePlaybackProbeBackoffUntil"))
        XCTAssertTrue(reader.contains("consecutiveEmptyOrFailureCount"))
        XCTAssertTrue(reader.contains("actor OSAScriptNowPlayingPayloadReader"))
        XCTAssertTrue(reader.contains("private var inFlightReadTask: Task<MusicNowPlayingPayload?, Never>?"))
        XCTAssertTrue(reader.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(reader.contains("ProcessRunner.run("))
        XCTAssertTrue(source.contains("probingActivePlayback: legacyPayload.isPlaybackLikelyActive"))
        XCTAssertTrue(reader.contains("if !bypassingBackoff {"))
        XCTAssertTrue(reader.contains("if probingActivePlayback"))
        XCTAssertTrue(reader.contains("payload?.hasDisplayableMediaRemoteMetadata == true"))
    }

    func testAdapterSourceBoundsMediaRemoteCallbacksBeforeScriptFallback() throws {
        let source = try sourceFile("Sources/Bough/Music/MediaRemoteNowPlayingService.swift")

        XCTAssertTrue(source.contains("private static let callbackTimeoutNanoseconds"))
        XCTAssertTrue(source.contains("private final class MediaRemoteContinuationGate"))
        XCTAssertTrue(source.contains("Task.sleep(nanoseconds: Self.callbackTimeoutNanoseconds)"))
        XCTAssertTrue(source.contains("await withMediaRemoteCallbackTimeout(defaultValue: NSDictionary())"))
        XCTAssertTrue(source.contains("await withMediaRemoteCallbackTimeout(defaultValue: nil)"))
    }

    func testAdapterSourceCachesQQMusicAlbumLookupMisses() throws {
        let source = try sourceFile("Sources/Bough/Music/QQMusicLocalLibrary.swift")

        XCTAssertTrue(source.contains("private var albumMidMissCache: [AlbumLookupKey: AlbumLookupMiss] = [:]"))
        XCTAssertTrue(source.contains("static let missRetryInterval: TimeInterval = 600"))
        XCTAssertTrue(source.contains("recordedAt: now()"))
        XCTAssertTrue(source.contains("now().timeIntervalSince(miss.recordedAt) < Self.missRetryInterval"))
        XCTAssertTrue(source.contains("private static func databaseModificationDate(for url: URL) -> Date?"))
    }

    func testAdapterSkipsRuntimeWhenNoAllowedPlayerIsRunning() async throws {
        var loadCount = 0
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: {
                loadCount += 1
                return FakeMediaRemoteRuntime()
            },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(isRunning: false)
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertNil(snapshot)
        XCTAssertEqual(loadCount, 0)
        XCTAssertFalse(service.isNowPlayingPollingLikelyUseful)
    }

    func testAdapterSkipsRunningAllowedPlayerLookupForExplicitAllowedIdentity() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.tencent.QQMusicMac",
            displayName: "QQ Music",
            title: "Runtime Track",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: 1,
            playbackRate: 1
        )
        var lookupCount = 0
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            runningAllowedPlayerProvider: {
                lookupCount += 1
                return MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
            }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertEqual(snapshot?.track?.title, "Runtime Track")
        XCTAssertEqual(lookupCount, 0)
    }

    func testAdapterDoesNotAttributeExplicitNonMusicIdentityToRunningAllowedPlayer() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.google.Chrome",
            displayName: nil,
            title: "QQ Runtime Track",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: nil,
            playbackRate: 1
        )
        var lookupCount = 0
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            runningAllowedPlayerProvider: {
                lookupCount += 1
                return MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
            },
            now: { Date(timeIntervalSince1970: 99) }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertNil(snapshot)
        XCTAssertEqual(lookupCount, 0)
    }

    func testAdapterDoesNotAttributeExplicitVideoIdentityToRunningAllowedPlayer() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.apple.TV",
            displayName: "TV",
            title: "Canada: Race",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: 1,
            playbackRate: 1
        )
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            runningAllowedPlayerProvider: {
                MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
            }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertNil(snapshot)
    }

    func testAdapterAttributesMissingIdentityToSingleRunningAllowedPlayer() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: nil,
            displayName: nil,
            title: "QQ Runtime Track",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: nil,
            playbackRate: 1
        )
        var lookupCount = 0
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            runningAllowedPlayerProvider: {
                lookupCount += 1
                return MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
            },
            now: { Date(timeIntervalSince1970: 99) }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertEqual(snapshot?.player.bundleIdentifier, "com.tencent.QQMusicMac")
        XCTAssertEqual(snapshot?.player.displayName, "QQ Music")
        XCTAssertEqual(snapshot?.track?.title, "QQ Runtime Track")
        XCTAssertEqual(snapshot?.playbackState, .playing)
        XCTAssertEqual(lookupCount, 1)
    }

    func testAdapterDoesNotAttributeNonMusicIdentityWithoutUniqueRunningMusicApp() async throws {
        let runtime = FakeMediaRemoteRuntime()
        runtime.payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.google.Chrome",
            displayName: nil,
            title: "QQ Runtime Track",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: 2,
            playbackRate: 1
        )
        let service = MediaRemoteNowPlayingService(
            runtimeLoader: { runtime },
            allowedPlayerMonitor: FakeAllowedPlayerMonitor(),
            runningAllowedPlayerProvider: { nil }
        )

        let snapshot = try await service.currentSnapshot()

        XCTAssertNil(snapshot)
    }

    func testAdapterSendsPlaybackCommandsThroughResolvedRuntime() async throws {
        let runtime = FakeMediaRemoteRuntime()
        let service = MediaRemoteNowPlayingService(runtimeLoader: { runtime })

        try await service.send(.playPause)
        try await service.send(.next)
        try await service.send(.previous)

        XCTAssertEqual(runtime.commands, [.playPause, .next, .previous])
        XCTAssertEqual(MediaRemoteNowPlayingService.commandIdentifier(for: .playPause), 2)
        XCTAssertEqual(MediaRemoteNowPlayingService.commandIdentifier(for: .next), 4)
        XCTAssertEqual(MediaRemoteNowPlayingService.commandIdentifier(for: .previous), 5)
    }

    func testAdapterPropagatesCommandUnavailable() async {
        let runtime = FakeMediaRemoteRuntime()
        runtime.commandError = MusicNowPlayingServiceError.commandUnavailable
        let service = MediaRemoteNowPlayingService(runtimeLoader: { runtime })

        do {
            try await service.send(.next)
            XCTFail("Expected command unavailable")
        } catch let error as MusicNowPlayingServiceError {
            XCTAssertEqual(error, .commandUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class FakeMediaRemoteRuntime: MediaRemoteNowPlayingRuntime {
    var payload = MusicNowPlayingPayload(
        bundleIdentifier: "com.tencent.QQMusicMac",
        displayName: "QQ Music",
        title: "Track",
        artist: "Artist",
        album: "Album",
        artworkData: nil,
        artworkMimeType: nil,
        playbackStateValue: 1,
        playbackRate: nil
    )
    var commandError: Error?
    private(set) var commands: [MusicCommand] = []
    private(set) var scriptBackoffBypassRequests: [Bool] = []

    func currentPayload() async throws -> MusicNowPlayingPayload {
        try await currentPayload(bypassingScriptBackoff: false)
    }

    func currentPayload(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingPayload {
        scriptBackoffBypassRequests.append(bypassingScriptBackoff)
        return payload
    }

    func send(_ command: MusicCommand) async throws {
        commands.append(command)
        if let commandError {
            throw commandError
        }
    }
}

private final class FakeAllowedPlayerMonitor: MusicAllowedPlayerRuntimeMonitoring {
    var isRunning: Bool
    private var didChangeHandler: (@MainActor () -> Void)?

    init(isRunning: Bool = true) {
        self.isRunning = isRunning
    }

    var hasAllowedPlayerRunning: Bool {
        isRunning
    }

    func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }

    @MainActor
    func setRunning(_ running: Bool) {
        isRunning = running
        didChangeHandler?()
    }
}
