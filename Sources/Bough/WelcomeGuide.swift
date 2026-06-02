import AppKit
import SwiftUI

enum WelcomeGuideStep: String, CaseIterable, Identifiable {
    case welcome
    case modeDisplay
    case codingSetup
    case sharingMusic
    case finish

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .welcome:
            return "welcome_guide_step_welcome"
        case .modeDisplay:
            return "welcome_guide_step_mode_display"
        case .codingSetup:
            return "welcome_guide_step_coding_setup"
        case .sharingMusic:
            return "welcome_guide_step_sharing_music"
        case .finish:
            return "welcome_guide_step_finish"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome:
            return "leaf"
        case .modeDisplay:
            return "switch.2"
        case .codingSetup:
            return "terminal"
        case .sharingMusic:
            return "square.and.arrow.up"
        case .finish:
            return "checkmark.seal"
        }
    }
}

enum WelcomeGuideToolConnectionState: String, CaseIterable {
    case connected
    case detected
    case notFound
    case needsReview
    case failed

    var titleKey: String {
        switch self {
        case .connected:
            return "welcome_guide_tool_connected"
        case .detected:
            return "welcome_guide_tool_detected"
        case .notFound:
            return "welcome_guide_tool_not_found"
        case .needsReview:
            return "welcome_guide_tool_needs_review"
        case .failed:
            return "welcome_guide_tool_failed"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            return .green
        case .detected:
            return .blue
        case .notFound:
            return .secondary
        case .needsReview:
            return .orange
        case .failed:
            return .red
        }
    }
}

struct WelcomeGuideToolStatus: Identifiable, Equatable {
    let source: String
    let displayName: String
    let state: WelcomeGuideToolConnectionState
    var isSelected: Bool

    var id: String { source }
}

struct WelcomeGuideToolDefinition: Equatable {
    let source: String
    let displayName: String
}

enum WelcomeGuideCompletionStatus: Equatable {
    case notCompleted
    case completed
    case updateAvailable
}

enum WelcomeGuideSettings {
    static let currentOnboardingVersion = "1.0.0"
    private static let welcomeGuideKeys: Set<String> = [
        SettingsKey.welcomeGuideCompletedVersion,
        SettingsKey.welcomeGuideCompletedAt,
        SettingsKey.welcomeGuideAutoOpenConsumed,
    ]

    static func completionStatus(defaults: UserDefaults = .standard) -> WelcomeGuideCompletionStatus {
        status(defaults: defaults)
    }

    static func status(defaults: UserDefaults = .standard) -> WelcomeGuideCompletionStatus {
        guard let version = defaults.string(forKey: SettingsKey.welcomeGuideCompletedVersion),
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notCompleted
        }

        if version == currentOnboardingVersion {
            return .completed
        }

        return .updateAvailable
    }

    static func markCompleted(defaults: UserDefaults = .standard, date: Date = Date()) {
        defaults.set(currentOnboardingVersion, forKey: SettingsKey.welcomeGuideCompletedVersion)
        defaults.set(date.timeIntervalSince1970, forKey: SettingsKey.welcomeGuideCompletedAt)
    }

    static func shouldAutoOpenOnLaunch(
        defaults: UserDefaults = .standard,
        persistentKeys: Set<String>? = nil
    ) -> Bool {
        guard status(defaults: defaults) == .notCompleted else {
            return false
        }
        guard defaults.bool(forKey: SettingsKey.welcomeGuideAutoOpenConsumed) == false else {
            return false
        }

        let keys = persistentKeys ?? storedDefaultKeys(defaults: defaults)
        return keys.subtracting(welcomeGuideKeys).isEmpty
    }

    static func markAutoOpenConsumed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: SettingsKey.welcomeGuideAutoOpenConsumed)
    }

    private static func storedDefaultKeys(defaults: UserDefaults) -> Set<String> {
        let domainName = Bundle.main.bundleIdentifier ?? "com.dgpisces.bough"
        guard let domain = defaults.persistentDomain(forName: domainName) else {
            return []
        }
        return Set(domain.keys)
    }
}

