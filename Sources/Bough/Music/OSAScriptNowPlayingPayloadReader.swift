import Foundation

actor OSAScriptNowPlayingPayloadReader {
    typealias ProcessRunning = @Sendable (_ path: String, _ args: [String], _ timeout: TimeInterval) -> Data?

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
        let elapsedTime: Double?
        let duration: Double?
        let lyrics: String?
    }

    private enum BackoffState {
        case idle
        case waiting(until: Date, consecutiveFailures: Int)
    }

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let emptyOrFailureBackoffIntervals: [TimeInterval] = [10, 30, 60]
    private static let activePlaybackProbeInterval: TimeInterval = 2
    private static let maxOutputBytes = 2 * 1024 * 1024
    private static let timeout: TimeInterval = 1.5

    private let processRunner: ProcessRunning
    private let now: () -> Date
    private var backoffState: BackoffState = .idle
    private var inFlightReadTask: Task<MusicNowPlayingPayload?, Never>?

    init(
        processRunner: @escaping ProcessRunning = { path, args, timeout in
            ProcessRunner.run(path: path, args: args, timeout: timeout)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.now = now
    }

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
            elapsedTime: numberForKey('kMRMediaRemoteNowPlayingInfoElapsedTime'),
            duration: numberForKey('kMRMediaRemoteNowPlayingInfoDuration'),
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
        let current = now()
        if !bypassingBackoff, case let .waiting(until, _) = backoffState, current < until {
            return nil
        }

        if let inFlightReadTask {
            return await inFlightReadTask.value
        }

        let runner = processRunner
        let readTask = Task.detached(priority: .utility) {
            Self.readPayload(runner: runner)
        }
        inFlightReadTask = readTask
        let payload = await readTask.value
        inFlightReadTask = nil

        if payload?.hasDisplayableMediaRemoteMetadata == true {
            backoffState = .idle
        } else {
            let failures: Int
            if case let .waiting(_, consecutiveFailures) = backoffState {
                failures = consecutiveFailures + 1
            } else {
                failures = 1
            }
            let interval = probingActivePlayback
                ? Self.activePlaybackProbeInterval
                : Self.emptyOrFailureBackoffIntervals[
                    min(failures - 1, Self.emptyOrFailureBackoffIntervals.count - 1)
                ]
            backoffState = .waiting(until: current.addingTimeInterval(interval), consecutiveFailures: failures)
        }

        return payload
    }

    private static func readPayload(runner: ProcessRunning) -> MusicNowPlayingPayload? {
        guard let data = runner(executableURL.path, ["-l", "JavaScript", "-e", script], timeout) else {
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
            elapsedTime: decoded.elapsedTime,
            duration: decoded.duration,
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
