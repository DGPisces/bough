import XCTest
@testable import Bough

final class L10nTests: XCTestCase {
    private static let supportedLanguages = ["en", "zh"]
    private var savedLanguage: String!
    private var savedLanguageDefaultValue: Any?
    private var lockedProcessState = false

    override func setUp() {
        super.setUp()
        TestHelpers.processStateLock.lock()
        lockedProcessState = true
        savedLanguage = L10n.shared.language
        savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        L10n.shared.language = "en"
    }

    override func tearDown() {
        if lockedProcessState {
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
        }
        savedLanguage = nil
        savedLanguageDefaultValue = nil
        if lockedProcessState {
            TestHelpers.processStateLock.unlock()
            lockedProcessState = false
        }
        super.tearDown()
    }

    func testChineseTranslationsContainAllKeysPresentInEnglish() {
        let enKeys = Set(L10n.strings["en"]?.keys ?? Dictionary<String, String>().keys)
        let zhKeys = Set(L10n.strings["zh"]?.keys ?? Dictionary<String, String>().keys)

        let missingKeys = enKeys.subtracting(zhKeys)
        XCTAssertTrue(missingKeys.isEmpty, "Chinese is missing keys: \(missingKeys)")
    }

    // V040-QUAL-02: per-cluster key-existence assertions backing
    // `28-LOCALIZATION-AUDIT.md` Table 2 (call-site gap closures).
    func testRecoveryNotificationKeysExistInAllLanguages() {
        let keys = [
            "usage_notifications_recovery_title_5h",
            "usage_notifications_recovery_title_weekly",
            "usage_notifications_recovery_default_body",
            "usage_notifications_recovery_detailed_body",
        ]
        for language in Self.supportedLanguages {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testThresholdNotificationKeysExistInAllLanguages() {
        let keys = [
            "usage_notifications_threshold_title_20",
            "usage_notifications_threshold_title_5",
            "usage_notifications_threshold_title_0",
            "usage_notifications_threshold_body",
            "usage_notifications_threshold_section_title",
            "usage_notifications_threshold_section_description",
            "usage_notifications_threshold_master_toggle_label",
            "usage_notifications_threshold_per_tool_codex_label",
            "usage_notifications_threshold_per_tool_claude_code_label",
            "usage_notifications_threshold_permission_request_hint",
            "usage_notifications_threshold_permission_denied_hint",
            "usage_notifications_action_request_permission",
        ]
        for language in Self.supportedLanguages {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testAccessibilityStatusKeysExistInAllLanguages() {
        let keys = [
            "accessibility_status_normal",
            "accessibility_status_normal_refreshing",
            "accessibility_status_today_quota_low",
            "accessibility_status_data_partial",
            "accessibility_status_data_stale",
            "accessibility_status_today_quota_overdrawn",
            "accessibility_status_today_quota_depleted",
            "accessibility_status_today_quota_just_depleted",
            "accessibility_status_data_unavailable",
            "accessibility_status_loading",
        ]
        for language in Self.supportedLanguages {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testCustomCLISectionKeysExistInAllLanguages() {
        let keys = [
            "settings_custom_clis_section",
            "settings_custom_clis_empty",
            "settings_custom_clis_name_placeholder",
            "settings_custom_clis_source_placeholder",
            "settings_custom_clis_path_placeholder",
            "settings_custom_clis_key_placeholder",
            "settings_custom_clis_template_picker",
            "settings_custom_clis_add_button",
        ]
        for language in Self.supportedLanguages {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testSystemLanguageDoesNotExposeUnsupportedLocales() {
        L10n.shared.language = "system"

        XCTAssertTrue(Self.supportedLanguages.contains(L10n.shared.effectiveLanguage))
    }

    func testUnsupportedExplicitLanguageFallsBackToEnglish() {
        L10n.shared.language = "tr"

        XCTAssertEqual(L10n.shared["general"], "General")
        XCTAssertEqual(L10n.shared["nonexistent_key"], "nonexistent_key")
    }

    func testAllLanguageOptionsAvailableInSettings() {
        let availableLanguages = ["system", "en", "zh"]

        for lang in availableLanguages {
            L10n.shared.language = lang
            let value = L10n.shared["general"]
            XCTAssertFalse(value.isEmpty, "Language '\(lang)' should return a value for 'general' key")
        }
    }

    func testUsageKeysExistInAllLanguages() {
        let keys = [
            "usage", "loading", "available", "stale", "unavailable", "partial", "refresh",
            "today_safe", "last_refresh", "data_source_status", "usage_5h",
            "usage_week", "usage_provider_codex", "usage_provider_claude_code",
            "usage_claude_unavailable_reason", "usage_reset_in", "usage_elapsed_ago",
            "usage_last_refresh_never", "usage_refresh_never_value",
            "usage_codex_hooks_disabled_banner", "usage_codex_hooks_enable_now",
            "usage_codex_hooks_dismiss", "usage_codex_hooks_disabled_badge",
            "usage_codex_cli_outdated_banner", "usage_codex_cli_outdated_badge",
            "usage_codex_cli_outdated_upgrade_now", "usage_codex_cli_outdated_dismiss",
            "usage_provider_disabled_empty", "usage_provider_controls_section",
            "usage_provider_display_toggle", "usage_provider_statistics_toggle",
            "usage_claude_payload-missing-rate-limits", "usage_claude_parse-failure",
            "usage_claude_stale",
            // Direct-OAuth usage channel failures (spec §9)
            "usage_oauth_no_credentials", "usage_oauth_token_expired",
            "usage_oauth_keychain_denied", "usage_oauth_rate_limited",
            "usage_oauth_unauthorized",
            // Direct-OAuth channel badge + pace rows (spec §8.3 / §9)
            "usage_oauth_badge_connected", "usage_oauth_badge_unknown",
            "usage_pace_on_track", "usage_pace_ahead_fmt", "usage_pace_behind_fmt",
            "usage_pace_lasts", "usage_pace_eta_fmt",
            "usage_pace_5h_row", "usage_pace_week_row",
            // Claude Code hook convergence (QUOTA-04, QUOTA-05 — plan 17-05)
            "usage_claude_code_hook_retry", "usage_claude_code_hook_section",
            "usage_claude_integration_subtitle", "usage_claude_integration_install_failed", "usage_claude_refresh_succeeded", "usage_claude_refresh_failed",
            "usage_monitor_section", "usage_monitor_status",
            "usage_monitor_state_installed", "usage_monitor_state_running", "usage_monitor_state_stopped",
            "usage_monitor_state_error", "usage_monitor_state_needs_approval", "usage_monitor_state_needs_repair",
            "usage_monitor_message_bundle_repair", "usage_monitor_message_approval",
            "usage_monitor_message_launch_agent_missing", "usage_monitor_message_unknown_status",
            "usage_monitor_message_collection_failed",
            "usage_monitor_action_enable", "usage_monitor_action_disable",
            "usage_monitor_action_repair", "usage_monitor_action_uninstall",
            "usage_monitor_uninstall_confirmation",
            "usage_notifications_section",
            "usage_notifications_permission_authorized", "usage_notifications_permission_not_determined",
            "usage_notifications_permission_denied", "usage_notifications_permission_unavailable",
            "usage_notifications_action_repair", "usage_notifications_action_open_settings"
        ]

        for language in Self.supportedLanguages {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    func testCodexHooksDisabledCopyExistsInEnglishAndChinese() {
        L10n.shared.language = "en"
        XCTAssertTrue(L10n.shared["usage_codex_hooks_disabled_banner"].contains("hooks = false"))
        XCTAssertEqual(L10n.shared["usage_codex_hooks_enable_now"], "Enable now")
        XCTAssertEqual(L10n.shared["usage_codex_hooks_dismiss"], "Dismiss")
        XCTAssertEqual(L10n.shared["usage_codex_hooks_disabled_badge"], "Disabled")

        L10n.shared.language = "zh"
        XCTAssertTrue(L10n.shared["usage_codex_hooks_disabled_banner"].contains("hooks = false"))
        XCTAssertEqual(L10n.shared["usage_codex_hooks_enable_now"], "现在启用")
        XCTAssertEqual(L10n.shared["usage_codex_hooks_dismiss"], "忽略")
    }

    func testCodexCLIOutdatedCopyExistsInEnglishAndChinese() {
        L10n.shared.language = "en"
        // Banner must contain %@ placeholders for detected version + minimum version.
        XCTAssertTrue(L10n.shared["usage_codex_cli_outdated_banner"].contains("%@"))
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_badge"], "Outdated")
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_upgrade_now"], "Copy upgrade command")
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_dismiss"], "Dismiss")

        L10n.shared.language = "zh"
        XCTAssertTrue(L10n.shared["usage_codex_cli_outdated_banner"].contains("%@"))
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_badge"], "已过时")
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_upgrade_now"], "复制升级命令")
        XCTAssertEqual(L10n.shared["usage_codex_cli_outdated_dismiss"], "忽略")
    }

}
