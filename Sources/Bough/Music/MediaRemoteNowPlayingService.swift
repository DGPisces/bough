import Darwin
import AppKit
import Foundation

protocol MediaRemoteNowPlayingRuntime: AnyObject {
    func currentPayload() async throws -> MusicNowPlayingPayload
    func currentPayload(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingPayload
    func send(_ command: MusicCommand) async throws
    func seek(to seconds: TimeInterval) async throws
}

protocol MusicAllowedPlayerRuntimeMonitoring: AnyObject {
    var hasAllowedPlayerRunning: Bool { get }
    func setDidChangeHandler(_ handler: (@MainActor () -> Void)?)
}

final class MusicAllowedPlayerRunningMonitor: MusicAllowedPlayerRuntimeMonitoring {
    private static let fallbackScanInterval: TimeInterval = 60

    private let workspace: NSWorkspace
    private let now: () -> Date
    private var runningAllowedBundleIds: Set<String> = []
    private var lastFullScan: Date = .distantPast
    private var observers: [NSObjectProtocol] = []
    private var didChangeHandler: (@MainActor () -> Void)?

    init(
        workspace: NSWorkspace = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspace = workspace
        self.now = now
        refreshRunningAllowedBundleIds(force: true)
        installObservers()
    }

    var hasAllowedPlayerRunning: Bool {
        refreshRunningAllowedBundleIdsIfStale()
        return !runningAllowedBundleIds.isEmpty
    }

    func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }

    deinit {
        let center = workspace.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func refreshRunningAllowedBundleIdsIfStale() {
        guard now().timeIntervalSince(lastFullScan) >= Self.fallbackScanInterval else {
            return
        }
        refreshRunningAllowedBundleIds(force: false)
    }

    private func refreshRunningAllowedBundleIds(force: Bool) {
        let current = now()
        guard force || current.timeIntervalSince(lastFullScan) >= Self.fallbackScanInterval else {
            return
        }
        lastFullScan = current

        let nextIds = Set(workspace.runningApplications.compactMap { application -> String? in
            guard let bundleIdentifier = application.bundleIdentifier,
                  MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: bundleIdentifier) != nil
            else {
                return nil
            }
            return bundleIdentifier
        })
        updateRunningAllowedBundleIds(nextIds)
    }

    private func installObservers() {
        let center = workspace.notificationCenter
        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleApplicationNotification(notification, isRunning: true)
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleApplicationNotification(notification, isRunning: false)
        }

        observers = [launchObserver, terminateObserver]
    }

    private func handleApplicationNotification(_ notification: Notification, isRunning: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = app.bundleIdentifier,
              MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: bundleIdentifier) != nil
        else {
            return
        }

        var nextIds = runningAllowedBundleIds
        if isRunning {
            nextIds.insert(bundleIdentifier)
        } else {
            nextIds.remove(bundleIdentifier)
        }
        updateRunningAllowedBundleIds(nextIds)
    }

    private func updateRunningAllowedBundleIds(_ nextIds: Set<String>) {
        guard runningAllowedBundleIds != nextIds else { return }
        runningAllowedBundleIds = nextIds
        guard let didChangeHandler else { return }
        Task { @MainActor in
            didChangeHandler()
        }
    }
}

extension MediaRemoteNowPlayingRuntime {
    func currentPayload(bypassingScriptBackoff _: Bool) async throws -> MusicNowPlayingPayload {
        try await currentPayload()
    }

    func seek(to _: TimeInterval) async throws {
        throw MusicNowPlayingServiceError.commandUnavailable
    }
}

final class MediaRemoteNowPlayingService: MusicNowPlayingServicing {
    typealias RuntimeLoader = () throws -> MediaRemoteNowPlayingRuntime
    typealias RunningAllowedPlayerProvider = () -> MusicPlayerIdentity?

    private let runtimeLoader: RuntimeLoader
    private let runningAllowedPlayerProvider: RunningAllowedPlayerProvider
    private let allowedPlayerMonitor: MusicAllowedPlayerRuntimeMonitoring
    private let now: () -> Date
    private var runtime: MediaRemoteNowPlayingRuntime?

