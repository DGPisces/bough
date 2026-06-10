import AppKit
import XCTest
@testable import Bough

final class PanelWindowControllerTests: XCTestCase {
    func testScreenHopMotionUsesMoreVisibleTiming() {
        let motion = PanelWindowController.screenHopMotion()

        XCTAssertEqual(motion.outgoingOffset, 18)
        XCTAssertEqual(motion.incomingOffset, 30)
        XCTAssertEqual(motion.fadeOutDuration, 0.14, accuracy: 0.001)
        XCTAssertEqual(motion.incomingPauseDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.fadeInDuration, 0.34, accuracy: 0.001)
    }

    func testScreenHopFramesRetractOldFrameAndDropIntoNewFrame() {
        let oldFrame = NSRect(x: 100, y: 820, width: 420, height: 180)
        let newFrame = NSRect(x: 1800, y: 900, width: 420, height: 180)

        let frames = PanelWindowController.screenHopFrames(
            oldFrame: oldFrame,
            newFrame: newFrame
        )

        XCTAssertEqual(frames.outgoing.origin.x, oldFrame.origin.x)
        XCTAssertEqual(frames.outgoing.origin.y, oldFrame.origin.y + 18)
        XCTAssertEqual(frames.outgoing.size, oldFrame.size)

        XCTAssertEqual(frames.incoming.origin.x, newFrame.origin.x)
        XCTAssertEqual(frames.incoming.origin.y, newFrame.origin.y + 30)
        XCTAssertEqual(frames.incoming.size, newFrame.size)
    }

    func testPanelVisibilityPolicyAllowsMusicUnderHideWhenIdle() {
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: true
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertTrue(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: false,
            activeSessionCount: 0,
            totalSessionCount: 0,
            hasVisibleMusicActivity: false
        ))
        XCTAssertFalse(MusicPanelActivityPolicy.shouldShowPanel(
            hideWhenIdle: true,
            codingSessionsEnabled: false,
            activeSessionCount: 1,
            totalSessionCount: 1,
            hasVisibleMusicActivity: false
        ))
    }

    func testPanelWindowControllerObservesMusicActivityForVisibility() throws {
        let source = try sourceFile("Sources/Bough/PanelWindowController.swift")

        XCTAssertTrue(source.contains("appState.musicStore.snapshot?.hasCurrentVisibleTrack"))
        XCTAssertTrue(source.contains("musicActivityObserver"))
        XCTAssertTrue(source.contains("MusicNowPlayingStore.didChangeNotification"))
        XCTAssertTrue(source.contains("object: appState.musicStore"))
        XCTAssertTrue(source.contains("self.updateVisibility()"))
        XCTAssertTrue(source.contains("refreshMusicPresentationNeededFromSettings()"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.hasVisibleMusicActivity"))
        XCTAssertTrue(source.contains("MusicPanelActivityPolicy.shouldShowPanel"))
        XCTAssertTrue(source.contains("codingSessionsEnabled: CodingSessionsSettings.isEnabled()"))
        XCTAssertTrue(source.contains("settings.showMusicControls"))
        XCTAssertFalse(source.contains("appState.activeSessionCount == 0"))
    }

    func testSpecificScreenChoiceGuardsNegativeIndex() throws {
        let source = try sourceFile("Sources/Bough/PanelWindowController.swift")

        XCTAssertTrue(source.contains("let index = Int(choice.dropFirst(7)),\n           index >= 0,\n           index < NSScreen.screens.count"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
