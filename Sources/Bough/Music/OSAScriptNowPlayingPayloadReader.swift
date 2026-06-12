import Foundation

actor OSAScriptNowPlayingPayloadReader {
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