    init(
        runtimeLoader: @escaping RuntimeLoader = { try DefaultMediaRemoteRuntime.load() },
        allowedPlayerMonitor: MusicAllowedPlayerRuntimeMonitoring = MusicAllowedPlayerRunningMonitor(),
        runningAllowedPlayerProvider: @escaping RunningAllowedPlayerProvider = {
            MediaRemoteNowPlayingService.singleRunningAllowedPlayer()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.runtimeLoader = runtimeLoader
        self.allowedPlayerMonitor = allowedPlayerMonitor
        self.runningAllowedPlayerProvider = runningAllowedPlayerProvider
        self.now = now
    }

    var isNowPlayingPollingLikelyUseful: Bool {
        allowedPlayerMonitor.hasAllowedPlayerRunning
    }

    func setPollingAvailabilityDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        allowedPlayerMonitor.setDidChangeHandler(handler)
    }

    func currentSnapshot() async throws -> MusicNowPlayingSnapshot? {
        try await currentSnapshot(bypassingScriptBackoff: false)
    }

    func currentSnapshot(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingSnapshot? {
        guard allowedPlayerMonitor.hasAllowedPlayerRunning else {
            return nil
        }

        // Running-player identity is sampled at most once per snapshot, inside the
        // resolver and only when an identity substitution is actually needed, so a
        // player launching/terminating mid-read cannot flip this snapshot's identity.
        let payload = try await loadRuntime().currentPayload(bypassingScriptBackoff: bypassingScriptBackoff)
            .resolvingMismatchedNonMusicIdentity {
                runningAllowedPlayerProvider()
            }
        return MusicNowPlayingPayloadParser.parse(payload, capturedAt: now())
    }

    func send(_ command: MusicCommand) async throws {
        try await loadRuntime().send(command)
    }

    func seek(to seconds: TimeInterval) async throws {
        try await loadRuntime().seek(to: seconds)
    }

    static func commandIdentifier(for command: MusicCommand) -> Int32 {
        switch command {
        case .previous:
            return 5
        case .playPause:
            return 2
        case .next:
            return 4
        }
    }

    private func loadRuntime() throws -> MediaRemoteNowPlayingRuntime {
        if let runtime {
            return runtime
        }
        let loaded = try runtimeLoader()
        runtime = loaded
        return loaded
    }

    private static func singleRunningAllowedPlayer() -> MusicPlayerIdentity? {
        var identitiesByBundleIdentifier: [String: MusicPlayerIdentity] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier,
                  let allowedPlayer = MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: bundleIdentifier)
            else { continue }

            identitiesByBundleIdentifier[bundleIdentifier] = MusicPlayerIdentity(
                bundleIdentifier: bundleIdentifier,
                displayName: application.localizedName ?? allowedPlayer.displayName
            )
        }

        guard identitiesByBundleIdentifier.count == 1 else {
            return nil
        }
        return identitiesByBundleIdentifier.values.first
    }
}

extension MusicNowPlayingPayload {
    func resolvingMismatchedNonMusicIdentity(
        runningAllowedPlayer: () -> MusicPlayerIdentity?
    ) -> MusicNowPlayingPayload {
        guard MusicAllowedPlayer.match(bundleIdentifier: bundleIdentifier, displayName: displayName) == nil,
              !hasExplicitPlayerIdentity,
              hasDisplayableMediaRemoteMetadata,
              playbackRate ?? 0 > 0
        else {
            return self
        }

        guard let runningAllowedPlayer = runningAllowedPlayer() else {
            return self
        }

        return MusicNowPlayingPayload(
            bundleIdentifier: runningAllowedPlayer.bundleIdentifier,
            displayName: runningAllowedPlayer.displayName,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            artworkMimeType: artworkMimeType,
            playbackStateValue: playbackStateValue,
            playbackRate: playbackRate,
            timestamp: timestamp,
            elapsedTime: elapsedTime,
            duration: duration,
            lyricCandidates: lyricCandidates,
            commandAvailability: commandAvailability
        )
    }

    var hasDisplayableMediaRemoteMetadata: Bool {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || artworkData?.isEmpty == false
    }

    var hasExplicitPlayerIdentity: Bool {
        bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isPlaybackLikelyActive: Bool {
        if let playbackStateValue {
            return playbackStateValue == 1
        }
        return playbackRate ?? 0 > 0
    }
}

extension MusicNowPlayingStore {
    static func live() -> MusicNowPlayingStore {
        MusicNowPlayingStore(service: MediaRemoteNowPlayingService())
    }
}

private final class DefaultMediaRemoteRuntime: MediaRemoteNowPlayingRuntime {
    private typealias NowPlayingInfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias NowPlayingStringBlock = @convention(block) (CFString?) -> Void
    private typealias NowPlayingPlaybackStateBlock = @convention(block) (Int32) -> Void
    private typealias GetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping NowPlayingInfoBlock) -> Void
    private typealias GetNowPlayingStringFunction = @convention(c) (DispatchQueue, @escaping NowPlayingStringBlock) -> Void
    private typealias GetNowPlayingPlaybackStateFunction = @convention(c) (DispatchQueue, @escaping NowPlayingPlaybackStateBlock) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> DarwinBoolean
    private typealias SetElapsedTimeFunction = @convention(c) (Double) -> Void

