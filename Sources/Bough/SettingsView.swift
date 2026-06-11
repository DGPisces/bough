import SwiftUI
import UniformTypeIdentifiers
import AppKit
import BoughCore

// MARK: - Main View

struct SettingsView: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedPage: SettingsPage = .general
    @State private var searchText = ""
    @State private var searchFocusToken = 0
    @State private var selectedSearchIndex = 0
    @State private var targetRequest: SettingsTargetRequest?
    @State private var highlightedTargetID: SettingsTargetID?
    @AppStorage(SettingsKey.codingSessionsEnabled) private var codingSessionsEnabled = SettingsDefaults.codingSessionsEnabled
    let appState: AppState

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchIndex.search(searchText, codingSessionsEnabled: codingSessionsEnabled)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SettingsSearchField(
                    text: $searchText,
                    placeholder: l10n["settings_search_placeholder"],
                    focusToken: searchFocusToken,
                    onSubmit: openSelectedSearchResult,
                    onCancel: clearSearch,
                    onMoveSelection: moveSearchSelection
                )
                .frame(height: 30)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                List(selection: $selectedPage) {
                    if isSearching {
                        SearchResultsList(
                            results: searchResults,
                            selectedIndex: selectedSearchIndex,
                            open: openSearchResult
                        )
                    } else {
                        ForEach(SettingsSidebarModel.sidebarGroups(codingSessionsEnabled: codingSessionsEnabled), id: \.title) { group in
                            Section {
                                ForEach(group.pages) { page in
                                    SidebarRow(page: page)
                                        .contentShape(Rectangle())
                                        .tag(page)
                                }
                            } header: {
                                if let title = group.title {
                                    Text(l10n[title])
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollViewReader { proxy in
                Group {
                    switch selectedPage {
                    case .general:
                        GeneralPage(highlightedTargetID: highlightedTargetID)
                    case .sessionDisplay:
                        SessionDisplayPage(highlightedTargetID: highlightedTargetID)
                    case .notch:
                        AppearancePage(highlightedTargetID: highlightedTargetID)
                    case .music:
                        MusicPage(
                            musicStore: appState.musicStore,
                            highlightedTargetID: highlightedTargetID
                        )
                    case .airDrop:
                        AirDropSettingsPage(highlightedTargetID: highlightedTargetID)
                    case .mascot:
                        MascotsPage(highlightedTargetID: highlightedTargetID)
                    case .sound:
                        SoundPage(highlightedTargetID: highlightedTargetID)
                    case .usageNotifications:
                        UsagePage(appState: appState, highlightedTargetID: highlightedTargetID)
                    case .integrations:
                        IntegrationsPage(highlightedTargetID: highlightedTargetID)
                    case .advanced:
                        AdvancedPage(appState: appState, highlightedTargetID: highlightedTargetID)
                    case .about:
                        AboutPage(appState: appState, highlightedTargetID: highlightedTargetID)
                    }
                }
                .onChange(of: targetRequest) { _, request in
                    guard let request, request.page == selectedPage else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(request.targetID, anchor: .center)
                        }
                    }
                }
            }
        }
        .toolbar(removing: .sidebarToggle)
        .onChange(of: searchText) { _, _ in
            selectedSearchIndex = 0
        }
        .onChange(of: codingSessionsEnabled) { _, _ in
            reconcileSelectionWithVisiblePages()
        }
        .onAppear {
            reconcileSelectionWithVisiblePages()
        }
        .onExitCommand {
            clearSearch()
        }
        .background(
            SettingsSearchShortcutBridge {
                searchFocusToken += 1
            }
        )
    }

    private func moveSearchSelection(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        let next = selectedSearchIndex + delta
        selectedSearchIndex = min(max(next, 0), searchResults.count - 1)
    }

    private func openSelectedSearchResult() {
        guard searchResults.indices.contains(selectedSearchIndex) else { return }
        openSearchResult(searchResults[selectedSearchIndex])
    }

    private func openSearchResult(_ result: SettingsSearchResult) {
        guard SettingsSidebarModel.isVisible(page: result.page, codingSessionsEnabled: codingSessionsEnabled) else {
            reconcileSelectionWithVisiblePages()
            return
        }
        selectedPage = result.page
        let isPageResult = result.kind == .page
        let targetID = isPageResult ? result.page.firstContentTargetID : result.targetID
        let request = SettingsTargetRequest(page: result.page, targetID: targetID)
        DispatchQueue.main.async {
            targetRequest = request
            highlightedTargetID = isPageResult ? nil : result.targetID
        }
        guard !isPageResult else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
            if highlightedTargetID == result.targetID {
                highlightedTargetID = nil
            }
        }
    }

    private func clearSearch() {
        if isSearching {
            searchText = ""
            selectedSearchIndex = 0
        }
    }

    private func reconcileSelectionWithVisiblePages() {
        guard SettingsSidebarModel.isVisible(page: selectedPage, codingSessionsEnabled: codingSessionsEnabled) else {
            selectedPage = .general
            targetRequest = nil
            highlightedTargetID = nil
            selectedSearchIndex = 0
            return
        }
        selectedSearchIndex = min(selectedSearchIndex, max(searchResults.count - 1, 0))
    }
}

private struct SearchResultsList: View {
    @ObservedObject private var l10n = L10n.shared
    let results: [SettingsSearchResult]
    let selectedIndex: Int
    let open: (SettingsSearchResult) -> Void

    var body: some View {
        Section {
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n["settings_search_no_results"])
                    Text(l10n["settings_search_try_suggestions"])
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    Button {
                        open(result)
                    } label: {
                        SearchResultRow(result: result, isSelected: index == selectedIndex)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                }
            }
        } header: {
            Text(l10n["settings_search_results"])
        }
    }
}

private struct SearchResultRow: View {
    let result: SettingsSearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            if let symbolName = result.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsSearchShortcutBridge: NSViewRepresentable {
    let focusSearch: () -> Void

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.focusSearch = focusSearch
        return view
    }

    func updateNSView(_ nsView: ShortcutView, context: Context) {
        nsView.focusSearch = focusSearch
    }

    final class ShortcutView: NSView {
        var focusSearch: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                        event.charactersIgnoringModifiers?.lowercased() == "f"
                    else {
                        return event
                    }
                    self?.focusSearch()
                    return nil
                }
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private struct RemoteHostRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var remoteManager = RemoteManager.shared
    let host: RemoteHost
    @State private var confirmRemove = false

    private var status: SSHForwarder.Status {
        remoteManager.connectionStatus[host.id] ?? .disconnected
    }

    private var statusText: String {
        switch status {
        case .connected:
            return l10n["remote_connected"]
        case .connecting:
            return l10n["remote_connecting"]
        case .disconnected:
            return l10n["remote_disconnected"]
        case .failed(let message):
            return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                    Text(host.displayAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if remoteManager.installRunning[host.id] == true {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let message = remoteManager.lastMessage[host.id], !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                switch status {
                case .connected, .connecting:
                    Button(l10n["remote_disconnect"]) {
                        remoteManager.disconnect(id: host.id)
                    }
                default:
                    Button(l10n["remote_connect"]) {
                        remoteManager.connect(id: host.id)
                    }
                }

                Button(l10n["reinstall"]) {
                    remoteManager.reconnect(id: host.id)
                }

                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Text(l10n["remote_remove"])
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            l10n["settings_confirm_remove_remote_title"],
            isPresented: $confirmRemove
        ) {
            Button(l10n["remote_remove"], role: .destructive) {
                remoteManager.removeHost(id: host.id)
            }
            Button(l10n["cancel"], role: .cancel) {}
        } message: {
            Text(String(format: l10n["settings_confirm_remove_remote_message"], host.name))
        }
    }
}

private struct SettingsTargetSection<Content: View>: View {
    let title: String
    let targetID: SettingsTargetID
    let highlightedTargetID: SettingsTargetID?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
                .foregroundStyle(highlightedTargetID == targetID ? .blue : .secondary)
        }
        .id(targetID)
        .settingsControlHighlight(isHighlighted: highlightedTargetID == targetID)
    }
}

private struct SidebarRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updater = UpdateChecker.shared
    let page: SettingsPage

    var body: some View {
        Label {
            Text(l10n[page.titleKey])
                .font(.system(size: 13))
                .padding(.leading, 2)
        } icon: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(page.color.gradient)
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .topTrailing) {
                    if page == .about && updater.state.isUpdateAvailable {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }
        }
    }
}

