import AppKit
import SwiftUI

enum AirDropDragOverlayPhase: Equatable {
    case preheat
    case dropZone
}

enum AirDropDragOverlayMetrics {
    static let horizontalTriggerInset: CGFloat = 120
    static let verticalTriggerInset: CGFloat = 96
    static let preheatDelay: TimeInterval = 0.18
    static let leaveTolerance: TimeInterval = 0.25
    static let expandedPanelHeight: CGFloat = 180
    static let topChromeExclusionHeight: CGFloat = 132
}

struct AirDropDragMagnetGeometry: Equatable {
    let visiblePanelFrame: NSRect
    let triggerFrame: NSRect
    let dropZoneFrame: NSRect

    static func make(
        panelFrame: NSRect,
        screenFrame: NSRect,
        surface: IslandSurface,
        notchHeight: CGFloat
    ) -> AirDropDragMagnetGeometry {
        let visibleHeight = surface.isExpanded
            ? min(panelFrame.height, AirDropDragOverlayMetrics.expandedPanelHeight)
            : max(24, notchHeight)
        let visiblePanel = NSRect(
            x: panelFrame.minX,
            y: panelFrame.maxY - visibleHeight,
            width: panelFrame.width,
            height: visibleHeight
        ).intersection(screenFrame)

        let trigger = NSRect(
            x: visiblePanel.minX - AirDropDragOverlayMetrics.horizontalTriggerInset,
            y: visiblePanel.minY - AirDropDragOverlayMetrics.verticalTriggerInset,
            width: visiblePanel.width + AirDropDragOverlayMetrics.horizontalTriggerInset * 2,
            height: visiblePanel.height + AirDropDragOverlayMetrics.verticalTriggerInset
        ).intersection(screenFrame)

        let dropZone = NSRect(
            x: visiblePanel.minX,
            y: visiblePanel.minY - AirDropDragOverlayMetrics.verticalTriggerInset,
            width: visiblePanel.width,
            height: AirDropDragOverlayMetrics.verticalTriggerInset
        ).intersection(screenFrame)

        return AirDropDragMagnetGeometry(
            visiblePanelFrame: visiblePanel,
            triggerFrame: trigger,
            dropZoneFrame: dropZone
        )
    }
}

struct AirDropDragTriggerPolicy {
    func canTrigger(payload: AirDropPasteboardPayload, dragStartPoint _: NSPoint, screenFrame _: NSRect) -> Bool {
        if payload.fileURLs.contains(where: \.isFileURL) {
            return true
        }

        guard payload.remoteURLs.isEmpty else {
            return false
        }

        return payload.textSnippets.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct AirDropDragPasteboardSessionGate {
    private var baselineChangeCount: Int?
    private var activeChangeCount: Int?

    mutating func start(baselineChangeCount: Int) {
        self.baselineChangeCount = baselineChangeCount
        activeChangeCount = nil
    }

    mutating func acceptsSnapshot(changeCount: Int) -> Bool {
        if let activeChangeCount {
            return changeCount == activeChangeCount
        }

        guard changeCount != baselineChangeCount else {
            return false
        }

        activeChangeCount = changeCount
        return true
    }

    mutating func resetSession() {
        if let activeChangeCount {
            baselineChangeCount = activeChangeCount
        }
        activeChangeCount = nil
    }

    mutating func stop() {
        baselineChangeCount = nil
        activeChangeCount = nil
    }
}

private struct AirDropDragContext {
    let geometry: AirDropDragMagnetGeometry
    let screenFrame: NSRect
}

@MainActor
final class AirDropDragOverlayController {
    private let appState: AppState
    private let panelFrameProvider: () -> NSRect?
    private let screenProvider: () -> NSScreen?
    private let notchHeightProvider: () -> CGFloat
    private let panelVisibilityProvider: () -> Bool
    private let pasteboardReader = AirDropPasteboardReader()
    private let classifier = AirDropItemClassifier()
    private let triggerPolicy = AirDropDragTriggerPolicy()
    private var pasteboardSessionGate = AirDropDragPasteboardSessionGate()

    private var globalDragMonitor: Any?
    private var phase: AirDropDragOverlayPhase = .preheat
    private var preheatTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var dragStartPoint: NSPoint?

    init(
        appState: AppState,
        panelFrameProvider: @escaping () -> NSRect?,
        screenProvider: @escaping () -> NSScreen?,
        notchHeightProvider: @escaping () -> CGFloat,
        panelVisibilityProvider: @escaping () -> Bool
    ) {
        self.appState = appState
        self.panelFrameProvider = panelFrameProvider
        self.screenProvider = screenProvider
        self.notchHeightProvider = notchHeightProvider
        self.panelVisibilityProvider = panelVisibilityProvider
    }

    func start() {
        guard globalDragMonitor == nil else { return }
        pasteboardSessionGate.start(baselineChangeCount: currentDragPasteboardChangeCount())
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.type {
                case .leftMouseDragged:
                    self.handleDrag(at: NSEvent.mouseLocation)
                case .leftMouseUp:
                    let shouldAcceptDrop = self.shouldAcceptDrop(at: NSEvent.mouseLocation)
                    if shouldAcceptDrop {
                        self.addCurrentDragPayloadIfSupported()
                    }
                    self.hideOverlay()
                    self.resetDragSession()
                    if shouldAcceptDrop {
                        self.leaveTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64(AirDropDragOverlayMetrics.leaveTolerance * 1_000_000_000))
                            guard let self, !Task.isCancelled else { return }
                            self.appState.dismissAirDropDragMagnetIfEmpty()
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    func stop() {
        preheatTask?.cancel()
        preheatTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        resetDragSession()
        pasteboardSessionGate.stop()
        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
        }
        globalDragMonitor = nil
    }

    private func handleDrag(at point: NSPoint) {
        let snapshot = currentDragPasteboardSnapshot()
        let dragStartPoint = dragStartPoint(for: point)
        guard pasteboardSessionGate.acceptsSnapshot(changeCount: snapshot.changeCount),
              let context = currentDragContext(for: point),
              appState.canEnterAirDrop,
              currentDragPasteboardCanTrigger(
                payload: snapshot.payload,
                dragStartPoint: dragStartPoint,
                screenFrame: context.screenFrame
              ) else {
            hideOverlay()
            return
        }
        let geometry = context.geometry

        let insideTrigger = geometry.triggerFrame.contains(point)
        let insideDropZone = geometry.dropZoneFrame.contains(point)
        guard insideTrigger || insideDropZone else {
            handleDragLeftMagnet()
            return
        }

        leaveTask?.cancel()
        leaveTask = nil

        if phase == .dropZone {
            appState.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)
            return
        }

        scheduleAirDropPreheat()
    }

    private func scheduleAirDropPreheat() {
        appState.setAirDropDragPreheating(true)
        guard preheatTask == nil else { return }
        preheatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AirDropDragOverlayMetrics.preheatDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.preheatTask = nil
            let mouseLocation = NSEvent.mouseLocation
            guard let latest = self.currentGeometry(for: mouseLocation),
                  latest.triggerFrame.contains(mouseLocation) else {
                self.hideOverlay()
                return
            }
            self.phase = .dropZone
            self.appState.showAirDropDropZone(highlighted: true, autoDismissIfEmpty: true)
        }
    }

    private func handleDragLeftMagnet() {
        preheatTask?.cancel()
        preheatTask = nil
        if phase == .preheat {
            hideOverlay()
            return
        }
        leaveTask?.cancel()
        leaveTask = nil
        leaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AirDropDragOverlayMetrics.leaveTolerance * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hideOverlay()
            self.appState.dismissAirDropDragMagnetIfEmpty()
        }
    }