    private static let frameworkBundlePath = "/System/Library/PrivateFrameworks/MediaRemote.framework/"
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    private static let callbackTimeoutNanoseconds: UInt64 = 750_000_000

    private let handle: UnsafeMutableRawPointer
    private let getInfo: GetNowPlayingInfoFunction
    private let getApplicationDisplayID: GetNowPlayingStringFunction?
    private let getApplicationPlaybackState: GetNowPlayingPlaybackStateFunction?
    private let sendCommand: SendCommandFunction?
    private let setElapsedTime: SetElapsedTimeFunction?
    private let keys: MediaRemoteNowPlayingKeys
    private let scriptPayloadReader = OSAScriptNowPlayingPayloadReader()
    private let qqMusicArtworkResolver = QQMusicArtworkResolver()
    private let mediaRemoteQueue = DispatchQueue(label: "dev.dgpisces.bough.media-remote")

    static func load() throws -> DefaultMediaRemoteRuntime {
        _ = Bundle(path: frameworkBundlePath)?.load()

        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            throw MusicNowPlayingServiceError.unavailable
        }

        guard let getInfo: GetNowPlayingInfoFunction = resolve("MRMediaRemoteGetNowPlayingInfo", from: handle) else {
            dlclose(handle)
            throw MusicNowPlayingServiceError.unavailable
        }

