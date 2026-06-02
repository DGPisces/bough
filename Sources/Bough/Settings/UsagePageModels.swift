import Foundation
import BoughCore

// MARK: - Usage Page Models

struct UsagePageActions {
    var refresh: () -> Void
    var enableCodexHooks: () -> Bool = { ConfigInstaller.setEnabled(source: "codex", enabled: true) }
}

// MARK: - Claude Code statusLine UI state (D-07)

/// Phase 21 / D-07: four-way classification of the Settings → Hooks → Claude Code 集成
/// section, driven by the on-disk `statusLine.command` and the chain-wrapper sentinel.
/// Pure value type — the classifier is a pure function (`classifyClaudeCodeStatusLineUIState`)
/// so it can be unit-tested without spinning up SwiftUI.
enum ClaudeCodeStatusLineUIState: Equatable {
    /// settings.json points at the Bough bridge directly (no third-party tool present).
    case installedBoughOnly
    /// settings.json points at the Bough wrapper; sentinel decoded — chained with `prevCmdBasename`.
    case installedChained(prevCmdBasename: String)
    /// settings.json carries a non-Bough statusLine command (starship / ccusage / etc.).
    /// Install button promotes this to chain-safe coexistence.
    case otherToolActive(prevCmdBasename: String)
    /// settings.json missing or has no statusLine key — clean slate.
    case notInstalledEmpty
}

