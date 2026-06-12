import Foundation
import XCTest
@testable import Bough

final class MusicMediaRemotePayloadParserTests: XCTestCase {
    func testAllowlistAcceptsSupportedMusicPlayers() {
        let players: [(String?, String?, String)] = [
            ("com.apple.Music", "Music", "Apple"),
            ("com.spotify.client", "Spotify", "Spotify"),
            ("com.tencent.QQMusicMac", "QQ Music", "QQ"),
            ("com.netease.163music", "NetEase Cloud Music", "NetEase"),
            ("com.netease.cloudmusic", "网易云音乐", "NetEase alternate"),
            (nil, "QQ音乐", "QQ display fallback"),
        ]

        for (bundleIdentifier, displayName, label) in players {
            let snapshot = MusicNowPlayingPayloadParser.parse(
                payload(bundleIdentifier: bundleIdentifier, displayName: displayName),
                capturedAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertNotNil(snapshot, label)
        }
    }

    func testAllowlistRejectsBrowsersMeetingsVideosAndUnknownPlayers() {
        let players: [(String?, String?, String)] = [
            ("com.apple.Safari", "Safari", "browser"),
            ("us.zoom.xos", "zoom.us", "meeting"),
            ("com.google.Chrome", "Chrome", "browser"),
            ("com.apple.TV", "TV", "video"),
            ("com.unknown.audio", "Unknown Player", "unknown"),
            ("com.fake.player", "Spotify", "unknown bundle wins over supported display name"),
            (nil, nil, "missing identity"),
        ]

        for (bundleIdentifier, displayName, label) in players {
            let snapshot = MusicNowPlayingPayloadParser.parse(
                payload(bundleIdentifier: bundleIdentifier, displayName: displayName),
                capturedAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertNil(snapshot, label)
        }
    }

    func testParserBuildsSnapshotFromCompletePayload() throws {
        let snapshot = try XCTUnwrap(MusicNowPlayingPayloadParser.parse(
            payload(
                title: "Track",
                artist: "Artist",
                album: "Album",
                artworkData: Self.validPNGData(),
                artworkMimeType: " IMAGE/PNG ",
                playbackStateValue: 1,
                lyricCandidates: [
                    MusicLyricCandidate(
                        text: "First line\nSecond line",
                        source: .officialNoTokenLocal
                    ),
                ],
                commandAvailability: MusicCommandAvailability(
                    canPlayPause: true,
                    canSkipPrevious: false,
                    canSkipNext: true
                )
            ),
            capturedAt: Date(timeIntervalSince1970: 42)
        ))

        XCTAssertEqual(snapshot.player.bundleIdentifier, "com.tencent.QQMusicMac")
        XCTAssertEqual(snapshot.track?.title, "Track")
        XCTAssertEqual(snapshot.track?.artist, "Artist")
        XCTAssertEqual(snapshot.track?.album, "Album")
        XCTAssertEqual(snapshot.track?.lyricLine, "First line")
        XCTAssertNotNil(snapshot.track?.artwork)
        XCTAssertEqual(snapshot.track?.artwork?.mimeType, "image/png")
        XCTAssertEqual(snapshot.playbackState, .playing)
        XCTAssertFalse(snapshot.commands.canSkipPrevious)
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 42))
    }

    func testParserFallsBackToBundleDisplayNameWhenRuntimeDisplayNameIsUnavailable() throws {
        let snapshot = try XCTUnwrap(MusicNowPlayingPayloadParser.parse(
            payload(displayName: nil),
            capturedAt: Date(timeIntervalSince1970: 42)
        ))

        XCTAssertEqual(snapshot.player.bundleIdentifier, "com.tencent.QQMusicMac")
        XCTAssertEqual(snapshot.player.displayName, "QQ Music")
    }

