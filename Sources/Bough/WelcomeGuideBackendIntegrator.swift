import Foundation
import BoughCore

struct WelcomeGuideBackendPlan: Equatable, Sendable {
    let codingSessionsEnabled: Bool
    let toolSelections: [String: Bool]
    let showCodexUsage: Bool
    let showClaudeUsage: Bool
    let backgroundMonitorEnabled: Bool
    let recoveryRemindersEnabled: Bool
    let thresholdAlertsEnabled: Bool

    func usageEnabled(for tool: UsageTool) -> Bool {
        switch tool {
        case .codex:
            return showCodexUsage
        case .claudeCode:
            return showClaudeUsage
        }
    }
}

typealias WelcomeGuideBackendApply = @MainActor (WelcomeGuideBackendPlan, UserDefaults, Date) async -> Void

enum WelcomeGuideBackendIntegrator {
    private static let usageTools: [UsageTool] = [.codex, .claudeCode]
    private static let recoveryWindows: [UsageWindowKind] = [.fiveHour, .weekly]

    @MainActor
    static func apply(_ plan: WelcomeGuideBackendPlan, defaults: UserDefaults, completedAt: Date) async {
        guard plan.codingSessionsEnabled else {
            UsageMonitorService().disableForCodingSessionsOff()
            return
        }

        await applyToolSelections(plan.toolSelections)
        applyUsagePreferences(plan, defaults: defaults, completedAt: completedAt)
        applyUsageMonitor(plan.backgroundMonitorEnabled)
        await requestNotificationAccessIfNeeded(plan)
    }

    @MainActor
    private static func applyToolSelections(_ selections: [String: Bool]) async {
        guard !selections.isEmpty else { return }

        for source in selections.keys.sorted() {
            guard let enabled = selections[source] else { continue }
            if source == "claude" {
                await applyClaudeSelection(enabled)
            } else {
                _ = ConfigInstaller.setEnabled(source: source, enabled: enabled)
            }
        }
    }

    @MainActor
    private static func applyClaudeSelection(_ enabled: Bool) async {
        if enabled {
            let result = await ChainInstallCoordinator.shared.installClaudeIntegration(replaceExisting: false)
            switch result {
            case .installed, .chained:
                break
            case .conflict, .failed:
                _ = ConfigInstaller.setEnabled(source: "claude", enabled: false)
            }
        } else {
            _ = await ChainInstallCoordinator.shared.uninstallClaudeIntegration()
        }

        NotificationCenter.default.post(
            name: SettingsNotification.claudeCodeStatusLineDidChange,
            object: nil
        )
    }

    @MainActor
    private static func applyUsagePreferences(
        _ plan: WelcomeGuideBackendPlan,
        defaults: UserDefaults,
        completedAt: Date
    ) {
        let usageStore = UsageStore(defaults: defaults, now: { completedAt })
        for tool in usageTools {
            let isEnabled = plan.usageEnabled(for: tool)
            usageStore.setUsageDisplayEnabled(tool: tool, isEnabled: isEnabled)
            usageStore.setUsageStatisticsEnabled(tool: tool, isEnabled: isEnabled)
            usageStore.setThresholdNotificationPreference(tool: tool, isEnabled: plan.thresholdAlertsEnabled && isEnabled)
            for window in recoveryWindows {
                usageStore.setRecoveryReminderPreference(
                    tool: tool,
                    windowKind: window,
                    isEnabled: plan.recoveryRemindersEnabled && isEnabled
                )
            }
        }
        usageStore.setThresholdNotificationsMasterEnabled(plan.thresholdAlertsEnabled)
    }

    @MainActor
    private static func applyUsageMonitor(_ enabled: Bool) {
        do {
            if enabled {
                _ = try UsageMonitorService().enable()
            } else {
                _ = try UsageMonitorService().disable()
            }
        } catch {
            // Settings surfaces repair state on the next open; onboarding should not block completion.
        }
    }

    @MainActor
    private static func requestNotificationAccessIfNeeded(_ plan: WelcomeGuideBackendPlan) async {
        guard plan.recoveryRemindersEnabled || plan.thresholdAlertsEnabled else { return }

        let service = UsageNotificationService(
            copy: .localized(),
            thresholdCopy: .localized(),
            providerEnabled: { tool in
                plan.usageEnabled(for: tool)
            }
        )
        let current = await service.permissionState()
        switch current {
        case .notDetermined, .failed:
            _ = await service.requestAccessForExplicitUserAction()
        case .authorized, .provisional, .ephemeral, .denied, .unavailable:
            break
        }
    }
}
