import Foundation
import BoughCore

extension UsageNotificationCopy {
    static func localized(via l10n: L10n = .shared) -> UsageNotificationCopy {
        UsageNotificationCopy(
            titleFiveHour: l10n["usage_notifications_recovery_title_5h"],
            titleWeekly: l10n["usage_notifications_recovery_title_weekly"],
            defaultBody: l10n["usage_notifications_recovery_default_body"],
            detailedBody: l10n["usage_notifications_recovery_detailed_body"],
            codexName: l10n["usage_provider_codex"],
            claudeCodeName: l10n["usage_provider_claude_code"]
        )
    }
}

extension UsageThresholdNotificationCopy {
    static func localized(via l10n: L10n = .shared) -> UsageThresholdNotificationCopy {
        UsageThresholdNotificationCopy(
            title20: l10n["usage_notifications_threshold_title_20"],
            title5: l10n["usage_notifications_threshold_title_5"],
            title0: l10n["usage_notifications_threshold_title_0"],
            body: l10n["usage_notifications_threshold_body"],
            codexName: l10n["usage_provider_codex"],
            claudeCodeName: l10n["usage_provider_claude_code"]
        )
    }
}
