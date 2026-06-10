import SwiftUI
import UniformTypeIdentifiers

enum AirDropEntryButtonLayout {
    case row
    case square
}

private enum AirDropEntryVisuals {
    static let surfaceCornerRadius: CGFloat = 6
}

@MainActor
struct AirDropEntryButton: View {
    let layout: AirDropEntryButtonLayout
    let action: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            switch layout {
            case .row:
                rowContent
            case .square:
                squareContent
            }
        }
        .buttonStyle(.plain)
        .help("AirDrop")
        .accessibilityLabel("AirDrop")
        .onHover { h in
            withAnimation(reduceMotion ? nil : NotchAnimation.micro) {
                hovering = h
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 34, height: 34)
                .background(entryFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AirDrop")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                Text(l10n["airdrop_entry_subtitle"])
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.82 : 0.42))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(entrySurfaceShape.fill(entryFill))
        .overlay(entryStroke)
        .clipShape(entrySurfaceShape)
        .padding(.horizontal, 6)
    }

    private var squareContent: some View {
        VStack(spacing: 6) {
            icon
                .font(.system(size: 18, weight: .semibold))
            Text("AirDrop")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 72, height: 72)
        .background(entrySurfaceShape.fill(entryFill))
        .overlay(entryStroke)
        .clipShape(entrySurfaceShape)
    }

    private var icon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: layout == .row ? 15 : 18, weight: .semibold))
            .foregroundStyle(Color(red: 0.46, green: 0.72, blue: 1.0))
            .symbolRenderingMode(.hierarchical)
    }

    private var entryFill: some ShapeStyle {
        Color.white.opacity(hovering ? 0.10 : 0.05)
    }

    private var entrySurfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AirDropEntryVisuals.surfaceCornerRadius, style: .continuous)
    }

    private var entryStroke: some View {
        entrySurfaceShape.strokeBorder(.white.opacity(hovering ? 0.16 : 0.0), lineWidth: 1)
    }
}

@MainActor
struct AirDropPanelView: View {
    var appState: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @AppStorage(SettingsKey.airDropDemoScenariosEnabled) private var airDropDemoScenariosEnabled = SettingsDefaults.airDropDemoScenariosEnabled
    #endif

