import Foundation
import XCTest
@testable import Bough

@MainActor
final class MusicNowPlayingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "MusicNowPlayingStoreTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPollingStartsOnlyWhenEnabledAndNeeded() {
        let scheduler = RecordingMusicPollingScheduler()
        let store = MusicNowPlayingStore(defaults: defaults, service: FakeMusicNowPlayingService(), scheduler: scheduler)

        store.setPresentationNeeded(false)
        XCTAssertNil(scheduler.interval)

        store.setPresentationNeeded(true)
        XCTAssertEqual(scheduler.interval, 1)

        defaults.set(false, forKey: SettingsKey.showMusicControls)
        store.refreshControlsEnabled()
        XCTAssertNil(scheduler.interval)
        XCTAssertEqual(scheduler.stopCount, 2)
        XCTAssertEqual(store.state, .disabled)
    }

    func testPollingPolicyUsesActiveOneSecondThenBacksOffAfterConsecutiveFailures() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [
            .failure(MusicNowPlayingServiceError.unavailable),
            .failure(MusicNowPlayingServiceError.unavailable),
        ]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        XCTAssertEqual(scheduler.interval, 1)

        await store.refreshNow()
        XCTAssertEqual(scheduler.interval, 1)
        XCTAssertEqual(scheduler.startCount, 1)

        await store.refreshNow()
        XCTAssertEqual(scheduler.interval, 5)
        XCTAssertEqual(scheduler.startCount, 2)
        XCTAssertEqual(store.settingsAbnormalMessage, "Music service unavailable")
    }

    func testPollingDoesNotRestartTimerWhenIntervalIsUnchanged() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(nil), .success(nil)]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        XCTAssertEqual(scheduler.interval, 1)
        XCTAssertEqual(scheduler.startCount, 1)

        await store.refreshNow()
        await store.refreshNow()

        XCTAssertEqual(scheduler.interval, 1)
        XCTAssertEqual(scheduler.startCount, 1)
    }

    func testPollingUsesFallbackIntervalWhenNoAllowedPlayerIsRunning() {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.pollingLikelyUseful = false
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)

        XCTAssertEqual(scheduler.interval, 60)
        XCTAssertEqual(scheduler.startCount, 1)
    }

    func testPollingReturnsToActiveIntervalWhenPlayerAvailabilityChanges() {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.pollingLikelyUseful = false
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        XCTAssertEqual(scheduler.interval, 60)

        service.setPollingLikelyUseful(true)

        XCTAssertEqual(scheduler.interval, 1)
        XCTAssertEqual(scheduler.startCount, 2)
    }

    func testPlayerUnavailableChangeClearsSnapshotImmediately() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        await store.refreshNow()
        XCTAssertNotNil(store.snapshot)
        let revisionAfterSnapshot = store.publishRevision

        service.setPollingLikelyUseful(false)

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.state, .available(nil))
        XCTAssertEqual(scheduler.interval, 60)
        XCTAssertEqual(store.publishRevision, revisionAfterSnapshot + 1)
    }

    func testRefreshSkipsServiceReadWhenPlayerUnavailable() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.pollingLikelyUseful = false
        service.readResults = [.success(Self.snapshot(title: "Stale Song", capturedAt: 1))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        await store.refreshNow()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(service.readCount, 0)
        XCTAssertEqual(scheduler.interval, 60)
    }

    func testRefreshClearsSnapshotAndBacksOffIfPlayerQuitsDuringRead() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        await store.refreshNow()
        XCTAssertNotNil(store.snapshot)

        service.readResults = [.success(Self.snapshot(title: "Stale Song", capturedAt: 2))]
        service.beforeReturningReadResult = {
            service.pollingLikelyUseful = false
        }
        await store.refreshNow()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(scheduler.interval, 60)
    }

    func testTurningControlsOffStopsPollingAndClearsSnapshot() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)

        store.setPresentationNeeded(true)
        await store.refreshNow()
        XCTAssertNotNil(store.snapshot)

        defaults.set(false, forKey: SettingsKey.showMusicControls)
        store.refreshControlsEnabled()

        XCTAssertNil(scheduler.interval)
        XCTAssertEqual(store.state, .disabled)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.settingsAbnormalMessage)
    }

    func testUnchangedSnapshotsDoNotPublish() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [
            .success(Self.snapshot(title: "Same Song", capturedAt: 1)),
            .success(Self.snapshot(title: "Same Song", capturedAt: 2)),
        ]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.refreshNow()
        let revisionAfterFirstRefresh = store.publishRevision

        await store.refreshNow()

        XCTAssertEqual(store.publishRevision, revisionAfterFirstRefresh)
    }

    func testPublishedSnapshotPostsStoreChangeNotification() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())
        let recorder = NotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MusicNowPlayingStore.didChangeNotification,
            object: store,
            queue: nil
        ) { notification in
            recorder.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setPresentationNeeded(true)
        await store.refreshNow()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertTrue(recorder.lastObject === store)
    }

    func testUnchangedSnapshotDoesNotPostStoreChangeNotification() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [
            .success(Self.snapshot(title: "Same Song", capturedAt: 1)),
            .success(Self.snapshot(title: "Same Song", capturedAt: 2)),
        ]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())
        let recorder = NotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MusicNowPlayingStore.didChangeNotification,
            object: store,
            queue: nil
        ) { _ in
            recorder.record()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setPresentationNeeded(true)
        await store.refreshNow()
        await store.refreshNow()

        XCTAssertEqual(recorder.count, 1)
    }

    func testSuccessfulCommandRefreshesImmediately() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "After Command", capturedAt: 3))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.send(.playPause)

        XCTAssertEqual(service.sentCommands, [.playPause])
        XCTAssertEqual(service.readCount, 1)
        XCTAssertEqual(service.scriptBackoffBypassRequests, [true])
        XCTAssertEqual(store.snapshot?.track?.title, "After Command")
        XCTAssertNil(store.softFailure)
    }

    func testNextCommandBypassesScriptBackoffForImmediateRefresh() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Next Song", capturedAt: 4))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.send(.next)

        XCTAssertEqual(service.sentCommands, [.next])
        XCTAssertEqual(service.readCount, 1)
        XCTAssertEqual(service.scriptBackoffBypassRequests, [true])
        XCTAssertEqual(store.snapshot?.track?.title, "Next Song")
    }

    func testPlayPauseCommandFlipsPlaybackStateOptimistically() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1, playbackState: .playing))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.refreshNow()
        let revisionAfterRefresh = store.publishRevision

        await store.send(.playPause)

        XCTAssertEqual(service.sentCommands, [.playPause])
        XCTAssertEqual(service.readCount, 1)
        XCTAssertEqual(store.snapshot?.playbackState, .paused)
        XCTAssertEqual(store.publishRevision, revisionAfterRefresh + 1)
        XCTAssertNil(store.softFailure)
    }

    func testFailedPlayPauseCommandRevertsOptimisticPlaybackState() async {
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(Self.snapshot(title: "Song", capturedAt: 1, playbackState: .playing))]
        service.commandError = MusicNowPlayingServiceError.commandUnavailable
        let store = MusicNowPlayingStore(
            defaults: defaults,
            service: service,
            scheduler: RecordingMusicPollingScheduler(),
            now: { Date(timeIntervalSince1970: 123) }
        )

        store.setPresentationNeeded(true)
        await store.refreshNow()

        await store.send(.playPause)

        XCTAssertEqual(service.sentCommands, [.playPause])
        XCTAssertEqual(store.snapshot?.playbackState, .playing)
        XCTAssertEqual(store.softFailure?.command, .playPause)
        XCTAssertEqual(store.softFailure?.message, "Music command unavailable")
    }

    func testFailedCommandSetsSoftFailureWithoutThrowing() async {
        let service = FakeMusicNowPlayingService()
        service.commandError = MusicNowPlayingServiceError.commandUnavailable
        let store = MusicNowPlayingStore(
            defaults: defaults,
            service: service,
            scheduler: RecordingMusicPollingScheduler(),
            now: { Date(timeIntervalSince1970: 123) }
        )

        store.setPresentationNeeded(true)
        await store.send(.next)

        XCTAssertEqual(service.sentCommands, [.next])
        XCTAssertEqual(store.softFailure?.command, .next)
        XCTAssertEqual(store.softFailure?.message, "Music command unavailable")
        XCTAssertEqual(store.softFailure?.occurredAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(store.settingsAbnormalMessage, "Music command unavailable")
    }

    func testSuccessfulRefreshClearsSoftFailureWhenSnapshotIsUnchanged() async {
        let unchangedSnapshot = Self.snapshot(title: "Same Song", capturedAt: 1)
        let service = FakeMusicNowPlayingService()
        service.readResults = [
            .success(unchangedSnapshot),
            .success(Self.snapshot(title: "Same Song", capturedAt: 2)),
        ]
        service.commandError = MusicNowPlayingServiceError.commandUnavailable
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.refreshNow()
        await store.send(.next)
        XCTAssertNotNil(store.softFailure)
        let revisionAfterFailure = store.publishRevision

        await store.refreshNow()

        XCTAssertNil(store.softFailure)
        XCTAssertEqual(store.publishRevision, revisionAfterFailure + 1)
    }

    func testNoopServiceDoesNotExposeReadyMessage() async {
        let store = MusicNowPlayingStore(defaults: defaults, service: NoopMusicNowPlayingService(), scheduler: RecordingMusicPollingScheduler())

        store.setPresentationNeeded(true)
        await store.refreshNow()

        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.settingsAbnormalMessage)
    }

    func testSeekAppliesOptimisticPositionThenSchedulesRefresh() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        let captured = Date(timeIntervalSince1970: 100)
        service.readResults = [.success(makeSeekSnapshot(
            position: MusicPlaybackPosition(elapsed: 10, duration: 60, rate: 1, capturedAt: captured)
        ))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)
        store.setPresentationNeeded(true)
        await store.refreshNow()

        await store.seek(to: 45)

        XCTAssertEqual(service.seekTargets, [45])
        XCTAssertEqual(store.snapshot?.position?.elapsed, 45)
    }

    func testSeekFailureRollsBackOptimisticPositionAndRaisesSoftFailure() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        let captured = Date(timeIntervalSince1970: 100)
        service.readResults = [.success(makeSeekSnapshot(
            position: MusicPlaybackPosition(elapsed: 10, duration: 60, rate: 1, capturedAt: captured)
        ))]
        service.seekError = MusicNowPlayingServiceError.commandUnavailable
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)
        store.setPresentationNeeded(true)
        await store.refreshNow()

        await store.seek(to: 45)

        XCTAssertEqual(store.settingsAbnormalMessage, "Music command unavailable")
        XCTAssertEqual(store.snapshot?.position?.elapsed, 10)
    }

    private func makeSeekSnapshot(position: MusicPlaybackPosition?) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.apple.Music", displayName: "Music"),
            track: MusicTrackSnapshot(title: "Song", artist: "A", album: nil, lyricLine: nil, artwork: nil),
            playbackState: .playing,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: position?.capturedAt ?? Date(),
            position: position
        )
    }

    func testStaleRefreshResultIsDiscardedByNewerGeneration() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = GatedFakeService(results: [makeStoreSnapshot(title: "stale"), makeStoreSnapshot(title: "fresh")])
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)
        store.setPresentationNeeded(true)

        async let firstRefresh: Void = store.refreshNow()   // gen1，挂起在 firstGate
        await service.waitForFirstRead()

        await store.refreshNow()                              // gen2，立即返回 fresh 并 apply
        XCTAssertEqual(store.snapshot?.track?.title, "fresh")

        service.releaseFirstRead()                            // gen1 现在返回 stale
        await firstRefresh
        XCTAssertEqual(store.snapshot?.track?.title, "fresh", "过期的 gen1 结果不得覆盖 fresh")
    }

    func testEveryOptimisticCommandTransitionPublishes() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        service.readResults = [.success(makeStoreSnapshot(title: "T", playbackState: .playing))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler)
        store.setPresentationNeeded(true)
        await store.refreshNow()

        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(forName: MusicNowPlayingStore.didChangeNotification, object: store, queue: nil) { recorder.record($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        let before = store.publishRevision
        await store.send(.playPause)
        await store.send(.playPause)

        XCTAssertGreaterThanOrEqual(store.publishRevision - before, 2)
        XCTAssertGreaterThanOrEqual(recorder.count, 2)
    }

    func testSettingsSourceShowsOnlyAbnormalMusicMessage() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")
        let page = try XCTUnwrap(source.slice(from: "private struct MusicPage: View", to: "// MARK: - Session Display Page"))

        XCTAssertTrue(source.contains("case .music:"))
        XCTAssertTrue(source.contains("MusicPage("))
        XCTAssertTrue(page.contains("let musicStore: MusicNowPlayingStore"))
        XCTAssertTrue(page.contains("if let message = musicStore.settingsAbnormalMessage"))
        XCTAssertTrue(page.contains(".foregroundStyle(.secondary)"))
        XCTAssertFalse(page.contains("music_ready"))
        XCTAssertFalse(page.contains("Retry"))
    }

    private static func snapshot(
        title: String,
        capturedAt: TimeInterval,
        playbackState: MusicPlaybackState = .playing
    ) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music"),
            track: MusicTrackSnapshot(title: title, artist: "Artist", album: "Album", lyricLine: nil, artwork: nil),
            playbackState: playbackState,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: Date(timeIntervalSince1970: capturedAt)
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class RecordingMusicPollingScheduler: MusicPollingScheduling {
    private(set) var interval: TimeInterval?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var action: (@MainActor () -> Void)?

    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        startCount += 1
        self.interval = interval
        self.action = action
    }

    func stop() {
        interval = nil
        action = nil
        stopCount += 1
    }

    func fire() {
        action?()
    }
}

