import AppKit
import XCTest
@testable import Bough

final class AirDropDragOverlayTests: XCTestCase {
    func testMagnetGeometryUsesCurrentPanelScreenAndRequiredInsets() {
        let panelFrame = NSRect(x: 200, y: 500, width: 580, height: 400)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let geometry = AirDropDragMagnetGeometry.make(
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            surface: .collapsed,
            notchHeight: 36
        )

        XCTAssertEqual(geometry.visiblePanelFrame, NSRect(x: 200, y: 864, width: 580, height: 36))
        XCTAssertEqual(geometry.triggerFrame, NSRect(x: 80, y: 768, width: 820, height: 132))
        XCTAssertEqual(geometry.dropZoneFrame, NSRect(x: 200, y: 768, width: 580, height: 96))
        XCTAssertEqual(AirDropDragOverlayMetrics.horizontalTriggerInset, 120)
        XCTAssertEqual(AirDropDragOverlayMetrics.verticalTriggerInset, 96)
    }

    func testMagnetGeometryUsesExpandedPanelHeightForExpandedSurfaces() {
        let panelFrame = NSRect(x: 200, y: 500, width: 580, height: 400)
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let geometry = AirDropDragMagnetGeometry.make(
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            surface: .sessionList,
            notchHeight: 36
        )

        XCTAssertEqual(geometry.visiblePanelFrame.height, AirDropDragOverlayMetrics.expandedPanelHeight)
        XCTAssertEqual(geometry.visiblePanelFrame.minY, 720)
        XCTAssertEqual(geometry.triggerFrame.minY, 624)
        XCTAssertEqual(geometry.dropZoneFrame.minY, 624)
    }

