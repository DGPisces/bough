import Foundation
import BoughCore

// MARK: - Usage Page Models

struct UsagePageActions {
    var refresh: () -> Void
    var enableCodexHooks: () -> Bool = { ConfigInstaller.setEnabled(source: "codex", enabled: true) }
}

/// Data-source row badge for one direct-OAuth usage channel (spec §9).
/// `degraded` reasons arrive pre-localized via `UsageStore.degradedReason`.
struct UsageOAuthBadgeModel: Equatable {
    enum Tone: Equatable { case ok, warning, off }
    let tone: Tone
    let text: String

    init(status: UsageOAuthChannelStatus, localized: (String) -> String) {
        switch status {
        case .unknown:
            tone = .off
            text = localized("usage_oauth_badge_unknown")
        case .connected:
            tone = .ok
            text = localized("usage_oauth_badge_connected")
        case .degraded(let reason, _):
            tone = .warning
            text = reason   // already localized by UsageStore.degradedReason
        case .missingCredentials(let reason, _):
            // Spec §9: no credentials is gray (with login guidance), not yellow.
            tone = .off
            text = reason   // already localized by UsageStore.degradedReason
        }
    }
}

/// Caption line under a usage window row: pace stage plus either the projected
/// exhaustion ETA or a lasts-to-reset note (spec §8.3). `text` is nil when the
/// slot has no live window or the pace cannot be computed (e.g. past reset).
struct UsagePaceRowModel: Equatable {
    let text: String?

    init(slot: UsageWindowSlot, now: Date, localized: (String) -> String) {
        guard case .available(let window) = slot,
              let pace = UsagePaceCalculator.pace(for: window, now: now) else {
            text = nil
            return
        }
        let stageText: String
        switch pace.stage {
        case .onTrack:
            stageText = localized("usage_pace_on_track")
        case .slightlyAhead, .ahead, .farAhead:
            stageText = String(format: localized("usage_pace_ahead_fmt"), Int(pace.deltaPercent.rounded()))
        case .slightlyBehind, .behind, .farBehind:
            stageText = String(format: localized("usage_pace_behind_fmt"), Int(abs(pace.deltaPercent).rounded()))
        }
        let tailText: String
        if let eta = pace.etaAt {
            tailText = String(format: localized("usage_pace_eta_fmt"),
                              DurationFormat.format(until: eta, now: now, .compact))
        } else {
            tailText = localized("usage_pace_lasts")
        }
        text = "\(stageText) · \(tailText)"
    }
}

struct UsageDetailsRow: Equatable {
    let title: String
    let value: String
}

struct UsageNotificationToggleModel: Equatable, Identifiable {
    let tool: UsageTool
    let windowKind: UsageWindowKind
    let title: String
    let isEnabled: Bool

    var id: String {
        "\(tool.rawValue)-\(windowKind.rawValue)"
    }
}

struct UsageRecoveryNotificationsModel: Equatable {
    let permissionState: UsageNotificationPermissionState
    let toggles: [UsageNotificationToggleModel]

    var controlsAreEnabled: Bool {
        permissionState.canSendNotifications
    }

    init(
        permissionState: UsageNotificationPermissionState,
        preferences: (UsageTool, UsageWindowKind) -> UsageRecoveryReminderPreference,
        localized: (String) -> String
    ) {
        self.permissionState = permissionState
        self.toggles = UsageTool.selectableQuotaProviders.flatMap { tool in
            [UsageWindowKind.fiveHour, .weekly].map { windowKind in
                UsageNotificationToggleModel(
                    tool: tool,
                    windowKind: windowKind,
                    title: "\(tool.settingsLabel(localized: localized)) \(windowKind.settingsLabel(localized: localized))",
                    isEnabled: preferences(tool, windowKind).isEnabled
                )
            }
        }
    }

    func statusText(localized: (String) -> String) -> String {
        switch permissionState {
        case .authorized, .provisional, .ephemeral:
            return localized("usage_notifications_permission_authorized")
        case .notDetermined:
            return localized("usage_notifications_permission_not_determined")
        case .denied:
            return localized("usage_notifications_permission_denied")
        case .unavailable:
            return localized("usage_notifications_permission_unavailable")
        case .failed(let message):
            return message
        }
    }
}