private final class FakeMusicNowPlayingService: MusicNowPlayingServicing {
    enum ReadResult {
        case success(MusicNowPlayingSnapshot?)
        case failure(Error)
    }

    var readResults: [ReadResult] = [.success(nil)]
    var commandError: Error?
    var pollingLikelyUseful = true
    private(set) var readCount = 0
    private(set) var sentCommands: [MusicCommand] = []
    private(set) var scriptBackoffBypassRequests: [Bool] = []
    var beforeReturningReadResult: (() -> Void)?
    private var pollingAvailabilityDidChangeHandler: (@MainActor () -> Void)?

    var isNowPlayingPollingLikelyUseful: Bool {
        pollingLikelyUseful
    }

    func setPollingAvailabilityDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        pollingAvailabilityDidChangeHandler = handler
    }

    @MainActor
    func setPollingLikelyUseful(_ useful: Bool) {
        pollingLikelyUseful = useful
        pollingAvailabilityDidChangeHandler?()
    }

    func currentSnapshot() async throws -> MusicNowPlayingSnapshot? {
        try await currentSnapshot(bypassingScriptBackoff: false)
    }

    func currentSnapshot(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingSnapshot? {
        scriptBackoffBypassRequests.append(bypassingScriptBackoff)
        readCount += 1
        let result = readResults.isEmpty ? .success(nil) : readResults.removeFirst()
        beforeReturningReadResult?()
        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }

    func send(_ command: MusicCommand) async throws {
        sentCommands.append(command)
        if let commandError {
            throw commandError
        }
    }

    private(set) var seekTargets: [TimeInterval] = []
    var seekError: Error?
    func seek(to seconds: TimeInterval) async throws {
        if let seekError { throw seekError }
        seekTargets.append(seconds)
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedCount = 0
    private var receivedLastObject: AnyObject?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    var lastObject: AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return receivedLastObject
    }

    func record(_ notification: Notification? = nil) {
        lock.lock()
        receivedCount += 1
        receivedLastObject = notification?.object as AnyObject
        lock.unlock()
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let lower = range(of: start)?.lowerBound,
              let upper = self[lower...].range(of: end)?.lowerBound else {
            return nil
        }
        return String(self[lower..<upper])
    }
}