        return DefaultMediaRemoteRuntime(
            handle: handle,
            getInfo: getInfo,
            getApplicationDisplayID: resolve("MRMediaRemoteGetNowPlayingApplicationDisplayID", from: handle),
            getApplicationPlaybackState: resolve("MRMediaRemoteGetNowPlayingApplicationPlaybackState", from: handle),
            sendCommand: resolve("MRMediaRemoteSendCommand", from: handle),
            setElapsedTime: resolve("MRMediaRemoteSetElapsedTime", from: handle),
            keys: MediaRemoteNowPlayingKeys(handle: handle)
        )
    }

    private init(
        handle: UnsafeMutableRawPointer,
        getInfo: GetNowPlayingInfoFunction,
        getApplicationDisplayID: GetNowPlayingStringFunction?,
        getApplicationPlaybackState: GetNowPlayingPlaybackStateFunction?,
        sendCommand: SendCommandFunction?,
        setElapsedTime: SetElapsedTimeFunction?,
        keys: MediaRemoteNowPlayingKeys
    ) {
        self.handle = handle
        self.getInfo = getInfo
        self.getApplicationDisplayID = getApplicationDisplayID
        self.getApplicationPlaybackState = getApplicationPlaybackState
        self.sendCommand = sendCommand
        self.setElapsedTime = setElapsedTime
        self.keys = keys
    }

    deinit {
        dlclose(handle)
    }

    func currentPayload() async throws -> MusicNowPlayingPayload {
        try await currentPayload(bypassingScriptBackoff: false)
    }

    func currentPayload(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingPayload {
        let playbackState = await currentPlaybackState()

        if let requestPayload = currentRequestPayload(playbackState: playbackState),
           requestPayload.hasDisplayableMediaRemoteMetadata {
            return await payloadByResolvingArtworkIfNeeded(requestPayload)
        }

        let dictionary = await currentInfoDictionary()
        let bundleIdentifier = await currentString(using: getApplicationDisplayID)

        let legacyPayload = MusicNowPlayingPayload(
            bundleIdentifier: bundleIdentifier,
            displayName: nil,
            title: stringValue(for: keys.title, in: dictionary),
            artist: stringValue(for: keys.artist, in: dictionary),
            album: stringValue(for: keys.album, in: dictionary),
            artworkData: dataValue(for: keys.artworkData, in: dictionary),
            artworkMimeType: stringValue(for: keys.artworkMIMEType, in: dictionary),
            playbackStateValue: playbackState,
            playbackRate: numberValue(for: keys.playbackRate, in: dictionary),
            timestamp: dateValue(for: keys.timestamp, in: dictionary),
            elapsedTime: numberValue(for: keys.elapsedTime, in: dictionary),
            duration: numberValue(for: keys.duration, in: dictionary),
            lyricCandidates: lyricCandidates(from: dictionary),
            commandAvailability: nil
        )

        if legacyPayload.hasDisplayableMediaRemoteMetadata {
            return await payloadByResolvingArtworkIfNeeded(legacyPayload)
        }

        if let scriptPayload = await scriptPayloadReader.currentPayload(
            bypassingBackoff: bypassingScriptBackoff,
            probingActivePlayback: legacyPayload.isPlaybackLikelyActive
        ),
           scriptPayload.hasDisplayableMediaRemoteMetadata,
           legacyPayload.describesSameSource(as: scriptPayload) {
            return await payloadByResolvingArtworkIfNeeded(scriptPayload)
        }

        return legacyPayload
    }

    private func payloadByResolvingArtworkIfNeeded(_ payload: MusicNowPlayingPayload) async -> MusicNowPlayingPayload {
        guard payload.artworkData == nil,
              let artworkData = await qqMusicArtworkResolver.artworkData(for: payload)
        else {
            return payload
        }
        return payload.withArtworkData(artworkData, mimeType: "image/jpeg")
    }

    private func currentRequestPayload(playbackState: Int?) -> MusicNowPlayingPayload? {
        guard let requestClass = NSClassFromString("MRNowPlayingRequest") as AnyObject? else {
            return nil
        }

        let item = objectValue(from: requestClass, selector: "localNowPlayingItem")
        let info = objectValue(from: item, selector: "nowPlayingInfo") as? NSDictionary
        let playerPath = objectValue(from: requestClass, selector: "localNowPlayingPlayerPath")
        let client = objectValue(from: playerPath, selector: "client")
        let dictionary = info ?? NSDictionary()

        return MusicNowPlayingPayload(
            bundleIdentifier: stringValue(from: objectValue(from: client, selector: "bundleIdentifier")),
            displayName: stringValue(from: objectValue(from: client, selector: "displayName")),
            title: stringValue(for: keys.title, in: dictionary),
            artist: stringValue(for: keys.artist, in: dictionary),
            album: stringValue(for: keys.album, in: dictionary),
            artworkData: dataValue(for: keys.artworkData, in: dictionary),
            artworkMimeType: stringValue(for: keys.artworkMIMEType, in: dictionary),
            playbackStateValue: playbackState,
            playbackRate: numberValue(for: keys.playbackRate, in: dictionary),
            timestamp: dateValue(for: keys.timestamp, in: dictionary),
            elapsedTime: numberValue(for: keys.elapsedTime, in: dictionary),
            duration: numberValue(for: keys.duration, in: dictionary),
            lyricCandidates: lyricCandidates(from: dictionary),
            commandAvailability: nil
        )
    }

    func send(_ command: MusicCommand) async throws {
        guard let sendCommand else {
            throw MusicNowPlayingServiceError.commandUnavailable
        }
        guard sendCommand(MediaRemoteNowPlayingService.commandIdentifier(for: command), nil).boolValue else {
            throw MusicNowPlayingServiceError.commandUnavailable
        }
    }

    func seek(to seconds: TimeInterval) async throws {
        guard let setElapsedTime else {
            throw MusicNowPlayingServiceError.commandUnavailable
        }
        setElapsedTime(max(0, seconds))
    }

    private func currentInfoDictionary() async -> NSDictionary {
        await withMediaRemoteCallbackTimeout(defaultValue: NSDictionary()) { resume in
            let block: NowPlayingInfoBlock = { info in
                resume((info as NSDictionary?) ?? NSDictionary())
            }

            getInfo(mediaRemoteQueue, block)
        }
    }

    private func currentString(using function: GetNowPlayingStringFunction?) async -> String? {
        guard let function else {
            return nil
        }
        return await withMediaRemoteCallbackTimeout(defaultValue: nil) { resume in
            let block: NowPlayingStringBlock = { value in
                resume(value as String?)
            }
            function(mediaRemoteQueue, block)
        }
    }

    private func currentPlaybackState() async -> Int? {
        guard let getApplicationPlaybackState else {
            return nil
        }
        return await withMediaRemoteCallbackTimeout(defaultValue: nil) { resume in
            let block: NowPlayingPlaybackStateBlock = { state in
                resume(Int(state))
            }
            getApplicationPlaybackState(mediaRemoteQueue, block)
        }
    }

    private func withMediaRemoteCallbackTimeout<T>(
        defaultValue: T,
        start: (@escaping (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = MediaRemoteContinuationGate(continuation)
            start { value in
                gate.resume(value)
            }
            Task {
                try? await Task.sleep(nanoseconds: Self.callbackTimeoutNanoseconds)
                gate.resume(defaultValue)
            }
        }
    }

    private func stringValue(for key: String?, in dictionary: NSDictionary) -> String? {
        guard let key, let value = dictionary.object(forKey: key) else {
            return nil
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return value as String
        }
        return nil
    }

    private func stringValue(from value: AnyObject?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return value as String
        }
        return nil
    }

    private func objectValue(from object: AnyObject?, selector: String) -> AnyObject? {
        guard let object else {
            return nil
        }
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else {
            return nil
        }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func dataValue(for key: String?, in dictionary: NSDictionary) -> Data? {
        guard let key, let value = dictionary.object(forKey: key) else {
            return nil
        }
        if let value = value as? Data {
            return value
        }
        if let value = value as? NSData {
            return value as Data
        }
        return nil
    }

    private func numberValue(for key: String?, in dictionary: NSDictionary) -> Double? {
        guard let key, let value = dictionary.object(forKey: key) else {
            return nil
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        return nil
    }

    private func dateValue(for key: String?, in dictionary: NSDictionary) -> Date? {
        guard let key, let value = dictionary.object(forKey: key) else {
            return nil
        }
        if let value = value as? Date {
            return value
        }
        if let value = value as? NSDate {
            return value as Date
        }
        return nil
    }

    private func lyricCandidates(from dictionary: NSDictionary) -> [MusicLyricCandidate] {
        guard let lyrics = stringValue(for: keys.lyrics, in: dictionary) else {
            return []
        }
        return [
            MusicLyricCandidate(text: lyrics, source: .mediaRemotePayload),
        ]
    }

    private static func resolve<T>(_ symbol: String, from handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, symbol) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private final class MediaRemoteContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let continuationToResume: CheckedContinuation<T, Never>?
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: value)
    }
}