struct UsageThresholdPermissionPromptModel: Equatable {
    let permissionState: UsageNotificationPermissionState

    var shouldShow: Bool {
        !permissionState.canSendNotifications
    }

    var opensSystemSettings: Bool {
        switch permissionState {
        case .notDetermined:
            return false
        case .authorized, .provisional, .ephemeral:
            return false
        case .denied, .unavailable, .failed:
            return true
        }
    }

    func message(localized: (String) -> String) -> String {
        switch permissionState {
        case .authorized, .provisional, .ephemeral:
            return localized("usage_notifications_permission_authorized")
        case .notDetermined:
            return localized("usage_notifications_threshold_permission_request_hint")
        case .denied:
            return localized("usage_notifications_threshold_permission_denied_hint")
        case .unavailable:
            return localized("usage_notifications_permission_unavailable")
        case .failed(let message):
            return message
        }
    }

    func actionTitle(localized: (String) -> String) -> String {
        opensSystemSettings
            ? localized("usage_notifications_action_open_settings")
            : localized("usage_notifications_action_request_permission")
    }
}

struct CodexHooksDisabledNoticeModel: Equatable {
    let hooksDisabled: Bool
    let dismissed: Bool

    var showsBanner: Bool {
        hooksDisabled && !dismissed
    }

    var showsDisabledBadge: Bool {
        hooksDisabled
    }
}

struct CodexCLIOutdatedNoticeModel: Equatable {
    /// nil when detection failed (binary missing, timeout, unparseable) — banner not shown (D-09).
    let detectedVersion: String?
    /// Always reflects ConfigInstaller.codexCLIMinimumHooksVersion (e.g. "0.130.0").
    let minimumVersion: String
    /// Pulled from UserDefaults with key derived from detectedVersion (D-12).
    let dismissed: Bool

    var isOutdated: Bool {
        guard let detectedVersion else { return false }
        return !ConfigInstaller.versionAtLeast(detectedVersion, minimumVersion)
    }

    var showsBanner: Bool { isOutdated && !dismissed }

    var showsOutdatedBadge: Bool { isOutdated }
}

struct UsageDetailsModel {
    let status: String
    let lastRefresh: String
    let rows: [UsageDetailsRow]
    /// Signed-integer percentage rendered as the primary value next to the
    /// `today_safe` label (e.g. `100%`, `0%`, `-40%`). nil when no Today value
    /// is available (loading / unavailable). TODAY-15 / TODAY-12.
    let todayPctText: String?
    /// `今日额度 X.X% 周占比` — verbatim mixed Chinese/numeric literal.
    /// Identical across en and zh locales per 05-UI-SPEC TODAY-16.
    let todayAllowanceLineText: String?
    /// `已用 X.X% 周占比` — verbatim. Computed from `today.basis` so the
    /// number always matches the calculator's `today_used` (no separate
    /// rederivation, no drift).
    let todayUsedLineText: String?
    let todayResetExplanationText: String?
    /// Drives the inline first-launch notice. True only when the accumulator
    /// flagged this process as the first-launch baseline source (TODAY-11 /
    /// D-13 / D-14). Never persisted.
    let isFirstLaunchBaseline: Bool
    /// Pace caption under the 5h row (spec §8.3). nil when no live window.
    let fiveHourPaceText: String?
    /// Pace caption under the weekly row. nil when no live window.
    let weeklyPaceText: String?