@MainActor
final class WelcomeGuideModel: ObservableObject {
    static let approvedToolItems: [WelcomeGuideToolDefinition] = [
        WelcomeGuideToolDefinition(source: "claude", displayName: "Claude Code"),
        WelcomeGuideToolDefinition(source: "codex", displayName: "Codex"),
        WelcomeGuideToolDefinition(source: "gemini", displayName: "Gemini"),
        WelcomeGuideToolDefinition(source: "cursor", displayName: "Cursor"),
        WelcomeGuideToolDefinition(source: "trae", displayName: "Trae"),
        WelcomeGuideToolDefinition(source: "traecn", displayName: "Trae CN"),
        WelcomeGuideToolDefinition(source: "traecli", displayName: "Trae CLI"),
        WelcomeGuideToolDefinition(source: "qoder", displayName: "Qoder"),
        WelcomeGuideToolDefinition(source: "droid", displayName: "Factory"),
        WelcomeGuideToolDefinition(source: "stepfun", displayName: "StepFun"),
        WelcomeGuideToolDefinition(source: "antigravity", displayName: "AntiGravity"),
        WelcomeGuideToolDefinition(source: "hermes", displayName: "Hermes"),
        WelcomeGuideToolDefinition(source: "qwen", displayName: "Qwen"),
        WelcomeGuideToolDefinition(source: "copilot", displayName: "GitHub Copilot"),
        WelcomeGuideToolDefinition(source: "kimi", displayName: "Kimi"),
        WelcomeGuideToolDefinition(source: "kiro", displayName: "Kiro"),
        WelcomeGuideToolDefinition(source: "opencode", displayName: "OpenCode"),
    ]

    @Published var selectedStep: WelcomeGuideStep = .welcome
    @Published var codingSessionsEnabled: Bool?
    @Published var displayChoice: String?
    @Published var toolStatuses: [WelcomeGuideToolStatus]
    @Published var showCodexUsage = true
    @Published var showClaudeUsage = true
    @Published var backgroundMonitor = true
    @Published var recoveryReminders = true
    @Published var thresholdAlerts = false
    @Published var airDropEnabled: Bool
    @Published var musicControlsEnabled: Bool
    @Published var compactBarPriority: CompactBarPriority

    private let defaults: UserDefaults
    private let applyBackendPlan: WelcomeGuideBackendApply

    init(
        defaults: UserDefaults = .standard,
        installedSources: Set<String>? = nil,
        cliExists: (String) -> Bool = WelcomeGuideToolDetector.cliExists(source:),
        backendApply: @escaping WelcomeGuideBackendApply = WelcomeGuideBackendIntegrator.apply
    ) {
        self.defaults = defaults
        self.applyBackendPlan = backendApply
        self.codingSessionsEnabled = CodingSessionsSettings.isEnabled(defaults: defaults)
        self.displayChoice = defaults.string(forKey: SettingsKey.displayChoice) ?? SettingsDefaults.displayChoice
        self.toolStatuses = Self.defaultToolItems(installedSources: installedSources, cliExists: cliExists)
        self.airDropEnabled = AirDropSettings.isEnabled(defaults: defaults)
        self.musicControlsEnabled = defaults.object(forKey: SettingsKey.showMusicControls) as? Bool ?? SettingsDefaults.showMusicControls
        self.compactBarPriority = CompactBarPriority.normalized(defaults.string(forKey: SettingsKey.compactBarPriority))
        reconcileSelectedStep()
    }

    static func visibleSteps(codingSessionsEnabled: Bool?) -> [WelcomeGuideStep] {
        if codingSessionsEnabled == false {
            return [.welcome, .modeDisplay, .sharingMusic, .finish]
        }

        return [.welcome, .modeDisplay, .codingSetup, .sharingMusic, .finish]
    }

    var visibleSteps: [WelcomeGuideStep] {
        Self.visibleSteps(codingSessionsEnabled: codingSessionsEnabled)
    }

    var currentStepIndex: Int {
        visibleSteps.firstIndex(of: selectedStep) ?? 0
    }

    var isFirstStep: Bool {
        currentStepIndex == 0
    }

    var isLastStep: Bool {
        currentStepIndex == visibleSteps.count - 1
    }