    private func shouldAcceptDrop(at point: NSPoint) -> Bool {
        guard phase == .dropZone,
              let geometry = currentGeometry(for: point) else {
            return false
        }
        return geometry.dropZoneFrame.contains(point)
    }

    private func currentDragPasteboardCanTrigger(
        payload: AirDropPasteboardPayload,
        dragStartPoint: NSPoint,
        screenFrame: NSRect
    ) -> Bool {
        guard triggerPolicy.canTrigger(payload: payload, dragStartPoint: dragStartPoint, screenFrame: screenFrame) else {
            return false
        }

        switch classifier.classify(payload, source: .drag) {
        case .supported:
            return true
        case .unsupported:
            return false
        }
    }

    @discardableResult
    private func addCurrentDragPayloadIfSupported() -> Bool {
        let snapshot = currentDragPasteboardSnapshot()
        guard pasteboardSessionGate.acceptsSnapshot(changeCount: snapshot.changeCount) else {
            return false
        }
        let payload = snapshot.payload
        switch classifier.classify(payload, source: .drag) {
        case .supported:
            appState.addAirDropPayload(payload, source: .drag)
            return true
        case .unsupported:
            return false
        }
    }

    private func currentDragPasteboardChangeCount() -> Int {
        NSPasteboard(name: .drag).changeCount
    }

    private func currentDragPasteboardSnapshot() -> AirDropPasteboardSnapshot {
        pasteboardReader.snapshot(from: NSPasteboard(name: .drag))
    }

    private func hideOverlay() {
        preheatTask?.cancel()
        preheatTask = nil
        leaveTask?.cancel()
        leaveTask = nil
        phase = .preheat
        appState.clearAirDropDragIndicators()
    }

    private func dragStartPoint(for point: NSPoint) -> NSPoint {
        if let dragStartPoint {
            return dragStartPoint
        }
        dragStartPoint = point
        return point
    }

    private func resetDragSession() {
        dragStartPoint = nil
        pasteboardSessionGate.resetSession()
    }

    private func currentGeometry(for point: NSPoint) -> AirDropDragMagnetGeometry? {
        currentDragContext(for: point)?.geometry
    }

    private func currentDragContext(for point: NSPoint) -> AirDropDragContext? {
        guard panelVisibilityProvider(),
              let panelFrame = panelFrameProvider(),
              let screen = screenProvider(),
              screen.frame.contains(point) else {
            return nil
        }
        let geometry = AirDropDragMagnetGeometry.make(
            panelFrame: panelFrame,
            screenFrame: screen.frame,
            surface: appState.surface,
            notchHeight: notchHeightProvider()
        )
        return AirDropDragContext(geometry: geometry, screenFrame: screen.frame)
    }
}
