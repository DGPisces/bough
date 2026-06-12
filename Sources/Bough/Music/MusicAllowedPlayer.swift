import Foundation

enum MusicAllowedPlayer: CaseIterable, Equatable {
    case appleMusic
    case spotify
    case qqMusic
    case netEaseCloudMusic

    var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        case .qqMusic:
            return "QQ Music"
        case .netEaseCloudMusic:
            return "NetEase Cloud Music"
        }
    }

    private var bundleIdentifiers: Set<String> {
        switch self {
        case .appleMusic:
            return ["com.apple.Music"]
        case .spotify:
            return ["com.spotify.client"]
        case .qqMusic:
            return ["com.tencent.QQMusicMac"]
        case .netEaseCloudMusic:
            return [
                "com.netease.163music",
                "com.netease.cloudmusic",
            ]
        }
    }

    private var displayNameHints: Set<String> {
        switch self {
        case .appleMusic:
            return ["music", "apple music"]
        case .spotify:
            return ["spotify"]
        case .qqMusic:
            return ["qq music", "qqmusic", "qq音乐"]
        case .netEaseCloudMusic:
            return ["netease cloud music", "neteasemusic", "网易云音乐"]
        }
    }

    /// Prefix-matched after exact hints fail. Deliberately excludes the generic
    /// "music" so arbitrary "*Music*" apps never alias to Apple Music.
    private var displayNamePrefixHints: [String] {
        switch self {
        case .appleMusic:
            return []
        case .spotify:
            return ["spotify"]
        case .qqMusic:
            return ["qq music", "qqmusic", "qq音乐"]
        case .netEaseCloudMusic:
            return ["netease", "网易云"]
        }
    }

    static func match(bundleIdentifier: String?, displayName: String?) -> MusicAllowedPlayer? {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedBundleIdentifier, !normalizedBundleIdentifier.isEmpty {
            for player in allCases where player.bundleIdentifiers.contains(normalizedBundleIdentifier) {
                return player
            }
            return nil
        }

        let normalizedDisplayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalizedDisplayName, !normalizedDisplayName.isEmpty else {
            return nil
        }

        if let exact = allCases.first(where: { $0.displayNameHints.contains(normalizedDisplayName) }) {
            return exact
        }
        return allCases.first { player in
            player.displayNamePrefixHints.contains { normalizedDisplayName.hasPrefix($0) }
        }
    }

    static func matchRunningApplication(bundleIdentifier: String?) -> MusicAllowedPlayer? {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedBundleIdentifier, !normalizedBundleIdentifier.isEmpty else {
            return nil
        }
        return allCases.first { player in
            player.bundleIdentifiers.contains(normalizedBundleIdentifier)
        }
    }
}
