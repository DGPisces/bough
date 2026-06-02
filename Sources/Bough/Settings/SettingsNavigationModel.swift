import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case sessionDisplay = "session_display"
    case notch
    case music
    case airDrop = "airdrop"
    case mascot
    case sound
    case usageNotifications = "usage_notifications"
    case integrations
    case advanced
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .airDrop: return "airdrop_section"
        case .notch: return "appearance"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sessionDisplay: return "rectangle.split.2x1.fill"
        case .notch: return "display"
        case .music: return "music.note"
        case .airDrop: return "square.and.arrow.up"
        case .mascot: return "person.2.fill"
        case .sound: return "speaker.wave.2.fill"
        case .usageNotifications: return "chart.line.uptrend.xyaxis"
        case .integrations: return "link.circle.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .sessionDisplay: return .indigo
        case .notch: return .blue
        case .music: return .mint
        case .airDrop: return .blue
        case .mascot: return .pink
        case .sound: return .green
        case .usageNotifications: return .teal
        case .integrations: return .purple
        case .advanced: return .orange
        case .about: return .cyan
        }
    }

    var pageTargetID: SettingsTargetID {
        switch self {
        case .general: return .generalPage
        case .sessionDisplay: return .sessionDisplayPage
        case .notch: return .notchPage
        case .music: return .musicPage
        case .airDrop: return .airDropPage
        case .mascot: return .mascotPage
        case .sound: return .soundPage
        case .usageNotifications: return .usagePage
        case .integrations: return .integrationsPage
        case .advanced: return .advancedPage
        case .about: return .aboutPage
        }
    }

    var firstContentTargetID: SettingsTargetID {
        switch self {
        case .general: return .generalCodingSessions
        case .sessionDisplay: return .sessionDisplayExpansion
        case .notch: return .notchDisplay
        case .music: return .musicControls
        case .airDrop: return .airDropEnabled
        case .mascot: return .mascotPreview
        case .sound: return .soundMaster
        case .usageNotifications: return .usageData
        case .integrations: return .integrationsLocalTools
        case .advanced: return .advancedAutomation
        case .about: return .aboutPage
        }
    }
}

enum SettingsTargetID: String, CaseIterable, Hashable {
    case generalPage
    case generalCodingSessions
    case generalWelcomeGuide
    case generalLanguage
    case generalStartup

    case sessionDisplayPage
    case sessionDisplayExpansion
    case sessionDisplayAutoCollapseAfterJump
    case sessionDisplayAutoExpandOnCompletion
    case sessionDisplayList
    case sessionDisplayMaxVisibleSessions
    case sessionDisplayContent
    case sessionDisplayContentFontSize
    case sessionDisplayAIReplyLines
    case sessionDisplayShowAgentDetails
    case sessionDisplayShowToolStatus

    case notchPage
    case notchDisplay
    case notchDisplayChoice
    case notchHorizontalDrag
    case notchVisibility
    case notchHideInFullscreen
    case notchHideWhenIdle
    case notchExpansion
    case notchCollapseOnMouseLeave
    case notchAutoCollapseAfterJump
    case notchAutoExpandOnCompletion
    case notchHapticOnHover
    case notchHapticIntensity
    case notchSizeLayout
    case notchMaxVisibleSessions
    case notchIslandWidth
    case notchTopBarHeight
    case notchCustomHeight
    case notchMusicControls
    case notchShowMusicControls
    case notchCompactBarPriority
    case notchContent
    case notchContentFontSize
    case notchAIReplyLines
    case notchShowAgentDetails
    case notchShowToolStatus

    case mascotPage
    case mascotPreview
    case mascotPreviewStatus
    case mascotDefaultSource
    case mascotAnimation
    case mascotAnimationSpeed

    case soundPage
    case soundMaster
    case soundEnable
    case soundVolume
    case soundEvents
    case soundSessionStart
    case soundTaskComplete
    case soundTaskError
    case soundApprovalNeeded
    case soundPromptSubmit
    case soundBoot

    case musicPage
    case musicControls
    case musicShowMusicControls
    case musicCompactBarPriority

    case airDropPage
    case airDropEnabled
    case airDropDemoScenarios

    case usagePage
    case usageData
    case usageDataSourcePicker
    case usageRefresh
    case usageDisplayCodex
    case usageDisplayClaudeCode
    case usageStatisticsCodex
    case usageStatisticsClaudeCode
    case usageBackgroundMonitor
    case usageMonitorEnable
    case usageMonitorDisable
    case usageMonitorRepair
    case usageMonitorUninstall
    case usageRecoveryNotifications
    case usageRecoveryCodexFiveHour
    case usageRecoveryCodexWeekly
    case usageRecoveryClaudeFiveHour
    case usageRecoveryClaudeWeekly
    case usageRecoveryRepair
    case usageRecoveryOpenSettings
    case usageThresholdAlerts
    case usageThresholdMaster
    case usageThresholdCodex
    case usageThresholdClaudeCode
    case usageThresholdRepair

