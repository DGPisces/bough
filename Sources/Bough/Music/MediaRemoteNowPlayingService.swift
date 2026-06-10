import Darwin
import AppKit
import Foundation
import SQLite3

protocol MediaRemoteNowPlayingRuntime: AnyObject {
    func currentPayload() async throws -> MusicNowPlayingPayload
    func currentPayload(bypassingScriptBackoff: Bool) async throws -> MusicNowPlayingPayload
    func send(_ command: MusicCommand) async throws
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

        let payload = try await loadRuntime().currentPayload(bypassingScriptBackoff: bypassingScriptBackoff)
            .resolvingMismatchedNonMusicIdentity {
                runningAllowedPlayerProvider()
            }
        return MusicNowPlayingPayloadParser.parse(payload, capturedAt: now())
    }

    func send(_ command: MusicCommand) async throws {
        try await loadRuntime().send(command)
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

private extension MusicNowPlayingPayload {
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

    private static let frameworkBundlePath = "/System/Library/PrivateFrameworks/MediaRemote.framework/"
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    private static let callbackTimeoutNanoseconds: UInt64 = 750_000_000

    private let handle: UnsafeMutableRawPointer
    private let getInfo: GetNowPlayingInfoFunction
    private let getApplicationDisplayID: GetNowPlayingStringFunction?
    private let getApplicationPlaybackState: GetNowPlayingPlaybackStateFunction?
    private let sendCommand: SendCommandFunction?
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
            keys: MediaRemoteNowPlayingKeys(handle: handle)
        )
    }

    private init(
        handle: UnsafeMutableRawPointer,
        getInfo: GetNowPlayingInfoFunction,
        getApplicationDisplayID: GetNowPlayingStringFunction?,
        getApplicationPlaybackState: GetNowPlayingPlaybackStateFunction?,
        sendCommand: SendCommandFunction?,
        keys: MediaRemoteNowPlayingKeys
    ) {
        self.handle = handle
        self.getInfo = getInfo
        self.getApplicationDisplayID = getApplicationDisplayID
        self.getApplicationPlaybackState = getApplicationPlaybackState
        self.sendCommand = sendCommand
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
           scriptPayload.hasDisplayableMediaRemoteMetadata {
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

private actor OSAScriptNowPlayingPayloadReader {
    private struct DecodedPayload: Decodable {
        let bundleIdentifier: String?
        let displayName: String?
        let title: String?
        let artist: String?
        let album: String?
        let artworkDataBase64: String?
        let artworkMimeType: String?
        let playbackStateValue: Int?
        let playbackRate: Double?
        let lyrics: String?
    }

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let emptyOrFailureBackoffIntervals: [TimeInterval] = [10, 30, 60]
    private static let activePlaybackProbeInterval: TimeInterval = 2
    private static let maxOutputBytes = 2 * 1024 * 1024
    private static let timeout: TimeInterval = 1.5
    private var emptyOrFailureBackoffUntil: Date?
    private var activePlaybackProbeBackoffUntil: Date?
    private var consecutiveEmptyOrFailureCount = 0
    private var inFlightReadTask: Task<MusicNowPlayingPayload?, Never>?
    private static let script = """
    function run() {
        ObjC.import('Foundation');

        var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        if (!bundle || !bundle.load) {
            return '{}';
        }

        var request = $.NSClassFromString('MRNowPlayingRequest');
        if (!request) {
            return '{}';
        }

        var playerPath = request.localNowPlayingPlayerPath;
        var item = request.localNowPlayingItem;
        var info = item ? item.nowPlayingInfo : null;
        var client = playerPath ? playerPath.client : null;

        function unwrap(value) {
            if (!value) {
                return null;
            }
            var unwrapped = ObjC.unwrap(value);
            return unwrapped === undefined ? null : unwrapped;
        }

        function objectForKey(key) {
            return info ? info.objectForKey(key) : null;
        }

        function stringForKey(key) {
            var value = unwrap(objectForKey(key));
            return value === null ? null : String(value);
        }

        function numberForKey(key) {
            var value = unwrap(objectForKey(key));
            if (value === null) {
                return null;
            }
            return numberFromValue(value);
        }

        function numberFromValue(value) {
            if (value === null) {
                return null;
            }
            var number = Number(value);
            return isNaN(number) ? null : number;
        }

        var payload = {
            bundleIdentifier: unwrap(client ? client.bundleIdentifier : null),
            displayName: unwrap(client ? client.displayName : null),
            title: stringForKey('kMRMediaRemoteNowPlayingInfoTitle'),
            artist: stringForKey('kMRMediaRemoteNowPlayingInfoArtist'),
            album: stringForKey('kMRMediaRemoteNowPlayingInfoAlbum'),
            artworkMimeType: stringForKey('kMRMediaRemoteNowPlayingInfoArtworkMIMEType'),
            playbackStateValue: numberFromValue(unwrap(request.localPlaybackState)),
            playbackRate: numberForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
            lyrics: stringForKey('kMRMediaRemoteNowPlayingInfoLyrics')
        };

        var artworkData = objectForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
        if (artworkData && unwrap(artworkData) !== null) {
            payload.artworkDataBase64 = unwrap(artworkData.base64EncodedStringWithOptions(0));
        }

        return JSON.stringify(payload);
    }
    """

    func currentPayload(
        bypassingBackoff: Bool,
        probingActivePlayback: Bool = false
    ) async -> MusicNowPlayingPayload? {
        let now = Date()
        if !bypassingBackoff {
            if probingActivePlayback {
                if let activePlaybackProbeBackoffUntil, now < activePlaybackProbeBackoffUntil {
                    return nil
                }
            } else if let emptyOrFailureBackoffUntil, now < emptyOrFailureBackoffUntil {
                return nil
            }
        }

        if let inFlightReadTask {
            return await inFlightReadTask.value
        }

        let readTask = Task.detached(priority: .utility) {
            Self.readPayload()
        }
        inFlightReadTask = readTask
        let payload = await readTask.value
        inFlightReadTask = nil

        if payload?.hasDisplayableMediaRemoteMetadata == true {
            emptyOrFailureBackoffUntil = nil
            activePlaybackProbeBackoffUntil = nil
            consecutiveEmptyOrFailureCount = 0
        } else {
            if probingActivePlayback {
                activePlaybackProbeBackoffUntil = now.addingTimeInterval(Self.activePlaybackProbeInterval)
            }
            emptyOrFailureBackoffUntil = now.addingTimeInterval(nextBackoffInterval())
            consecutiveEmptyOrFailureCount += 1
        }

        return payload
    }

    private func nextBackoffInterval() -> TimeInterval {
        Self.emptyOrFailureBackoffIntervals[
            min(consecutiveEmptyOrFailureCount, Self.emptyOrFailureBackoffIntervals.count - 1)
        ]
    }

    private static func readPayload() -> MusicNowPlayingPayload? {
        guard let data = ProcessRunner.run(
            path: executableURL.path,
            args: ["-l", "JavaScript", "-e", script],
            timeout: timeout
        ) else {
            return nil
        }
        guard !data.isEmpty, data.count <= maxOutputBytes else {
            return nil
        }

        guard let decoded = try? JSONDecoder().decode(DecodedPayload.self, from: data) else {
            return nil
        }

        return MusicNowPlayingPayload(
            bundleIdentifier: decoded.bundleIdentifier,
            displayName: decoded.displayName,
            title: decoded.title,
            artist: decoded.artist,
            album: decoded.album,
            artworkData: artworkData(from: decoded.artworkDataBase64),
            artworkMimeType: decoded.artworkMimeType,
            playbackStateValue: decoded.playbackStateValue,
            playbackRate: decoded.playbackRate,
            lyricCandidates: lyricCandidates(from: decoded.lyrics),
            commandAvailability: nil
        )
    }

    private static func artworkData(from base64: String?) -> Data? {
        guard let base64,
              !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return Data(base64Encoded: base64)
    }

    private static func lyricCandidates(from lyrics: String?) -> [MusicLyricCandidate] {
        guard let lyrics,
              !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }
        return [
            MusicLyricCandidate(text: lyrics, source: .mediaRemotePayload),
        ]
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
            lyricCandidates: lyricCandidates,
            commandAvailability: commandAvailability
        )
    }
}

