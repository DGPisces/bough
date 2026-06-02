import AppKit
import SwiftUI

@MainActor
extension AppState {
    var canEnterAirDrop: Bool {
        guard airDropEnabledProvider() else { return false }
        guard pendingPermission == nil, pendingQuestion == nil else { return false }
        switch surface {
        case .approvalCard, .questionCard:
            return false
        default:
            return true
        }
    }

    func beginAirDropPanelSelection() {
        enterAirDropMode()
    }

    func enterAirDropMode() {
        guard canEnterAirDrop else { return }
        configureAirDropFlowIfNeeded()
        let returnSurface = airDropReturnTarget(from: surface)
        clearAirDropPreviewScenario()
        cancelAirDropEmptyDragDismiss()
        airDropReturnSurface = returnSurface
        airDropIncludeText = false
        airDropReturnTask?.cancel()
        airDropFlowController.reset()
        withAnimation(NotchAnimation.open) {
            surface = .airDrop(returningTo: returnSurface)
        }
    }

    func openAirDropItemPicker() {
        guard isShowingAirDrop || canEnterAirDrop else { return }
        if !isShowingAirDrop {
            enterAirDropMode()
        }
        guard isShowingAirDrop else { return }
        cancelAirDropEmptyDragDismiss()

        if let panel = airDropOpenPanel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = "选择要 AirDrop 的项目"
        panel.prompt = "选择"
        airDropOpenPanel = panel
        panel.begin { [weak self, panel] response in
            Task { @MainActor in
                guard let self else { return }
                let urls = panel.urls
                self.airDropOpenPanel = nil
                guard case .airDrop = self.surface else { return }
                guard response == .OK, !urls.isEmpty else {
                    return
                }
                self.addAirDropPayload(
                    AirDropPasteboardPayload(fileURLs: urls),
                    source: .panel
                )
            }
        }
    }

    func beginAirDrop(payload: AirDropPasteboardPayload, source: AirDropEntrySource) {
        guard canEnterAirDrop else { return }
        configureAirDropFlowIfNeeded()
        let returnSurface = airDropReturnTarget(from: surface)
        clearAirDropPreviewScenario()
        cancelAirDropEmptyDragDismiss()
        airDropReturnSurface = returnSurface
        airDropIncludeText = false
        airDropReturnTask?.cancel()
        airDropDropZoneHighlighted = false
        withAnimation(NotchAnimation.open) {
            surface = .airDrop(returningTo: returnSurface)
        }
        prepareAirDropPayload(payload, source: source)
    }

    func showAirDropDropZone(highlighted: Bool = false, autoDismissIfEmpty: Bool = false) {
        guard canEnterAirDrop || isShowingAirDrop else { return }
        configureAirDropFlowIfNeeded()
        clearAirDropPreviewScenario()
        let openedByThisCall = !isShowingAirDrop
        if openedByThisCall {
            let returnSurface = airDropReturnTarget(from: surface)
            airDropReturnSurface = returnSurface
            withAnimation(NotchAnimation.open) {
                surface = .airDrop(returningTo: returnSurface)
            }
        }
        airDropReturnTask?.cancel()
        if !airDropHasDraft {
            airDropIncludeText = false
        }
        airDropMagnetPreheating = false
        airDropDropZoneHighlighted = highlighted
        if case .idle = airDropState {
            airDropFlowController.reset()
        }
        if autoDismissIfEmpty, openedByThisCall, airDropState == .idle {
            scheduleAirDropEmptyDragDismiss()
        }
    }

    func prepareAirDropPayload(_ payload: AirDropPasteboardPayload, source: AirDropEntrySource) {
        guard canEnterAirDrop || isShowingAirDrop else { return }
        guard !shouldSuppressDuplicateAirDropDragPayload(payload, source: source) else { return }
        configureAirDropFlowIfNeeded()
        cancelAirDropEmptyDragDismiss()
        airDropIncludeText = false
        airDropDropZoneHighlighted = false
        let nextState = airDropFlowController.prepare(payload: payload, source: source)
        airDropState = nextState
        defaultAirDropTextSelectionIfNeeded(nextState)
    }

