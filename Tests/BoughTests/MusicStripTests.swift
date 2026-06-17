import Foundation
import XCTest
@testable import Bough

final class MusicStripTests: XCTestCase {
    func testModelFormatsMetadataAndReservesOneLyricLine() throws {
        let snapshot = Self.snapshot(
            title: "Long Track",
            artist: "Artist",
            album: "Album",
            lyricLine: "one lyric line",
            playbackState: .playing
        )
        let model = try XCTUnwrap(MusicStripModel(snapshot: snapshot))

        XCTAssertEqual(model.title, "Long Track")
        XCTAssertEqual(model.subtitle, "Artist · QQ Music")
        XCTAssertEqual(model.lyricLine, "one lyric line")
        XCTAssertEqual(model.reservedLyricText, "one lyric line")
        XCTAssertEqual(model.lyricOpacity, 1)
        XCTAssertEqual(model.playPauseIcon, "pause.fill")
        XCTAssertEqual(model.playPauseLabelKey, "music_pause")
        XCTAssertEqual(model.playerBundleIdentifier, "com.tencent.QQMusicMac")
        XCTAssertTrue(model.commands.supports(.previous))
        XCTAssertTrue(model.commands.supports(.playPause))
        XCTAssertTrue(model.commands.supports(.next))
    }

    func testModelFallsBackAndKeepsMissingLyricsStable() throws {
        let snapshot = Self.snapshot(
            title: nil,
            artist: nil,
            album: nil,
            lyricLine: nil,
            artwork: MusicArtworkSnapshot(data: Data([0x01]), mimeType: nil),
            playbackState: .paused
        )
        let model = try XCTUnwrap(MusicStripModel(snapshot: snapshot))

        XCTAssertEqual(model.title, "QQ Music")
        XCTAssertEqual(model.subtitle, "QQ Music")
        XCTAssertNil(model.lyricLine)
        XCTAssertEqual(model.reservedLyricText, " ")
        XCTAssertEqual(model.lyricOpacity, 0)
        XCTAssertEqual(model.playPauseIcon, "play.fill")
        XCTAssertEqual(model.playPauseLabelKey, "music_play")
    }

    func testModelHidesStoppedUnknownOrMissingSnapshots() {
        XCTAssertNil(MusicStripModel(snapshot: nil))
        XCTAssertNil(MusicStripModel(snapshot: Self.snapshot(playbackState: .stopped)))
        XCTAssertNil(MusicStripModel(snapshot: Self.snapshot(playbackState: .unknown)))
    }

