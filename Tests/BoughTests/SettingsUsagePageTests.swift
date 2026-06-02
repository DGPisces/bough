import XCTest
import ServiceManagement

@testable import Bough
@testable import BoughCore

@MainActor
final class SettingsUsagePageTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    func testUsagePageIsVisibleBeforeRemote() {
        let physicalHardwareRouteRawValue = "bud" + "dy"
        let pages = SettingsSidebarModel.visiblePages(codingSessionsEnabled: true)

        XCTAssertTrue(pages.contains(.usageNotifications))
        XCTAssertLessThan(
            pages.firstIndex(of: .usageNotifications) ?? Int.max,
            pages.firstIndex(of: .integrations) ?? Int.max
        )
        XCTAssertFalse(pages.contains { $0.rawValue == physicalHardwareRouteRawValue })
    }

    func testUsageDetailsModelFormatsUnavailableAndLastRefresh() {
        let snapshot = UsageSnapshot.claudeUnavailable(now: Date(timeIntervalSince1970: 100))

        let model = UsageDetailsModel(snapshot: snapshot, now: Date(timeIntervalSince1970: 160))

        XCTAssertEqual(model.status, "Unavailable")
        XCTAssertEqual(model.lastRefresh, "1m ago")
        XCTAssertTrue(model.rows.contains(.init(title: "5h", value: "Unavailable")))
        XCTAssertTrue(model.rows.contains(.init(title: "Week", value: "Unavailable")))
    }

    func testUsageDetailsModelFormatsAvailableStatus() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fiveHour = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 12,
            resetsAt: Date(timeIntervalSince1970: 2_800),
            windowDurationMins: 300,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: 48,
            resetsAt: Date(timeIntervalSince1970: 4_600),
            windowDurationMins: 10080,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "pro",
            fiveHour: .available(fiveHour),
            weekly: .available(weekly),
            today: nil,
            availability: .available,
            lastRefresh: nil
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.status, "Available")
        XCTAssertEqual(model.lastRefresh, "Never")
        XCTAssertTrue(model.rows.contains(.init(title: "5h", value: "88% · resets in 30m")))
        XCTAssertTrue(model.rows.contains(.init(title: "Week", value: "52% · resets in 0d 1h 0m")))
    }

    func testUsageDetailsModelFormatsClaudeCodeAvailableRows() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fiveHour = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 18,
            resetsAt: Date(timeIntervalSince1970: 2_800),
            windowDurationMins: 300,
            sourceLabel: "Claude Code",
            updatedAt: now
        )
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: 32,
            resetsAt: Date(timeIntervalSince1970: 100_000),
            windowDurationMins: 10080,
            sourceLabel: "Claude Code",
            updatedAt: now
        )
        let snapshot = UsageSnapshot(
            tool: .claudeCode,
            planName: "Claude Sonnet 4",
            fiveHour: .available(fiveHour),
            weekly: .available(weekly),
            today: TodayValue(
                pct: 82,
                todayAllowanceOfWeek: 14,
                severity: .healthy,
                basis: TodayBasis(
                    localDate: "2026-05-14",
                    weeklyUsedAtDayStart: 24,
                    weeklyUsedNow: 32,
                    todayAllowanceOfWeek: 14,
                    daysRemainingUntilWeeklyReset: 5,
                    weeklyResetAlreadyFiredToday: false
                )
            ),
            availability: .available,
            lastRefresh: now
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.status, "Available")
        XCTAssertEqual(model.lastRefresh, "0s ago")
        XCTAssertTrue(model.rows.contains(.init(title: "5h", value: "82% · resets in 30m")))
        XCTAssertTrue(model.rows.contains(.init(title: "Week", value: "68% · resets in 1d 3h 30m")))
        XCTAssertEqual(model.todayPctText, "82%")
        XCTAssertNil(model.todayResetExplanationText)
    }

    func testUsageDetailsModelTreatsNonFiniteTodayValueAsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .loading,
            weekly: .loading,
            today: TodayValue(
                pct: .nan,
                todayAllowanceOfWeek: 0,
                severity: .depleted,
                basis: TodayBasis(
                    localDate: "2026-05-14",
                    weeklyUsedAtDayStart: 100,
                    weeklyUsedNow: 100,
                    todayAllowanceOfWeek: 0,
                    daysRemainingUntilWeeklyReset: 7,
                    weeklyResetAlreadyFiredToday: false
                )
            ),
            availability: .available,
            lastRefresh: now
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertNil(model.todayPctText)
        XCTAssertNil(model.todayAllowanceLineText)
        XCTAssertNil(model.todayUsedLineText)
        XCTAssertNil(model.todayResetExplanationText)
    }

    func testUsageDetailsModelShowsExplicitResetExplanation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .loading,
            weekly: .loading,
            today: TodayValue(
                pct: -20,
                todayAllowanceOfWeek: 20,
                severity: .overdraft,
                basis: TodayBasis(
                    localDate: "2026-05-14",
                    weeklyUsedAtDayStart: 80,
                    weeklyUsedNow: 4,
                    todayAllowanceOfWeek: 20,
                    daysRemainingUntilWeeklyReset: 7,
                    weeklyResetAlreadyFiredToday: true,
                    resetProvenance: .explicitReset
                )
            ),
            availability: .available,
            lastRefresh: now
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.todayResetExplanationText, "Today includes usage before the weekly reset")
    }

    func testUsageDetailsModelShowsImplicitResetExplanation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .loading,
            weekly: .loading,
            today: TodayValue(
                pct: -15,
                todayAllowanceOfWeek: 20,
                severity: .overdraft,
                basis: TodayBasis(
                    localDate: "2026-05-14",
                    weeklyUsedAtDayStart: 82,
                    weeklyUsedNow: 5,
                    todayAllowanceOfWeek: 20,
                    daysRemainingUntilWeeklyReset: 7,
                    weeklyResetAlreadyFiredToday: true,
                    resetProvenance: .implicitReset
                )
            ),
            availability: .available,
            lastRefresh: now
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.todayResetExplanationText, "Today includes usage before an early provider reset")
    }

    func testUsageDetailsModelLocalizesElapsedSuffix() {
        L10n.shared.language = "zh"
        let snapshot = UsageSnapshot.claudeUnavailable(now: Date(timeIntervalSince1970: 100))

        let model = UsageDetailsModel(snapshot: snapshot, now: Date(timeIntervalSince1970: 160))

        XCTAssertEqual(model.lastRefresh, "1m前")
        XCTAssertFalse(model.lastRefresh.contains("ago"))
        XCTAssertFalse(model.lastRefresh.contains("上次刷新"))
    }

    func testUsageDetailsModelFormatsStaleState() {
        let now = Date(timeIntervalSince1970: 2_000)
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: 58,
            resetsAt: Date(timeIntervalSince1970: 4_000),
            windowDurationMins: 10080,
            sourceLabel: "Codex",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .unavailable(reason: "5-hour window unavailable"),
            weekly: .stale(weekly, reason: "Usage data is stale"),
            today: nil,
            availability: .stale(reason: "Usage data is stale"),
            lastRefresh: Date(timeIntervalSince1970: 1_000)
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.status, "Stale")
        XCTAssertTrue(model.rows.contains(.init(title: "Week", value: "42% · resets in 0d 0h 33m · Stale")))
    }

    func testUsageDetailsModelDistinguishesRefreshFailedState() {
        let now = Date(timeIntervalSince1970: 2_000)
        let weekly = UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: 58,
            resetsAt: Date(timeIntervalSince1970: 4_000),
            windowDurationMins: 10080,
            sourceLabel: "Codex",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .unavailable(reason: "5-hour window unavailable"),
            weekly: .stale(weekly, reason: "Refresh failed"),
            today: nil,
            availability: .stale(reason: "Refresh failed"),
            lastRefresh: Date(timeIntervalSince1970: 1_000)
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.status, "Refresh failed")
        XCTAssertEqual(model.lastRefresh, "16m ago")
        XCTAssertTrue(model.rows.contains(.init(title: "Week", value: "42% · resets in 0d 0h 33m · Refresh failed")))
    }

    func testManualRefreshActionIsInvoked() {
        var didRefresh = false
        let action = UsagePageActions(refresh: { didRefresh = true })

        action.refresh()

        XCTAssertTrue(didRefresh)
    }

    func testCodexHooksDisabledNoticeModelShowsBannerUntilDismissed() {
        let visible = CodexHooksDisabledNoticeModel(hooksDisabled: true, dismissed: false)

        XCTAssertTrue(visible.showsBanner)
        XCTAssertTrue(visible.showsDisabledBadge)

        let dismissed = CodexHooksDisabledNoticeModel(hooksDisabled: true, dismissed: true)

        XCTAssertFalse(dismissed.showsBanner)
        XCTAssertTrue(dismissed.showsDisabledBadge)
    }

    func testCodexHooksDisabledNoticeModelHidesWhenHooksAreEnabled() {
        let model = CodexHooksDisabledNoticeModel(hooksDisabled: false, dismissed: false)

        XCTAssertFalse(model.showsBanner)
        XCTAssertFalse(model.showsDisabledBadge)
    }

    func testCodexHooksDisabledDismissalKeyExists() {
        XCTAssertEqual(SettingsKey.codexHooksDisabledNoticeDismissed, "codexHooksDisabledNoticeDismissed")
    }

    func testUsagePageRefreshHandlesBothProviders() throws {
        // Regression guard: the data-source refresh button is now
        // actionable for BOTH providers. Codex routes through `pageActions.refresh`
        // (the server reader). Claude Code re-reads ~/.bough/claude-usage.json
        // from disk via `refreshClaudeCodeUsageFromDisk` and bumps the mutation
        // tick so the connectivity probe re-runs. Without per-provider routing
        // the button silently no-oped for Claude Code users.
        let usagePage = try usagePageSource()

        XCTAssertTrue(
            usagePage.contains("refreshClaudeCodeUsageFromDisk"),
            "Claude Code refresh must call refreshClaudeCodeUsageFromDisk so the @Published snapshot updates and the connectivity probe re-runs."
        )
        XCTAssertTrue(
            usagePage.contains("pageActions.refresh()"),
            "Codex refresh must still route through pageActions.refresh() (the server reader path)."
        )
    }

    func testUsagePageHasSingleRefreshControlForClaudeCode() throws {
        let usagePage = try usagePageSource()

        XCTAssertFalse(
            usagePage.contains("usage_claude_code_hook_retry"),
            "Claude Code usage must not render a second retry button next to the shared refresh control."
        )
    }

    func testUsageDetailsSectionRendersLastRefreshOnce() throws {
        let source = try settingsSource()
        let section = try XCTUnwrap(source.slice(from: "private struct UsageDetailsSection: View", to: "private struct UsageRecoveryNotificationsSection: View"))
        let count = section.components(separatedBy: #"LabeledContent(l10n["last_refresh"], value: model.lastRefresh)"#).count - 1

        XCTAssertEqual(count, 1, "Usage details should render a single Last refresh row.")
    }

    func testUsagePageContainsCodexHooksDisabledBannerAndBadgePaths() throws {
        let usagePage = try usagePageSource()

        XCTAssertTrue(usagePage.contains("hooks = false"))
        XCTAssertTrue(usagePage.contains("usage_codex_hooks_enable_now"))
        XCTAssertTrue(usagePage.contains("usage_codex_hooks_dismiss"))
        XCTAssertTrue(usagePage.contains("usage_codex_hooks_disabled_badge"))
    }

    func testUsagePageContainsProviderPreferenceToggles() throws {
        let usagePage = try usagePageSource()

        XCTAssertTrue(usagePage.contains("UsageProviderPreferencesSection"))
        XCTAssertTrue(usagePage.contains("usageDisplayEnabled"))
        XCTAssertTrue(usagePage.contains("setUsageDisplayEnabled"))
        XCTAssertTrue(usagePage.contains("usageStatisticsEnabled"))
        XCTAssertTrue(usagePage.contains("setUsageStatisticsEnabled"))
        XCTAssertTrue(usagePage.contains("usage_provider_disabled_empty"))
    }

    func testUsageMonitorLifecycleModelLabelsAllStates() {
        let labels = Dictionary(uniqueKeysWithValues: UsageMonitorLifecycleState.allCases.map {
            ($0, L10n.shared[UsageMonitorLifecycleModel.stateLabelKey(for: $0)])
        })

        XCTAssertEqual(labels[.installed], "Installed")
        XCTAssertEqual(labels[.running], "Running")
        XCTAssertEqual(labels[.stopped], "Stopped")
        XCTAssertEqual(labels[.error], "Error")
        XCTAssertEqual(labels[.needsApproval], "Needs approval")
        XCTAssertEqual(labels[.needsRepair], "Needs repair")
    }

    func testUsageMonitorLifecycleModelActionLabelsAndAvailability() {
        let service = UsageMonitorService(client: FakeSettingsUsageMonitorClient())
        let status = UsageMonitorLifecycleStatus(state: .needsRepair, writerOwner: .app, message: nil)
        let model = UsageMonitorLifecycleModel(
            status: status,
            availableActions: UsageMonitorLifecycleAction.allCases.filter {
                service.isActionAvailable($0, for: status.state)
            },
            localized: { L10n.shared[$0] }
        )

        XCTAssertEqual(model.availableActions, [.enable, .repair, .uninstall])
        XCTAssertEqual(L10n.shared[UsageMonitorLifecycleModel.actionLabelKey(for: .enable)], "Enable")
        XCTAssertEqual(L10n.shared[UsageMonitorLifecycleModel.actionLabelKey(for: .disable)], "Disable")
        XCTAssertEqual(L10n.shared[UsageMonitorLifecycleModel.actionLabelKey(for: .repair)], "Repair")
        XCTAssertEqual(L10n.shared[UsageMonitorLifecycleModel.actionLabelKey(for: .uninstall)], "Uninstall")
    }

    func testUsageMonitorUninstallCopyPreservesContinuityData() {
        let model = UsageMonitorLifecycleModel(
            status: UsageMonitorLifecycleStatus(state: .running, writerOwner: .helper, message: nil),
            availableActions: [.uninstall],
            localized: { L10n.shared[$0] }
        )

        XCTAssertTrue(model.uninstallConfirmation.contains("preserves usage continuity data"))
    }

    func testUsageRecoveryNotificationsModelDefaultsOffAndDeniedDisablesControls() {
        let model = UsageRecoveryNotificationsModel(
            permissionState: .denied,
            preferences: { tool, windowKind in
                UsageRecoveryReminderPreference(
                    tool: tool,
                    windowKind: windowKind,
                    isEnabled: false,
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            },
            localized: { L10n.shared[$0] }
        )

        XCTAssertEqual(model.toggles.count, 4)
        XCTAssertEqual(Set(model.toggles.map(\.id)), Set([
            "codex-fiveHour",
            "codex-weekly",
            "claudeCode-fiveHour",
            "claudeCode-weekly"
        ]))
        XCTAssertTrue(model.toggles.allSatisfy { !$0.isEnabled })
        XCTAssertFalse(model.controlsAreEnabled)
        XCTAssertEqual(model.statusText(localized: { L10n.shared[$0] }), "System notification permission is denied. Open Settings to grant access, then repair.")
    }

    func testThresholdPermissionPromptRequestsOnlyWhenNotDetermined() {
        let model = UsageThresholdPermissionPromptModel(permissionState: .notDetermined)

        XCTAssertTrue(model.shouldShow)
        XCTAssertFalse(model.opensSystemSettings)
        XCTAssertEqual(model.actionTitle(localized: { L10n.shared[$0] }), "Request permission")
        XCTAssertEqual(
            model.message(localized: { L10n.shared[$0] }),
            "Bough needs notification permission before it can send usage threshold alerts."
        )
    }

    func testThresholdPermissionPromptOpensSettingsWhenDenied() {
        let model = UsageThresholdPermissionPromptModel(permissionState: .denied)

        XCTAssertTrue(model.shouldShow)
        XCTAssertTrue(model.opensSystemSettings)
        XCTAssertEqual(model.actionTitle(localized: { L10n.shared[$0] }), "Open Settings")
        XCTAssertEqual(
            model.message(localized: { L10n.shared[$0] }),
            "Notifications are off in System Settings — enable them under Notifications → Bough to receive threshold alerts."
        )
    }

    func testThresholdPermissionPromptHidesWhenAuthorized() {
        let model = UsageThresholdPermissionPromptModel(permissionState: .authorized)

        XCTAssertFalse(model.shouldShow)
        XCTAssertFalse(model.opensSystemSettings)
    }

    func testUsagePageContainsNotificationSectionWithoutTrustDiagnosticsOrReminders() throws {
        let source = try settingsSource()
        let usagePage = try usagePageSource()

        XCTAssertTrue(usagePage.contains("UsageRecoveryNotificationsSection"))
        XCTAssertFalse(usagePage.contains("UsageTrustDiagnosticsSection"))
        XCTAssertFalse(usagePage.contains("usage_diagnostics_section"))
        XCTAssertTrue(source.contains("usage_notifications_action_open_settings"))
        XCTAssertTrue(usagePage.contains("NSApplication.didBecomeActiveNotification"))
        XCTAssertTrue(usagePage.contains("usageNotificationService.permissionState()"))
        XCTAssertFalse(source.contains("EventKit"))
        XCTAssertFalse(source.contains("EKReminder"))
    }

    func testUsageThresholdMasterToggleUsesUsageStoreNotAppStorage() throws {
        let usagePage = try usagePageSource()

        XCTAssertTrue(usagePage.contains("UsageThresholdNotificationsSection"))
        XCTAssertTrue(usagePage.contains("thresholdNotificationsMasterEnabled"))
        XCTAssertTrue(usagePage.contains("setThresholdNotificationsMasterEnabled"))
        XCTAssertFalse(
            usagePage.contains("@AppStorage(SettingsKey.notificationsThresholdMasterEnabled)"),
            "UsagePage must not use an independent AppStorage source for the threshold master toggle."
        )
        XCTAssertFalse(
            usagePage.contains("SettingsKey.notificationsThresholdMasterEnabled"),
            "UsagePage must not write the threshold master preference directly; use UsageStore instead."
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = Self.repoRoot
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func settingsSource() throws -> String {
        let settingsView = try sourceFile("Sources/Bough/SettingsView.swift")
        let settingsDirectory = Self.repoRoot
            .appendingPathComponent("Sources/Bough/Settings", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: settingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return settingsView
        }

        let splitSources = try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        return [settingsView, splitSources].joined(separator: "\n")
    }

    private func usagePageSource() throws -> String {
        let source = try settingsSource()
        return try XCTUnwrap(
            source.slice(from: "struct UsagePage: View", to: "private struct UsageDetailsSection: View")
        )
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class FakeSettingsUsageMonitorClient: UsageMonitorAppServiceClient {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let lower = range(of: start)?.lowerBound,
              let upper = self[lower...].range(of: end)?.lowerBound else {
            return nil
        }
        return String(self[lower..<upper])
    }
}