// MARK: - GatedFakeService for concurrency tests

private final class GatedFakeService: MusicNowPlayingServicing {
    var pollingLikelyUseful = true
    private var results: [MusicNowPlayingSnapshot?]
    private var index = 0
    private var readStarted: CheckedContinuation<Void, Never>?
    private var firstGate: CheckedContinuation<Void, Never>?

    init(results: [MusicNowPlayingSnapshot?]) { self.results = results }

    var isNowPlayingPollingLikelyUseful: Bool { pollingLikelyUseful }
    func setPollingAvailabilityDidChangeHandler(_ handler: (@MainActor () -> Void)?) {}
    func send(_ command: MusicCommand) async throws {}
    func seek(to seconds: TimeInterval) async throws {}
    func currentSnapshot() async throws -> MusicNowPlayingSnapshot? { try await currentSnapshot(bypassingScriptBackoff: false) }
    func currentSnapshot(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingSnapshot? {
        let i = index; index += 1
        if i == 0 {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                firstGate = cont
                readStarted?.resume(); readStarted = nil
            }
        }
        return results[min(i, results.count - 1)]
    }
    func waitForFirstRead() async { await withCheckedContinuation { readStarted = $0 } }
    func releaseFirstRead() { firstGate?.resume(); firstGate = nil }
}

