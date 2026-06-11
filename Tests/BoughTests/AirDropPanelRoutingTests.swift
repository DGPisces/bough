import XCTest
@testable import Bough

@MainActor
final class AirDropPanelRoutingTests: XCTestCase {
    func testPanelAndDragEntryUseAirDropSurfaceWithReturnTarget() {
        let state = AppState()
        state.surface = .sessionList

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("AirDrop entry should switch to dedicated AirDrop surface")
            return
        }
        XCTAssertEqual(returningTo, .sessionList)
        guard case .ready(let draft) = state.airDropState else {
            XCTFail("AirDrop payload should be ready for native AirDrop")
            return
        }
        XCTAssertEqual(draft.source, .drag)
        XCTAssertEqual(draft.fileURLs, [URL(fileURLWithPath: "/tmp/example.txt")])
    }

    func testAirDropCancelReturnsToPreviousSurface() {
        let state = AppState()
        state.surface = .collapsed

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )
        state.cancelAirDrop()

        XCTAssertEqual(state.surface, .collapsed)
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testNonExplicitAirDropCancellationStaysInAirDropMode() {
        let state = AppState()
        state.surface = .sessionList

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )
        state.airDropFlowController.cancel()

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("Native cancellation should keep AirDrop mode visible")
            return
        }
        XCTAssertEqual(returningTo, .sessionList)
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testDragPreheatCanOpenIdleDropZoneWithoutPayload() {
        let state = AppState()
        state.surface = .completionCard(sessionId: "done")

        state.showAirDropDropZone()

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("Preheat should switch to AirDrop drop zone")
            return
        }
        XCTAssertEqual(returningTo, .completionCard(sessionId: "done"))
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testExpandedIdleDropZoneStaysUntilExplicitClose() {
        let state = AppState()
        state.surface = .completionCard(sessionId: "done")

        state.showAirDropDropZone()
        state.dismissAirDropDragMagnetIfEmpty()

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("Expanded AirDrop mode should stay foreground until explicit close")
            return
        }
        XCTAssertEqual(returningTo, .completionCard(sessionId: "done"))
        XCTAssertEqual(state.airDropState, .idle)

        state.cancelAirDrop()
        XCTAssertEqual(state.surface, .completionCard(sessionId: "done"))
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testDragOpenedEmptyDropZoneAutoReturnsWhenNoPayloadArrives() async throws {
        let state = AppState()
        state.surface = .sessionList
        state.airDropEmptyDragDismissDelay = 0.01

        state.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("Drag preheat should open AirDrop mode")
            return
        }
        XCTAssertEqual(returningTo, .sessionList)

        let didReturn = try await TestHelpers.waitUntil {
            state.surface == .sessionList
        }

        XCTAssertTrue(didReturn)
        XCTAssertEqual(state.surface, .sessionList)
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testManualEmptyAirDropDoesNotAutoReturn() async throws {
        let state = AppState()
        state.surface = .sessionList
        state.airDropEmptyDragDismissDelay = 0.01

        state.beginAirDropPanelSelection()

        try await Task.sleep(nanoseconds: 120_000_000)

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("Manual AirDrop entry should stay foreground")
            return
        }
        XCTAssertEqual(returningTo, .sessionList)
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testDragPreheatDoesNotResetExistingDraftAndDropAddsMore() {
        let state = AppState()
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [first]),
            source: .panel
        )
        state.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)
        state.addAirDropPayload(
            AirDropPasteboardPayload(fileURLs: [second]),
            source: .drag
        )

        guard case .ready(let draft) = state.airDropState else {
            XCTFail("Existing AirDrop draft should remain ready after drag preheat")
            return
        }
        XCTAssertEqual(draft.fileURLs, [first, second])
    }

    func testTextFirstAppendFilesKeepsTxtSelectedByDefault() {
        let state = AppState()
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(text: "include this note"),
            source: .drag
        )
        state.addAirDropPayload(
            AirDropPasteboardPayload(fileURLs: [first, second]),
            source: .drag
        )

        guard case .ready(let draft) = state.airDropState else {
            XCTFail("Text-first append should become a mixed ready draft")
            return
        }
        XCTAssertEqual(draft.fileURLs, [first, second])
        XCTAssertEqual(draft.textSnippets, ["include this note"])
        XCTAssertTrue(state.airDropIncludeText)
    }

    func testImmediateDuplicateDragPayloadIsSuppressedButLaterDuplicateCanBeAdded() {
        let state = AppState()
        var now = Date(timeIntervalSince1970: 10)
        state.airDropDateProvider = { now }
        state.airDropDuplicateDragSuppressionInterval = 0.75

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(text: "same note"),
            source: .drag
        )
        state.addAirDropPayload(
            AirDropPasteboardPayload(text: "same note"),
            source: .drag
        )

        guard case .confirmingText(let firstDraft) = state.airDropState else {
            XCTFail("First text payload should stay in text confirmation")
            return
        }
        XCTAssertEqual(firstDraft.textSnippets, ["same note"])

        now = now.addingTimeInterval(1.0)
        state.addAirDropPayload(
            AirDropPasteboardPayload(text: "same note"),
            source: .drag
        )

        guard case .confirmingText(let secondDraft) = state.airDropState else {
            XCTFail("Later duplicate drag should still be addable")
            return
        }
        XCTAssertEqual(secondDraft.textSnippets, ["same note", "same note"])
    }

    func testMixedPayloadSelectsTxtByDefaultAndCountsItWhenSelected() {
        let state = AppState()
        let file = URL(fileURLWithPath: "/tmp/file.txt")

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [file], text: "include this note"),
            source: .drag
        )

        guard case .ready(let draft) = state.airDropState else {
            XCTFail("Mixed payload should become a ready draft")
            return
        }
        XCTAssertTrue(state.airDropIncludeText)
        XCTAssertEqual(draft.displaySummary(includeText: true).title, "2 个项目已准备")
        XCTAssertEqual(draft.displaySummary(includeText: false).title, "1 个项目已准备")
    }

    func testFileFirstAppendTextSelectsTxtByDefault() {
        let state = AppState()
        let file = URL(fileURLWithPath: "/tmp/file.txt")

        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [file]),
            source: .panel
        )
        state.addAirDropPayload(
            AirDropPasteboardPayload(text: "include this note"),
            source: .drag
        )

        guard case .ready(let draft) = state.airDropState else {
            XCTFail("File-first append should become a mixed ready draft")
            return
        }
        XCTAssertEqual(draft.fileURLs, [file])
        XCTAssertEqual(draft.textSnippets, ["include this note"])
        XCTAssertTrue(state.airDropIncludeText)
        XCTAssertEqual(draft.displaySummary(includeText: state.airDropIncludeText).title, "2 个项目已准备")
    }

    func testDragOpenedEmptyDropZoneCancelsAutoReturnAfterPayload() async throws {
        let state = AppState()
        let file = URL(fileURLWithPath: "/tmp/example.txt")
        state.surface = .sessionList
        state.airDropEmptyDragDismissDelay = 0.01

        state.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)
        state.addAirDropPayload(
            AirDropPasteboardPayload(fileURLs: [file]),
            source: .drag
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        guard case .airDrop(let returningTo) = state.surface else {
            XCTFail("AirDrop mode should stay open after payload arrives")
            return
        }
        XCTAssertEqual(returningTo, .sessionList)
        guard case .ready(let draft) = state.airDropState else {
            XCTFail("AirDrop payload should stay ready")
            return
        }
        XCTAssertEqual(draft.fileURLs, [file])
    }

    func testApprovalAndQuestionSurfacesBlockAirDropEntry() {
        let state = AppState()

        state.surface = .approvalCard(sessionId: "s1")
        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )
        XCTAssertEqual(state.surface, .approvalCard(sessionId: "s1"))
        XCTAssertEqual(state.airDropState, .idle)

        state.surface = .questionCard(sessionId: "s1")
        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )
        XCTAssertEqual(state.surface, .questionCard(sessionId: "s1"))
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testSourceWiresPanelEntryOpenPanelAndDedicatedAirDropMode() throws {
        let appState = try Self.sourceFile("Sources/Bough/AppState.swift")
        let appStateAirDrop = try Self.sourceFile("Sources/Bough/AppState+AirDrop.swift")
        let notchPanel = try Self.sourceFile("Sources/Bough/NotchPanelView.swift")
        let panelController = try Self.sourceFile("Sources/Bough/PanelWindowController.swift")
        let airDropPanel = try Self.sourceFile("Sources/Bough/AirDropPanelView.swift")

        XCTAssertTrue(appState.contains("airDropEmptyDragDismissDelay: TimeInterval = 2.0"))
        XCTAssertTrue(appStateAirDrop.contains("let panel = NSOpenPanel()"))
        XCTAssertTrue(appStateAirDrop.contains("panel.canChooseFiles = true"))
        XCTAssertTrue(appStateAirDrop.contains("panel.canChooseDirectories = true"))
        XCTAssertTrue(appStateAirDrop.contains("panel.allowsMultipleSelection = true"))
        XCTAssertTrue(appStateAirDrop.contains("panel.begin { [weak self, panel] response in"))
        XCTAssertTrue(appStateAirDrop.contains("let urls = panel.urls"))
        XCTAssertLessThan(
            try XCTUnwrap(appStateAirDrop.range(of: "let urls = panel.urls")?.lowerBound),
            try XCTUnwrap(appStateAirDrop.range(of: "self.airDropOpenPanel = nil")?.lowerBound)
        )
        XCTAssertTrue(appStateAirDrop.contains("autoDismissIfEmpty: Bool = false"))
        XCTAssertFalse(appStateAirDrop.contains("showsHiddenFiles"))
        XCTAssertFalse(appStateAirDrop.contains("scheduleAirDropReturn"))

        XCTAssertTrue(notchPanel.contains("AirDropPanelView(appState: appState)"))
        XCTAssertTrue(notchPanel.contains("AirDropMusicEntryLayout("))
        XCTAssertTrue(notchPanel.contains("panelWidth < 520"))
        XCTAssertTrue(notchPanel.contains("case .airDrop: return"))
        XCTAssertTrue(panelController.contains("case .approvalCard, .questionCard, .airDrop: return"))
        XCTAssertTrue(notchPanel.contains("AirDropEntryButton(layout: .square)"))
        XCTAssertTrue(notchPanel.contains("AirDropEntryButton(layout: .row)"))

        XCTAssertTrue(airDropPanel.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(airDropPanel.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(airDropPanel.contains("checkmark.square.fill"))
        XCTAssertTrue(airDropPanel.contains("@ObservedObject private var l10n = L10n.shared"))
        XCTAssertTrue(airDropPanel.contains("l10n[\"airdrop_include_text_title\"]"))
        XCTAssertTrue(airDropPanel.contains("l10n[\"airdrop_include_text_on_desc\"]"))
        XCTAssertTrue(airDropPanel.contains("l10n[\"airdrop_ready_for_more\"]"))
        XCTAssertTrue(airDropPanel.contains("l10n[\"airdrop_temp_text_cleaned\"]"))
        XCTAssertTrue(airDropPanel.contains("l10n[\"airdrop_drop_zone_another_subtitle\"]"))
        XCTAssertTrue(airDropPanel.contains(".accessibilityLabel(l10n[\"airdrop_drop_zone_accessibility\"])"))
        XCTAssertTrue(airDropPanel.contains("localizedFlowMessage"))
        XCTAssertTrue(airDropPanel.contains("localizedSummary"))
    }

    func testAirDropEntryUsesRoundedSurfaceConsistentWithExpandedStrips() throws {
        let airDropPanel = try Self.sourceFile("Sources/Bough/AirDropPanelView.swift")

        XCTAssertTrue(airDropPanel.contains("static let surfaceCornerRadius: CGFloat = 6"))
        XCTAssertGreaterThanOrEqual(
            airDropPanel.components(separatedBy: ".background(entrySurfaceShape.fill(entryFill))").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            airDropPanel.components(separatedBy: ".clipShape(entrySurfaceShape)").count - 1,
            2
        )
        XCTAssertTrue(airDropPanel.contains("entrySurfaceShape.strokeBorder"))
        XCTAssertFalse(airDropPanel.contains(".frame(maxWidth: .infinity, minHeight: 54)\n        .background(entryFill)"))
        XCTAssertFalse(airDropPanel.contains("cornerRadius: layout == .row ? 10 : 10"))
        XCTAssertFalse(airDropPanel.contains(".clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))"))
    }

    private static func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