    func testTriggerPolicyAllowsFileAndFolderDragsFromTopChrome() {
        let policy = AirDropDragTriggerPolicy()
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topChromePoint = NSPoint(x: 620, y: 860)

        XCTAssertTrue(policy.canTrigger(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]),
            dragStartPoint: topChromePoint,
            screenFrame: screenFrame
        ))
        XCTAssertTrue(policy.canTrigger(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)]),
            dragStartPoint: topChromePoint,
            screenFrame: screenFrame
        ))
    }

    func testTriggerPolicyBlocksURLDragsButAllowsPureText() throws {
        let policy = AirDropDragTriggerPolicy()
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topChromePoint = NSPoint(x: 620, y: 800)
        let contentPoint = NSPoint(x: 620, y: 760)

        XCTAssertFalse(policy.canTrigger(
            payload: AirDropPasteboardPayload(remoteURLs: [try XCTUnwrap(URL(string: "https://example.com"))]),
            dragStartPoint: topChromePoint,
            screenFrame: screenFrame
        ))
        XCTAssertTrue(policy.canTrigger(
            payload: AirDropPasteboardPayload(text: "selected text"),
            dragStartPoint: topChromePoint,
            screenFrame: screenFrame
        ))
        XCTAssertFalse(policy.canTrigger(
            payload: AirDropPasteboardPayload(remoteURLs: [try XCTUnwrap(URL(string: "https://example.com"))]),
            dragStartPoint: contentPoint,
            screenFrame: screenFrame
        ))
        XCTAssertTrue(policy.canTrigger(
            payload: AirDropPasteboardPayload(text: "selected text"),
            dragStartPoint: contentPoint,
            screenFrame: screenFrame
        ))
        XCTAssertFalse(policy.canTrigger(
            payload: AirDropPasteboardPayload(
                remoteURLs: [try XCTUnwrap(URL(string: "https://example.com"))],
                text: "Example page"
            ),
            dragStartPoint: contentPoint,
            screenFrame: screenFrame
        ))
    }

    func testPasteboardSessionGateRequiresFreshDragPasteboard() {
        var gate = AirDropDragPasteboardSessionGate()

        gate.start(baselineChangeCount: 10)

        XCTAssertFalse(gate.acceptsSnapshot(changeCount: 10))
        XCTAssertTrue(gate.acceptsSnapshot(changeCount: 11))
        XCTAssertTrue(gate.acceptsSnapshot(changeCount: 11))
        XCTAssertFalse(gate.acceptsSnapshot(changeCount: 12))

        gate.resetSession()

        XCTAssertFalse(gate.acceptsSnapshot(changeCount: 11))
        XCTAssertTrue(gate.acceptsSnapshot(changeCount: 12))
    }

    func testSourceWiresBoughPreheatAndGlobalDragMonitorWithoutStandaloneOverlay() throws {
        let overlay = try sourceFile("Sources/Bough/AirDropDragOverlay.swift")
        let controller = try sourceFile("Sources/Bough/PanelWindowController.swift")
        let appStateAirDrop = try sourceFile("Sources/Bough/AppState+AirDrop.swift")
        let notchPanel = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertTrue(overlay.contains("static let horizontalTriggerInset: CGFloat = 120"))
        XCTAssertTrue(overlay.contains("static let verticalTriggerInset: CGFloat = 96"))
        XCTAssertTrue(overlay.contains("static let preheatDelay: TimeInterval = 0.18"))
        XCTAssertTrue(overlay.contains("static let leaveTolerance: TimeInterval = 0.25"))
        XCTAssertTrue(overlay.contains("static let topChromeExclusionHeight: CGFloat = 132"))
        XCTAssertTrue(overlay.contains("NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp])"))
        XCTAssertTrue(overlay.contains("AirDropDragPasteboardSessionGate"))
        XCTAssertTrue(overlay.contains("pasteboardSessionGate.start(baselineChangeCount: currentDragPasteboardChangeCount())"))
        XCTAssertTrue(overlay.contains("pasteboardSessionGate.acceptsSnapshot(changeCount: snapshot.changeCount)"))
        XCTAssertTrue(overlay.contains("currentDragPasteboardCanTrigger(\n                payload: snapshot.payload"))
        XCTAssertTrue(overlay.contains("dragStartPoint(for: point)"))
        XCTAssertTrue(overlay.contains("resetDragSession()"))
        XCTAssertTrue(overlay.contains("addCurrentDragPayloadIfSupported()"))
        XCTAssertTrue(overlay.contains("scheduleAirDropPreheat()"))
        XCTAssertTrue(overlay.contains("guard preheatTask == nil else { return }"))
        XCTAssertTrue(overlay.contains("let shouldAcceptDrop = self.shouldAcceptDrop(at: NSEvent.mouseLocation)"))
        XCTAssertTrue(overlay.contains("private func shouldAcceptDrop(at point: NSPoint) -> Bool"))
        XCTAssertTrue(overlay.contains("return geometry.dropZoneFrame.contains(point)"))
        XCTAssertTrue(overlay.contains("appState.addAirDropPayload(payload, source: .drag)"))
        XCTAssertTrue(overlay.contains("NSPasteboard(name: .drag)"))
        XCTAssertTrue(overlay.contains("appState.setAirDropDragPreheating(true)"))
        XCTAssertTrue(overlay.contains("appState.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)"))
        XCTAssertTrue(overlay.contains("appState.dismissAirDropDragMagnetIfEmpty()"))
        XCTAssertFalse(overlay.contains("styleMask: [.borderless, .nonactivatingPanel]"))
        XCTAssertFalse(overlay.contains("AirDropDragOverlayView"))
        XCTAssertFalse(overlay.contains("registerForDraggedTypes([.fileURL, .URL, .string])"))
        XCTAssertFalse(overlay.contains("appState.submitAirDrop()"))

        XCTAssertTrue(controller.contains("configureAirDropDragOverlay()"))
        XCTAssertTrue(controller.contains("panelFrameProvider"))
        XCTAssertTrue(controller.contains("panelVisibilityProvider"))
        XCTAssertTrue(controller.contains("airDropDragOverlayController?.start()"))
        XCTAssertTrue(controller.contains("airDropDragOverlayController.stop()"))

        XCTAssertTrue(appStateAirDrop.contains("func showAirDropDropZone(highlighted: Bool = false, autoDismissIfEmpty: Bool = false)"))
        XCTAssertTrue(appStateAirDrop.contains("scheduleAirDropEmptyDragDismiss()"))
        XCTAssertTrue(appStateAirDrop.contains("guard self.isShowingAirDrop, self.airDropState == .idle else { return }"))
        XCTAssertTrue(notchPanel.contains(".shadow("))
        XCTAssertTrue(notchPanel.contains("appState.airDropMagnetPreheating ? .white.opacity(0.18) : .clear"))
        XCTAssertFalse(notchPanel.contains("? Color(red: 0.46, green: 0.72, blue: 1.0).opacity(0.58)"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