extension MusicNowPlayingStoreTests {
    fileprivate func makeStoreSnapshot(title: String, playbackState: MusicPlaybackState = .playing) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.apple.Music", displayName: "Music"),
            track: MusicTrackSnapshot(title: title, artist: "A", album: nil, lyricLine: nil, artwork: nil),
            playbackState: playbackState,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: Date()
        )
    }
}

// MARK: - FakeOnlineProvider

private final class FakeOnlineProvider: MusicOnlineDataProviding, @unchecked Sendable {
    var lyrics: MusicTimedLyrics?
    var artwork: Data?
    func timedLyrics(for key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> MusicTimedLyrics? { lyrics }
    func artworkData(for key: MusicTrackMatchKey, player: MusicAllowedPlayer?, rawTitle: String?, rawArtist: String?, rawAlbum: String?, durationHint: TimeInterval?) async -> Data? { artwork }
}

// MARK: - Online data tests

extension MusicNowPlayingStoreTests {
    func testOnlineLyricsAreFetchedAndPublishedWhenSnapshotLacksLyrics() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        let provider = FakeOnlineProvider()
        provider.lyrics = MusicTimedLyrics.parsingLRC("[00:01]online")
        service.readResults = [.success(makeStoreSnapshot(title: "Song"))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler, onlineProvider: provider)
        store.setPresentationNeeded(true)
        await store.refreshNow()
        await store.onlineFetchTaskForTesting?.value
        XCTAssertEqual(store.onlineLyrics?.currentLine(at: 2), "online")
    }