private actor QQMusicArtworkResolver {
    private static let maxArtworkBytes = 2 * 1024 * 1024
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let databaseRelativePath = "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/qqmusic.sqlite"
    private static let albumMidQuery = """
        SELECT K_SONG_RESERVE9, album
        FROM SONGS
        WHERE K_SONG_RESERVE9 <> ''
          AND name = ? COLLATE NOCASE
          AND (? = '' OR singer = ? COLLATE NOCASE)
        ORDER BY id DESC
        LIMIT 25
        """

    private let session: URLSession
    private var artworkCache: [String: Data] = [:]
    private var albumMidCache: [AlbumLookupKey: String] = [:]
    private var albumMidMissCache: [AlbumLookupKey: AlbumLookupMiss] = [:]
    private var failedAlbumMids: Set<String> = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.5
        session = URLSession(configuration: configuration)
    }

    func artworkData(for payload: MusicNowPlayingPayload) async -> Data? {
        guard MusicAllowedPlayer.match(bundleIdentifier: payload.bundleIdentifier, displayName: payload.displayName) == .qqMusic,
              let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let albumMid = cachedAlbumMid(title: title, artist: payload.artist, album: payload.album),
              !failedAlbumMids.contains(albumMid)
        else {
            return nil
        }

        if let cached = artworkCache[albumMid] {
            return cached
        }

        for url in artworkURLs(albumMid: albumMid) {
            if let data = await fetchArtwork(from: url) {
                artworkCache[albumMid] = data
                return data
            }
        }

        failedAlbumMids.insert(albumMid)
        return nil
    }

    private func cachedAlbumMid(title: String, artist: String?, album: String?) -> String? {
        let key = AlbumLookupKey(title: title, artist: artist, album: album)
        if let cached = albumMidCache[key] {
            return cached
        }

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.databaseRelativePath)
        let databaseModificationDate = Self.databaseModificationDate(for: databaseURL)

        if let miss = albumMidMissCache[key],
           miss.databaseModificationDate == databaseModificationDate {
            return nil
        }

        guard let resolved = albumMid(
            title: title,
            artist: artist,
            album: album,
            databaseURL: databaseURL
        ) else {
            albumMidMissCache[key] = AlbumLookupMiss(databaseModificationDate: databaseModificationDate)
            return nil
        }
        albumMidMissCache[key] = nil
        albumMidCache[key] = resolved
        return resolved
    }

    private func albumMid(title: String, artist: String?, album: String?, databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.albumMidQuery, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let artistValue = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sqlite3_bind_text(statement, 1, title, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 2, artistValue, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 3, artistValue, -1, Self.transientDestructor)

        let requestedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstAlbumMid: String?
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            if let albumMidPointer = sqlite3_column_text(statement, 0) {
                let candidateAlbumMid = String(cString: albumMidPointer)
                if Self.isValidAlbumMid(candidateAlbumMid) {
                    if firstAlbumMid == nil {
                        firstAlbumMid = candidateAlbumMid
                    }

                    let storedAlbum = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                    if Self.albumMatches(requestedAlbum: requestedAlbum, storedAlbum: storedAlbum) {
                        return candidateAlbumMid
                    }
                }
            }
            stepStatus = sqlite3_step(statement)
        }

        guard stepStatus == SQLITE_DONE else { return nil }
        return firstAlbumMid
    }

    private static func databaseModificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func artworkURLs(albumMid: String) -> [URL] {
        [
            "https://y.qq.com/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
            "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
        ].compactMap(URL.init(string:))
    }

    private func fetchArtwork(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty,
                  data.count <= Self.maxArtworkBytes,
                  NSImage(data: data) != nil
            else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func albumMatches(requestedAlbum: String?, storedAlbum: String?) -> Bool {
        guard let requestedAlbum,
              !requestedAlbum.isEmpty,
              let storedAlbum,
              !storedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return true
        }

        let requested = requestedAlbum.lowercased()
        let stored = storedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return requested == stored || requested.contains(stored) || stored.contains(requested)
    }

    private static func isValidAlbumMid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{14}$"#, options: .regularExpression) != nil
    }

    private struct AlbumLookupKey: Hashable {
        let title: String
        let artist: String
        let album: String

        init(title: String, artist: String?, album: String?) {
            self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.album = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private struct AlbumLookupMiss: Equatable {
        let databaseModificationDate: Date?
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

    init(handle: UnsafeMutableRawPointer) {
        title = Self.constant("kMRMediaRemoteNowPlayingInfoTitle", handle: handle)
        artist = Self.constant("kMRMediaRemoteNowPlayingInfoArtist", handle: handle)
        album = Self.constant("kMRMediaRemoteNowPlayingInfoAlbum", handle: handle)
        artworkData = Self.constant("kMRMediaRemoteNowPlayingInfoArtworkData", handle: handle)
        artworkMIMEType = Self.constant("kMRMediaRemoteNowPlayingInfoArtworkMIMEType", handle: handle)
        playbackRate = Self.constant("kMRMediaRemoteNowPlayingInfoPlaybackRate", handle: handle)
        timestamp = Self.constant("kMRMediaRemoteNowPlayingInfoTimestamp", handle: handle)
        lyrics = Self.optionalConstant("kMRMediaRemoteNowPlayingInfoLyrics", handle: handle)
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