    case integrationsPage
    case integrationsLocalTools
    case integrationsLocalToolClaude
    case integrationsLocalToolCodex
    case integrationsLocalToolGemini
    case integrationsLocalToolCursor
    case integrationsLocalToolTrae
    case integrationsLocalToolTraeCN
    case integrationsLocalToolTraeCLI
    case integrationsLocalToolQoder
    case integrationsLocalToolFactory
    case integrationsLocalToolStepFun
    case integrationsLocalToolAntiGravity
    case integrationsLocalToolHermes
    case integrationsLocalToolQwen
    case integrationsLocalToolCopilot
    case integrationsLocalToolKimi
    case integrationsLocalToolKiro
    case integrationsLocalToolOpenCode
    case integrationsCustomCLIs
    case integrationsCustomCLIName
    case integrationsCustomCLISource
    case integrationsCustomCLIPath
    case integrationsCustomCLIKey
    case integrationsCustomCLIFormat
    case integrationsCustomCLIAdd
    case integrationsRemoteHosts
    case integrationsRemoteName
    case integrationsRemoteHost
    case integrationsRemoteUser
    case integrationsRemotePort
    case integrationsRemoteIdentity
    case integrationsRemoteAuthSocket
    case integrationsRemoteAutoConnect
    case integrationsRemoteAdd
    case integrationsWebhooks
    case integrationsWebhookEnabled
    case integrationsWebhookURL
    case integrationsWebhookFilter
    case integrationsReinstallHooks
    case integrationsUninstallHooks

    case advancedPage
    case advancedAutomation
    case advancedAutoApproveTaskCreate
    case advancedAutoApproveTaskUpdate
    case advancedAutoApproveTaskGet
    case advancedAutoApproveTaskList
    case advancedAutoApproveTaskOutput
    case advancedAutoApproveTaskStop
    case advancedAutoApproveTodoRead
    case advancedAutoApproveTodoWrite
    case advancedAutoApproveEnterPlanMode
    case advancedAutoApproveExitPlanMode
    case advancedHookFilters
    case advancedExcludedHookPaths
    case advancedSessionHandling
    case advancedSessionCleanup
    case advancedRotationInterval
    case advancedToolHistoryLimit
    case advancedPluginSessions
    case advancedDiagnosticsRepair
    case advancedExportDiagnostics

    case aboutPage
    case aboutGitHub
    case aboutIssues
    case aboutUpdates
    case aboutAutoUpdate
    case aboutCheckForUpdates
    case aboutUpdateNow
    case aboutUpdateCopyCommand
    case aboutDiagnostics
}

struct SettingsTargetRequest: Equatable, Hashable, Identifiable {
    let page: SettingsPage
    let targetID: SettingsTargetID
    let nonce: UUID

    var id: UUID { nonce }

    init(page: SettingsPage, targetID: SettingsTargetID, nonce: UUID = UUID()) {
        self.page = page
        self.targetID = targetID
        self.nonce = nonce
    }
}

struct SidebarGroup: Hashable {
    let title: String?
    let pages: [SettingsPage]
}

enum SettingsSidebarModel {
    static let nonCodingGroupTitleKey = "settings_group_non_coding"
    static let codingGroupTitleKey = "settings_group_coding_sessions"

    static func sidebarGroups(codingSessionsEnabled: Bool = CodingSessionsSettings.isEnabled()) -> [SidebarGroup] {
        var groups = [
            SidebarGroup(title: nonCodingGroupTitleKey, pages: [.general, .music, .airDrop, .notch, .about]),
        ]
        if codingSessionsEnabled {
            groups.append(SidebarGroup(
                title: codingGroupTitleKey,
                pages: [.sessionDisplay, .mascot, .sound, .usageNotifications, .integrations, .advanced]
            ))
        }
        return groups
    }

    static var sidebarGroups: [SidebarGroup] {
        sidebarGroups()
    }

    static var visiblePages: [SettingsPage] {
        sidebarGroups.flatMap(\.pages)
    }

    static func visiblePages(codingSessionsEnabled: Bool) -> [SettingsPage] {
        sidebarGroups(codingSessionsEnabled: codingSessionsEnabled).flatMap(\.pages)
    }

    static func isVisible(page: SettingsPage, codingSessionsEnabled: Bool = CodingSessionsSettings.isEnabled()) -> Bool {
        visiblePages(codingSessionsEnabled: codingSessionsEnabled).contains(page)
    }

    static func pages(inGroup title: String?) -> [SettingsPage] {
        sidebarGroups.first { $0.title == title }?.pages ?? []
    }

    static func pages(inGroup title: String?, codingSessionsEnabled: Bool) -> [SettingsPage] {
        sidebarGroups(codingSessionsEnabled: codingSessionsEnabled).first { $0.title == title }?.pages ?? []
    }
}