    var body: some View {
        VStack(spacing: 10) {
            header
            #if DEBUG
            if airDropDemoScenariosEnabled || appState.airDropPreviewScenarioName != nil {
                AirDropDemoControlPanel(appState: appState)
            }
            #endif
            stateContent
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AirDrop")
        .animation(reduceMotion ? nil : NotchAnimation.micro, value: appState.airDropState)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.46, green: 0.72, blue: 1.0))
                .frame(width: 28, height: 28)
                .background(Color(red: 0.46, green: 0.72, blue: 1.0).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AirDrop")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.94))
                Text(statusText)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if case .idle = appState.airDropState {
                Button {
                    appState.cancelAirDrop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(l10n["airdrop_cancel_accessibility"])
                .accessibilityLabel(l10n["airdrop_cancel_accessibility"])
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch appState.airDropState {
        case .idle:
            idleDropZone
        case .ready(let draft):
            VStack(spacing: 8) {
                draftView(draft, asksForTextConfirmation: false)
                appendDropZone
            }
        case .confirmingText(let draft):
            VStack(spacing: 8) {
                draftView(draft, asksForTextConfirmation: true)
                appendDropZone
            }
        case .opening(let transfer):
            openingView(transfer)
        case .complete(let completion):
            VStack(spacing: 8) {
                statusView(
                    icon: "checkmark.circle.fill",
                    title: l10n["airdrop_complete_title"],
                    detail: completion.cleanedTemporaryTextFile ? l10n["airdrop_temp_text_cleaned"] : l10n["airdrop_ready_for_more"],
                    tint: Color(red: 0.38, green: 0.9, blue: 0.48)
                )
                completeDropZone
            }
        case .unavailable(let message):
            statusView(icon: "wifi.slash", title: l10n["airdrop_unavailable_title"], detail: localizedFlowMessage(message), tint: Color(red: 1.0, green: 0.72, blue: 0.28))
        case .failed(let message):
            statusView(icon: "exclamationmark.triangle.fill", title: l10n["airdrop_incomplete_title"], detail: localizedFlowMessage(message), tint: Color(red: 1.0, green: 0.52, blue: 0.42))
        case .cleanupError(let message):
            statusView(icon: "xmark.octagon.fill", title: l10n["airdrop_cleanup_failed_title"], detail: localizedFlowMessage(message), tint: Color(red: 1.0, green: 0.36, blue: 0.36))
        case .cancelled:
            EmptyView()
        }
    }

    private var idleDropZone: some View {
        AirDropDropZoneButton(
            title: l10n["airdrop_drop_zone_title"],
            subtitle: nil,
            highlighted: appState.airDropDropZoneHighlighted,
            action: { appState.openAirDropItemPicker() },
            onDrop: { payload in appState.addAirDropPayload(payload, source: .drag) }
        )
    }

    private var appendDropZone: some View {
        AirDropDropZoneButton(
            title: l10n["airdrop_drop_zone_title"],
            subtitle: l10n["airdrop_drop_zone_append_subtitle"],
            highlighted: appState.airDropDropZoneHighlighted,
            action: { appState.openAirDropItemPicker() },
            onDrop: { payload in appState.addAirDropPayload(payload, source: .drag) }
        )
        .frame(minHeight: 62)
    }

    private var completeDropZone: some View {
        AirDropDropZoneButton(
            title: l10n["airdrop_drop_zone_title"],
            subtitle: l10n["airdrop_drop_zone_another_subtitle"],
            highlighted: appState.airDropDropZoneHighlighted,
            action: { appState.openAirDropItemPicker() },
            onDrop: { payload in appState.addAirDropPayload(payload, source: .drag) }
        )
        .frame(minHeight: 62)
    }

    private func draftView(_ draft: AirDropDraft, asksForTextConfirmation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: draftIcon(for: draft))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.46, green: 0.72, blue: 1.0))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedSummary(for: draft).title)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if let detail = localizedSummary(for: draft).detail {
                        Text(detail)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if !draft.textPreviews.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(draft.textPreviews.prefix(2).enumerated()), id: \.offset) { index, preview in
                        Text(String(format: l10n["airdrop_text_preview"], index + 1, preview.text))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    if draft.textPreviews.count > 2 {
                        Text(String(format: l10n["airdrop_text_more"], draft.textPreviews.count - 2))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                }
                .accessibilityLabel(l10n["airdrop_text_preview_accessibility"])
            }

            if asksForTextConfirmation {
                Text(l10n["airdrop_confirm_text_question"])
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityLabel(l10n["airdrop_confirm_text_accessibility"])
            } else if draft.mode == .readyWithOptionalText {
                includeTextOption(for: draft)
            }

            addMoreButton
        }
        .padding(10)
        .background(Color.white.opacity(0.045))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func includeTextOption(for draft: AirDropDraft) -> some View {
        Button {
            appState.airDropIncludeText.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: appState.airDropIncludeText ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(appState.airDropIncludeText ? AirDropVisuals.tint : .white.opacity(0.6))
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: l10n["airdrop_include_text_title"], draft.textItemCount))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(appState.airDropIncludeText ? l10n["airdrop_include_text_on_desc"] : l10n["airdrop_include_text_off_desc"])
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(appState.airDropIncludeText ? 0.64 : 0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appState.airDropIncludeText ? AirDropVisuals.tint.opacity(0.16) : Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    appState.airDropIncludeText ? AirDropVisuals.tint.opacity(0.62) : Color.white.opacity(0.13),
                    lineWidth: appState.airDropIncludeText ? 1.2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(String(format: l10n["airdrop_include_text_accessibility"], draft.textItemCount, draft.textItemCount))
        .accessibilityValue(appState.airDropIncludeText ? l10n["airdrop_selected"] : l10n["airdrop_not_selected"])
    }

    private func localizedSummary(for draft: AirDropDraft) -> AirDropSummary {
        let includeText = displayIncludesText(for: draft)
        let itemCount = draft.primaryItemCount + (includeText ? draft.textItemCount : 0)
        return AirDropSummary(
            title: String(format: l10n["airdrop_items_ready"], itemCount),
            detail: localizedItemCountDetail(for: draft, includeText: includeText),
            itemCount: itemCount
        )
    }

    private func localizedItemCountDetail(for draft: AirDropDraft, includeText: Bool) -> String? {
        let fileCount = draft.fileURLs.filter { !$0.hasDirectoryPath }.count
        let folderCount = draft.fileURLs.filter(\.hasDirectoryPath).count
        let linkCount = draft.remoteURLs.count
        var parts: [String] = [
            localizedCount(fileCount, singularKey: "airdrop_file_count_one", pluralKey: "airdrop_file_count_other"),
            localizedCount(folderCount, singularKey: "airdrop_folder_count_one", pluralKey: "airdrop_folder_count_other"),
            localizedCount(linkCount, singularKey: "airdrop_link_count_one", pluralKey: "airdrop_link_count_other")
        ].compactMap { $0 }

        if includeText, draft.textItemCount > 0 {
            parts.append(localizedCount(draft.textItemCount, singularKey: "airdrop_txt_count_one", pluralKey: "airdrop_txt_count_other") ?? "")
        }

        let countDetail = parts.isEmpty ? nil : parts.joined(separator: l10n["airdrop_count_separator"])
        guard !includeText, draft.textItemCount > 0 else {
            return countDetail
        }

        let optionalTextDetail = String(
            format: l10n["airdrop_optional_text_detail"],
            draft.textItemCount,
            draft.textItemCount
        )
        return [countDetail, optionalTextDetail]
            .compactMap { $0 }
            .joined(separator: l10n["airdrop_detail_joiner"])
    }

    private func localizedCount(_ count: Int, singularKey: String, pluralKey: String) -> String? {
        guard count > 0 else { return nil }
        return String(format: l10n[count == 1 ? singularKey : pluralKey], count)
    }

    private func localizedFlowMessage(_ message: String) -> String {
        switch message {
        case AirDropFlowMessageKey.unavailable:
            return l10n["airdrop_flow_unavailable_detail"]
        case AirDropFlowMessageKey.failed:
            return l10n["airdrop_flow_failed_detail"]
        case AirDropFlowMessageKey.prepareTempFailed:
            return l10n["airdrop_flow_prepare_temp_failed"]
        case AirDropFlowMessageKey.cleanupFailed:
            return l10n["airdrop_flow_cleanup_failed"]
        default:
            return message
        }
    }

    private func displayIncludesText(for draft: AirDropDraft) -> Bool {
        switch draft.mode {
        case .needsTextConfirmation:
            return true
        case .readyWithOptionalText:
            return appState.airDropIncludeText
        case .ready:
            return false
        }
    }

    private var addMoreButton: some View {
        Button {
            appState.openAirDropItemPicker()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(l10n["airdrop_add_more"])
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n["airdrop_add_more_accessibility"])
    }

    private func openingView(_ transfer: AirDropTransfer) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(l10n["airdrop_opening_accessibility"])
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n["airdrop_opening_title"])
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Text(String(format: l10n["airdrop_items_ready"], transfer.sharingItems.count))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func statusView(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel(title)
    }

    private var controls: some View {
        HStack(spacing: 7) {
            if showsBottomCancel {
                AirDropActionButton(title: l10n["cancel"], role: .secondary) {
                    appState.cancelAirDrop()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(l10n["airdrop_cancel_accessibility"])
            }

            if canSubmit {
                AirDropActionButton(title: submitTitle, role: .primary) {
                    appState.submitAirDrop()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(submitAccessibilityLabel)
            }
        }
    }

    private var showsBottomCancel: Bool {
        switch appState.airDropState {
        case .idle, .cancelled:
            return false
        default:
            return true
        }
    }

    private var canSubmit: Bool {
        switch appState.airDropState {
        case .ready, .confirmingText:
            return true
        default:
            return false
        }
    }

    private var submitTitle: String {
        if case .confirmingText = appState.airDropState {
            return l10n["airdrop_submit_text"]
        }
        return "AirDrop"
    }

    private var submitAccessibilityLabel: String {
        if case .confirmingText = appState.airDropState {
            return l10n["airdrop_submit_text_accessibility"]
        }
        return l10n["airdrop_submit_accessibility"]
    }

    private var statusText: String {
        switch appState.airDropState {
        case .idle:
            return l10n["airdrop_status_waiting"]
        case .ready:
            return l10n["airdrop_status_ready"]
        case .confirmingText:
            return l10n["airdrop_status_confirm_text"]
        case .opening:
            return l10n["airdrop_status_native_open"]
        case .complete(_):
            return l10n["airdrop_status_complete"]
        case .unavailable:
            return l10n["airdrop_status_unavailable"]
        case .failed:
            return l10n["airdrop_status_failed"]
        case .cancelled:
            return l10n["airdrop_status_cancelled"]
        case .cleanupError:
            return l10n["airdrop_status_cleanup_error"]
        }
    }

    private func draftIcon(for draft: AirDropDraft) -> String {
        if draft.fileURLs.contains(where: \.hasDirectoryPath) {
            return "folder.fill"
        }
        if !draft.fileURLs.isEmpty {
            return "doc.fill"
        }
        if !draft.remoteURLs.isEmpty {
            return "link"
        }
        return "text.alignleft"
    }
}

#if DEBUG
@MainActor
private struct AirDropDemoControlPanel: View {
    var appState: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(appState.airDropPreviewScenarioName ?? l10n["airdrop_demo_title"])
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)

            Spacer(minLength: 0)

            Menu(l10n["airdrop_demo_menu"]) {
                ForEach(AirDropDemoScenario.allCases) { scenario in
                    Button(demoTitle(for: scenario)) {
                        DebugHarness.applyAirDropDemo(scenario, to: appState)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .accessibilityLabel(l10n["airdrop_demo_accessibility"])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func demoTitle(for scenario: AirDropDemoScenario) -> String {
        switch scenario {
        case .magnet: return l10n["airdrop_demo_magnet"]
        case .dropzone: return l10n["airdrop_demo_dropzone"]
        case .fileReady: return l10n["airdrop_demo_file_ready"]
        case .urlReady: return l10n["airdrop_demo_url_ready"]
        case .textConfirm: return l10n["airdrop_demo_text_confirm"]
        case .unavailable: return l10n["airdrop_demo_unavailable"]
        case .failed: return l10n["airdrop_demo_failed"]
        case .cleanupError: return l10n["airdrop_demo_cleanup_error"]
        case .completionOverlay: return l10n["airdrop_demo_completion_overlay"]
        case .approvalBlocked: return l10n["airdrop_demo_approval_blocked"]
        case .questionBlocked: return l10n["airdrop_demo_question_blocked"]
        case .disabled: return l10n["airdrop_demo_disabled"]
        }
    }
}
#endif

private struct AirDropDropZoneButton: View {
    let title: String
    let subtitle: String?
    let highlighted: Bool
    let action: () -> Void
    let onDrop: (AirDropPasteboardPayload) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false
    @State private var targeted = false

    private var active: Bool { highlighted || hovering || targeted }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(active ? AirDropVisuals.tint : .white.opacity(0.56))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(active ? 0.88 : 0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 82 : 62)
            .background(Color.white.opacity(active ? 0.075 : 0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        active ? AirDropVisuals.tint.opacity(0.58) : Color.white.opacity(0.12),
                        style: StrokeStyle(lineWidth: active ? 1.2 : 1, dash: active ? [] : [5, 4])
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(reduceMotion ? nil : NotchAnimation.micro) {
                hovering = h
            }
        }
        .onDrop(
            of: AirDropItemProviderReader.acceptedTypeIdentifiers,
            isTargeted: $targeted
        ) { providers in
            AirDropItemProviderReader.loadPayload(from: providers) { payload in
                onDrop(payload)
            }
        }
        .animation(reduceMotion ? nil : NotchAnimation.micro, value: highlighted)
        .accessibilityLabel(l10n["airdrop_drop_zone_accessibility"])
    }
}

private enum AirDropVisuals {
    static let tint = Color(red: 0.46, green: 0.72, blue: 1.0)
}

private enum AirDropItemProviderReader {
    static let acceptedTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.plainText.identifier,
        UTType.text.identifier
    ]

    static func loadPayload(
        from providers: [NSItemProvider],
        completion: @escaping (AirDropPasteboardPayload) -> Void
    ) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var fileURLs: [URL] = []
        var remoteURLs: [URL] = []
        var textValues: [String] = []

        func appendFileURL(_ url: URL) {
            lock.lock()
            if url.isFileURL {
                fileURLs.append(url)
            } else {
                remoteURLs.append(url)
            }
            lock.unlock()
        }

        func appendText(_ text: String) {
            lock.lock()
            textValues.append(text)
            lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = url(from: item) {
                        appendFileURL(url)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = url(from: item) {
                        appendFileURL(url)
                    }
                    group.leave()
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let text = text(from: item) {
                        appendText(text)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    if let text = text(from: item) {
                        appendText(text)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(AirDropPasteboardPayload(
                fileURLs: fileURLs,
                remoteURLs: remoteURLs,
                textSnippets: uniqueTextValues(textValues)
            ))
        }
        return true
    }

    private static func uniqueTextValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        if let nsString = item as? NSString {
            return URL(string: nsString as String)
        }
        return nil
    }

    private static func text(from item: NSSecureCoding?) -> String? {
        if let string = item as? String { return string }
        if let nsString = item as? NSString { return nsString as String }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

private enum AirDropActionButtonRole {
    case primary
    case secondary
}

private struct AirDropActionButton: View {
    let title: String
    let role: AirDropActionButtonRole
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(role == .primary ? .black.opacity(0.9) : .white.opacity(0.86))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch role {
        case .primary:
            return Color(red: 0.46, green: 0.72, blue: 1.0).opacity(hovering ? 0.96 : 0.86)
        case .secondary:
            return Color.white.opacity(hovering ? 0.1 : 0.055)
        }
    }

    private var stroke: Color {
        switch role {
        case .primary:
            return Color.white.opacity(0.2)
        case .secondary:
            return Color.white.opacity(hovering ? 0.18 : 0.1)
        }
    }
}