    init(snapshot: UsageSnapshot, isFirstLaunchBaseline: Bool = false, now: Date = Date()) {
        status = Self.statusText(for: snapshot.availability)
        lastRefresh = Self.lastRefreshText(snapshot.lastRefresh, now: now)
        rows = [
            UsageDetailsRow(title: L10n.shared["usage_5h"], value: Self.valueText(for: snapshot.fiveHour, now: now, format: .compact)),
            UsageDetailsRow(title: L10n.shared["usage_week"], value: Self.valueText(for: snapshot.weekly, now: now, format: .fullDHM)),
        ]
        fiveHourPaceText = UsagePaceRowModel(slot: snapshot.fiveHour, now: now, localized: { L10n.shared[$0] }).text
        weeklyPaceText = UsagePaceRowModel(slot: snapshot.weekly, now: now, localized: { L10n.shared[$0] }).text
        if let today = snapshot.today,
           today.pct.isFinite,
           today.todayAllowanceOfWeek.isFinite {
            // Int conversion preserves the leading `-` for overdraft; no clamp.
            todayPctText = "\(Int(today.pct.rounded()))%"
            // `today_used` derived from the calculator's basis so the two
            // numbers never drift (Phase 5 spec contract for TODAY-16).
            // Baseline is re-locked at a weekly reset (spec §8.1), so the delta from
            // baseline IS today's usage — no cross-reset segment math.
            let todayUsed = max(0, today.basis.weeklyUsedNow - today.basis.weeklyUsedAtDayStart)
            todayAllowanceLineText = String(format: "今日额度 %.1f%% 周占比", today.todayAllowanceOfWeek)
            todayUsedLineText = String(format: "已用 %.1f%% 周占比", todayUsed)
            todayResetExplanationText = Self.todayResetExplanation(for: today.basis.resetProvenance)
        } else {
            todayPctText = nil
            todayAllowanceLineText = nil
            todayUsedLineText = nil
            todayResetExplanationText = nil
        }
        self.isFirstLaunchBaseline = isFirstLaunchBaseline
    }

    private static func todayResetExplanation(for provenance: UsageResetProvenance) -> String? {
        switch provenance {
        case .explicitReset:
            return L10n.shared["today_reset_explicit"]
        case .implicitReset:
            return L10n.shared["today_reset_implicit"]
        case .ordinaryProgress, .correctionIgnored:
            return nil
        }
    }

    private static func statusText(for availability: UsageAvailability) -> String {
        switch availability {
        case .loading:
            return L10n.shared["loading"]
        case .available:
            return L10n.shared["available"]
        case .partial:
            return L10n.shared["partial"]
        case .stale(let reason):
            return staleLabel(for: reason)
        case .unavailable:
            return L10n.shared["unavailable"]
        }
    }

    private static func valueText(for slot: UsageWindowSlot, now: Date, format: DurationFormat) -> String {
        switch slot {
        case .loading:
            return L10n.shared["loading"]
        case .available(let snapshot):
            return windowText(snapshot, now: now, format: format)
        case .stale(let snapshot, let reason):
            return "\(windowText(snapshot, now: now, format: format)) · \(staleLabel(for: reason))"
        case .unavailable:
            return L10n.shared["unavailable"]
        }
    }

    private static func staleLabel(for reason: String) -> String {
        reason == L10n.shared["usage_refresh_failed"] ? reason : L10n.shared["stale"]
    }

    private static func windowText(_ snapshot: UsageWindowSnapshot, now: Date, format: DurationFormat) -> String {
        let percent = Int((100 - snapshot.usedPercent).rounded())
        let reset = UsageRelativeTimeFormatter.windowDuration(until: snapshot.resetsAt, now: now, format: format)
        return "\(percent)% · \(L10n.shared["usage_reset_in"]) \(reset)"
    }

    private static func lastRefreshText(_ date: Date?, now: Date) -> String {
        guard let date else {
            return L10n.shared["usage_refresh_never_value"]
        }
        return String(
            format: L10n.shared["usage_elapsed_ago"],
            UsageRelativeTimeFormatter.elapsed(since: date, now: now)
        )
    }
}

enum UsageRelativeTimeFormatter {
    static func elapsed(since date: Date, now: Date) -> String {
        duration(from: date, to: now)
    }

    static func duration(until date: Date, now: Date) -> String {
        duration(from: now, to: date)
    }

    static func windowDuration(until date: Date, now: Date, format: DurationFormat) -> String {
        DurationFormat.format(until: date, now: now, format)
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        return "\(hours / 24)d"
    }
}

private extension String {
    func localized(using localized: (String) -> String) -> String {
        localized(self)
    }
}

private extension UsageTool {
    func settingsLabel(localized: (String) -> String) -> String {
        switch self {
        case .codex:
            return localized("usage_provider_codex")
        case .claudeCode:
            return localized("usage_provider_claude_code")
        }
    }
}

private extension UsageWindowKind {
    func settingsLabel(localized: (String) -> String) -> String {
        switch self {
        case .fiveHour:
            return localized("usage_5h")
        case .weekly:
            return localized("usage_week")
        }
    }
}