/// WR-1 fold-in: classifier extracted as pure function so unit tests can cover every
/// branch (installed / chained / conflict / empty) without instantiating a SwiftUI view.
/// `currentCommand` is the raw string from settings.json (`nil` if file absent or no key);
/// `proposedBridgePath` is `Bundle.module`-resolved bridge (`nil` if bundle lookup failed);
/// `wrapperPath` is the wrapper-install path constant; `wrapperPrevCmd` is the wrapper's
/// decoded sentinel (`nil` when not chained or sentinel corrupt).
func classifyClaudeCodeStatusLineUIState(
    currentCommand: String?,
    proposedBridgePath: String?,
    wrapperPath: String,
    wrapperPrevCmd: String?
) -> ClaudeCodeStatusLineUIState {
    guard let current = currentCommand, !current.isEmpty else {
        return .notInstalledEmpty
    }
    if let proposed = proposedBridgePath, current == proposed {
        return .installedBoughOnly
    }
    if current == wrapperPath {
        // We are chained. Decoded sentinel gives the true prev_cmd; if the sentinel is
        // corrupt, fall back to the wrapper basename rather than spoofing a fake basename
        // (T-21-13 mitigation — UI never claims a prev that uninstall would not restore).
        let basename: String
        if let prev = wrapperPrevCmd {
            basename = (prev as NSString).lastPathComponent
        } else {
            basename = (wrapperPath as NSString).lastPathComponent
        }
        return .installedChained(prevCmdBasename: basename)
    }
    return .otherToolActive(prevCmdBasename: (current as NSString).lastPathComponent)
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

struct ClaudeCodeHookConnectivityModel: Equatable {
    let hookInstalled: Bool
    let socketReachable: Bool

    enum ConnectivityState: Equatable {
        case connected
        case warning
        case absent
    }

    var state: ConnectivityState {
        if !hookInstalled { return .absent }
        return socketReachable ? .connected : .warning
    }

    /// Always shown when Claude Code is the selected tool.
    var showsBadge: Bool { true }
}

// MARK: - StatusLine connectivity (Regression guard)
//
// Rate-limit data for Claude Code flows in via the statusLine bridge —
// `~/.bough/claude-usage.json` is written by `bough-statusline-bridge.sh`
// on each Claude Code turn. The data-source row's "Connected" badge in the
// Usage page must reflect whether that data pipeline is alive, not whether
// the hook entry exists in `~/.claude/settings.json` (the round-4 binding,
// which lit the green dot even when the statusLine wrapper had never run).
//
// State semantics:
//   .connected — Bough's statusLine is installed and claude-usage.json exists,
//                parses cleanly, and contains at least one recognized
//                rate_limits window. Quota staleness is shown in the usage
//                rows; the badge only describes pipeline readability.
//   .warning   — Bough's statusLine is installed and the file exists, but the
//                payload shape is not readable.
//   .absent    — file missing entirely or unreadable. Wrapper not installed
//                or never ran.
//
// `ClaudeCodeHookConnectivityModel` (above) intentionally stays in place
// for any future surface that wants raw hook-state semantics; this model
// is the data-source-row's specific binding.
struct ClaudeCodeStatusLineConnectivityModel: Equatable {
    /// `~/.bough/claude-usage.json` exists.
    let fileExists: Bool
    /// File parsed as JSON AND contained at least one recognized rate-limit
    /// window (five_hour OR seven_day used_percentage).
    let payloadValid: Bool
    /// File mtime is within `freshnessWindow`. Kept for diagnostics; the badge
    /// no longer treats an idle Claude Code session as disconnected.
    let isFresh: Bool?

    enum ConnectivityState: Equatable {
        case connected
        case warning
        case absent
    }

    var state: ConnectivityState {
        guard fileExists else { return .absent }
        return payloadValid ? .connected : .warning
    }

    var showsBadge: Bool { true }
}

/// Reads `~/.bough/claude-usage.json` synchronously and classifies the
/// data-source connectivity. Disk I/O is cheap (single small JSON), so this
/// runs on the calling thread; it is called from `body` and recomputes on
/// every render dependency change (e.g. statusLineMutationTick bump).
///
/// - Parameters:
///   - path: Override the default `~/.bough/claude-usage.json` path. Tests
///     pass a temporary directory.
///   - freshnessWindow: Used only to populate diagnostic `isFresh`. Idle
///     Claude Code sessions must not read as disconnected just because the
///     last statusLine payload is older than the window.
///   - now: Clock source for testability. Default `Date()`.
@MainActor
func evaluateClaudeCodeStatusLineConnectivity(
    path: String = NSHomeDirectory() + "/.bough/claude-usage.json",
    freshnessWindow: TimeInterval = 600,
    now: Date = Date(),
    statusLineInstalled: Bool? = nil
) -> ClaudeCodeStatusLineConnectivityModel {
    let fm = FileManager.default
    // Regression guard: precondition gate. The data-source row
    // must report `.absent` whenever Bough's statusLine wrapper / bridge is
    // not installed, regardless of any leftover ~/.bough/claude-usage.json.
    // Without this, a stale file inside the 10-minute freshness window
    // would keep the green dot lit immediately after uninstall. Callers
    // (tests) can inject `statusLineInstalled:` to exercise this branch
    // deterministically; the default reads ConfigInstaller live.
    let installed: Bool = statusLineInstalled ?? {
        guard let cmd = ConfigInstaller.currentClaudeCodeStatusLineCommand() else { return false }
        let wrapper = ConfigInstaller.claudeCodeStatusLineWrapperInstallPath()
        if cmd == wrapper { return true }
        if let proposed = ConfigInstaller.proposedClaudeCodeStatusLineCommand(),
           cmd == proposed { return true }
        // Anything else (a third-party tool, an old Bough path, etc.) is
        // treated as "Bough's pipeline is not the active source" — UI
        // should show .absent until the user explicitly installs.
        return false
    }()
    guard installed else {
        return ClaudeCodeStatusLineConnectivityModel(
            fileExists: false, payloadValid: false, isFresh: nil
        )
    }
    guard fm.fileExists(atPath: path) else {
        return ClaudeCodeStatusLineConnectivityModel(
            fileExists: false, payloadValid: false, isFresh: nil
        )
    }
    let url = URL(fileURLWithPath: path)
    let data = (try? Data(contentsOf: url)) ?? Data()
    let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    let isFresh = mtime.map { now.timeIntervalSince($0) <= freshnessWindow } ?? false

    // Probe just the rate_limits shape — we accept the same key variants the
    // Claude bridge emits (real Anthropic statusline payloads use snake_case;
    // accept camelCase variants defensively to match UsageModels.parse).
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rateLimits = json["rate_limits"] as? [String: Any]
    else {
        return ClaudeCodeStatusLineConnectivityModel(
            fileExists: true, payloadValid: false, isFresh: isFresh
        )
    }
    let fiveHourKeys = ["five_hour", "fiveHour", "primary"]
    let sevenDayKeys = ["seven_day", "sevenDay", "weekly", "secondary"]
    func hasUsedPct(in window: [String: Any]) -> Bool {
        // Accept snake_case or camelCase; numeric or string-encoded.
        return window["used_percentage"] != nil
            || window["usedPercentage"] != nil
            || window["used_pct"] != nil
    }
    let fiveHourValid = fiveHourKeys.contains { key in
        (rateLimits[key] as? [String: Any]).map(hasUsedPct(in:)) ?? false
    }
    let sevenDayValid = sevenDayKeys.contains { key in
        (rateLimits[key] as? [String: Any]).map(hasUsedPct(in:)) ?? false
    }
    let payloadValid = fiveHourValid || sevenDayValid
    return ClaudeCodeStatusLineConnectivityModel(
        fileExists: true, payloadValid: payloadValid, isFresh: isFresh
    )
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

    init(snapshot: UsageSnapshot, isFirstLaunchBaseline: Bool = false, now: Date = Date()) {
        status = Self.statusText(for: snapshot.availability)
        lastRefresh = Self.lastRefreshText(snapshot.lastRefresh, now: now)
        rows = [
            UsageDetailsRow(title: L10n.shared["usage_5h"], value: Self.valueText(for: snapshot.fiveHour, now: now, format: .compact)),
            UsageDetailsRow(title: L10n.shared["usage_week"], value: Self.valueText(for: snapshot.weekly, now: now, format: .fullDHM)),
        ]
        if let today = snapshot.today,
           today.pct.isFinite,
           today.todayAllowanceOfWeek.isFinite {
            // Int conversion preserves the leading `-` for overdraft; no clamp.
            todayPctText = "\(Int(today.pct.rounded()))%"
            // `today_used` derived from the calculator's basis so the two
            // numbers never drift (Phase 5 spec contract for TODAY-16).
            let todayUsed: Double = {
                if today.basis.weeklyResetAlreadyFiredToday {
                    return max(0, (100.0 - today.basis.weeklyUsedAtDayStart) + today.basis.weeklyUsedNow)
                }
                return max(0, today.basis.weeklyUsedNow - today.basis.weeklyUsedAtDayStart)
            }()
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

private extension UsageSnapshot {
    var providerSourceLabel: String? {
        for slot in [fiveHour, weekly] {
            switch slot {
            case .available(let snapshot), .stale(let snapshot, _):
                if !snapshot.sourceLabel.isEmpty { return snapshot.sourceLabel }
            case .loading, .unavailable:
                continue
            }
        }
        return nil
    }
}

private extension UsageAvailability {
    var reason: String? {
        switch self {
        case .partial(let reason), .stale(let reason), .unavailable(let reason):
            return reason
        case .loading:
            return L10n.shared["loading"]
        case .available:
            return nil
        }
    }

    var isPlainAvailable: Bool {
        if case .available = self { return true }
        return false
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