private extension MusicNowPlayingPayload {
    func withArtworkData(_ data: Data, mimeType: String?) -> MusicNowPlayingPayload {
        MusicNowPlayingPayload(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            title: title,
            artist: artist,
            album: album,
            artworkData: data,
            artworkMimeType: mimeType ?? artworkMimeType,
            playbackStateValue: playbackStateValue,
            playbackRate: playbackRate,
            timestamp: timestamp,
            elapsedTime: elapsedTime,
            duration: duration,
            lyricCandidates: lyricCandidates,
            commandAvailability: commandAvailability
        )
    }
}

private struct MediaRemoteNowPlayingKeys {
    let title: String
    let artist: String
    let album: String
    let artworkData: String
    let artworkMIMEType: String
    let playbackRate: String
    let timestamp: String
    let lyrics: String?
    let elapsedTime: String
    let duration: String

    init(handle: UnsafeMutableRawPointer) {
        title = Self.constant("kMRMediaRemoteNowPlayingInfoTitle", handle: handle)
        artist = Self.constant("kMRMediaRemoteNowPlayingInfoArtist", handle: handle)
        album = Self.constant("kMRMediaRemoteNowPlayingInfoAlbum", handle: handle)
        artworkData = Self.constant("kMRMediaRemoteNowPlayingInfoArtworkData", handle: handle)
        artworkMIMEType = Self.constant("kMRMediaRemoteNowPlayingInfoArtworkMIMEType", handle: handle)
        playbackRate = Self.constant("kMRMediaRemoteNowPlayingInfoPlaybackRate", handle: handle)
        timestamp = Self.constant("kMRMediaRemoteNowPlayingInfoTimestamp", handle: handle)
        lyrics = Self.optionalConstant("kMRMediaRemoteNowPlayingInfoLyrics", handle: handle)
        elapsedTime = Self.constant("kMRMediaRemoteNowPlayingInfoElapsedTime", handle: handle)
        duration = Self.constant("kMRMediaRemoteNowPlayingInfoDuration", handle: handle)
    }

    private static func constant(_ symbol: String, handle: UnsafeMutableRawPointer) -> String {
        optionalConstant(symbol, handle: handle) ?? symbol
    }

    private static func optionalConstant(_ symbol: String, handle: UnsafeMutableRawPointer) -> String? {
        guard let pointer = dlsym(handle, symbol) else {
            return nil
        }
        return pointer.assumingMemoryBound(to: CFString.self).pointee as String
    }
}