    func testParserHandlesMissingFieldsWithoutThrowing() {
        XCTAssertNil(MusicNowPlayingPayloadParser.parse(payload(title: nil, artist: nil, album: nil)))

        let snapshot = MusicNowPlayingPayloadParser.parse(payload(title: nil, artist: "Artist Only", album: nil))
        XCTAssertEqual(snapshot?.track?.artist, "Artist Only")
        XCTAssertNil(snapshot?.track?.title)
    }

    func testParserDropsCorruptArtworkWithoutNetworkFallback() throws {
        let snapshot = try XCTUnwrap(MusicNowPlayingPayloadParser.parse(
            payload(artworkData: Data("not an image".utf8), artworkMimeType: "image/png")
        ))

        XCTAssertNil(snapshot.track?.artwork)
        XCTAssertEqual(snapshot.track?.title, "Track")
    }

    func testParserDropsStalePayloads() {
        let snapshot = MusicNowPlayingPayloadParser.parse(
            payload(playbackStateValue: 99, playbackRate: nil, timestamp: Date(timeIntervalSince1970: 1)),
            capturedAt: Date(timeIntervalSince1970: MusicNowPlayingPayloadParser.stalePayloadAge + 2)
        )

        XCTAssertNil(snapshot)
    }

    func testParserKeepsPausedCurrentTrackVisibleWithOldTimestamp() throws {
        let snapshot = try XCTUnwrap(MusicNowPlayingPayloadParser.parse(
            payload(
                playbackStateValue: 2,
                playbackRate: nil,
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            capturedAt: Date(timeIntervalSince1970: MusicNowPlayingPayloadParser.stalePayloadAge + 2)
        ))

        XCTAssertEqual(snapshot.playbackState, .paused)
        XCTAssertEqual(snapshot.track?.title, "Track")
    }

    func testParserMapsPlaybackStateAndCommandAvailability() {
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: 1, playbackRate: nil)),
            .playing
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: 2, playbackRate: nil)),
            .paused
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: 3, playbackRate: nil)),
            .stopped
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: 99, playbackRate: nil)),
            .unknown
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: nil, playbackRate: 1)),
            .playing
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: nil, playbackRate: 0)),
            .paused
        )
        XCTAssertEqual(
            MusicNowPlayingPayloadParser.playbackState(from: payload(playbackStateValue: 2, playbackRate: 1)),
            .paused
        )

        let snapshot = MusicNowPlayingPayloadParser.parse(payload(commandAvailability: nil))
        XCTAssertEqual(snapshot?.commands, MusicNowPlayingPayloadParser.defaultCommandAvailability)
    }

    func testLyricLineUsesSingleTrimmedMetadataLine() {
        let lyric = MusicLyricsBoundary.oneLine(from: [
            MusicLyricCandidate(text: "\n  first usable line  \nsecond", source: .mediaRemotePayload),
        ])

        XCTAssertEqual(lyric, "first usable line")
    }

    func testLyricsHideBlankTokenOAuthSDKAndReverseEngineeredSources() {
        let lyric = MusicLyricsBoundary.oneLine(from: [
            MusicLyricCandidate(text: "token lyric", source: .officialNoTokenLocal, requiresToken: true),
            MusicLyricCandidate(text: "sdk lyric", source: .thirdPartySDK),
            MusicLyricCandidate(text: "reverse lyric", source: .reverseEngineeredAPI),
            MusicLyricCandidate(text: "oauth lyric", source: .tokenRequiredAPI),
            MusicLyricCandidate(text: "   ", source: .mediaRemotePayload),
        ])

        XCTAssertNil(lyric)
    }

    func testParserCapturesPlaybackPositionFromPayload() {
        let captured = Date(timeIntervalSince1970: 500)
        let payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.apple.Music",
            displayName: "Music",
            title: "Track",
            artist: nil,
            album: nil,
            artworkData: nil,
            artworkMimeType: nil,
            playbackStateValue: 1,
            playbackRate: 1,
            timestamp: Date(timeIntervalSince1970: 480),
            elapsedTime: 42,
            duration: 240
        )
        let snapshot = MusicNowPlayingPayloadParser.parse(payload, capturedAt: captured)
        XCTAssertEqual(snapshot?.position?.elapsed, 42)
        XCTAssertEqual(snapshot?.position?.duration, 240)
        XCTAssertEqual(snapshot?.position?.capturedAt, Date(timeIntervalSince1970: 480))
    }

    func testBoughOnlineSearchLyricSourceIsAllowed() {
        XCTAssertTrue(MusicLyricCandidateSource.boughOnlineSearch.isAllowed)
        XCTAssertFalse(MusicLyricCandidateSource.reverseEngineeredAPI.isAllowed)
        XCTAssertEqual(
            MusicLyricsBoundary.oneLine(from: [
                MusicLyricCandidate(text: "online line", source: .boughOnlineSearch),
            ]),
            "online line"
        )
    }

    func testParserPositionRateIsZeroWhenPaused() {
        let payload = MusicNowPlayingPayload(
            bundleIdentifier: "com.apple.Music", displayName: "Music",
            title: "Track", artist: nil, album: nil,
            artworkData: nil, artworkMimeType: nil,
            playbackStateValue: 2, playbackRate: 0,
            timestamp: nil, elapsedTime: 42, duration: 240
        )
        let snapshot = MusicNowPlayingPayloadParser.parse(payload, capturedAt: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(snapshot?.position?.rate, 0)
        XCTAssertEqual(snapshot?.position?.capturedAt, Date(timeIntervalSince1970: 500))
    }

    func testDescribesSameSourceUsesBundleIdWhenBothPresent() {
        let qq = makeSourcePayload(bundle: "com.tencent.QQMusicMac")
        let spotify = makeSourcePayload(bundle: "com.spotify.client", title: "Other Song")
        XCTAssertFalse(qq.describesSameSource(as: spotify))
        XCTAssertTrue(qq.describesSameSource(as: qq))
        let anonymous = makeSourcePayload(bundle: nil)
        XCTAssertTrue(anonymous.describesSameSource(as: spotify), "两侧可比维度都缺时放行")
    }

    func testDescribesSameSourceRejectsConflictingDisplayNamesWhenBundlesAbsent() {
        let a = makeSourcePayload(bundle: nil, name: "Apple Music")
        let b = makeSourcePayload(bundle: nil, name: "Spotify")
        XCTAssertFalse(a.describesSameSource(as: b))
    }

    func testDescribesSameSourceRejectsConflictingTitlesWhenNoBundleOrName() {
        let a = makeSourcePayload(bundle: nil, name: nil, title: "Song A")
        let b = makeSourcePayload(bundle: nil, name: nil, title: "Song B")
        XCTAssertFalse(a.describesSameSource(as: b))
    }

    func testScriptFallbackIsGuardedBySourceConsistency() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let adapter = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(adapter.contains("legacyPayload.describesSameSource(as: scriptPayload)"))
    }

    private func makeSourcePayload(bundle: String?, name: String? = nil, title: String? = nil) -> MusicNowPlayingPayload {
        MusicNowPlayingPayload(
            bundleIdentifier: bundle, displayName: name,
            title: title, artist: nil, album: nil,
            artworkData: nil, artworkMimeType: nil,
            playbackStateValue: nil, playbackRate: nil
        )
    }

    private func payload(
        bundleIdentifier: String? = "com.tencent.QQMusicMac",
        displayName: String? = "QQ Music",
        title: String? = "Track",
        artist: String? = "Artist",
        album: String? = "Album",
        artworkData: Data? = nil,
        artworkMimeType: String? = nil,
        playbackStateValue: Int? = 1,
        playbackRate: Double? = nil,
        timestamp: Date? = nil,
        lyricCandidates: [MusicLyricCandidate] = [],
        commandAvailability: MusicCommandAvailability? = MusicCommandAvailability(
            canPlayPause: true,
            canSkipPrevious: true,
            canSkipNext: true
        )
    ) -> MusicNowPlayingPayload {
        MusicNowPlayingPayload(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
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

    private static func validPNGData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    }
}
