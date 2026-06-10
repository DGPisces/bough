import Foundation
import XCTest
@testable import Bough

final class MusicSettingsAndModelsTests: XCTestCase {
    func testShowMusicControlsDefaultsOnAndIsRegistered() throws {
        let source = try sourceFile("Sources/Bough/Settings.swift")

        XCTAssertEqual(SettingsKey.showMusicControls, "showMusicControls")
        XCTAssertTrue(SettingsDefaults.showMusicControls)
        XCTAssertTrue(source.contains("SettingsKey.showMusicControls: SettingsDefaults.showMusicControls"))
    }

    func testCompactBarPriorityDefaultsToAIActivityAndNormalizesInvalidValues() throws {
        let source = try sourceFile("Sources/Bough/Settings.swift")
        let accessor = try XCTUnwrap(source.slice(from: "var compactBarPriority: CompactBarPriority {", to: "var notchHeightMode: NotchHeightMode {"))

        XCTAssertEqual(SettingsKey.compactBarPriority, "compactBarPriority")
        XCTAssertEqual(SettingsDefaults.compactBarPriority, CompactBarPriority.aiActivity.rawValue)
        XCTAssertEqual(CompactBarPriority.normalized(nil), .aiActivity)
        XCTAssertEqual(CompactBarPriority.normalized(""), .aiActivity)
        XCTAssertEqual(CompactBarPriority.normalized("status"), .aiActivity)
        XCTAssertEqual(CompactBarPriority.normalized("music"), .music)
        XCTAssertTrue(source.contains("SettingsKey.compactBarPriority: SettingsDefaults.compactBarPriority"))
        XCTAssertTrue(accessor.contains("CompactBarPriority.normalized(defaults.string(forKey: SettingsKey.compactBarPriority))"))
        XCTAssertTrue(accessor.contains("defaults.set(newValue.rawValue, forKey: SettingsKey.compactBarPriority)"))
    }

    func testCompactBarPriorityFallsBackWhenPreferredSourceUnavailable() {
        XCTAssertEqual(
            CompactBarPriority.resolvedSource(rawValue: "music", musicControlsEnabled: true, aiAvailable: true, musicAvailable: true),
            .music
        )
        XCTAssertEqual(
            CompactBarPriority.resolvedSource(rawValue: "music", musicControlsEnabled: true, aiAvailable: true, musicAvailable: false),
            .aiActivity
        )
        XCTAssertEqual(
            CompactBarPriority.resolvedSource(rawValue: "aiActivity", musicControlsEnabled: true, aiAvailable: false, musicAvailable: true),
            .music
        )
        XCTAssertEqual(
            CompactBarPriority.resolvedSource(rawValue: "music", musicControlsEnabled: false, aiAvailable: true, musicAvailable: true),
            .aiActivity
        )
        XCTAssertNil(
            CompactBarPriority.resolvedSource(rawValue: "music", musicControlsEnabled: false, aiAvailable: false, musicAvailable: true)
        )
        XCTAssertNil(
            CompactBarPriority.resolvedSource(rawValue: "aiActivity", musicControlsEnabled: true, aiAvailable: false, musicAvailable: false)
        )
    }

    func testMusicSnapshotTreatsPlayingAndPausedTracksAsVisibleActivity() {
        let player = MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
        let track = MusicTrackSnapshot(title: "Track", artist: "Artist", album: "Album", lyricLine: "Line", artwork: nil)
        let commands = MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true)
        let playing = MusicNowPlayingSnapshot(player: player, track: track, playbackState: .playing, commands: commands, capturedAt: Date(timeIntervalSince1970: 1))
        let paused = MusicNowPlayingSnapshot(player: player, track: track, playbackState: .paused, commands: commands, capturedAt: Date(timeIntervalSince1970: 2))
        let stopped = MusicNowPlayingSnapshot(player: player, track: track, playbackState: .stopped, commands: commands, capturedAt: Date(timeIntervalSince1970: 3))
        let noTrack = MusicNowPlayingSnapshot(player: player, track: nil, playbackState: .playing, commands: commands, capturedAt: Date(timeIntervalSince1970: 4))

