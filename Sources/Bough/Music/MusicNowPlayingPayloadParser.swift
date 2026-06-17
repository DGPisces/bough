import AppKit
import Foundation

struct MusicNowPlayingPayload: Equatable, Sendable {
    let bundleIdentifier: String?
    let displayName: String?
    let title: String?
    let artist: String?
    let album: String?
    let artworkData: Data?
    let artworkMimeType: String?
    let playbackStateValue: Int?
    let playbackRate: Double?
    let timestamp: Date?
    let elapsedTime: Double?
    let duration: Double?
    let lyricCandidates: [MusicLyricCandidate]
    let commandAvailability: MusicCommandAvailability?

    init(
        bundleIdentifier: String?,
        displayName: String?,
        title: String?,
        artist: String?,
        album: String?,
        artworkData: Data?,
        artworkMimeType: String?,
        playbackStateValue: Int?,
        playbackRate: Double?,
        timestamp: Date? = nil,
        elapsedTime: Double? = nil,
        duration: Double? = nil,
        lyricCandidates: [MusicLyricCandidate] = [],
        commandAvailability: MusicCommandAvailability? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.artworkMimeType = artworkMimeType
        self.playbackStateValue = playbackStateValue
        self.playbackRate = playbackRate
        self.timestamp = timestamp
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.lyricCandidates = lyricCandidates
        self.commandAvailability = commandAvailability
    }
}

enum MusicNowPlayingPayloadParser {
    static let stalePayloadAge: TimeInterval = 60 * 15
    static let defaultCommandAvailability = MusicCommandAvailability(
        canPlayPause: true,
        canSkipPrevious: true,
        canSkipNext: true
    )

    static func parse(_ payload: MusicNowPlayingPayload, capturedAt: Date = Date()) -> MusicNowPlayingSnapshot? {
        let playbackState = playbackState(from: payload)
        guard !isStale(payload, playbackState: playbackState, capturedAt: capturedAt) else {
            return nil
        }

        guard let allowedPlayer = MusicAllowedPlayer.match(
            bundleIdentifier: payload.bundleIdentifier,
            displayName: payload.displayName
        ) else {
            return nil
        }

        guard playbackState.keepsCurrentTrackVisible else {
            return nil
        }

        let track = MusicTrackSnapshot(
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            lyricLine: MusicLyricsBoundary.oneLine(from: payload.lyricCandidates),
            artwork: artwork(from: payload)
        )

        guard track.hasDisplayableMetadata else {
            return nil
        }

        return MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(
                bundleIdentifier: payload.bundleIdentifier,
                displayName: payload.displayName ?? allowedPlayer.displayName
            ),
            track: track,
            playbackState: playbackState,
            commands: payload.commandAvailability ?? defaultCommandAvailability,
            capturedAt: capturedAt,
            position: MusicPlaybackPosition(
                elapsed: payload.elapsedTime,
                duration: payload.duration,
                rate: playbackState == .playing ? (payload.playbackRate ?? 1) : 0,
                capturedAt: payload.timestamp ?? capturedAt
            )
        )
    }

    static func playbackState(from payload: MusicNowPlayingPayload) -> MusicPlaybackState {
        if let playbackStateValue = payload.playbackStateValue {
            switch playbackStateValue {
            case 1:
                return .playing
            case 2:
                return .paused
            case 3:
                return .stopped
            default:
                return .unknown
            }
        }

        if let playbackRate = payload.playbackRate, playbackRate > 0 {
            return .playing
        }

        if payload.playbackRate != nil {
            return .paused
        }

        return .unknown
    }

    private static func isStale(
        _ payload: MusicNowPlayingPayload,
        playbackState: MusicPlaybackState,
        capturedAt: Date
    ) -> Bool {
        guard !playbackState.keepsCurrentTrackVisible else {
            return false
        }
        guard let timestamp = payload.timestamp else {
            return false
        }
        return capturedAt.timeIntervalSince(timestamp) > stalePayloadAge
    }

    private static func artwork(from payload: MusicNowPlayingPayload) -> MusicArtworkSnapshot? {
        guard let artworkData = payload.artworkData, !artworkData.isEmpty else {
            return nil
        }
        guard NSBitmapImageRep(data: artworkData) != nil || NSImage(data: artworkData) != nil else {
            return nil
        }
        return MusicArtworkSnapshot(data: artworkData, mimeType: payload.artworkMimeType)
    }
}

extension MusicNowPlayingPayload {
    /// Two payloads may be substituted for each other only if they cannot be
    /// from different players. The first dimension present on BOTH sides decides:
    /// bundle id (must be equal) → display name (must mutually contain) →
    /// title (normalized must be equal). A dimension missing on either side is
    /// skipped; if all dimensions are skipped the payloads are allowed.
    func describesSameSource(as other: MusicNowPlayingPayload) -> Bool {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        if let lhs = clean(bundleIdentifier), let rhs = clean(other.bundleIdentifier) {
            return lhs == rhs
        }
        if let lhs = clean(displayName)?.lowercased(), let rhs = clean(other.displayName)?.lowercased() {
            return lhs.contains(rhs) || rhs.contains(lhs)
        }
        if let lhs = clean(title)?.lowercased(), let rhs = clean(other.title)?.lowercased() {
            return lhs == rhs
        }
        return true
    }
}