    var normalizedDisplayChoice: String? {
        let value = displayChoice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var canFinish: Bool {
        codingSessionsEnabled != nil && normalizedDisplayChoice != nil
    }

    var selectedToolsCount: Int {
        toolStatuses.filter(\.isSelected).count
    }

    var isShowingCodingSetup: Bool {
        visibleSteps.contains(.codingSetup)
    }

    var enableBackgroundMonitor: Bool {
        get { backgroundMonitor }
        set { backgroundMonitor = newValue }
    }

    var enableRecoveryReminders: Bool {
        get { recoveryReminders }
        set { recoveryReminders = newValue }
    }

    var enableThresholdAlerts: Bool {
        get { thresholdAlerts }
        set { thresholdAlerts = newValue }
    }

    func selectCodingSessions(_ isEnabled: Bool) {
        setCodingSessionsEnabled(isEnabled)
    }

    func setCodingSessionsEnabled(_ isEnabled: Bool) {
        codingSessionsEnabled = isEnabled
        reconcileSelectedStep()
    }

    func setToolSelected(source: String, isSelected: Bool) {
        guard let index = toolStatuses.firstIndex(where: { $0.source == source }) else {
            return
        }
        toolStatuses[index].isSelected = isSelected
    }

    func next() {
        reconcileSelectedStep()
        guard currentStepIndex < visibleSteps.count - 1 else {
            return
        }
        selectedStep = visibleSteps[currentStepIndex + 1]
    }

    func back() {
        reconcileSelectedStep()
        guard currentStepIndex > 0 else {
            return
        }
        selectedStep = visibleSteps[currentStepIndex - 1]
    }

    @discardableResult
    func finish(defaults overrideDefaults: UserDefaults? = nil, completedAt: Date = Date()) async -> Bool {
        guard let codingSessionsEnabled,
              let displayChoice = normalizedDisplayChoice else {
            return false
        }

        let defaults = overrideDefaults ?? self.defaults
        let backendPlan = WelcomeGuideBackendPlan(
            codingSessionsEnabled: codingSessionsEnabled,
            toolSelections: Dictionary(uniqueKeysWithValues: toolStatuses.map { ($0.source, $0.isSelected) }),
            showCodexUsage: showCodexUsage,
            showClaudeUsage: showClaudeUsage,
            backgroundMonitorEnabled: backgroundMonitor,
            recoveryRemindersEnabled: recoveryReminders,
            thresholdAlertsEnabled: thresholdAlerts
        )
        defaults.set(codingSessionsEnabled, forKey: SettingsKey.codingSessionsEnabled)
        defaults.set(displayChoice, forKey: SettingsKey.displayChoice)
        defaults.set(airDropEnabled, forKey: SettingsKey.airDropEnabled)
        defaults.set(musicControlsEnabled, forKey: SettingsKey.showMusicControls)
        defaults.set(compactBarPriority.rawValue, forKey: SettingsKey.compactBarPriority)
        WelcomeGuideSettings.markCompleted(defaults: defaults, date: completedAt)
        await applyBackendPlan(backendPlan, defaults, completedAt)
        return true
    }

    @discardableResult
    func finish(date: Date) async -> Bool {
        await finish(completedAt: date)
    }

    private func reconcileSelectedStep() {
        if !visibleSteps.contains(selectedStep) {
            selectedStep = .sharingMusic
        }
    }

    static func defaultToolItems(
        installedSources: Set<String>? = nil,
        cliExists: (String) -> Bool = WelcomeGuideToolDetector.cliExists(source:)
    ) -> [WelcomeGuideToolStatus] {
        approvedToolItems.compactMap { item in
            let isInstalled = installedSources?.contains(item.source) ?? cliExists(item.source)
            guard isInstalled else {
                return nil
            }
            return WelcomeGuideToolStatus(
                source: item.source,
                displayName: item.displayName,
                state: .detected,
                isSelected: true
            )
        }
    }
}

struct WelcomeGuideView: View {
    @StateObject private var model: WelcomeGuideModel
    @State private var isFinishing = false
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let defaults: UserDefaults
    private let onFinish: () -> Void