    func testOnlineDataClearsWhenTrackChanges() async {
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        let provider = FakeOnlineProvider()
        provider.lyrics = MusicTimedLyrics.parsingLRC("[00:01]online")
        service.readResults = [.success(makeStoreSnapshot(title: "Song A")), .success(makeStoreSnapshot(title: "Song B"))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler, onlineProvider: provider)
        store.setPresentationNeeded(true)
        await store.refreshNow()
        await store.onlineFetchTaskForTesting?.value
        XCTAssertNotNil(store.onlineLyrics)
        provider.lyrics = nil
        await store.refreshNow()
        XCTAssertNil(store.onlineLyrics, "换曲必须立即清空在线歌词")
    }

    func testOnlineArtworkMergesIntoSnapshotWhenKeyStillMatches() async {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let scheduler = RecordingMusicPollingScheduler()
        let service = FakeMusicNowPlayingService()
        let provider = FakeOnlineProvider()
        provider.artwork = Data(base64Encoded: pngBase64)!
        service.readResults = [.success(makeStoreSnapshot(title: "Song"))]
        let store = MusicNowPlayingStore(defaults: defaults, service: service, scheduler: scheduler, onlineProvider: provider)
        store.setPresentationNeeded(true)
        await store.refreshNow()
        await store.onlineFetchTaskForTesting?.value
        XCTAssertNotNil(store.snapshot?.track?.artwork, "在线封面应合并进当前 snapshot")
    }
}
