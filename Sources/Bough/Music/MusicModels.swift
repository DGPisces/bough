import Foundation

enum MusicPlaybackState: String, CaseIterable, Equatable {
    case playing
    case paused
    case stopped
    case unknown

    var keepsCurrentTrackVisible: Bool {
        switch self {
        case .playing, .paused:
            return true
        case .stopped, .unknown:
            return false
        }
    }
}

enum MusicCommand: String, CaseIterable, Equatable {
    case previous
    case playPause
    case next
}

struct MusicPlayerIdentity: Equatable, Hashable {
    let bundleIdentifier: String?
    let displayName: String

    init(bundleIdentifier: String?, displayName: String) {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        self.bundleIdentifier = normalizedBundleIdentifier?.isEmpty == false ? normalizedBundleIdentifier : nil
        self.displayName = normalizedDisplayName.isEmpty ? "Music" : normalizedDisplayName
    }
}

struct MusicArtworkSnapshot: Equatable {
    let data: Data
    let mimeType: String?

    init(data: Data, mimeType: String?) {
        self.data = data
        let normalizedMimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.mimeType = normalizedMimeType?.isEmpty == false ? normalizedMimeType : nil
    }
}

/// In-memory now-playing metadata for UI rendering only.
///
/// Titles, artists, album names, lyric lines, artwork, and player identities are
/// transient. Do not persist, export, webhook, or write them to diagnostics.
struct MusicTrackSnapshot: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let lyricLine: String?
    let artwork: MusicArtworkSnapshot?

    init(title: String?, artist: String?, album: String?, lyricLine: String?, artwork: MusicArtworkSnapshot?) {
        self.title = Self.normalized(title)
        self.artist = Self.normalized(artist)
        self.album = Self.normalized(album)
        self.lyricLine = Self.normalized(lyricLine)
        self.artwork = artwork
    }

    var hasDisplayableMetadata: Bool {
        title != nil || artist != nil || album != nil || lyricLine != nil || artwork != nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct MusicCommandAvailability: Equatable {
    let canPlayPause: Bool
    let canSkipPrevious: Bool
    let canSkipNext: Bool

    static let unavailable = MusicCommandAvailability(
        canPlayPause: false,
        canSkipPrevious: false,
        canSkipNext: false
    )

    func supports(_ command: MusicCommand) -> Bool {
        switch command {
        case .previous:
            return canSkipPrevious
        case .playPause:
            return canPlayPause
        case .next:
            return canSkipNext
        }
    }
}

struct MusicSoftFailure: Equatable {
    let message: String
    let command: MusicCommand?
    let occurredAt: Date
}

/// A single transient now-playing read from an eligible player.
///
/// This is deliberately not `Codable`; downstream phases should keep music
/// metadata inside the Bough app process and render it directly.
struct MusicNowPlayingSnapshot: Equatable {
    let player: MusicPlayerIdentity
    let track: MusicTrackSnapshot?
    let playbackState: MusicPlaybackState
    let commands: MusicCommandAvailability
    let capturedAt: Date

    var hasCurrentVisibleTrack: Bool {
        playbackState.keepsCurrentTrackVisible && track?.hasDisplayableMetadata == true
    }

    func isDisplayEquivalent(to other: MusicNowPlayingSnapshot) -> Bool {
        player == other.player
            && track == other.track
            && playbackState == other.playbackState
            && commands == other.commands
    }
}

enum MusicServiceState: Equatable {
    case disabled
    case unavailable(reason: String)
    case available(MusicNowPlayingSnapshot?)

    var snapshot: MusicNowPlayingSnapshot? {
        if case let .available(snapshot) = self {
            return snapshot
        }
        return nil
    }

    var abnormalMessage: String? {
        if case let .unavailable(reason) = self {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
