import SwiftUI
import AppKit
import BoughCore

// MARK: - Usage Page

struct UsagePage: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.codexHooksDisabledNoticeDismissed)
    private var codexHooksDisabledNoticeDismissed = false
    @State private var thresholdNotificationsEnabled = false
    @State private var codexHooksDisabled = ConfigInstaller.codexHooksFeatureDisabled()
    /// Dismissal state for the Codex CLI outdated banner. Not @AppStorage because the key
    /// depends on the detected version at runtime (D-12). Synced from UserDefaults on appear.
    @State private var codexCLIOutdatedDismissed = false
    /// Detected Codex CLI version, populated asynchronously on first appear to avoid
    /// blocking the main thread with a subprocess spawn (WR-01). nil until detection completes.
    @State private var codexCLIVersion: String? = nil
    @State private var usageMonitorStatus = UsageMonitorLifecycleStatus(state: .stopped, writerOwner: .app, message: nil)
    @State private var notificationPermissionState: UsageNotificationPermissionState = .notDetermined
    @State private var confirmUsageMonitorRepair = false
    @State private var confirmUsageMonitorUninstall = false
    let appState: AppState
    var highlightedTargetID: SettingsTargetID? = nil
    var actions: UsagePageActions?
    private let usageMonitorService = UsageMonitorService()
    private let usageNotificationService = UsageNotificationService(copy: .localized())

    var body: some View {
        @Bindable var usageStore = appState.usageStore
        let selectedDisplayTool = usageStore.selectedDisplayTool
        let model = selectedDisplayTool.map { tool in
            UsageDetailsModel(
                snapshot: usageStore.snapshot(for: tool),
                isFirstLaunchBaseline: usageStore.isFirstLaunchBaseline(for: tool)
            )
        }
        let pageActions = actions ?? UsagePageActions(refresh: appState.refreshUsageManually)
        let codexNotice = CodexHooksDisabledNoticeModel(
            hooksDisabled: codexHooksDisabled,
            dismissed: codexHooksDisabledNoticeDismissed
        )
        // codexCLIVersion is populated asynchronously from .onAppear (nil → banner hidden, D-09).
        let cliOutdatedDismissalKey = SettingsKey.codexCLIOutdatedDismissalKey(
            forDetectedVersion: codexCLIVersion ?? ""
        )
        let cliOutdatedNotice = CodexCLIOutdatedNoticeModel(
            detectedVersion: codexCLIVersion,
            minimumVersion: ConfigInstaller.codexCLIMinimumHooksVersion,
            dismissed: codexCLIOutdatedDismissed
        )
        let usageMonitorModel = UsageMonitorLifecycleModel(
            status: usageMonitorStatus,
            availableActions: UsageMonitorLifecycleAction.allCases.filter {
                usageMonitorService.isActionAvailable($0, for: usageMonitorStatus.state)
            },
            localized: { l10n[$0] }
        )
        let notificationsModel = UsageRecoveryNotificationsModel(
            permissionState: notificationPermissionState,
            preferences: { tool, windowKind in
                usageStore.recoveryReminderPreference(tool: tool, windowKind: windowKind)
            },
            localized: { l10n[$0] }
        )
        Form {
            if codexNotice.showsBanner {
                Section {
                    // User-visible copy includes "hooks = false" through L10n.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n["usage_codex_hooks_disabled_banner"])
                            .font(.callout)
                        HStack {
                            Button(l10n["usage_codex_hooks_enable_now"]) {
                                if pageActions.enableCodexHooks() {
                                    codexHooksDisabled = ConfigInstaller.codexHooksFeatureDisabled()
                                    codexHooksDisabledNoticeDismissed = true
                                }
                            }
                            Button(l10n["usage_codex_hooks_dismiss"]) {
                                codexHooksDisabledNoticeDismissed = true
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Outdated Codex CLI banner — sibling to the hooks-disabled banner (D-10).
            // Renders only when detectedVersion != nil && version < minimumVersion && !dismissed (D-09, D-12).
            if cliOutdatedNotice.showsBanner {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(
                            format: l10n["usage_codex_cli_outdated_banner"],
                            codexCLIVersion ?? "?",
                            ConfigInstaller.codexCLIMinimumHooksVersion
                        ))
                        .font(.callout)
                        HStack {
                            Button(l10n["usage_codex_cli_outdated_upgrade_now"]) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "npm install -g @openai/codex@latest",
                                    forType: .string
                                )
                            }
                            Button(l10n["usage_codex_cli_outdated_dismiss"]) {
                                UserDefaults.standard.set(true, forKey: cliOutdatedDismissalKey)
                                codexCLIOutdatedDismissed = true
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Regression guard: the standalone "Claude Code 集成"
            // Section was deleted in this round. The Hooks tab Claude Code
            // toggle is now the single install/uninstall lever — it enables
            // BOTH the per-CLI hook AND the statusLine wrapper through
            // `ChainInstallCoordinator`, mirroring the round-6 atomic-install
            // pairing. This removes ~150 LOC of redundant UI and matches the
            // user's mental model ("one switch turns Bough's Claude Code
            // integration on or off").

            Section(l10n["usage_data_section"]) {
                if let selectedDisplayTool, let model {
                    Picker(l10n["data_source_status"], selection: $usageStore.selectedTool) {
                        ForEach(usageStore.selectableTools, id: \.self) { tool in
                            Text(label(for: tool)).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                    .id(SettingsTargetID.usageDataSourcePicker)
                    .settingsControlHighlight(
                        isHighlighted: highlightedTargetID == .usageDataSourcePicker
                    )

                    HStack {
                        Text(model.status)
                        if selectedDisplayTool == .codex && codexNotice.showsDisabledBadge {
                            Text(l10n["usage_codex_hooks_disabled_badge"])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if selectedDisplayTool == .codex && cliOutdatedNotice.showsOutdatedBadge {
                            Text(l10n["usage_codex_cli_outdated_badge"])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        // Direct-OAuth channel badge for the selected tool (spec §9).
                        let badge = UsageOAuthBadgeModel(
                            status: selectedDisplayTool == .codex
                                ? usageStore.codexOAuthStatus
                                : usageStore.claudeOAuthStatus,
                            localized: { l10n[$0] }
                        )
                        Circle()
                            .fill(badgeColor(for: badge.tone))
                            .frame(width: 8, height: 8)
                        Text(badge.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(l10n["refresh"]) {
                            // Unified refresh: both providers route through the
                            // page action, which forces a direct-OAuth refresh
                            // of every enabled channel.
                            pageActions.refresh()
                        }
                        .id(SettingsTargetID.usageRefresh)
                        .settingsControlHighlight(
                            isHighlighted: highlightedTargetID == .usageRefresh
                        )
                    }
                } else {
                    Text(l10n["usage_provider_disabled_empty"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(SettingsTargetID.usageData)

            UsageProviderPreferencesSection(
                displayEnabled: { tool in usageStore.usageDisplayEnabled(tool: tool) },
                setDisplayEnabled: { tool, isEnabled in
                    usageStore.setUsageDisplayEnabled(tool: tool, isEnabled: isEnabled)
                },
                statisticsEnabled: { tool in usageStore.usageStatisticsEnabled(tool: tool) },
                setStatisticsEnabled: { tool, isEnabled in
                    usageStore.setUsageStatisticsEnabled(tool: tool, isEnabled: isEnabled)
                },
                highlightedTargetID: highlightedTargetID
            )

            Section(l10n["usage_monitor_section"]) {
                LabeledContent(l10n["usage_monitor_status"], value: usageMonitorModel.stateLabel)
                if let message = usageMonitorModel.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(usageMonitorModel.availableActions, id: \.self) { action in
                        let targetID = usageMonitorTargetID(for: action)
                        Button(l10n[UsageMonitorLifecycleModel.actionLabelKey(for: action)]) {
                            performUsageMonitorAction(action)
                        }
                        .id(targetID)
                        .settingsControlHighlight(isHighlighted: highlightedTargetID == targetID)
                    }
                }
            }
            .id(SettingsTargetID.usageBackgroundMonitor)

            if let model {
                UsageDetailsSection(model: model)
            }

            UsageRecoveryNotificationsSection(
                model: notificationsModel,
                setPreference: { tool, windowKind, isEnabled in
                    usageStore.setRecoveryReminderPreference(tool: tool, windowKind: windowKind, isEnabled: isEnabled)
                },
                repair: {
                    requestNotificationPermission()
                },
                openSettings: {
                    openNotificationsPrivacySettings()
                },
                highlightedTargetID: highlightedTargetID
            )
            .id(SettingsTargetID.usageRecoveryNotifications)

            UsageThresholdNotificationsSection(
                masterEnabled: $thresholdNotificationsEnabled,
                setMasterEnabled: { isEnabled in
                    usageStore.setThresholdNotificationsMasterEnabled(isEnabled)
                },
                permissionState: notificationPermissionState,
                preference: { tool in
                    usageStore.thresholdNotificationPreference(tool: tool).isEnabled
                },
                setPreference: { tool, isEnabled in
                    usageStore.setThresholdNotificationPreference(tool: tool, isEnabled: isEnabled)
                },
                repair: {
                    requestNotificationPermission()
                },
                openSettings: {
                    openNotificationsPrivacySettings()
                },
                highlightedTargetID: highlightedTargetID
            )
            .id(SettingsTargetID.usageThresholdAlerts)

            #if DEBUG
            UsageDebugSection(usageStore: usageStore)
            #endif
        }
        .formStyle(.grouped)
        .onAppear {
            appState.setUsageRefreshActivity(.active)
            usageMonitorStatus = usageMonitorService.refreshStatus()
            refreshNotificationPermissionState()
            thresholdNotificationsEnabled = usageStore.thresholdNotificationsMasterEnabled()
            codexHooksDisabled = ConfigInstaller.codexHooksFeatureDisabled()
            // Detect Codex CLI version off the main thread (subprocess spawn).
            // On completion, update @State so body re-renders reactively (WR-01, WR-03).
            // Sync CLI-outdated dismissal AFTER version is known so the key is stable
            // (D-12: key is version-derived, so @AppStorage cannot be used directly).
            Task.detached(priority: .userInitiated) {
                let detected = ConfigInstaller.detectCodexVersion()
                await MainActor.run {
                    codexCLIVersion = detected
                    let dismissKey = SettingsKey.codexCLIOutdatedDismissalKey(
                        forDetectedVersion: detected ?? ""
                    )
                    codexCLIOutdatedDismissed = UserDefaults.standard.bool(forKey: dismissKey)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationPermissionState()
        }
        .onDisappear {
            appState.setUsageRefreshActivity(.idle)
        }
        .confirmationDialog(
            l10n["usage_monitor_repair_confirmation"],
            isPresented: $confirmUsageMonitorRepair
        ) {
            Button(l10n["usage_monitor_action_repair"]) {
                usageMonitorStatus = (try? usageMonitorService.repair()) ?? usageMonitorService.refreshStatus()
            }
            Button(l10n["cancel"], role: .cancel) {}
        }
        .confirmationDialog(
            usageMonitorModel.uninstallConfirmation,
            isPresented: $confirmUsageMonitorUninstall
        ) {
            Button(l10n["usage_monitor_action_uninstall"], role: .destructive) {
                usageMonitorStatus = (try? usageMonitorService.uninstall())
                    ?? usageMonitorService.refreshStatus()
            }
        }
    }

    private func performUsageMonitorAction(_ action: UsageMonitorLifecycleAction) {
        switch action {
        case .enable:
            usageMonitorStatus = (try? usageMonitorService.enable()) ?? usageMonitorService.refreshStatus()
        case .disable:
            usageMonitorStatus = (try? usageMonitorService.disable()) ?? usageMonitorService.refreshStatus()
        case .repair:
            confirmUsageMonitorRepair = true
        case .uninstall:
            confirmUsageMonitorUninstall = true
        }
    }

    private func usageMonitorTargetID(for action: UsageMonitorLifecycleAction) -> SettingsTargetID {
        switch action {
        case .enable:
            return .usageMonitorEnable
        case .disable:
            return .usageMonitorDisable
        case .repair:
            return .usageMonitorRepair
        case .uninstall:
            return .usageMonitorUninstall
        }
    }

    private func openNotificationsPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshNotificationPermissionState() {
        Task {
            let state = await usageNotificationService.permissionState()
            await MainActor.run {
                notificationPermissionState = state
            }
        }
    }

    private func requestNotificationPermission() {
        Task {
            let current = await usageNotificationService.permissionState()
            await MainActor.run {
                notificationPermissionState = current
            }
            switch current {
            case .notDetermined, .failed:
                let state = await usageNotificationService.requestAccessForExplicitUserAction()
                await MainActor.run {
                    notificationPermissionState = state
                }
            case .denied:
                await MainActor.run {
                    openNotificationsPrivacySettings()
                }
            case .authorized, .provisional, .ephemeral, .unavailable:
                break
            }
        }
    }

    private func label(for tool: UsageTool) -> String {
        switch tool {
        case .codex:
            return l10n["usage_provider_codex"]
        case .claudeCode:
            return l10n["usage_provider_claude_code"]
        }
    }

    // OAuth channel badge color mapping (mirrors UsageStrip.swift exact values).
    private func badgeColor(for tone: UsageOAuthBadgeModel.Tone) -> Color {
        switch tone {
        case .ok:      return Color(red: 0.32, green: 0.78, blue: 0.42)
        case .warning: return Color(red: 0.91, green: 0.612, blue: 0.227)
        case .off:     return .white.opacity(0.35)
        }
    }
}

private struct UsageProviderPreferencesSection: View {
    @ObservedObject private var l10n = L10n.shared
    let displayEnabled: (UsageTool) -> Bool
    let setDisplayEnabled: (UsageTool, Bool) -> Void
    let statisticsEnabled: (UsageTool) -> Bool
    let setStatisticsEnabled: (UsageTool, Bool) -> Void
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Section(l10n["usage_provider_controls_section"]) {
            ForEach(UsageTool.selectableQuotaProviders, id: \.self) { tool in
                let displayTargetID = displayTargetID(for: tool)
                Toggle(String(format: l10n["usage_provider_display_toggle"], toolLabel(for: tool)), isOn: Binding(
                    get: { displayEnabled(tool) },
                    set: { setDisplayEnabled(tool, $0) }
                ))
                .accessibilityLabel(String(format: l10n["usage_provider_display_toggle"], toolLabel(for: tool)))
                .id(displayTargetID)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == displayTargetID)

                let statisticsTargetID = statisticsTargetID(for: tool)
                Toggle(String(format: l10n["usage_provider_statistics_toggle"], toolLabel(for: tool)), isOn: Binding(
                    get: { statisticsEnabled(tool) },
                    set: { setStatisticsEnabled(tool, $0) }
                ))
                .accessibilityLabel(String(format: l10n["usage_provider_statistics_toggle"], toolLabel(for: tool)))
                .id(statisticsTargetID)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == statisticsTargetID)
            }
        }
    }

    private func toolLabel(for tool: UsageTool) -> String {
        switch tool {
        case .codex:
            return l10n["usage_provider_codex"]
        case .claudeCode:
            return l10n["usage_provider_claude_code"]
        }
    }

    private func displayTargetID(for tool: UsageTool) -> SettingsTargetID {
        switch tool {
        case .codex:
            return .usageDisplayCodex
        case .claudeCode:
            return .usageDisplayClaudeCode
        }
    }

    private func statisticsTargetID(for tool: UsageTool) -> SettingsTargetID {
        switch tool {
        case .codex:
            return .usageStatisticsCodex
        case .claudeCode:
            return .usageStatisticsClaudeCode
        }
    }
}

private struct UsageDetailsSection: View {
    @ObservedObject private var l10n = L10n.shared
    let model: UsageDetailsModel

    var body: some View {
        Section(l10n["usage"]) {
            ForEach(model.rows, id: \.title) { row in
                LabeledContent(row.title, value: row.value)
            }
            // Spec §8.3: pace captions under the window rows. Same 11pt
            // secondary typography as the Today subtree below.
            if let fiveHourPace = model.fiveHourPaceText {
                Text("\(l10n["usage_pace_5h_row"]): \(fiveHourPace)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let weeklyPace = model.weeklyPaceText {
                Text("\(l10n["usage_pace_week_row"]): \(weeklyPace)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(l10n["last_refresh"], value: model.lastRefresh)
            // TODAY-16: Today row + two-line subtree. The subtree literals are
            // verbatim mixed Chinese/numeric and intentionally identical across
            // en and zh locales per 05-UI-SPEC (do NOT auto-translate to en).
            if let pctText = model.todayPctText,
               let allowanceLine = model.todayAllowanceLineText,
               let usedLine = model.todayUsedLineText {
                LabeledContent(l10n["today_safe"], value: pctText)
                VStack(alignment: .leading, spacing: 2) {  // 2pt — inherited compact-subtree
                    Text(allowanceLine)
                    Text(usedLine)
                    if let resetExplanation = model.todayResetExplanationText {
                        Text(resetExplanation)
                    }
                }
                .font(.system(size: 11))                    // 11pt regular per 05-UI-SPEC Typography
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                // TODAY-11: first-launch inline notice. Not dismissible; auto-
                // disappears at next local-midnight rollover when the
                // accumulator's in-memory flag flips off.
                if model.isFirstLaunchBaseline {
                    Text(l10n["today_first_launch_notice"])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 4)                    // 4pt — Phase 5 owned sm token
                }
            }
        }
    }
}

private struct UsageRecoveryNotificationsSection: View {
    @ObservedObject private var l10n = L10n.shared
    let model: UsageRecoveryNotificationsModel
    let setPreference: (UsageTool, UsageWindowKind, Bool) -> Void
    let repair: () -> Void
    let openSettings: () -> Void
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Section(l10n["usage_notifications_section"]) {
            Text(model.statusText(localized: { l10n[$0] }))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.toggles) { toggle in
                let targetID = recoveryTargetID(for: toggle.tool, windowKind: toggle.windowKind)
                Toggle(toggle.title, isOn: Binding(
                    get: { toggle.isEnabled },
                    set: { setPreference(toggle.tool, toggle.windowKind, $0) }
                ))
                .disabled(!model.controlsAreEnabled)
                .accessibilityLabel(toggle.title)
                .id(targetID)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == targetID)
            }

            if !model.controlsAreEnabled {
                HStack {
                    Button(l10n["usage_notifications_action_repair"]) {
                        repair()
                    }
                    .id(SettingsTargetID.usageRecoveryRepair)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .usageRecoveryRepair)
                    Button(l10n["usage_notifications_action_open_settings"]) {
                        openSettings()
                    }
                    .id(SettingsTargetID.usageRecoveryOpenSettings)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .usageRecoveryOpenSettings)
                }
            }
        }
    }

    private func recoveryTargetID(for tool: UsageTool, windowKind: UsageWindowKind) -> SettingsTargetID {
        switch (tool, windowKind) {
        case (.codex, .fiveHour):
            return .usageRecoveryCodexFiveHour
        case (.codex, .weekly):
            return .usageRecoveryCodexWeekly
        case (.claudeCode, .fiveHour):
            return .usageRecoveryClaudeFiveHour
        case (.claudeCode, .weekly):
            return .usageRecoveryClaudeWeekly
        }
    }
}

private struct UsageThresholdNotificationsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @Binding var masterEnabled: Bool
    let setMasterEnabled: (Bool) -> Void
    let permissionState: UsageNotificationPermissionState
    let preference: (UsageTool) -> Bool
    let setPreference: (UsageTool, Bool) -> Void
    let repair: () -> Void
    let openSettings: () -> Void
    let highlightedTargetID: SettingsTargetID?

    var body: some View {
        Section(l10n["usage_notifications_threshold_section_title"]) {
            Text(l10n["usage_notifications_threshold_section_description"])
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(l10n["usage_notifications_threshold_master_toggle_label"], isOn: $masterEnabled)
                .onChange(of: masterEnabled) { _, newValue in
                    setMasterEnabled(newValue)
                }
                .id(SettingsTargetID.usageThresholdMaster)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == .usageThresholdMaster)

            ForEach([UsageTool.codex, .claudeCode], id: \.self) { tool in
                let targetID = thresholdTargetID(for: tool)
                Toggle(toolLabel(for: tool), isOn: Binding(
                    get: { preference(tool) },
                    set: { setPreference(tool, $0) }
                ))
                .disabled(!masterEnabled)
                .accessibilityLabel(toolLabel(for: tool))
                .id(targetID)
                .settingsControlHighlight(isHighlighted: highlightedTargetID == targetID)
            }

            if masterEnabled && !permissionState.canSendNotifications {
                let prompt = UsageThresholdPermissionPromptModel(permissionState: permissionState)
                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.message(localized: { l10n[$0] }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(prompt.actionTitle(localized: { l10n[$0] })) {
                        if prompt.opensSystemSettings {
                            openSettings()
                        } else {
                            repair()
                        }
                    }
                    .id(SettingsTargetID.usageThresholdRepair)
                    .settingsControlHighlight(isHighlighted: highlightedTargetID == .usageThresholdRepair)
                }
            }
        }
    }

    private func toolLabel(for tool: UsageTool) -> String {
        switch tool {
        case .codex:
            return l10n["usage_notifications_threshold_per_tool_codex_label"]
        case .claudeCode:
            return l10n["usage_notifications_threshold_per_tool_claude_code_label"]
        }
    }

    private func thresholdTargetID(for tool: UsageTool) -> SettingsTargetID {
        switch tool {
        case .codex:
            return .usageThresholdCodex
        case .claudeCode:
            return .usageThresholdClaudeCode
        }
    }
}

#if DEBUG
private struct UsageDebugSection: View {
    @Bindable var usageStore: UsageStore

    var body: some View {
        Section("Debug · Usage strip preview") {
            Picker("Inject preset", selection: presetBinding) {
                Text("Off (live data)").tag(Optional<UsageDebugPresets.Preset>.none)
                ForEach(UsageDebugPresets.Preset.allCases) { preset in
                    Text(preset.displayName).tag(Optional(preset))
                }
            }
            .pickerStyle(.menu)

            Text("Overrides the live snapshot in-memory only — restart Bough or pick \"Off\" to clear. DEBUG builds only.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var presetBinding: Binding<UsageDebugPresets.Preset?> {
        Binding(
            get: {
                MainActor.assumeIsolated {
                    usageStore.debugPreset
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    setPreset(newValue)
                }
            }
        )
    }

    @MainActor
    private func setPreset(_ newValue: UsageDebugPresets.Preset?) {
        // Always clear refresh override before applying a new preset; the
        // refreshing case re-sets it below.
        UsageDebugPresets.clearOverrides(store: usageStore)
        guard let newValue else {
            usageStore.debugPreset = nil
            return
        }
        switch newValue {
        case .refreshing:
            UsageDebugPresets.applyRefreshing(store: usageStore)
        case .justDepleted:
            Task { @MainActor in
                await UsageDebugPresets.applyJustDepletedSequence(store: usageStore)
            }
        default:
            usageStore.debugPreset = newValue
        }
    }
}
#endif