        XCTAssertTrue(playing.hasCurrentVisibleTrack)
        XCTAssertTrue(paused.hasCurrentVisibleTrack)
        XCTAssertFalse(stopped.hasCurrentVisibleTrack)
        XCTAssertFalse(noTrack.hasCurrentVisibleTrack)
        XCTAssertTrue(commands.supports(.playPause))
        XCTAssertTrue(commands.supports(.previous))
        XCTAssertTrue(commands.supports(.next))
    }

    func testMusicModelsNormalizeBlankMetadata() {
        let player = MusicPlayerIdentity(bundleIdentifier: "  ", displayName: "  ")
        let track = MusicTrackSnapshot(title: "  ", artist: "\n", album: nil, lyricLine: "", artwork: nil)

        XCTAssertNil(player.bundleIdentifier)
        XCTAssertEqual(player.displayName, "Music")
        XCTAssertFalse(track.hasDisplayableMetadata)
        XCTAssertNil(track.title)
        XCTAssertNil(track.artist)
        XCTAssertNil(track.album)
        XCTAssertNil(track.lyricLine)
    }

    func testAllowedPlayerMatchesRunningApplicationBundleIdentifiersOnly() {
        XCTAssertEqual(MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: "com.tencent.QQMusicMac"), .qqMusic)
        XCTAssertEqual(MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: " com.spotify.client "), .spotify)
        XCTAssertNil(MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: "QQ Music"))
        XCTAssertNil(MusicAllowedPlayer.matchRunningApplication(bundleIdentifier: nil))
    }

    func testSettingsDisplaySourcePreservesMusicPriorityWhenControlsAreOff() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")
        let page = try XCTUnwrap(source.slice(from: "private struct MusicPage: View", to: "// MARK: - Session Display Page"))

        XCTAssertTrue(page.contains("@AppStorage(SettingsKey.showMusicControls)"))
        XCTAssertTrue(page.contains("@AppStorage(SettingsKey.compactBarPriority)"))
        XCTAssertTrue(page.contains("Toggle(l10n[\"show_music_controls\"], isOn: showMusicControlsBinding)"))
        XCTAssertTrue(page.contains("musicStore.refreshControlsEnabled()"))
        XCTAssertTrue(page.contains("Picker(selection: compactBarPriority)"))
        XCTAssertTrue(page.contains(".tag(CompactBarPriority.music.rawValue)"))
        XCTAssertTrue(page.contains(".disabled(!showMusicControls)"))
        XCTAssertFalse(page.contains("compactBarPriorityRaw = CompactBarPriority.aiActivity.rawValue"))
    }

    func testHideWhenIdleCopyIncludesMusicActivity() {
        XCTAssertEqual(L10n.strings["en"]?["hide_when_no_session"], "Hide When Idle")
        XCTAssertEqual(
            L10n.strings["en"]?["hide_when_no_session_desc"],
            "Hide panel completely when there are no AI sessions and no eligible music players active"
        )
    }

    func testMusicSettingsKeysExistInAllLanguages() {
        let keys = [
            "music_controls_section",
            "show_music_controls",
            "show_music_controls_desc",
            "compact_bar_priority",
            "compact_bar_priority_desc",
            "compact_priority_ai_activity",
            "compact_priority_music",
            "compact_bar_priority_music_disabled_desc",
        ]

        for language in ["en", "zh"] {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testMusicModelsStayTransientAndAppTargetLocal() throws {
        let source = try sourceFile("Sources/Bough/Music/MusicModels.swift")
        let appSources = try sources(under: "Sources/Bough")
        let coreSources = try sources(under: "Sources/BoughCore")
        let helperSources = try sources(under: "Sources/BoughBridge") + sources(under: "Sources/BoughUsageMonitor")

        XCTAssertTrue(source.contains("struct MusicNowPlayingSnapshot"))
        XCTAssertTrue(source.contains("Do not persist, export, webhook, or write them to diagnostics"))
        XCTAssertFalse(source.contains(": Codable"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("DiagnosticsExporter"))
        XCTAssertFalse(source.contains("MediaRemote"))
        XCTAssertFalse(source.contains("MRMediaRemote"))
        XCTAssertFalse(source.contains("dlopen"))
        XCTAssertFalse(source.contains("dlsym"))
        XCTAssertTrue(appSources.contains("MusicNowPlayingSnapshot"))
        XCTAssertFalse(coreSources.contains("MusicNowPlayingSnapshot"))
        XCTAssertFalse(helperSources.contains("MusicNowPlayingSnapshot"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sources(under relativePath: String) throws -> String {
        let root = Self.repoRoot.appendingPathComponent(relativePath, isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), "Failed to enumerate source scan root: \(root.path)")

        let sources = try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(sources.isEmpty, "Source scan must include Swift files under \(relativePath).")
        return sources.joined(separator: "\n")
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
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