    func addAirDropPayload(_ payload: AirDropPasteboardPayload, source: AirDropEntrySource) {
        guard canEnterAirDrop || isShowingAirDrop else { return }
        guard !shouldSuppressDuplicateAirDropDragPayload(payload, source: source) else { return }
        configureAirDropFlowIfNeeded()
        cancelAirDropEmptyDragDismiss()
        let textSelectionAfterAppend = airDropTextSelectionAfterAppend
        if !isShowingAirDrop {
            let returnSurface = airDropReturnTarget(from: surface)
            clearAirDropPreviewScenario()
            airDropReturnSurface = returnSurface
            airDropReturnTask?.cancel()
            withAnimation(NotchAnimation.open) {
                surface = .airDrop(returningTo: returnSurface)
            }
        }
        airDropDropZoneHighlighted = false
        let nextState = airDropFlowController.append(payload: payload, source: source)
        airDropState = nextState
        updateAirDropTextSelectionAfterAppend(nextState, textSelectionAfterAppend: textSelectionAfterAppend)
    }

    func submitAirDrop() {
        guard isShowingAirDrop else { return }
        cancelAirDropEmptyDragDismiss()
        airDropFlowController.submit(includeText: airDropSubmitIncludesText)
    }

    func cancelAirDrop() {
        guard isShowingAirDrop else { return }
        cancelAirDropEmptyDragDismiss()
        airDropExplicitDismissInFlight = true
        closeAirDropOpenPanel()
        airDropReturnTask?.cancel()
        airDropFlowController.cancel()
    }

    func chooseMoreAirDropItems() {
        guard isShowingAirDrop else { return }
        openAirDropItemPicker()
    }

    func setAirDropDragPreheating(_ isPreheating: Bool) {
        guard isPreheating != airDropMagnetPreheating else { return }
        airDropMagnetPreheating = isPreheating
        if !isPreheating {
            airDropDropZoneHighlighted = false
        }
    }

    func clearAirDropDragIndicators() {
        airDropMagnetPreheating = false
        airDropDropZoneHighlighted = false
    }

    func dismissAirDropDragMagnetIfEmpty() {
        clearAirDropDragIndicators()
    }

    private var isShowingAirDrop: Bool {
        if case .airDrop = surface { return true }
        return false
    }

    private var airDropHasDraft: Bool {
        switch airDropState {
        case .ready, .confirmingText:
            return true
        default:
            return false
        }
    }

    private var airDropSubmitIncludesText: Bool {
        switch airDropState {
        case .confirmingText:
            return true
        case .ready(let draft):
            return draft.mode == .readyWithOptionalText ? airDropIncludeText : false
        default:
            return airDropIncludeText
        }
    }

    private var airDropTextSelectionAfterAppend: Bool {
        switch airDropState {
        case .ready(let draft):
            return draft.mode == .readyWithOptionalText ? airDropIncludeText : true
        default:
            return true
        }
    }

    private func defaultAirDropTextSelectionIfNeeded(_ state: AirDropFlowState) {
        guard case .ready(let draft) = state, draft.mode == .readyWithOptionalText else { return }
        airDropIncludeText = true
    }

    private func updateAirDropTextSelectionAfterAppend(
        _ state: AirDropFlowState,
        textSelectionAfterAppend: Bool
    ) {
        guard case .ready(let draft) = state, draft.mode == .readyWithOptionalText else {
            airDropIncludeText = false
            return
        }
        airDropIncludeText = textSelectionAfterAppend
    }