private let settingsMascotOptions: [(name: String, source: String, desc: String, color: Color)] = [
    ("Clawd", "claude", "Claude Code", Color(red: 0.871, green: 0.533, blue: 0.427)),
    ("Dex", "codex", "Codex (OpenAI)", Color(red: 0.92, green: 0.92, blue: 0.93)),
    ("Gemini", "gemini", "Gemini CLI", Color(red: 0.278, green: 0.588, blue: 0.894)),
    ("CursorBot", "cursor", "Cursor", Color(red: 0.96, green: 0.31, blue: 0.0)),
    ("TraeBot", "trae", "Trae", Color(red: 0.96, green: 0.31, blue: 0.0)),
    ("TraeCNBot", "traecn", "Trae CN", Color(red: 0.96, green: 0.31, blue: 0.0)),
    ("CopilotBot", "copilot", "GitHub Copilot", Color(red: 0.35, green: 0.75, blue: 0.95)),
    ("QoderBot", "qoder", "Qoder", Color(red: 0.165, green: 0.859, blue: 0.361)),
    ("Droid", "droid", "Factory", Color(red: 0.835, green: 0.416, blue: 0.149)),
    ("Buddy", "codebuddy", "CodeBuddy", Color(red: 0.424, green: 0.302, blue: 1.0)),
    ("BuddyCN", "codybuddycn", "CodyBuddyCN", Color(red: 0.424, green: 0.302, blue: 1.0)),
    ("StepFun", "stepfun", "StepFun", Color(red: 0.424, green: 0.302, blue: 1.0)),
    ("AntiGravity", "antigravity", "AntiGravity", Color(red: 0.424, green: 0.302, blue: 1.0)),
    ("WorkBuddy", "workbuddy", "WorkBuddy", Color(red: 0.475, green: 0.380, blue: 0.870)),
    ("Hermes", "hermes", "Hermes", Color(red: 0.424, green: 0.302, blue: 1.0)),
    ("QwenBot", "qwen", "Qwen Code", Color(red: 0.486, green: 0.228, blue: 0.929)),
    ("KimiBot", "kimi", "Kimi Code CLI", Color(red: 0.29, green: 0.56, blue: 1.0)),
    ("OpBot", "opencode", "OpenCode", Color(red: 0.55, green: 0.55, blue: 0.57)),
]

// MARK: - General Page

