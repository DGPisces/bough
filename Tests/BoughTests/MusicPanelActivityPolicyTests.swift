import Foundation
import XCTest
@testable import Bough

final class MusicPanelActivityPolicyTests: XCTestCase {
    func testPlayingAndPausedMusicCountAsVisibleActivity() {
        XCTAssertTrue(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: Self.snapshot(playbackState: .playing),
            musicControlsEnabled: true
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: Self.snapshot(playbackState: .paused),
            musicControlsEnabled: true
        ))
    }

    func testStoppedUnknownNoSnapshotAndDisabledControlsDoNotCountAsMusicActivity() {
        XCTAssertFalse(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: Self.snapshot(playbackState: .stopped),
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: Self.snapshot(playbackState: .unknown),
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: nil,
            musicControlsEnabled: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: Self.snapshot(playbackState: .playing),
            musicControlsEnabled: false
        ))
    }

    func testVisibleMusicKeepsPanelVisibleUnderHideWhenIdle() {
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
    }

    func testNoMusicAndNoActiveSessionFollowsHideWhenIdle() {
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 2,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: false,
            activeSessionCount: 0,
            totalSessionCount: 2,
            hasVisibleMusicActivity: false
        ))
    }

    func testCodingSessionsOffIgnoresSessionCountsButKeepsMusicVisible() {
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            codingSessionsEnabled: false,
            activeSessionCount: 2,
            totalSessionCount: 3,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: false,
            codingSessionsEnabled: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            codingSessionsEnabled: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: false,
            codingSessionsEnabled: false,
            activeSessionCount: 3,
            totalSessionCount: 3,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: true,
            codingSessionsEnabled: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowIdleIndicator(
            hideWhenIdle: false,
            codingSessionsEnabled: false,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
    }

    func testBarHidesWhenOnlyIdleIndicatorShouldRender() {
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: false,
            activeSessionCount: 0,
            totalSessionCount: 2,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
    }

    func testMusicControlsOffSuppressesAllMusicActivityBoundaries() {
        let playingSnapshot = Self.snapshot(playbackState: .playing)

        XCTAssertFalse(MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: playingSnapshot,
            musicControlsEnabled: false
        ))
        XCTAssertNil(MusicPanelActivityPolicy.compactSource(
            rawPriority: CompactBarPriority.music.rawValue,
            musicControlsEnabled: false,
            aiAvailable: false,
            musicAvailable: true,
            surface: .collapsed
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowBar(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.presentationNeeded(
            musicControlsEnabled: false,
            hideWhenIdle: true,
            surface: .collapsed
        ))
    }

    func testIdleIndicatorDoesNotShowWhenMusicIsVisible() {
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowIdleIndicator(
            hideWhenIdle: false,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowIdleIndicator(
            hideWhenIdle: false,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
    }

    func testCompactPriorityChoosesMusicOnlyInCollapsedPresentation() {
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.music.rawValue,
                musicControlsEnabled: true,
                aiAvailable: true,
                musicAvailable: true,
                surface: .collapsed
            ),
            .music
        )
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.music.rawValue,
                musicControlsEnabled: true,
                aiAvailable: true,
                musicAvailable: true,
                surface: .sessionList
            ),
            .aiActivity
        )
    }

    func testCompactPriorityFallsBackWhenPreferredSourceMissing() {
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.music.rawValue,
                musicControlsEnabled: true,
                aiAvailable: true,
                musicAvailable: false,
                surface: .collapsed
            ),
            .aiActivity
        )
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.aiActivity.rawValue,
                musicControlsEnabled: true,
                aiAvailable: false,
                musicAvailable: true,
                surface: .collapsed
            ),
            .music
        )
        XCTAssertNil(MusicPanelActivityPolicy.compactSource(
            rawPriority: CompactBarPriority.music.rawValue,
            musicControlsEnabled: false,
            aiAvailable: false,
            musicAvailable: true,
            surface: .collapsed
        ))
    }

    func testApprovalAndQuestionSurfacesForceAIActivity() {
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.music.rawValue,
                musicControlsEnabled: true,
                aiAvailable: true,
                musicAvailable: true,
                surface: .approvalCard(sessionId: "s1")
            ),
            .aiActivity
        )
        XCTAssertEqual(
            MusicPanelActivityPolicy.compactSource(
                rawPriority: CompactBarPriority.music.rawValue,
                musicControlsEnabled: true,
                aiAvailable: true,
                musicAvailable: true,
                surface: .questionCard(sessionId: "s1")
            ),
            .aiActivity
        )
    }

    func testPresentationNeededStopsWhenMusicControlsAreOff() {
        XCTAssertFalse(MusicPanelActivityPolicy.presentationNeeded(
            musicControlsEnabled: false,
            hideWhenIdle: true,
            surface: .collapsed
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.presentationNeeded(
            musicControlsEnabled: true,
            hideWhenIdle: true,
            surface: .collapsed
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.presentationNeeded(
            musicControlsEnabled: true,
            hideWhenIdle: false,
            surface: .collapsed
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.presentationNeeded(
            musicControlsEnabled: true,
            hideWhenIdle: false,
            surface: .sessionList
        ))
    }

    private static func snapshot(playbackState: MusicPlaybackState) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: MusicPlayerIdentity(bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music"),
            track: MusicTrackSnapshot(title: "Track", artist: "Artist", album: "Album", lyricLine: nil, artwork: nil),
            playbackState: playbackState,
            commands: MusicCommandAvailability(canPlayPause: true, canSkipPrevious: true, canSkipNext: true),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