    func testExpandedVisibilityRequiresSessionListMusicAndControlsOn() {
        let snapshot = Self.snapshot(playbackState: .playing)

        XCTAssertTrue(MusicStripModel.shouldShowExpanded(
            surface: .sessionList,
            onlySessionId: nil,
            snapshot: snapshot,
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicStripModel.shouldShowExpanded(
            surface: .sessionList,
            onlySessionId: nil,
            snapshot: snapshot,
            musicControlsEnabled: false
        ))
        XCTAssertFalse(MusicStripModel.shouldShowExpanded(
            surface: .approvalCard(sessionId: "s1"),
            onlySessionId: nil,
            snapshot: snapshot,
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicStripModel.shouldShowExpanded(
            surface: .questionCard(sessionId: "s1"),
            onlySessionId: nil,
            snapshot: snapshot,
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicStripModel.shouldShowExpanded(
            surface: .sessionList,
            onlySessionId: "s1",
            snapshot: snapshot,
            musicControlsEnabled: true
        ))
    }

    func testSoftFailureMarksOnlyFailedCommand() throws {
        let failure = MusicSoftFailure(
            message: "Music command unavailable",
            command: .next,
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        let model = try XCTUnwrap(MusicStripModel(
            snapshot: Self.snapshot(playbackState: .playing),
            softFailure: failure
        ))

        XCTAssertEqual(model.failedCommand, .next)
        XCTAssertTrue(model.hasSoftFailure)
    }

    func testLayoutConstantsKeepExpandedStripStable() {
        XCTAssertEqual(MusicStripModel.artworkSize, 46)
        XCTAssertEqual(MusicStripModel.controlSize, 26)
        XCTAssertEqual(MusicStripModel.compactControlSize, 24)
        XCTAssertEqual(MusicStripModel.lyricLineHeight, 14)
    }

    func testMusicStripSourceWiresExpandedCommandsAndOneLineLyric() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")

        XCTAssertTrue(source.contains("struct MusicStrip: View"))
        XCTAssertTrue(source.contains("appState.musicStore.openCurrentPlayer()"))
        XCTAssertTrue(source.contains("appState.musicStore.send(.previous)"))
        XCTAssertTrue(source.contains("appState.musicStore.send(.playPause)"))
        XCTAssertTrue(source.contains("appState.musicStore.send(.next)"))
        XCTAssertTrue(source.contains("l10n[\"music_open_player\"]"))
        XCTAssertTrue(source.contains(".frame(width: 88, alignment: .trailing)"))
        XCTAssertTrue(source.contains(".frame(height: MusicStripModel.lyricLineHeight"))
        XCTAssertTrue(source.contains(".lineLimit(1)"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("spectrum"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("marquee"))
    }

    func testCompactControlOnlySendsPlayPause() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")
        let compact = try XCTUnwrap(source.slice(from: "struct CompactMusicPlayPauseControl", to: "struct MusicFigureView"))

        XCTAssertTrue(compact.contains("appState.musicStore.send(.playPause)"))
        XCTAssertTrue(compact.contains("var musicArtworkNamespace: Namespace.ID?"))
        XCTAssertTrue(compact.contains(".matchedGeometryEffect(id: MusicArtworkTransitionID.playPause, in: musicArtworkNamespace)"))
        XCTAssertTrue(compact.contains(".zIndex(MusicArtworkTransitionID.zIndex)"))
        XCTAssertTrue(compact.contains("onHoverChanged: onHoverChanged"))
        XCTAssertFalse(compact.contains("musicPlayPauseMotionBlur"))
        XCTAssertFalse(compact.contains(".blur(radius:"))
        XCTAssertFalse(compact.contains(".previous"))
        XCTAssertFalse(compact.contains(".next"))
    }

    func testExpandedArtworkCanJoinCompactMatchedTransition() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")
        let strip = try XCTUnwrap(source.slice(from: "struct MusicStrip: View", to: "@MainActor\nstruct CompactMusicPlayPauseControl"))

        XCTAssertTrue(source.contains("enum MusicArtworkTransitionID"))
        XCTAssertTrue(source.contains("static let playPause"))
        XCTAssertTrue(source.contains("static let zIndex"))
        XCTAssertTrue(strip.contains("var musicArtworkNamespace: Namespace.ID?"))
        XCTAssertTrue(strip.contains("artworkButton(model: model)"))
        XCTAssertTrue(strip.contains(".matchedGeometryEffect(id: MusicArtworkTransitionID.artwork, in: musicArtworkNamespace)"))
        XCTAssertTrue(strip.contains(".matchedGeometryEffect(id: MusicArtworkTransitionID.playPause, in: musicArtworkNamespace)"))
        XCTAssertTrue(strip.contains(".zIndex(MusicArtworkTransitionID.zIndex)"))
        XCTAssertFalse(source.contains("musicPlayPauseMotionBlur"))
        XCTAssertFalse(strip.contains(".blur(radius:"))
    }

    func testMusicFigureUsesSingleArtworkTilePathForFallbackAndPause() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")
        let figure = try XCTUnwrap(source.slice(from: "struct MusicFigureView", to: "private struct MusicArtworkTile"))
        XCTAssertTrue(figure.contains("artwork: model?.artwork"))
        XCTAssertTrue(figure.contains(".saturation(isPlaying ? 1 : 0)"))
        XCTAssertTrue(figure.contains("Image(systemName: \"pause.fill\")"))
        XCTAssertFalse(source.contains("MusicFallbackFigure"))
        XCTAssertFalse(source.contains("MusicEqualizerBars"))
        XCTAssertFalse(figure.contains("\"play.fill\""))
    }

    func testArtworkTileDecodesOnlyWhenArtworkChanges() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")
        let tile = try XCTUnwrap(source.slice(from: "private struct MusicArtworkTile", to: "struct MusicControlButton"))

        XCTAssertTrue(tile.contains("_decodedImage = State(initialValue: nil)"))
        XCTAssertTrue(tile.contains(".onChange(of: artwork, initial: true)"))
        XCTAssertFalse(tile.contains("State(initialValue: artwork.flatMap { NSImage(data: $0.data) })"))
    }

    func testExpandedStripAndControlsRespectReduceMotion() throws {
        let source = try sourceFile("Sources/Bough/Notch/MusicStrip.swift")
        let strip = try XCTUnwrap(source.slice(from: "struct MusicStrip: View", to: "@MainActor\nstruct CompactMusicPlayPauseControl"))
        let control = try XCTUnwrap(source.slice(from: "private struct MusicControlButton", to: "\n}"))

        XCTAssertTrue(strip.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(strip.contains("if reduceMotion"))
        XCTAssertTrue(strip.contains(".transition(reduceMotion ? .opacity"))
        XCTAssertTrue(control.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(control.contains("if reduceMotion"))
    }

    func testModelDisplaysTimedLyricLineForCurrentPosition() {
        let captured = Date(timeIntervalSince1970: 100)
        let snapshot = makeStripSnapshot(position: MusicPlaybackPosition(elapsed: 15, duration: 60, rate: 1, capturedAt: captured))
        let lyrics = MusicTimedLyrics.parsingLRC("[00:10]ten\n[00:20]twenty")
        let model = MusicStripModel(snapshot: snapshot, timedLyrics: lyrics)!
        XCTAssertEqual(model.displayedLyricLine(at: captured), "ten")
        XCTAssertEqual(model.displayedLyricLine(at: captured.addingTimeInterval(5)), "twenty")
    }

    func testModelFallsBackToStaticLyricLineWithoutTimedLyrics() {
        let snapshot = makeStripSnapshot(lyricLine: "static line")
        let model = MusicStripModel(snapshot: snapshot)!
        XCTAssertEqual(model.displayedLyricLine(at: Date()), "static line")
    }

    func testModelProgressFractionClampsToUnitRange() {
        let captured = Date(timeIntervalSince1970: 100)
        let snapshot = makeStripSnapshot(position: MusicPlaybackPosition(elapsed: 30, duration: 60, rate: 1, capturedAt: captured))
        let model = MusicStripModel(snapshot: snapshot)!
        XCTAssertEqual(model.progressFraction(at: captured)!, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.progressFraction(at: captured.addingTimeInterval(120))!, 1.0, accuracy: 0.001)
    }

    func testModelProgressFractionNilWithoutDuration() {
        let snapshot = makeStripSnapshot(position: nil)
        let model = MusicStripModel(snapshot: snapshot)!
        XCTAssertNil(model.progressFraction(at: Date()))
    }

    func testLocalArtworkAndLyricsTakePriorityOverOnline() {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let localArtwork = MusicArtworkSnapshot(data: Data(base64Encoded: pngBase64)!, mimeType: nil)
        let onlineArtwork = MusicArtworkSnapshot(data: Data([0x01, 0x02]), mimeType: nil)
        let onlineLyrics = MusicTimedLyrics.parsingLRC("[00:01.00]online lyric")

        let snapshot = MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.apple.Music", displayName: "Music"),
            track: MusicTrackSnapshot(title: "Song", artist: "Artist", album: nil, lyricLine: "local lyric", artwork: localArtwork),
            playbackState: .playing,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: Date()
        )
        let model = MusicStripModel(snapshot: snapshot, timedLyrics: onlineLyrics, onlineArtwork: onlineArtwork)!

        XCTAssertEqual(model.artwork, localArtwork, "本地 artwork 应优先于在线 artwork")
        XCTAssertEqual(model.displayedLyricLine(at: Date()), "local lyric", "本地 lyricLine 应优先于 timedLyrics")
    }

    func testModelUsesOnlineArtworkWhenLocalMissing() {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let online = MusicArtworkSnapshot(data: Data(base64Encoded: pngBase64)!, mimeType: nil)
        let snapshot = makeStripSnapshot(lyricLine: "x")   // 本地无 artwork
        let model = MusicStripModel(snapshot: snapshot, onlineArtwork: online)!
        XCTAssertEqual(model.artwork, online)
    }

    private func makeStripSnapshot(lyricLine: String? = nil, position: MusicPlaybackPosition? = nil) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.apple.Music", displayName: "Music"),
            track: MusicTrackSnapshot(title: "Song", artist: "Artist", album: nil, lyricLine: lyricLine, artwork: nil),
            playbackState: .playing,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: position?.capturedAt ?? Date(),
            position: position
        )
    }

    private static func snapshot(
        title: String? = "Track",
        artist: String? = "Artist",
        album: String? = "Album",
        lyricLine: String? = nil,
        artwork: MusicArtworkSnapshot? = nil,
        playbackState: MusicPlaybackState
    ) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music"),
            track: MusicTrackSnapshot(title: title, artist: artist, album: album, lyricLine: lyricLine, artwork: artwork),
            playbackState: playbackState,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
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