    init(defaults: UserDefaults = .standard, onFinish: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: WelcomeGuideModel(defaults: defaults))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                content
                Divider()
                footer
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: model.selectedStep)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: model.visibleSteps)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n["welcome_guide_sidebar_title"])
                    .font(.headline)
                Text("\(model.currentStepIndex + 1)/\(model.visibleSteps.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(model.visibleSteps) { step in
                    WelcomeGuideSidebarRow(
                        title: l10n[step.titleKey],
                        symbolName: step.symbolName,
                        usesBrandIcon: step == .welcome,
                        isSelected: model.selectedStep == step,
                        isComplete: (model.visibleSteps.firstIndex(of: step) ?? 0) < model.currentStepIndex
                    )
                    .onTapGesture {
                        move(to: step)
                    }
                }
            }
            Spacer()
        }
        .padding(22)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch model.selectedStep {
            case .welcome:
                WelcomeGuideWelcomeStep()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .modeDisplay:
                WelcomeGuideModeDisplayStep(model: model)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .codingSetup:
                WelcomeGuideCodingSetupStep(model: model)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .sharingMusic:
                WelcomeGuideSharingMusicStep(model: model)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .finish:
                WelcomeGuideFinishStep(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button(l10n["welcome_guide_back"]) {
                moveBack()
            }
            .disabled(model.isFirstStep)

            Spacer()

            Text(l10n["welcome_guide_finish_later_note"])
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isLastStep {
                Button(l10n["welcome_guide_finish_action"]) {
                    guard !isFinishing else { return }
                    isFinishing = true
                    Task { @MainActor in
                        let didFinish = await model.finish(defaults: defaults)
                        isFinishing = false
                        if didFinish {
                            onFinish()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFinish || isFinishing)
                .buttonStyle(.borderedProminent)
            } else {
                Button(l10n["welcome_guide_next"]) {
                    moveNext()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func move(to step: WelcomeGuideStep) {
        if reduceMotion {
            model.selectedStep = step
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                model.selectedStep = step
            }
        }
    }

    private func moveNext() {
        if reduceMotion {
            model.next()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                model.next()
            }
        }
    }

    private func moveBack() {
        if reduceMotion {
            model.back()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                model.back()
            }
        }
    }
}

private struct WelcomeGuideSidebarRow: View {
    let title: String
    let symbolName: String
    let usesBrandIcon: Bool
    let isSelected: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                } else if usesBrandIcon {
                    WelcomeGuideBrandIcon(size: 22, cornerRadius: 11)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transaction { transaction in
                    transaction.animation = nil
                }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WelcomeGuideWelcomeStep: View {
    @ObservedObject private var l10n = L10n.shared

    private let features: [(String, String, String)] = [
        ("welcome_guide_feature_ai", "welcome_guide_feature_ai_desc", "terminal"),
        ("welcome_guide_feature_hooks", "welcome_guide_feature_hooks_desc", "point.3.connected.trianglepath.dotted"),
        ("welcome_guide_feature_usage", "welcome_guide_feature_usage_desc", "chart.bar.xaxis"),
        ("welcome_guide_feature_reminders", "welcome_guide_feature_reminders_desc", "bell.badge"),
        ("welcome_guide_feature_airdrop", "welcome_guide_feature_airdrop_desc", "square.and.arrow.up"),
        ("welcome_guide_feature_music", "welcome_guide_feature_music_desc", "music.note"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WelcomeGuideHero(
                    eyebrow: "",
                    title: l10n["welcome_guide_welcome_title"],
                    subtitle: "",
                    symbolName: "leaf",
                    usesBrandIcon: true
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(features, id: \.0) { feature in
                        WelcomeGuideFeatureTile(
                            title: l10n[feature.0],
                            description: l10n[feature.1],
                            symbolName: feature.2,
                            tint: Color.accentColor
                        )
                    }
                }
            }
            .padding(28)
        }
    }
}

private struct WelcomeGuideModeDisplayStep: View {
    @ObservedObject var model: WelcomeGuideModel
    @ObservedObject private var l10n = L10n.shared

    private var displayBinding: Binding<String> {
        Binding(
            get: { model.displayChoice ?? SettingsDefaults.displayChoice },
            set: { model.displayChoice = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WelcomeGuideHero(
                    eyebrow: l10n["welcome_guide_required_1"],
                    title: l10n["welcome_guide_mode_title"],
                    subtitle: l10n["welcome_guide_mode_subtitle"],
                    symbolName: "switch.2"
                )

                HStack(spacing: 12) {
                    WelcomeGuideChoiceCard(
                        title: l10n["welcome_guide_coding_on"],
                        description: l10n["welcome_guide_coding_on_desc"],
                        symbolName: "terminal",
                        isSelected: model.codingSessionsEnabled == true
                    ) {
                        model.setCodingSessionsEnabled(true)
                    }

                    WelcomeGuideChoiceCard(
                        title: l10n["welcome_guide_coding_off"],
                        description: l10n["welcome_guide_coding_off_desc"],
                        symbolName: "cursorarrow.click",
                        isSelected: model.codingSessionsEnabled == false
                    ) {
                        model.setCodingSessionsEnabled(false)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label(l10n["welcome_guide_required_2"], systemImage: "display")
                        .font(.headline)

                    Picker(l10n["display"], selection: displayBinding) {
                        Text(l10n["auto"]).tag("auto")
                        Text(l10n["builtin_display"]).tag("builtin")
                        Text(l10n["main_display"]).tag("main")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(28)
        }
    }
}

private struct WelcomeGuideCodingSetupStep: View {
    @ObservedObject var model: WelcomeGuideModel
    @ObservedObject private var l10n = L10n.shared
    private let toolColumns = [
        GridItem(.adaptive(minimum: 210), spacing: 8, alignment: .leading)
    ]

    private var selectedTools: [WelcomeGuideToolStatus] {
        model.toolStatuses.filter(\.isSelected)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WelcomeGuideHero(
                    eyebrow: l10n["welcome_guide_step_coding_setup"],
                    title: l10n["welcome_guide_coding_title"],
                    subtitle: l10n["welcome_guide_coding_subtitle"],
                    symbolName: "terminal"
                )

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(l10n["welcome_guide_local_tools"], systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)

                        if model.toolStatuses.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(l10n["welcome_guide_no_local_tools"])
                                    .font(.subheadline.weight(.semibold))
                                Text(l10n["welcome_guide_no_local_tools_desc"])
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 8) {
                                ForEach(model.toolStatuses) { tool in
                                    WelcomeGuideToolChip(tool: tool) { isSelected in
                                        model.setToolSelected(source: tool.source, isSelected: isSelected)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 12) {
                        Label(l10n["welcome_guide_usage_hints"], systemImage: "chart.line.uptrend.xyaxis")
                            .font(.headline)

                        WelcomeGuideSwitchRow(isOn: $model.showCodexUsage) {
                            Text(l10n["welcome_guide_show_codex_usage"])
                                .font(.callout)
                        }
                        WelcomeGuideSwitchRow(isOn: $model.showClaudeUsage) {
                            Text(l10n["welcome_guide_show_claude_usage"])
                                .font(.callout)
                        }
                        WelcomeGuideSwitchRow(isOn: $model.backgroundMonitor) {
                            Text(l10n["welcome_guide_background_monitor"])
                                .font(.callout)
                        }
                        WelcomeGuideSwitchRow(isOn: $model.recoveryReminders) {
                            Text(l10n["welcome_guide_recovery_reminders"])
                                .font(.callout)
                        }
                        WelcomeGuideSwitchRow(isOn: $model.thresholdAlerts) {
                            Text(l10n["welcome_guide_threshold_alerts"])
                                .font(.callout)
                        }
                    }
                    .padding(16)
                    .frame(width: 220, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(28)
        }
    }
}

private struct WelcomeGuideSharingMusicStep: View {
    @ObservedObject var model: WelcomeGuideModel
    @ObservedObject private var l10n = L10n.shared

    private var compactBarPriorityBinding: Binding<CompactBarPriority> {
        Binding(
            get: { model.compactBarPriority },
            set: { model.compactBarPriority = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WelcomeGuideHero(
                    eyebrow: l10n["welcome_guide_step_sharing_music"],
                    title: l10n["welcome_guide_sharing_title"],
                    subtitle: l10n["welcome_guide_sharing_subtitle"],
                    symbolName: "square.and.arrow.up"
                )

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        WelcomeGuideSwitchRow(isOn: $model.airDropEnabled) {
                            Label(l10n["welcome_guide_airdrop_title"], systemImage: "square.and.arrow.up")
                                .font(.headline)
                        }
                        Text(l10n["welcome_guide_airdrop_desc_full"])
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: "doc.on.doc")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l10n["welcome_guide_airdrop_preview_title"])
                                    .font(.subheadline.weight(.semibold))
                                Text(l10n["welcome_guide_airdrop_preview_desc"])
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 12) {
                        WelcomeGuideSwitchRow(isOn: $model.musicControlsEnabled) {
                            Label(l10n["welcome_guide_music_title"], systemImage: "music.note")
                                .font(.headline)
                        }
                        Text(l10n["welcome_guide_music_desc_full"])
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Picker(selection: compactBarPriorityBinding) {
                            Text(l10n[CompactBarPriority.aiActivity.localizedKey]).tag(CompactBarPriority.aiActivity)
                            Text(l10n[CompactBarPriority.music.localizedKey]).tag(CompactBarPriority.music)
                        } label: {
                            Text(l10n["compact_bar_priority"])
                        }
                        .pickerStyle(.segmented)
                        .disabled(!model.musicControlsEnabled)
                    }
                    .padding(16)
                    .frame(width: 240, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(28)
        }
    }
}

private struct WelcomeGuideFinishStep: View {
    @ObservedObject var model: WelcomeGuideModel
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            WelcomeGuideHero(
                eyebrow: l10n["welcome_guide_step_finish"],
                title: l10n["welcome_guide_finish_title"],
                subtitle: l10n["welcome_guide_finish_subtitle"],
                symbolName: "checkmark.seal"
            )

            VStack(spacing: 10) {
                WelcomeGuideSummaryRow(
                    title: l10n["welcome_guide_summary_mode"],
                    value: model.codingSessionsEnabled == false ? l10n["welcome_guide_coding_off"] : l10n["welcome_guide_coding_on"],
                    symbolName: "switch.2"
                )
                WelcomeGuideSummaryRow(
                    title: l10n["display"],
                    value: l10n[model.normalizedDisplayChoice ?? SettingsDefaults.displayChoice],
                    symbolName: "display"
                )
                WelcomeGuideSummaryRow(
                    title: l10n["welcome_guide_local_tools"],
                    value: String(format: l10n["welcome_guide_summary_tools"], model.selectedToolsCount),
                    symbolName: "terminal"
                )
                WelcomeGuideSummaryRow(
                    title: l10n["airdrop_section"],
                    value: model.airDropEnabled ? l10n["enabled"] : l10n["disabled"],
                    symbolName: "square.and.arrow.up"
                )
                WelcomeGuideSummaryRow(
                    title: l10n["music"],
                    value: model.musicControlsEnabled ? l10n["enabled"] : l10n["disabled"],
                    symbolName: "music.note"
                )
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            Text(l10n["welcome_guide_finish_settings_note"])
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(28)
    }
}

private struct WelcomeGuideHero: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let symbolName: String
    var usesBrandIcon = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if usesBrandIcon {
                WelcomeGuideBrandIcon(size: 54, cornerRadius: 8)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: 54, height: 54)
                    WelcomeGuideAnimatedIcon(
                        symbolName: symbolName,
                        size: 24,
                        tint: Color.accentColor
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .textCase(.uppercase)
                }
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct WelcomeGuideBrandIcon: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private static var image: NSImage {
        if let url = Bundle.appModule.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return SettingsWindowController.bundleAppIcon()
    }
}

private struct WelcomeGuideAnimatedIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    let symbolName: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .scaleEffect(reduceMotion ? 1 : (isAnimating ? 1.08 : 0.96))
            .opacity(reduceMotion ? 1 : (isAnimating ? 1 : 0.78))
            .onAppear {
                guard !reduceMotion else {
                    return
                }

                withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
            .onChange(of: reduceMotion) { _, newValue in
                if newValue {
                    isAnimating = false
                } else {
                    withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                        isAnimating = true
                    }
                }
            }
    }
}

private struct WelcomeGuideFeatureTile: View {
    let title: String
    let description: String
    let symbolName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WelcomeGuideChoiceCard: View {
    let title: String
    let description: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbolName)
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.green : Color.secondary)
                }
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WelcomeGuideToolChip: View {
    @ObservedObject private var l10n = L10n.shared
    let tool: WelcomeGuideToolStatus
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(tool.state.tint)
                        .frame(width: 6, height: 6)
                    Text(l10n[tool.state.titleKey])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { tool.isSelected }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WelcomeGuideSwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        _isOn = isOn
        self.label = label()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WelcomeGuideSummaryRow: View {
    let title: String
    let value: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