private struct GeneralPage: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.codingSessionsEnabled) private var codingSessionsEnabled = SettingsDefaults.codingSessionsEnabled
    @AppStorage(SettingsKey.welcomeGuideCompletedVersion) private var welcomeGuideCompletedVersion = ""
    @State private var launchAtLogin: Bool
    let highlightedTargetID: SettingsTargetID?

    init(highlightedTargetID: SettingsTargetID? = nil) {
        self.highlightedTargetID = highlightedTargetID
        _launchAtLogin = State(initialValue: SettingsManager.shared.launchAtLogin)
    }

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["product_mode"],
                targetID: .generalCodingSessions,
                highlightedTargetID: highlightedTargetID
            ) {
                Toggle(l10n[CodingSessionsSettings.titleLocalizationKey], isOn: $codingSessionsEnabled)
                    .id(SettingsTargetID.generalCodingSessions)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .generalCodingSessions)
                Text(l10n[CodingSessionsSettings.descriptionLocalizationKey])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsTargetSection(
                title: l10n["welcome_guide_settings_section"],
                targetID: .generalWelcomeGuide,
                highlightedTargetID: highlightedTargetID
            ) {
                HStack(spacing: 12) {
                    Button {
                        WelcomeGuideWindowController.shared.show()
                    } label: {
                        Label(l10n["welcome_guide_open_settings"], systemImage: "sparkles")
                    }
                    .id(SettingsTargetID.generalWelcomeGuide)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .generalWelcomeGuide)

                    Spacer()

                    Text(welcomeGuideStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(welcomeGuideStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(welcomeGuideStatusColor.opacity(0.12), in: Capsule())
                }

                Text(l10n["welcome_guide_settings_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsTargetSection(
                title: l10n["language"],
                targetID: .generalLanguage,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(l10n["language"], selection: $l10n.language) {
                    Text(l10n["system_language"]).tag("system")
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                }
                .id(SettingsTargetID.generalLanguage)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .generalLanguage)
                Text(l10n["language_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsTargetSection(
                title: l10n["settings_section_startup"],
                targetID: .generalStartup,
                highlightedTargetID: highlightedTargetID
            ) {
                Toggle(l10n["launch_at_login"], isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        SettingsManager.shared.launchAtLogin = v
                    }
                    .id(SettingsTargetID.generalStartup)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .generalStartup)
                Text(l10n["launch_at_login_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var welcomeGuideStatusText: String {
        switch WelcomeGuideSettings.status() {
        case .notCompleted:
            return l10n["welcome_guide_status_not_completed"]
        case .completed:
            return String(format: l10n["welcome_guide_status_completed"], welcomeGuideCompletedVersion)
        case .updateAvailable:
            return l10n["welcome_guide_status_update_available"]
        }
    }

    private var welcomeGuideStatusColor: Color {
        switch WelcomeGuideSettings.status() {
        case .notCompleted:
            return .secondary
        case .completed:
            return .green
        case .updateAvailable:
            return .orange
        }
    }
}

// MARK: - Appearance Page

private struct AppearancePage: View {
    @ObservedObject private var l10n = L10n.shared
    let highlightedTargetID: SettingsTargetID?

    @AppStorage(SettingsKey.displayChoice) private var displayChoice = SettingsDefaults.displayChoice
    @AppStorage(SettingsKey.allowHorizontalDrag) private var allowHorizontalDrag = SettingsDefaults.allowHorizontalDrag
    @AppStorage(SettingsKey.hideInFullscreen) private var hideInFullscreen = SettingsDefaults.hideInFullscreen
    @AppStorage(SettingsKey.hideWhenNoSession) private var hideWhenNoSession = SettingsDefaults.hideWhenNoSession
    @AppStorage(SettingsKey.collapseOnMouseLeave) private var collapseOnMouseLeave = SettingsDefaults.collapseOnMouseLeave
    @AppStorage(SettingsKey.hapticOnHover) private var hapticOnHover = SettingsDefaults.hapticOnHover
    @AppStorage(SettingsKey.hapticIntensity) private var hapticIntensity = SettingsDefaults.hapticIntensity
    @AppStorage(SettingsKey.collapsedWidthScale) private var collapsedWidthScale = SettingsDefaults.collapsedWidthScale
    @AppStorage(SettingsKey.notchHeightMode) private var notchHeightModeRaw = SettingsDefaults.notchHeightMode
    @AppStorage(SettingsKey.customNotchHeight) private var customNotchHeight = SettingsDefaults.customNotchHeight

    private var notchHeightMode: Binding<NotchHeightMode> {
        Binding(
            get: { NotchHeightMode(rawValue: notchHeightModeRaw) ?? .matchNotch },
            set: { notchHeightModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["display"],
                targetID: .notchDisplay,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(l10n["display"], selection: $displayChoice) {
                    Text(l10n["auto"]).tag("auto")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        let name = screen.localizedName
                        let isBuiltin = name.contains("Built-in") || name.contains("内置")
                        let label = isBuiltin ? l10n["builtin_display"] : name
                        Text(label).tag("screen_\(index)")
                    }
                }
                .id(SettingsTargetID.notchDisplayChoice)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchDisplayChoice)
                Toggle(l10n["allow_horizontal_drag"], isOn: $allowHorizontalDrag)
                    .onChange(of: allowHorizontalDrag) { _, enabled in
                        if !enabled {
                            SettingsManager.shared.panelHorizontalOffset = 0
                        }
                    }
                    .id(SettingsTargetID.notchHorizontalDrag)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchHorizontalDrag)
                Text(l10n["allow_horizontal_drag_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsTargetSection(
                title: l10n["settings_section_visibility"],
                targetID: .notchVisibility,
                highlightedTargetID: highlightedTargetID
            ) {
                BehaviorToggleRow(
                    title: l10n["hide_in_fullscreen"],
                    desc: l10n["hide_in_fullscreen_desc"],
                    isOn: $hideInFullscreen,
                    animation: .hideFullscreen,
                    targetID: .notchHideInFullscreen,
                    highlightedTargetID: highlightedTargetID
                )
                BehaviorToggleRow(
                    title: l10n["hide_when_no_session"],
                    desc: l10n["hide_when_no_session_desc"],
                    isOn: $hideWhenNoSession,
                    animation: .hideNoSession,
                    targetID: .notchHideWhenIdle,
                    highlightedTargetID: highlightedTargetID
                )
            }

            SettingsTargetSection(
                title: l10n["settings_section_expansion"],
                targetID: .notchExpansion,
                highlightedTargetID: highlightedTargetID
            ) {
                BehaviorToggleRow(
                    title: l10n["collapse_on_mouse_leave"],
                    desc: l10n["collapse_on_mouse_leave_desc"],
                    isOn: $collapseOnMouseLeave,
                    animation: .collapseMouseLeave,
                    targetID: .notchCollapseOnMouseLeave,
                    highlightedTargetID: highlightedTargetID
                )
                BehaviorToggleRow(
                    title: l10n["haptic_on_hover"],
                    desc: l10n["haptic_on_hover_desc"],
                    isOn: $hapticOnHover,
                    animation: .hapticHover,
                    targetID: .notchHapticOnHover,
                    highlightedTargetID: highlightedTargetID
                )
                if hapticOnHover {
                    Picker(selection: $hapticIntensity) {
                        Text(l10n["haptic_light"]).tag(1)
                        Text(l10n["haptic_medium"]).tag(2)
                        Text(l10n["haptic_strong"]).tag(3)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, BehaviorToggleRowMetrics.secondaryControlLeadingPadding)
                    .id(SettingsTargetID.notchHapticIntensity)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchHapticIntensity)
                }
            }

            SettingsTargetSection(
                title: l10n["settings_section_size_layout"],
                targetID: .notchSizeLayout,
                highlightedTargetID: highlightedTargetID
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(l10n["collapsed_width_scale"])
                        Spacer()
                        Text("\(collapsedWidthScale)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(collapsedWidthScale) },
                        set: { collapsedWidthScale = Int($0) }
                    ), in: 50...150, step: 10)
                    Text(l10n["collapsed_width_scale_desc"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .id(SettingsTargetID.notchIslandWidth)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchIslandWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: notchHeightMode) {
                        Text(l10n["notch_height_match_notch"]).tag(NotchHeightMode.matchNotch)
                        Text(l10n["notch_height_match_menubar"]).tag(NotchHeightMode.matchMenuBar)
                        Text(l10n["notch_height_custom"]).tag(NotchHeightMode.custom)
                    } label: {
                        Text(l10n["notch_height_mode"])
                        Text(l10n["notch_height_mode_desc"])
                    }
                    .id(SettingsTargetID.notchTopBarHeight)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchTopBarHeight)

                    if notchHeightMode.wrappedValue == .custom {
                        HStack {
                            Text(l10n["custom_notch_height"])
                            Spacer()
                            Text("\(Int(customNotchHeight.rounded()))pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $customNotchHeight, in: 15...60, step: 1)
                            .id(SettingsTargetID.notchCustomHeight)
                            .settingsControlHighlight(isHighlighted: highlightedTargetID == .notchCustomHeight)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Music Page

private struct MusicPage: View {
    @ObservedObject private var l10n = L10n.shared
    let musicStore: MusicNowPlayingStore
    let highlightedTargetID: SettingsTargetID?

    @AppStorage(SettingsKey.showMusicControls) private var showMusicControls = SettingsDefaults.showMusicControls
    @AppStorage(SettingsKey.compactBarPriority) private var compactBarPriorityRaw = SettingsDefaults.compactBarPriority

    private var compactBarPriority: Binding<String> {
        Binding(
            get: { CompactBarPriority.normalizedRawValue(compactBarPriorityRaw) },
            set: { compactBarPriorityRaw = CompactBarPriority.normalizedRawValue($0) }
        )
    }

    private var showMusicControlsBinding: Binding<Bool> {
        Binding(
            get: { showMusicControls },
            set: { enabled in
                showMusicControls = enabled
                musicStore.refreshControlsEnabled()
            }
        )
    }

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["music_controls_section"],
                targetID: .musicControls,
                highlightedTargetID: highlightedTargetID
            ) {
                Toggle(l10n["show_music_controls"], isOn: showMusicControlsBinding)
                    .id(SettingsTargetID.musicShowMusicControls)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .musicShowMusicControls)
                Text(l10n["show_music_controls_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(selection: compactBarPriority) {
                    Text(l10n[CompactBarPriority.aiActivity.localizedKey])
                        .tag(CompactBarPriority.aiActivity.rawValue)
                    Text(l10n[CompactBarPriority.music.localizedKey])
                        .tag(CompactBarPriority.music.rawValue)
                        .disabled(!showMusicControls)
                } label: {
                    Text(l10n["compact_bar_priority"])
                    Text(l10n["compact_bar_priority_desc"])
                }
                .pickerStyle(.segmented)
                .id(SettingsTargetID.musicCompactBarPriority)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .musicCompactBarPriority)

                if !showMusicControls {
                    Text(l10n["compact_bar_priority_music_disabled_desc"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = musicStore.settingsAbnormalMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AirDrop Page

private struct AirDropSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.airDropEnabled) private var airDropEnabled = SettingsDefaults.airDropEnabled
    @AppStorage(SettingsKey.airDropDemoScenariosEnabled) private var airDropDemoScenariosEnabled = SettingsDefaults.airDropDemoScenariosEnabled
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["airdrop_section"],
                targetID: .airDropEnabled,
                highlightedTargetID: highlightedTargetID
            ) {
                Toggle(l10n["airdrop_enabled"], isOn: $airDropEnabled)
                    .id(SettingsTargetID.airDropEnabled)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .airDropEnabled)
                Text(l10n["airdrop_enabled_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if DEBUG
                Toggle(l10n["airdrop_demo_scenarios"], isOn: $airDropDemoScenariosEnabled)
                    .id(SettingsTargetID.airDropDemoScenarios)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .airDropDemoScenarios)
                Text(l10n["airdrop_demo_scenarios_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Session Display Page

private struct SessionDisplayPage: View {
    @ObservedObject private var l10n = L10n.shared
    let highlightedTargetID: SettingsTargetID?

    @AppStorage(SettingsKey.autoCollapseAfterSessionJump) private var autoCollapseAfterSessionJump = SettingsDefaults.autoCollapseAfterSessionJump
    @AppStorage(SettingsKey.autoExpandOnCompletion) private var autoExpandOnCompletion = SettingsDefaults.autoExpandOnCompletion
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.aiMessageLines) private var aiMessageLines = SettingsDefaults.aiMessageLines
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["settings_section_expansion"],
                targetID: .sessionDisplayExpansion,
                highlightedTargetID: highlightedTargetID
            ) {
                BehaviorToggleRow(
                    title: l10n["auto_collapse_after_session_jump"],
                    desc: l10n["auto_collapse_after_session_jump_desc"],
                    isOn: $autoCollapseAfterSessionJump,
                    animation: .clickJumpCollapse,
                    targetID: .sessionDisplayAutoCollapseAfterJump,
                    highlightedTargetID: highlightedTargetID
                )
                BehaviorToggleRow(
                    title: l10n["auto_expand_on_completion"],
                    desc: l10n["auto_expand_on_completion_desc"],
                    isOn: $autoExpandOnCompletion,
                    animation: .completionExpand,
                    targetID: .sessionDisplayAutoExpandOnCompletion,
                    highlightedTargetID: highlightedTargetID
                )
            }

            SettingsTargetSection(
                title: l10n["settings_section_session_list"],
                targetID: .sessionDisplayList,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(selection: $maxVisibleSessions) {
                    Text("3").tag(3)
                    Text("5").tag(5)
                    Text("8").tag(8)
                    Text("10").tag(10)
                    Text(l10n["unlimited"]).tag(99)
                } label: {
                    Text(l10n["max_visible_sessions"])
                    Text(l10n["max_visible_sessions_desc"])
                }
                .id(SettingsTargetID.sessionDisplayMaxVisibleSessions)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .sessionDisplayMaxVisibleSessions)
            }

            SettingsTargetSection(
                title: l10n["content"],
                targetID: .sessionDisplayContent,
                highlightedTargetID: highlightedTargetID
            ) {
                AppearancePreview(
                    fontSize: contentFontSize,
                    lineLimit: aiMessageLines,
                    showDetails: showAgentDetails
                )
                Picker(l10n["content_font_size"], selection: $contentFontSize) {
                    Text("10pt").tag(10)
                    Text(l10n["11pt_default"]).tag(11)
                    Text("12pt").tag(12)
                    Text("13pt").tag(13)
                }
                .id(SettingsTargetID.sessionDisplayContentFontSize)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .sessionDisplayContentFontSize)
                Picker(l10n["ai_reply_lines"], selection: $aiMessageLines) {
                    Text(l10n["1_line_default"]).tag(1)
                    Text(l10n["2_lines"]).tag(2)
                    Text(l10n["3_lines"]).tag(3)
                    Text(l10n["5_lines"]).tag(5)
                    Text(l10n["unlimited"]).tag(0)
                }
                .id(SettingsTargetID.sessionDisplayAIReplyLines)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .sessionDisplayAIReplyLines)
                Toggle(l10n["show_agent_details"], isOn: $showAgentDetails)
                    .id(SettingsTargetID.sessionDisplayShowAgentDetails)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .sessionDisplayShowAgentDetails)
                Toggle(l10n["show_tool_status"], isOn: $showToolStatus)
                    .id(SettingsTargetID.sessionDisplayShowToolStatus)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .sessionDisplayShowToolStatus)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations Page

private struct IntegrationsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var remoteManager = RemoteManager.shared
    @State private var cliStatuses: [String: Bool] = [:]
    @State private var cliEnabledStates: [String: Bool] = [:]
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var refreshKey = 0
    @State private var customName = ""
    @State private var customSource = ""
    @State private var customConfigPath = ""
    @State private var customConfigKey = "hooks"
    @State private var customFormat: HookFormat = .claude
    @State private var remoteName = ""
    @State private var remoteHost = ""
    @State private var remoteUser = ""
    @State private var remotePort = ""
    @State private var remoteIdentityFile = ""
    @State private var remoteAuthSocket = ""
    @State private var remoteAutoConnect = false
    @State private var confirmGlobalHooksReinstall = false
    @State private var confirmGlobalHooksUninstall = false
    @State private var pendingCustomCLIRemoval: String?
    @AppStorage(SettingsKey.webhookEnabled) private var webhookEnabled: Bool = SettingsDefaults.webhookEnabled
    @AppStorage(SettingsKey.webhookURL) private var webhookURL: String = SettingsDefaults.webhookURL
    @AppStorage(SettingsKey.webhookEventFilter) private var webhookEventFilter: String = SettingsDefaults.webhookEventFilter
    let highlightedTargetID: SettingsTargetID?
    /// Regression guard: tracks the in-flight ChainInstallCoordinator
    /// call for the unified Claude Code toggle. When non-nil, the claude row's
    /// toggle is disabled and a spinner renders. Cleared when the coordinator
    /// returns (success or failure).
    @State private var claudeBusy = false
    /// Regression guard: authoritative toggle value for the
    /// Claude Code row, read at body-eval time so toggling off + on across
    /// app launches reflects the actual installed state.
    @State private var claudeIntegrationEnabled = IntegrationsPage.computeClaudeIntegrationEnabled()
    /// Regression guard: install failure banner. Surfaces just
    /// above the cli_status section when set. Cleared on the next successful
    /// install or when the user manually dismisses by toggling again.
    @State private var claudeInstallError: String?

    /// Source-of-truth for whether Bough's Claude Code integration is on.
    /// statusLine retired (spec §7): the integration is now only the
    /// session-monitoring hook, so the hook flag alone decides the toggle.
    private static func computeClaudeIntegrationEnabled() -> Bool {
        ConfigInstaller.isEnabled(source: "claude")
    }

    private func refreshCLIStatuses() {
        for cli in ConfigInstaller.allCLIs {
            cliStatuses[cli.source] = ConfigInstaller.isInstalled(source: cli.source)
            cliEnabledStates[cli.source] = ConfigInstaller.isEnabled(source: cli.source)
        }
        cliStatuses["opencode"] = ConfigInstaller.isInstalled(source: "opencode")
        cliEnabledStates["opencode"] = ConfigInstaller.isEnabled(source: "opencode")
        claudeIntegrationEnabled = IntegrationsPage.computeClaudeIntegrationEnabled()
    }

    /// Regression guard: unified install / uninstall lever.
    /// Toggle ON → enable the session-monitoring hook (statusLine retired, spec §7).
    /// Toggle OFF → disable hook AND retire any historical statusLine leftovers.
    /// Both paths go through ChainInstallCoordinator so concurrent callers
    /// (Settings toggle, Welcome Guide) serialize.
    @MainActor
    private func handleClaudeIntegrationToggle(_ desired: Bool) async {
        claudeBusy = true
        claudeInstallError = nil
        defer {
            claudeBusy = false
            refreshCLIStatuses()
            refreshKey += 1
            NotificationCenter.default.post(
                name: SettingsNotification.claudeCodeStatusLineDidChange,
                object: nil
            )
        }
        if desired {
            let result = await ChainInstallCoordinator.shared.installClaudeIntegration(replaceExisting: false)
            switch result {
            case .installed, .chained:
                claudeIntegrationEnabled = true
            case .conflict:
                // A user-installed third-party statusLine is in place. Surface
                // an error and revert the toggle — the chain-aware install
                // would have wrapped it transparently, so a conflict here
                // means the chain decision tree rejected the proposal
                // (e.g. wrapper already references a different prev_cmd).
                // The user can resolve manually; we don't run the legacy
                // conflict sheet anymore.
                claudeInstallError = l10n["usage_claude_integration_install_failed"]
                claudeIntegrationEnabled = false
            case .failed(let message):
                claudeInstallError = "\(l10n["usage_claude_integration_install_failed"]): \(message)"
                claudeIntegrationEnabled = false
            }
        } else {
            _ = await ChainInstallCoordinator.shared.uninstallClaudeIntegration()
            claudeIntegrationEnabled = false
        }
    }

    private func statusText(installed: Bool, exists: Bool) -> String {
        installed ? l10n["activated"] : (exists ? l10n["not_installed"] : l10n["not_detected"])
    }

    private func localToolTargetID(for source: String) -> SettingsTargetID? {
        switch source {
        case "claude": return .integrationsLocalToolClaude
        case "codex": return .integrationsLocalToolCodex
        case "gemini": return .integrationsLocalToolGemini
        case "cursor": return .integrationsLocalToolCursor
        case "trae": return .integrationsLocalToolTrae
        case "traecn": return .integrationsLocalToolTraeCN
        case "traecli": return .integrationsLocalToolTraeCLI
        case "qoder": return .integrationsLocalToolQoder
        case "droid": return .integrationsLocalToolFactory
        case "stepfun": return .integrationsLocalToolStepFun
        case "antigravity": return .integrationsLocalToolAntiGravity
        case "hermes": return .integrationsLocalToolHermes
        case "qwen": return .integrationsLocalToolQwen
        case "copilot": return .integrationsLocalToolCopilot
        case "kimi": return .integrationsLocalToolKimi
        case "kiro": return .integrationsLocalToolKiro
        default: return nil
        }
    }

    var body: some View {
        Form {
            if let claudeInstallError {
                Section {
                    Text(claudeInstallError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            SettingsTargetSection(
                title: l10n["settings_section_local_ai_tools"],
                targetID: .integrationsLocalTools,
                highlightedTargetID: highlightedTargetID
            ) {
                ForEach(ConfigInstaller.allCLIs, id: \.source) { cli in
                    let installed = cliStatuses[cli.source] ?? false
                    let enabled = cliEnabledStates[cli.source] ?? ConfigInstaller.isEnabled(source: cli.source)
                    let exists = ConfigInstaller.cliExists(source: cli.source)
                    let targetID = localToolTargetID(for: cli.source)
                    if cli.source == "claude" {
                        // Regression guard: unified Claude Code
                        // row — toggle wires up the session-monitoring hook
                        // through ChainInstallCoordinator (statusLine retired).
                        CLIStatusRow(
                            name: cli.name,
                            source: cli.source,
                            configPath: cli.displayConfigPath,
                            fullPath: cli.fullPath,
                            installed: installed,
                            enabled: claudeIntegrationEnabled,
                            exists: exists,
                            subtitle: l10n["usage_claude_integration_subtitle"],
                            busy: claudeBusy,
                            overrideEnabled: claudeIntegrationEnabled
                        ) { newValue in
                            Task { await handleClaudeIntegrationToggle(newValue) }
                        }
                        .id(targetID ?? .integrationsLocalTools)
                        .settingsControlHighlight(isHighlighted: targetID != nil && highlightedTargetID == targetID)
                    } else {
                        CLIStatusRow(
                            name: cli.name,
                            source: cli.source,
                            configPath: cli.displayConfigPath,
                            fullPath: cli.fullPath,
                            installed: installed,
                            enabled: enabled,
                            exists: exists
                        ) { _ in refreshCLIStatuses() }
                        .id(targetID ?? .integrationsLocalTools)
                        .settingsControlHighlight(isHighlighted: targetID != nil && highlightedTargetID == targetID)
                    }
                }
                // OpenCode (plugin-based, not hooks)
                let ocInstalled = cliStatuses["opencode"] ?? false
                let ocEnabled = cliEnabledStates["opencode"] ?? ConfigInstaller.isEnabled(source: "opencode")
                let ocExists = ConfigInstaller.cliExists(source: "opencode")
                CLIStatusRow(
                    name: "OpenCode",
                    source: "opencode",
                    configPath: ConfigInstaller.opencodePluginDisplayPath(),
                    fullPath: ConfigInstaller.opencodePluginInstallPath(),
                    installed: ocInstalled,
                    enabled: ocEnabled,
                    exists: ocExists
                ) { _ in refreshCLIStatuses() }
                .id(SettingsTargetID.integrationsLocalToolOpenCode)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsLocalToolOpenCode)
            }

            SettingsTargetSection(
                title: l10n["settings_custom_clis_section"],
                targetID: .integrationsCustomCLIs,
                highlightedTargetID: highlightedTargetID
            ) {
                let customItems = ConfigInstaller.customCLIConfigs()
                if customItems.isEmpty {
                    Text(L10n.shared["settings_custom_clis_empty"])
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customItems) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text("\(item.source) · \(item.configPath)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                pendingCustomCLIRemoval = item.source
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                TextField(L10n.shared["settings_custom_clis_name_placeholder"], text: $customName)
                    .id(SettingsTargetID.integrationsCustomCLIName)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLIName)
                TextField(L10n.shared["settings_custom_clis_source_placeholder"], text: $customSource)
                    .id(SettingsTargetID.integrationsCustomCLISource)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLISource)
                TextField(L10n.shared["settings_custom_clis_path_placeholder"], text: $customConfigPath)
                    .id(SettingsTargetID.integrationsCustomCLIPath)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLIPath)
                TextField(L10n.shared["settings_custom_clis_key_placeholder"], text: $customConfigKey)
                    .id(SettingsTargetID.integrationsCustomCLIKey)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLIKey)
                Picker(L10n.shared["settings_custom_clis_template_picker"], selection: $customFormat) {
                    Text("Claude").tag(HookFormat.claude)
                    Text("Codex/Gemini").tag(HookFormat.nested)
                    Text("Cursor").tag(HookFormat.flat)
                    Text("Copilot").tag(HookFormat.copilot)
                }
                .id(SettingsTargetID.integrationsCustomCLIFormat)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLIFormat)

                Button(L10n.shared["settings_custom_clis_add_button"]) {
                    let result = ConfigInstaller.addCustomCLI(
                        name: customName,
                        source: customSource,
                        configPath: customConfigPath,
                        format: customFormat,
                        configKey: customConfigKey
                    )
                    statusMessage = result.message
                    statusIsError = !result.ok
                    guard result.ok else { return }

                    let normalizedSource = customSource
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard ConfigInstaller.setEnabled(source: normalizedSource, enabled: true) else {
                        _ = ConfigInstaller.removeCustomCLI(source: normalizedSource)
                        _ = ConfigInstaller.setEnabled(source: normalizedSource, enabled: false)
                        statusMessage = "Custom CLI saved, but hook installation failed"
                        statusIsError = true
                        refreshCLIStatuses()
                        refreshKey += 1
                        return
                    }
                    customName = ""
                    customSource = ""
                    customConfigPath = ""
                    customConfigKey = "hooks"
                    customFormat = .claude
                    refreshCLIStatuses()
                    refreshKey += 1
                }
                .id(SettingsTargetID.integrationsCustomCLIAdd)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsCustomCLIAdd)
            }

            SettingsTargetSection(
                title: l10n["remote_hosts"],
                targetID: .integrationsRemoteHosts,
                highlightedTargetID: highlightedTargetID
            ) {
                if remoteManager.hosts.isEmpty {
                    Text(l10n["remote_hosts_empty"])
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteManager.hosts) { remoteHost in
                        RemoteHostRow(host: remoteHost)
                    }
                }

                Divider()

                TextField(l10n["remote_name"], text: $remoteName)
                    .id(SettingsTargetID.integrationsRemoteName)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteName)
                TextField(l10n["remote_host"], text: $remoteHost)
                    .id(SettingsTargetID.integrationsRemoteHost)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteHost)
                TextField(l10n["remote_user"], text: $remoteUser)
                    .id(SettingsTargetID.integrationsRemoteUser)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteUser)
                TextField(l10n["remote_port"], text: $remotePort)
                    .id(SettingsTargetID.integrationsRemotePort)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemotePort)
                TextField(l10n["remote_identity"], text: $remoteIdentityFile)
                    .id(SettingsTargetID.integrationsRemoteIdentity)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteIdentity)
                TextField(l10n["remote_auth_socket"], text: $remoteAuthSocket,
                          prompt: Text(l10n["remote_auth_socket_placeholder"]))
                    .id(SettingsTargetID.integrationsRemoteAuthSocket)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteAuthSocket)
                Toggle(l10n["remote_auto_connect"], isOn: $remoteAutoConnect)
                    .id(SettingsTargetID.integrationsRemoteAutoConnect)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteAutoConnect)

                Button(l10n["remote_add_button"]) {
                    addRemoteHost()
                }
                .disabled(remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .id(SettingsTargetID.integrationsRemoteAdd)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsRemoteAdd)

                Text(l10n["remote_hint"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsTargetSection(
                title: l10n["webhook_title"],
                targetID: .integrationsWebhooks,
                highlightedTargetID: highlightedTargetID
            ) {
                Text(l10n["webhook_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(l10n["webhook_enable"], isOn: $webhookEnabled)
                    .id(SettingsTargetID.integrationsWebhookEnabled)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsWebhookEnabled)
                if webhookEnabled {
                    TextField(l10n["webhook_url_placeholder"], text: $webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .id(SettingsTargetID.integrationsWebhookURL)
                        .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsWebhookURL)
                    TextField(l10n["webhook_filter_placeholder"], text: $webhookEventFilter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .id(SettingsTargetID.integrationsWebhookFilter)
                        .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsWebhookFilter)
                    Text(l10n["webhook_filter_hint"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(l10n["management"]) {
                HStack(spacing: 8) {
                    Button {
                        confirmGlobalHooksReinstall = true
                    } label: {
                        Text(l10n["reinstall"])
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .id(SettingsTargetID.integrationsReinstallHooks)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsReinstallHooks)

                    Button(role: .destructive) {
                        confirmGlobalHooksUninstall = true
                    } label: {
                        Text(l10n["uninstall"])
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .id(SettingsTargetID.integrationsUninstallHooks)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .integrationsUninstallHooks)
                }

                if !statusMessage.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(statusIsError ? .red : .green)
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshCLIStatuses() }
        .confirmationDialog(
            l10n["settings_confirm_reinstall_hooks_title"],
            isPresented: $confirmGlobalHooksReinstall
        ) {
            Button(l10n["reinstall"]) {
                reinstallAllHooks()
            }
            Button(l10n["cancel"], role: .cancel) {}
        } message: {
            Text(l10n["settings_confirm_reinstall_hooks_message"])
        }
        .confirmationDialog(
            l10n["settings_confirm_uninstall_hooks_title"],
            isPresented: $confirmGlobalHooksUninstall
        ) {
            Button(l10n["uninstall"], role: .destructive) {
                uninstallAllHooks()
            }
            Button(l10n["cancel"], role: .cancel) {}
        } message: {
            Text(l10n["settings_confirm_uninstall_hooks_message"])
        }
        .confirmationDialog(
            l10n["settings_confirm_remove_custom_cli_title"],
            isPresented: Binding(
                get: { pendingCustomCLIRemoval != nil },
                set: { if !$0 { pendingCustomCLIRemoval = nil } }
            )
        ) {
            Button(l10n["remove"], role: .destructive) {
                if let source = pendingCustomCLIRemoval {
                    _ = ConfigInstaller.setEnabled(source: source, enabled: false)
                    _ = ConfigInstaller.removeCustomCLI(source: source)
                    refreshCLIStatuses()
                    refreshKey += 1
                    pendingCustomCLIRemoval = nil
                }
            }
            Button(l10n["cancel"], role: .cancel) {
                pendingCustomCLIRemoval = nil
            }
        } message: {
            Text(l10n["settings_confirm_remove_custom_cli_message"])
        }
    }

    private func addRemoteHost() {
        let trimmedName = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty else { return }

        remoteManager.addHost(RemoteHost(
            name: trimmedName,
            host: trimmedHost,
            user: remoteUser.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(remotePort.trimmingCharacters(in: .whitespacesAndNewlines)),
            identityFile: remoteIdentityFile.trimmingCharacters(in: .whitespacesAndNewlines),
            autoConnect: remoteAutoConnect,
            authSocket: remoteAuthSocket.trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        remoteName = ""
        remoteHost = ""
        remoteUser = ""
        remotePort = ""
        remoteIdentityFile = ""
        remoteAuthSocket = ""
        remoteAutoConnect = false
    }

    private func reinstallAllHooks() {
        for cli in ConfigInstaller.allCLIs where ConfigInstaller.cliExists(source: cli.source) {
            UserDefaults.standard.set(true, forKey: "cli_enabled_\(cli.source)")
        }
        if ConfigInstaller.cliExists(source: "opencode") {
            UserDefaults.standard.set(true, forKey: "cli_enabled_opencode")
        }
        if ConfigInstaller.install() {
            refreshCLIStatuses()
            refreshKey += 1
            statusMessage = l10n["hooks_installed"]
            statusIsError = false
        } else {
            statusMessage = l10n["install_failed"]
            statusIsError = true
        }
    }

    private func uninstallAllHooks() {
        for cli in ConfigInstaller.allCLIs {
            UserDefaults.standard.set(false, forKey: "cli_enabled_\(cli.source)")
        }
        UserDefaults.standard.set(false, forKey: "cli_enabled_opencode")
        ConfigInstaller.uninstall()
        refreshCLIStatuses()
        refreshKey += 1
        statusMessage = l10n["hooks_uninstalled"]
        statusIsError = false
    }
}

private struct CLIStatusRow: View {
    @ObservedObject private var l10n = L10n.shared
    let name: String
    let source: String
    let configPath: String
    let fullPath: String
    let installed: Bool
    let enabled: Bool
    let exists: Bool
    /// Regression guard: subtitle text under the row label.
    /// Used by the Claude Code row to explain that the toggle wires up
    /// BOTH the hook AND the statusLine wrapper. `nil` for other CLIs.
    let subtitle: String?
    /// Regression guard: when set, the toggle is disabled
    /// (Working…) while the parent runs an async install/uninstall in
    /// response to a toggle change. Prevents a second click from
    /// interleaving with the in-flight ChainInstallCoordinator call.
    let busy: Bool
    /// Regression guard: external state override used by the
    /// parent to force the visual toggle back to the previous value when an
    /// install fails. nil keeps the row authoritative (default behavior).
    let overrideEnabled: Bool?
    var onToggle: ((Bool) -> Void)?

    init(name: String, source: String, configPath: String, fullPath: String,
         installed: Bool, enabled: Bool? = nil, exists: Bool,
         subtitle: String? = nil,
         busy: Bool = false,
         overrideEnabled: Bool? = nil,
         onToggle: ((Bool) -> Void)? = nil) {
        self.name = name
        self.source = source
        self.configPath = configPath
        self.fullPath = fullPath
        self.installed = installed
        self.enabled = enabled ?? ConfigInstaller.isEnabled(source: source)
        self.exists = exists
        self.subtitle = subtitle
        self.busy = busy
        self.overrideEnabled = overrideEnabled
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = cliIcon(source: source, size: 20) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if !exists {
                        Text(l10n["not_detected"])
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else if installed {
                        HStack(spacing: 2) {
                            Text(configPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                            } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                if busy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
                if exists {
                    let toggleBinding = Binding<Bool>(
                        get: { overrideEnabled ?? enabled },
                        set: { newValue in
                            if overrideEnabled == nil {
                                let ok = ConfigInstaller.setEnabled(source: source, enabled: newValue)
                                if !ok {
                                    onToggle?(false)
                                    return
                                }
                            }
                            onToggle?(newValue)
                        }
                    )
                    Toggle("", isOn: toggleBinding)
                        .labelsHidden()
                        .disabled(busy)
                }
            }
            if let subtitle, exists {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Advanced Page

private struct AdvancedPage: View {
    @ObservedObject private var l10n = L10n.shared
    let appState: AppState
    let highlightedTargetID: SettingsTargetID?

    @AppStorage(SettingsKey.autoApproveTools) private var autoApproveRaw: String = SettingsDefaults.autoApproveTools
    @AppStorage(SettingsKey.excludedHookCwdSubstrings) private var excludedHookCwdSubstrings: String = SettingsDefaults.excludedHookCwdSubstrings
    @AppStorage(SettingsKey.sessionTimeout) private var sessionTimeout = SettingsDefaults.sessionTimeout
    @AppStorage(SettingsKey.rotationInterval) private var rotationInterval = SettingsDefaults.rotationInterval
    @AppStorage(SettingsKey.maxToolHistory) private var maxToolHistory = SettingsDefaults.maxToolHistory
    @AppStorage(SettingsKey.pluginSessionMode) private var pluginSessionMode = SettingsDefaults.pluginSessionMode

    private func autoApproveBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { autoApproveRaw.split(separator: ",").contains(Substring(name)) },
            set: { isOn in
                var set = Set(autoApproveRaw.split(separator: ",").map(String.init))
                if isOn { set.insert(name) } else { set.remove(name) }
                autoApproveRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["auto_approve_tools"],
                targetID: .advancedAutomation,
                highlightedTargetID: highlightedTargetID
            ) {
                Text(l10n["auto_approve_tools_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(SettingsManager.allAutoApproveTools, id: \.name) { tool in
                    let targetID = autoApproveTargetID(for: tool.name)
                    Toggle(isOn: autoApproveBinding(for: tool.name)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                                .font(.system(size: 12, design: .monospaced))
                            Text(l10n["auto_approve_\(tool.name)"])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(targetID)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == targetID)
                }
            }

            SettingsTargetSection(
                title: l10n["excluded_hook_cwd_title"],
                targetID: .advancedHookFilters,
                highlightedTargetID: highlightedTargetID
            ) {
                Text(l10n["excluded_hook_cwd_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n["excluded_hook_cwd_placeholder"], text: $excludedHookCwdSubstrings)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .id(SettingsTargetID.advancedExcludedHookPaths)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedExcludedHookPaths)
            }

            SettingsTargetSection(
                title: l10n["settings_section_session_handling"],
                targetID: .advancedSessionHandling,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(selection: $sessionTimeout) {
                    Text(l10n["no_cleanup"]).tag(0)
                    Text(l10n["10_minutes"]).tag(10)
                    Text(l10n["30_minutes"]).tag(30)
                    Text(l10n["1_hour"]).tag(60)
                    Text(l10n["2_hours"]).tag(120)
                } label: {
                    Text(l10n["session_cleanup"])
                    Text(l10n["session_cleanup_desc"])
                }
                .id(SettingsTargetID.advancedSessionCleanup)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedSessionCleanup)
                Picker(selection: $rotationInterval) {
                    Text(l10n["3_seconds"]).tag(3)
                    Text(l10n["5_seconds"]).tag(5)
                    Text(l10n["8_seconds"]).tag(8)
                    Text(l10n["10_seconds"]).tag(10)
                } label: {
                    Text(l10n["rotation_interval"])
                    Text(l10n["rotation_interval_desc"])
                }
                .id(SettingsTargetID.advancedRotationInterval)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedRotationInterval)
                Picker(selection: $maxToolHistory) {
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("50").tag(50)
                    Text("100").tag(100)
                } label: {
                    Text(l10n["tool_history_limit"])
                    Text(l10n["tool_history_limit_desc"])
                }
                .id(SettingsTargetID.advancedToolHistoryLimit)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedToolHistoryLimit)
                Picker(selection: $pluginSessionMode) {
                    Text(l10n["plugin_session_mode_separate"]).tag("separate")
                    Text(l10n["plugin_session_mode_merge"]).tag("merge")
                    Text(l10n["plugin_session_mode_hide"]).tag("hide")
                } label: {
                    Text(l10n["plugin_session_mode"])
                    Text(l10n["plugin_session_mode_desc"])
                }
                .id(SettingsTargetID.advancedPluginSessions)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedPluginSessions)
            }

            SettingsTargetSection(
                title: l10n["settings_section_diagnostics_repair"],
                targetID: .advancedDiagnosticsRepair,
                highlightedTargetID: highlightedTargetID
            ) {
                Button {
                    DiagnosticsExporter.export(appState: appState)
                } label: {
                    Label(l10n["export_diagnostics"], systemImage: "square.and.arrow.up")
                }
                .id(SettingsTargetID.advancedExportDiagnostics)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .advancedExportDiagnostics)
                Text(l10n["export_diagnostics_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func autoApproveTargetID(for name: String) -> SettingsTargetID {
        switch name {
        case "TaskCreate": return .advancedAutoApproveTaskCreate
        case "TaskUpdate": return .advancedAutoApproveTaskUpdate
        case "TaskGet": return .advancedAutoApproveTaskGet
        case "TaskList": return .advancedAutoApproveTaskList
        case "TaskOutput": return .advancedAutoApproveTaskOutput
        case "TaskStop": return .advancedAutoApproveTaskStop
        case "TodoRead": return .advancedAutoApproveTodoRead
        case "TodoWrite": return .advancedAutoApproveTodoWrite
        case "EnterPlanMode": return .advancedAutoApproveEnterPlanMode
        case "ExitPlanMode": return .advancedAutoApproveExitPlanMode
        default: return .advancedAutomation
        }
    }
}

/// Live preview mimicking the real SessionCard layout.
private struct AppearancePreview: View {
    let fontSize: Int
    let lineLimit: Int
    let showDetails: Bool

    private var fs: CGFloat { CGFloat(fontSize) }
    private let green = Color(red: 0.3, green: 0.85, blue: 0.4)
    private let aiColor = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Column 1: Mascot
            VStack(spacing: 3) {
                MascotView(source: "claude", status: .processing, size: 32)
                if showDetails {
                    HStack(spacing: 1) {
                        MiniAgentIcon(active: true, size: 8)
                        MiniAgentIcon(active: false, size: 8)
                    }
                }
            }
            .frame(width: 36)

            // Column 2: Content
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack(spacing: 6) {
                    Text("my-project")
                        .font(.system(size: fs + 2, weight: .bold, design: .monospaced))
                        .foregroundStyle(green)
                    Spacer()
                    Text("3m")
                        .font(.system(size: max(9, fs - 1.5), weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
                }

                // Chat
                VStack(alignment: .leading, spacing: 3) {
                    // User prompt
                    HStack(alignment: .top, spacing: 4) {
                        Text(">")
                            .font(.system(size: fs, weight: .bold, design: .monospaced))
                            .foregroundStyle(green)
                        Text("Fix the login bug")
                            .font(.system(size: fs, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    // AI reply
                    HStack(alignment: .top, spacing: 4) {
                        Text("$")
                            .font(.system(size: fs, weight: .bold, design: .monospaced))
                            .foregroundStyle(aiColor)
                        Text("I've analyzed the codebase and found the issue in the authentication module. The token validation was skipping the expiry check when refreshing sessions.")
                            .font(.system(size: fs, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(lineLimit > 0 ? lineLimit : nil)
                            .truncationMode(.tail)
                    }
                    // Working indicator
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: fs, weight: .bold, design: .monospaced))
                            .foregroundStyle(aiColor)
                        Text("Edit src/auth.ts")
                            .font(.system(size: fs, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.05))
        )
        .animation(.easeInOut(duration: 0.25), value: fontSize)
        .animation(.easeInOut(duration: 0.25), value: lineLimit)
        .animation(.easeInOut(duration: 0.25), value: showDetails)
    }
}

// MARK: - Mascots Page

private struct MascotsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var previewStatus: AgentStatus = .processing
    @AppStorage(SettingsKey.defaultSource) private var defaultSource = SettingsDefaults.defaultSource
    @AppStorage(SettingsKey.mascotSpeed) private var mascotSpeed = SettingsDefaults.mascotSpeed
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["default_mascot"],
                targetID: .mascotDefaultSource,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(selection: $defaultSource) {
                    ForEach(settingsMascotOptions, id: \.source) { mascot in
                        Text(mascot.desc).tag(mascot.source)
                    }
                } label: {
                    Text(l10n["default_mascot"])
                    Text(l10n["default_mascot_desc"])
                }
                .id(SettingsTargetID.mascotDefaultSource)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .mascotDefaultSource)
            }

            SettingsTargetSection(
                title: l10n["preview"],
                targetID: .mascotPreview,
                highlightedTargetID: highlightedTargetID
            ) {
                Picker(l10n["preview_status"], selection: $previewStatus) {
                    Text(l10n["processing"]).tag(AgentStatus.processing)
                    Text(l10n["idle"]).tag(AgentStatus.idle)
                    Text(l10n["waiting_approval"]).tag(AgentStatus.waitingApproval)
                }
                .pickerStyle(.segmented)
                .id(SettingsTargetID.mascotPreviewStatus)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .mascotPreviewStatus)
            }

            SettingsTargetSection(
                title: l10n["settings_section_animation"],
                targetID: .mascotAnimation,
                highlightedTargetID: highlightedTargetID
            ) {
                HStack {
                    Text(l10n["mascot_speed"])
                    Spacer()
                    Text(mascotSpeed == 0
                         ? l10n["speed_off"]
                         : String(format: "%.1f×", Double(mascotSpeed) / 100.0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(mascotSpeed) },
                    set: { mascotSpeed = Int($0) }
                ), in: 0...300, step: 25)
                .id(SettingsTargetID.mascotAnimationSpeed)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .mascotAnimationSpeed)
            }

            Section {
                ForEach(settingsMascotOptions, id: \.source) { mascot in
                    MascotRow(
                        name: mascot.name,
                        source: mascot.source,
                        desc: mascot.desc,
                        color: mascot.color,
                        status: previewStatus
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MascotRow: View {
    let name: String
    let source: String
    let desc: String
    let color: Color
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 56, height: 56)
                MascotView(source: source, status: status, size: 40)
                    .frame(width: 40, height: 40)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    if let icon = cliIcon(source: source, size: 16) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                }
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sound Page

private struct SoundPage: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.soundVolume) private var soundVolume = SettingsDefaults.soundVolume
    @AppStorage(SettingsKey.soundSessionStart) private var soundSessionStart = SettingsDefaults.soundSessionStart
    @AppStorage(SettingsKey.soundTaskComplete) private var soundTaskComplete = SettingsDefaults.soundTaskComplete
    @AppStorage(SettingsKey.soundTaskError) private var soundTaskError = SettingsDefaults.soundTaskError
    @AppStorage(SettingsKey.soundApprovalNeeded) private var soundApprovalNeeded = SettingsDefaults.soundApprovalNeeded
    @AppStorage(SettingsKey.soundPromptSubmit) private var soundPromptSubmit = SettingsDefaults.soundPromptSubmit
    @AppStorage(SettingsKey.soundBoot) private var soundBoot = SettingsDefaults.soundBoot
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Form {
            SettingsTargetSection(
                title: l10n["settings_section_sound_master"],
                targetID: .soundMaster,
                highlightedTargetID: highlightedTargetID
            ) {
                Toggle(l10n["enable_sound"], isOn: $soundEnabled)
                    .id(SettingsTargetID.soundEnable)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .soundEnable)
                if soundEnabled {
                    HStack(spacing: 8) {
                        Text(l10n["volume"])
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(soundVolume) },
                                set: { soundVolume = Int($0) }
                            ),
                            in: 0...100,
                            step: 5
                        )
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(soundVolume)%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .id(SettingsTargetID.soundVolume)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .soundVolume)
                }
            }

            if soundEnabled {
                SettingsTargetSection(
                    title: l10n["settings_section_sound_events"],
                    targetID: .soundEvents,
                    highlightedTargetID: highlightedTargetID
                ) {
                    SoundEventRow(title: l10n["session_start"], subtitle: l10n["new_claude_session"], soundName: "8bit_start", isOn: $soundSessionStart, targetID: .soundSessionStart, highlightedTargetID: highlightedTargetID)
                    SoundEventRow(title: l10n["task_complete"], subtitle: l10n["ai_completed_reply"], soundName: "8bit_complete", isOn: $soundTaskComplete, targetID: .soundTaskComplete, highlightedTargetID: highlightedTargetID)
                    SoundEventRow(title: l10n["task_error"], subtitle: l10n["tool_or_api_error"], soundName: "8bit_error", isOn: $soundTaskError, targetID: .soundTaskError, highlightedTargetID: highlightedTargetID)
                    SoundEventRow(title: l10n["approval_needed"], subtitle: l10n["waiting_approval_desc"], soundName: "8bit_approval", isOn: $soundApprovalNeeded, targetID: .soundApprovalNeeded, highlightedTargetID: highlightedTargetID)
                    SoundEventRow(title: l10n["task_confirmation"], subtitle: l10n["you_sent_message"], soundName: "8bit_submit", isOn: $soundPromptSubmit, targetID: .soundPromptSubmit, highlightedTargetID: highlightedTargetID)
                    SoundEventRow(title: l10n["boot_sound"], subtitle: l10n["boot_sound_desc"], soundName: "8bit_boot", isOn: $soundBoot, targetID: .soundBoot, highlightedTargetID: highlightedTargetID)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundEventRow: View {
    @ObservedObject private var l10n = L10n.shared
    let title: String
    var subtitle: String? = nil
    let soundName: String
    @Binding var isOn: Bool
    let targetID: SettingsTargetID?
    let highlightedTargetID: SettingsTargetID?
    @State private var customPath: String = ""

    init(
        title: String,
        subtitle: String? = nil,
        soundName: String,
        isOn: Binding<Bool>,
        targetID: SettingsTargetID? = nil,
        highlightedTargetID: SettingsTargetID? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.soundName = soundName
        _isOn = isOn
        self.targetID = targetID
        self.highlightedTargetID = highlightedTargetID
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if customPath.isEmpty {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(l10n["custom_sound_set"].replacingOccurrences(of: "%@", with: URL(fileURLWithPath: customPath).lastPathComponent))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 16)
            // Choose custom sound
            Menu {
                Button {
                    chooseCustomSound()
                } label: {
                    Label(l10n["choose_sound_file"], systemImage: "folder")
                }
                if !customPath.isEmpty {
                    Button {
                        clearCustomSound()
                    } label: {
                        Label(l10n["reset_to_default"], systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Image(systemName: customPath.isEmpty ? "waveform" : "waveform.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(customPath.isEmpty ? .secondary : Color.orange)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            Button {
                if !customPath.isEmpty {
                    SoundManager.shared.previewCustom(customPath)
                } else {
                    SoundManager.shared.preview(soundName)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .onAppear {
            customPath = UserDefaults.standard.string(forKey: SettingsKey.soundCustomPath(soundName)) ?? ""
        }
        .id(targetID)
        .settingsControlHighlight(isHighlighted: targetID != nil && highlightedTargetID == targetID)
    }

    private func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.title = l10n["choose_sound_file"]
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            UserDefaults.standard.set(url.path, forKey: SettingsKey.soundCustomPath(soundName))
        }
    }

    private func clearCustomSound() {
        customPath = ""
        UserDefaults.standard.removeObject(forKey: SettingsKey.soundCustomPath(soundName))
    }
}

// MARK: - About Page

private struct AboutPage: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updater = UpdateChecker.shared
    let appState: AppState
    let highlightedTargetID: SettingsTargetID?

    @State private var autoUpdateEnabled: Bool = UpdateChecker.shared.updater.automaticallyChecksForUpdates

    var body: some View {
        // Regression guard: wrap the About page in a ScrollView so
        // users on shorter Settings windows can still reach the Automatic
        // Updates section below. The outer ScrollView coexists with the
        // AppKit window sizing in SettingsWindowController.swift: the window
        // can grow when there is screen room, and this page scrolls when there
        // is not.
        ScrollView {
            VStack(spacing: 24) {
                BoughMascotView(frameSize: 100)
                    .id(SettingsTargetID.aboutPage)

                VStack(spacing: 6) {
                    Text("Bough")
                        .font(.custom(BoughFonts.pixelifySansRegular, size: 26))
                        .fontWeight(.bold)
                    Text("Version \(AppVersion.current)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    aboutLink("GitHub", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/DGPisces/bough")
                        .id(SettingsTargetID.aboutGitHub)
                        .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutGitHub)
                    aboutLink("Issues", icon: "ladybug", url: "https://github.com/DGPisces/bough/issues")
                        .id(SettingsTargetID.aboutIssues)
                        .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutIssues)
                }

                if !updater.isHomebrewInstall {
                    Form {
                        Section(l10n["about_auto_update_section"]) {
                            Toggle(l10n["about_auto_update_toggle"], isOn: $autoUpdateEnabled)
                                .onChange(of: autoUpdateEnabled) { _, v in
                                    updater.updater.automaticallyChecksForUpdates = v
                                }
                                .id(SettingsTargetID.aboutAutoUpdate)
                                .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutAutoUpdate)

                            updateSection
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(SettingsTargetID.aboutUpdates)
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: 360)
                    .scrollDisabled(true)
                } else {
                    Form {
                        Section(l10n["update_homebrew_managed_title"]) {
                            homebrewUpdateSection
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(SettingsTargetID.aboutUpdates)
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: 360)
                    .scrollDisabled(true)
                }

                Button {
                    DiagnosticsExporter.export(appState: appState)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "ladybug")
                            .font(.system(size: 11))
                        Text(l10n["export_diagnostics"])
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
                .buttonStyle(.plain)
                .id(SettingsTargetID.aboutDiagnostics)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutDiagnostics)
                .onHover { h in
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var homebrewUpdateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n["update_homebrew_command"])
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

            aboutButton(l10n["update_copy_command"], icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(l10n["update_homebrew_command"], forType: .string)
            }
            .id(SettingsTargetID.aboutUpdateCopyCommand)
            .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutUpdateCopyCommand)
            .accessibilityLabel(l10n["update_copy_command"])
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        switch updater.state {
        case .idle:
            aboutButton(l10n["check_for_updates"], icon: "arrow.triangle.2.circlepath") {
                updater.checkForUpdates()
            }
            .id(SettingsTargetID.aboutCheckForUpdates)
            .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutCheckForUpdates)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(l10n["check_for_updates"])
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13))
                    Text(String(format: l10n["no_update_body"], AppVersion.current))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .id(SettingsTargetID.aboutCheckForUpdates)
            .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutCheckForUpdates)
            .onHover { h in
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

        case let .available(version):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 13))
                    Text(String(format: l10n["update_available_body"], version, AppVersion.current))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Sparkle owns the download + install alert; this button just
                // re-surfaces it if the user dismissed it earlier.
                aboutButton(l10n["update_now"], icon: "arrow.down.to.line") {
                    updater.checkForUpdates()
                }
                .id(SettingsTargetID.aboutUpdateNow)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutUpdateNow)
            }

        // Download progress and install state are owned by Sparkle's standard
        // UI, not the About page — those enum cases no longer exist.

        case let .failed(message):
            // Phase 21 Bug #4: error text can be long ("无法安装更新: …"). Render
            // the icon on its own row so the multi-line message can wrap across
            // the full Section column without competing with the icon's width.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    Text(String(format: l10n["update_failed_body"], message))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                aboutButton(l10n["update_retry"], icon: "arrow.clockwise") {
                    updater.checkForUpdates()
                }
                .id(SettingsTargetID.aboutCheckForUpdates)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .aboutCheckForUpdates)
            }
        }
    }

    private func aboutButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func aboutLink(_ title: String, icon: String, url: String) -> some View {
        aboutButton(title, icon: icon) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }
}

// MARK: - Behavior Animation Previews

struct ClickJumpCollapsePreviewTimeline {
    let expand: Double
    let showClickRing: Bool
    let ringOpacity: Double
    let ringRadius: CGFloat
    let cursorX: CGFloat
    let cursorY: CGFloat
    let clickPointY: CGFloat
    let showSuccessArrow: Bool
    let successArrowOpacity: Double
}

func clickJumpCollapsePreviewTimeline(progress: Double) -> ClickJumpCollapsePreviewTimeline {
    // Wrap to [0,1) so loop seam is identical between end and start.
    let p = progress >= 1 ? progress.truncatingRemainder(dividingBy: 1) : min(1, max(0, progress))

    let clickPointY: CGFloat = 16 // lowered ~20% vs previous ~8

    // Seam-friendly phases:
    // [0.00, 0.08): expanded + cursor very fast move in (from offscreen)
    // [0.08, 0.26): expanded + cursor hover before click
    // [0.26, 0.32): click ring pulse
    // [0.32, 0.47): collapse (match mouse-leave collapse speed)
    // [0.47, 0.62): collapsed hold
    // [0.62, 0.80): cursor moves fully offscreen
    // [0.80, 0.93): expand back (match mouse-leave expand speed, after cursor is offscreen)
    // [0.93, 1.00): fully expanded idle with cursor still offscreen
    let expand: Double
    switch p {
    case ..<0.32:
        expand = 1.0
    case ..<0.47:
        expand = max(0, 1.0 - (p - 0.32) / 0.15)
    case ..<0.80:
        expand = 0
    case ..<0.93:
        expand = min(1, (p - 0.80) / 0.13)
    default:
        expand = 1.0
    }

    // Cursor path: offscreen -> click point -> offscreen, aligned to mouse-leave move-out timing.
    let cursorX: CGFloat
    let cursorY: CGFloat
    switch p {
    case ..<0.08:
        let m = p / 0.08
        cursorX = CGFloat((1 - m) * 34)
        cursorY = CGFloat((1 - m) * 28)
    case ..<0.62:
        cursorX = 0
        cursorY = 0
    case ..<0.80:
        let m = (p - 0.62) / 0.18
        cursorX = CGFloat(m * 34)
        cursorY = CGFloat(m * 28)
    default:
        cursorX = 34
        cursorY = 28
    }

    let ringWindow = p >= 0.26 && p <= 0.32
    let ringPhase = ringWindow ? (p - 0.26) / 0.06 : 0
    let ringOpacity = ringWindow ? sin(ringPhase * .pi) : 0
    let ringRadius: CGFloat = 4 + CGFloat(ringPhase) * 6

    let arrowWindow = p >= 0.34 && p <= 0.42
    let arrowPhase = arrowWindow ? (p - 0.34) / 0.08 : 0
    let arrowOpacity = arrowWindow ? sin(arrowPhase * .pi) : 0

    return ClickJumpCollapsePreviewTimeline(
        expand: expand,
        showClickRing: ringWindow,
        ringOpacity: ringOpacity,
        ringRadius: ringRadius,
        cursorX: cursorX,
        cursorY: cursorY,
        clickPointY: clickPointY,
        showSuccessArrow: arrowWindow,
        successArrowOpacity: arrowOpacity
    )
}

private enum BehaviorToggleRowMetrics {
    static let previewSize = SettingsBehaviorSpriteCatalog.frameSize
    static let previewTextSpacing: CGFloat = 12
    static var secondaryControlLeadingPadding: CGFloat {
        previewSize.width + previewTextSpacing
    }
}

private struct BehaviorToggleRow: View {
    let title: String
    let desc: String
    @Binding var isOn: Bool
    let animation: SettingsBehaviorAnimation
    var targetID: SettingsTargetID? = nil
    var highlightedTargetID: SettingsTargetID? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: BehaviorToggleRowMetrics.previewTextSpacing) {
                SettingsBehaviorSpriteView(animation: animation, size: BehaviorToggleRowMetrics.previewSize)
                    .frame(width: BehaviorToggleRowMetrics.previewSize.width, height: BehaviorToggleRowMetrics.previewSize.height)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(desc)
                }
            }
        }
        .id(targetID)
        .settingsControlHighlight(isHighlighted: targetID != nil && highlightedTargetID == targetID)
    }
}