    private func configureAirDropFlowIfNeeded() {
        guard !airDropFlowConfigured else { return }
        airDropFlowController.onStateChange = { [weak self] state in
            guard let self else { return }
            self.handleAirDropStateChange(state)
        }
        airDropFlowConfigured = true
        airDropState = airDropFlowController.state
    }

    private func handleAirDropStateChange(_ state: AirDropFlowState) {
        airDropState = state
        switch state {
        case .complete(_):
            cancelAirDropEmptyDragDismiss()
            airDropIncludeText = false
            clearAirDropDragIndicators()
        case .cancelled:
            cancelAirDropEmptyDragDismiss()
            closeAirDropOpenPanel()
            if airDropExplicitDismissInFlight {
                airDropExplicitDismissInFlight = false
                returnFromAirDrop(resetFlow: true)
            } else {
                airDropIncludeText = false
                clearAirDropDragIndicators()
                airDropFlowController.reset()
            }
        case .cleanupError:
            airDropExplicitDismissInFlight = false
        default:
            break
        }
    }

    private func returnFromAirDrop(resetFlow: Bool) {
        airDropReturnTask?.cancel()
        cancelAirDropEmptyDragDismiss()
        guard isShowingAirDrop else {
            if resetFlow {
                airDropFlowController.reset()
            }
            return
        }
        let target = airDropReturnSurface.surface
        withAnimation(target.isExpanded ? NotchAnimation.open : NotchAnimation.close) {
            surface = target
        }
        airDropIncludeText = false
        clearAirDropDragIndicators()
        if resetFlow {
            airDropFlowController.reset()
        }
    }

    func clearAirDropPreviewScenario() {
        airDropPreviewOverlayPhase = nil
        airDropPreviewScenarioName = nil
    }

    private func scheduleAirDropEmptyDragDismiss() {
        cancelAirDropEmptyDragDismiss()
        let delay = airDropEmptyDragDismissDelay
        airDropEmptyDragDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.isShowingAirDrop, self.airDropState == .idle else { return }
            self.returnFromAirDrop(resetFlow: true)
        }
    }

    private func cancelAirDropEmptyDragDismiss() {
        airDropEmptyDragDismissTask?.cancel()
        airDropEmptyDragDismissTask = nil
    }

    private func closeAirDropOpenPanel() {
        airDropOpenPanel?.close()
        airDropOpenPanel = nil
    }

    private func shouldSuppressDuplicateAirDropDragPayload(
        _ payload: AirDropPasteboardPayload,
        source: AirDropEntrySource
    ) -> Bool {
        guard source == .drag else { return false }
        let now = airDropDateProvider()
        let signature = payload.duplicateSuppressionSignature
        defer {
            airDropLastDragPayloadSignature = signature
            airDropLastDragPayloadAcceptedAt = now
        }

        guard let previousSignature = airDropLastDragPayloadSignature,
              let previousAcceptedAt = airDropLastDragPayloadAcceptedAt,
              previousSignature == signature,
              now.timeIntervalSince(previousAcceptedAt) <= airDropDuplicateDragSuppressionInterval else {
            return false
        }
        return true
    }

    private func airDropReturnTarget(from surface: IslandSurface) -> AirDropReturnSurface {
        switch surface {
        case .airDrop(let returningTo):
            return returningTo
        case .completionCard(let sessionId):
            return .completionCard(sessionId: sessionId)
        case .sessionList:
            return .sessionList
        default:
            return .collapsed
        }
    }
}

private extension AirDropPasteboardPayload {
    var duplicateSuppressionSignature: String {
        let filePart = fileURLs
            .map { $0.isFileURL ? $0.standardizedFileURL.absoluteString : $0.absoluteString }
            .joined(separator: "\u{1F}")
        let remotePart = remoteURLs
            .map(\.absoluteString)
            .joined(separator: "\u{1F}")
        let textPart = textSnippets.joined(separator: "\u{1F}")
        return [filePart, remotePart, textPart].joined(separator: "\u{1E}")
    }
}