// MARK: - App Logo

struct AppLogoView: View {
    var size: CGFloat = 100
    var showBackground: Bool = true
    private let orange = Color(red: 0.96, green: 0.65, blue: 0.14)

    var body: some View {
        Canvas { ctx, sz in
            // macOS icon standard: ~10% padding on each side
            let inset = sz.width * 0.1
            let contentRect = CGRect(x: inset, y: inset, width: sz.width - inset * 2, height: sz.height - inset * 2)
            let px = contentRect.width / 16
            if showBackground {
                let bgPath = Path(roundedRect: contentRect, cornerRadius: contentRect.width * 0.22, style: .continuous)
                ctx.fill(bgPath, with: .color(.white))
            }
            // Notch pill
            let pillColor = showBackground ? Color(white: 0.1) : Color(white: 0.5)
            let pillRect = CGRect(x: contentRect.minX + px * 3, y: contentRect.minY + px * 6, width: px * 10, height: px * 4)
            ctx.fill(Path(roundedRect: pillRect, cornerRadius: px * 2, style: .continuous), with: .color(pillColor))
            // Eyes
            ctx.fill(Path(CGRect(x: contentRect.minX + px * 5, y: contentRect.minY + px * 7, width: px * 2, height: px * 2)), with: .color(orange))
            ctx.fill(Path(CGRect(x: contentRect.minX + px * 9, y: contentRect.minY + px * 7, width: px * 2, height: px * 2)), with: .color(orange))
            // Pupils
            ctx.fill(Path(CGRect(x: contentRect.minX + px * 6, y: contentRect.minY + px * 7, width: px, height: px)), with: .color(.white))
            ctx.fill(Path(CGRect(x: contentRect.minX + px * 10, y: contentRect.minY + px * 7, width: px, height: px)), with: .color(.white))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(showBackground ? 0.15 : 0), radius: size * 0.12, y: size * 0.04)
    }
}

// MARK: - Shortcuts Page

private struct ShortcutsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var recordingAction: ShortcutAction?
    @State private var eventMonitor: Any?
    @State private var refreshKey = 0

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(
                        action: action,
                        isRecording: recordingAction == action,
                        onStartRecording: { startRecording(action) },
                        onClear: { clearBinding(action) }
                    )
                    .id("\(action.rawValue)-\(refreshKey)")
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape — cancel
                self.stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
                return nil
            }
            action.setBinding(keyCode: event.keyCode, modifiers: mods)
            if !action.isEnabled { action.setEnabled(true) }
            self.stopRecording()
            self.refreshKey += 1
            self.notifyChange()
            return nil
        }
    }

    private func clearBinding(_ action: ShortcutAction) {
        action.setEnabled(false)
        refreshKey += 1
        notifyChange()
    }

    private func stopRecording() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
        recordingAction = nil
    }

    private func notifyChange() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.setupGlobalShortcut()
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onClear: () -> Void
    @ObservedObject private var l10n = L10n.shared

    private var conflict: ShortcutAction? { action.conflictingAction() }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n["shortcut_\(action.rawValue)"])
                Text(l10n["shortcut_\(action.rawValue)_desc"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let conflict {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(l10n["shortcut_conflict"]) \(l10n["shortcut_\(conflict.rawValue)"])")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                }
            }
            Spacer()
            if isRecording {
                Text(l10n["shortcut_recording"])
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(.orange, lineWidth: 1))
            } else if action.isEnabled {
                HStack(spacing: 6) {
                    Text(action.binding.displayString)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        .onTapGesture { onStartRecording() }

                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(l10n["shortcut_none"])
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .onTapGesture { onStartRecording() }
            }
        }
        .contentShape(Rectangle())
    }
}
