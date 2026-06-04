import Foundation

enum SettingsSearchText: Hashable {
    case key(String)
    case literal(String)

    var localized: String {
        switch self {
        case .key(let key):
            return L10n.shared[key]
        case .literal(let value):
            return value
        }
    }
}

struct SettingsSearchEntry: Identifiable {
    enum Kind: Int {
        case page = 0
        case section = 1
        case control = 2

        var rankBase: Int {
            switch self {
            case .control: return 0
            case .section: return 100
            case .page: return 200
            }
        }
    }

    let id: String
    let page: SettingsPage
    let targetID: SettingsTargetID
    let kind: Kind
    let title: SettingsSearchText
    let description: SettingsSearchText
    let path: [SettingsSearchText]
    let aliases: [String]
    let symbolName: String?
    let priority: Int
    let isVisible: () -> Bool
}

struct SettingsSearchResult: Identifiable, Hashable {
    let id: String
    let page: SettingsPage
    let targetID: SettingsTargetID
    let kind: SettingsSearchEntry.Kind
    let title: String
    let description: String
    let path: String
    let symbolName: String?
}

enum SettingsSearchIndex {
    static let maximumQueryLength = 80

    static var entries: [SettingsSearchEntry] {
        entries(codingSessionsEnabled: CodingSessionsSettings.isEnabled())
    }

    static func entries(codingSessionsEnabled: Bool) -> [SettingsSearchEntry] {
        entries(codingSessionsEnabled: codingSessionsEnabled, isHomebrewInstall: currentIsHomebrewInstall)
    }

    static func entries(
        codingSessionsEnabled: Bool,
        isHomebrewInstall: Bool
    ) -> [SettingsSearchEntry] {
        SettingsSearchCatalog.entries(isHomebrewInstall: isHomebrewInstall).filter {
            SettingsSidebarModel.isVisible(page: $0.page, codingSessionsEnabled: codingSessionsEnabled)
                && $0.isVisible()
        }
    }

    static func search(
        _ query: String,
        codingSessionsEnabled: Bool = CodingSessionsSettings.isEnabled(),
        isHomebrewInstall: Bool = currentIsHomebrewInstall
    ) -> [SettingsSearchResult] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return entries(codingSessionsEnabled: codingSessionsEnabled, isHomebrewInstall: isHomebrewInstall).enumerated()
            .compactMap { offset, entry -> (rank: Int, offset: Int, result: SettingsSearchResult)? in
                guard let rank = rank(entry: entry, query: normalizedQuery) else { return nil }
                return (rank, offset, makeResult(entry))
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.offset < rhs.offset
            }
            .map(\.result)
    }

    private static func makeResult(_ entry: SettingsSearchEntry) -> SettingsSearchResult {
        SettingsSearchResult(
            id: entry.id,
            page: entry.page,
            targetID: entry.targetID,
            kind: entry.kind,
            title: entry.title.localized,
            description: entry.description.localized,
            path: entry.path.map(\.localized).joined(separator: " > "),
            symbolName: entry.symbolName
        )
    }

    private static func rank(entry: SettingsSearchEntry, query: String) -> Int? {
        let title = normalized(entry.title.localized, cap: false)
        let description = normalized(entry.description.localized, cap: false)
        let path = normalized(entry.path.map(\.localized).joined(separator: " "), cap: false)
        let aliases = entry.aliases.map { normalized($0, cap: false) }
        let base = entry.kind.rankBase + entry.priority

        if title == query || title.hasPrefix(query) {
            return base
        }
        if title.contains(query) {
            return base + 10
        }
        if aliases.contains(where: { $0 == query || $0.hasPrefix(query) || query.hasPrefix($0) }) {
            return base + 20
        }
        if aliases.contains(where: { $0.contains(query) || query.contains($0) }) {
            return base + 25
        }
        if description.contains(query) {
            return base + 35
        }
        if path.contains(query) {
            return base + 45
        }
        return nil
    }

    static func normalized(_ rawValue: String, cap: Bool = true) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = cap ? String(trimmed.prefix(maximumQueryLength)) : trimmed
        return capped
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    private static var currentIsHomebrewInstall: Bool {
        UpdateChecker.isHomebrewInstall(
            bundlePath: Bundle.main.bundlePath,
            resolvedBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path
        )
    }
}

enum SettingsSearchCatalog {
    static func entries(isHomebrewInstall: Bool) -> [SettingsSearchEntry] {
        pages + sections(isHomebrewInstall: isHomebrewInstall) + controls(isHomebrewInstall: isHomebrewInstall)
    }

    private static var pages: [SettingsSearchEntry] {
        [
            .page(.general, "settings_search_page_general", "settings_search_desc_page_general", ["settings_search_page_general"], ["general", "preferences", "coding sessions", "通用", "偏好设置", "编程会话"], "gearshape"),
            .page(.notch, "appearance", "settings_search_desc_page_appearance", ["appearance"], ["display", "island", "panel", "灵动岛", "刘海", "面板", "外观"], "display"),
            .page(.music, "music", "settings_search_desc_page_music", ["music"], ["music", "now playing", "qq music", "apple music", "音乐", "播放"], "music.note"),
            .page(.airDrop, "airdrop_section", "settings_search_desc_page_airdrop", ["airdrop_section"], ["airdrop", "drag to airdrop", "share", "隔空投送", "拖拽投送"], "square.and.arrow.up"),
            .page(.sessionDisplay, "session_display", "settings_search_desc_page_session_display", ["session_display"], ["session display", "session list", "agent details", "tool status", "会话显示", "工具状态"], "rectangle.split.2x1"),
            .page(.mascot, "mascot", "settings_search_desc_page_mascot", ["mascot"], ["mascot", "character", "avatar", "角色", "形象"], "person.2"),
            .page(.sound, "sound", "settings_search_desc_page_sound", ["sound"], ["sound", "audio", "effects", "声音", "音效"], "speaker.wave.2"),
            .page(.usageNotifications, "usage_notifications", "settings_search_desc_page_usage_notifications", ["usage_notifications"], ["usage", "quota", "notifications", "用量", "额度", "通知"], "chart.line.uptrend.xyaxis"),
            .page(.integrations, "integrations", "settings_search_desc_page_integrations", ["integrations"], ["integrations", "cli", "hooks", "remote", "webhook", "集成", "钩子", "远程"], "link.circle"),
            .page(.advanced, "advanced", "settings_search_desc_page_advanced", ["advanced"], ["advanced", "automation", "diagnostics", "高级", "诊断", "自动化"], "wrench.and.screwdriver"),
            .page(.about, "about", "settings_search_desc_page_about", ["about"], ["about", "version", "github", "关于", "版本"], "info.circle"),
        ]
    }

    private static func sections(isHomebrewInstall: Bool) -> [SettingsSearchEntry] {
        [
            .section(.general, .generalCodingSessions, "coding_sessions", "settings_search_desc_coding_sessions", ["general", "coding_sessions"], ["coding mode", "product mode", "coding sessions", "编程会话", "产品模式"], "hammer"),
            .section(.general, .generalWelcomeGuide, "welcome_guide_settings_section", "settings_search_desc_welcome_guide", ["general", "welcome_guide_settings_section"], ["welcome guide", "onboarding", "setup assistant", "new user setup", "欢迎引导", "新手引导"], "sparkles"),
            .section(.general, .generalLanguage, "language", "settings_search_desc_language", ["general", "language"], ["locale", "translation", "语言", "本地化"], "globe"),
            .section(.general, .generalStartup, "settings_section_startup", "settings_search_desc_startup", ["general", "settings_section_startup"], ["launch", "login", "startup", "开机", "登录启动", "自启动"], "power"),

            .section(.notch, .notchDisplay, "display", "settings_search_desc_notch_display", ["appearance", "display"], ["screen", "monitor", "显示器", "屏幕"], "display"),
            .section(.notch, .notchVisibility, "settings_section_visibility", "settings_search_desc_notch_visibility", ["appearance", "settings_section_visibility"], ["hide", "fullscreen", "idle", "隐藏", "全屏", "空闲"], "eye.slash"),
            .section(.notch, .notchExpansion, "settings_section_expansion", "settings_search_desc_notch_expansion", ["appearance", "settings_section_expansion"], ["collapse", "mouse", "haptic", "收起", "鼠标", "触觉"], "arrow.up.left.and.arrow.down.right"),
            .section(.notch, .notchSizeLayout, "settings_section_size_layout", "settings_search_desc_notch_size_layout", ["appearance", "settings_section_size_layout"], ["size", "height", "width", "layout", "尺寸", "高度", "宽度"], "ruler"),

            .section(.music, .musicControls, "music_controls_section", "settings_search_desc_music_controls", ["music", "music_controls_section"], ["music", "now playing", "qq music", "apple music", "音乐", "播放", "正在播放"], "music.note"),

            .section(.airDrop, .airDropEnabled, "airdrop_section", "settings_search_desc_airdrop", ["airdrop_section"], ["airdrop", "drag to airdrop", "share", "隔空投送", "拖拽投送"], "square.and.arrow.up"),

            .section(.sessionDisplay, .sessionDisplayExpansion, "settings_section_expansion", "settings_search_desc_session_display_expansion", ["session_display", "settings_section_expansion"], ["expand", "collapse", "completion", "展开", "收起", "完成"], "arrow.up.left.and.arrow.down.right"),
            .section(.sessionDisplay, .sessionDisplayList, "settings_section_session_list", "settings_search_desc_session_display_list", ["session_display", "settings_section_session_list"], ["visible sessions", "session count", "会话数量"], "number"),
            .section(.sessionDisplay, .sessionDisplayContent, "content", "settings_search_desc_notch_content", ["session_display", "content"], ["font", "agent details", "tool status", "字体", "内容", "工具状态"], "textformat.size"),

            .section(.mascot, .mascotDefaultSource, "default_mascot", "default_mascot_desc", ["mascot", "default_mascot"], ["default source", "default mascot", "默认角色", "默认来源"], "person.crop.circle"),
            .section(.mascot, .mascotPreview, "preview", "settings_search_desc_mascot_preview", ["mascot", "preview"], ["preview status", "预览", "状态"], "play.rectangle"),
            .section(.mascot, .mascotAnimation, "settings_section_animation", "settings_search_desc_mascot_animation", ["mascot", "settings_section_animation"], ["speed", "animation", "动画", "速度"], "speedometer"),

            .section(.sound, .soundMaster, "settings_section_sound_master", "settings_search_desc_sound_master", ["sound", "settings_section_sound_master"], ["volume", "master", "音量", "总开关"], "speaker.wave.2"),
            .section(.sound, .soundEvents, "settings_section_sound_events", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["session start", "approval", "task complete", "事件音", "完成音", "审批音"], "waveform", visible: soundEnabled),

            .section(.usageNotifications, .usageData, "usage_data_section", "settings_search_desc_usage_data", ["usage_notifications", "usage_data_section"], ["data source", "providers", "usage details", "数据源", "统计"], "chart.bar"),
            .section(.usageNotifications, .usageBackgroundMonitor, "usage_monitor_section", "settings_search_desc_usage_monitor", ["usage_notifications", "usage_monitor_section"], ["background monitor", "launch agent", "后台监控", "修复"], "waveform.path.ecg"),
            .section(.usageNotifications, .usageRecoveryNotifications, "usage_notifications_section", "settings_search_desc_usage_recovery", ["usage_notifications", "usage_notifications_section"], ["recovery", "reminder", "提醒", "恢复提醒"], "bell.badge"),
            .section(.usageNotifications, .usageThresholdAlerts, "usage_notifications_threshold_section_title", "settings_search_desc_usage_threshold", ["usage_notifications", "usage_notifications_threshold_section_title"], ["threshold", "alert", "quota alert", "阈值", "提醒"], "bell.and.waves.left.and.right"),

            .section(.integrations, .integrationsLocalTools, "settings_section_local_ai_tools", "settings_search_desc_local_tools", ["integrations", "settings_section_local_ai_tools"], ["claude code", "codex", "opencode", "local tools", "本地工具", "本地 CLI"], "terminal"),
            .section(.integrations, .integrationsCustomCLIs, "settings_custom_clis_section", "settings_search_desc_custom_clis", ["integrations", "settings_custom_clis_section"], ["custom cli", "custom hooks", "自定义 CLI", "自定义钩子"], "plus.rectangle.on.rectangle"),
            .section(.integrations, .integrationsRemoteHosts, "remote_hosts", "settings_search_desc_remote_hosts", ["integrations", "remote_hosts"], ["ssh", "remote hosts", "远程主机", "SSH"], "network"),
            .section(.integrations, .integrationsWebhooks, "webhook_title", "settings_search_desc_webhooks", ["integrations", "webhook_title"], ["webhook", "external endpoint", "event forwarding", "外部端点", "事件转发"], "point.3.connected.trianglepath.dotted"),

            .section(.advanced, .advancedAutomation, "auto_approve_tools", "settings_search_desc_automation", ["advanced", "auto_approve_tools"], ["automation", "auto approve", "自动批准", "自动化"], "bolt.badge.checkmark"),
            .section(.advanced, .advancedHookFilters, "excluded_hook_cwd_title", "settings_search_desc_hook_filters", ["advanced", "excluded_hook_cwd_title"], ["hook filter", "excluded cwd", "路径过滤", "hook 过滤"], "line.3.horizontal.decrease.circle"),
            .section(.advanced, .advancedSessionHandling, "settings_section_session_handling", "settings_search_desc_session_handling", ["advanced", "settings_section_session_handling"], ["session cleanup", "rotation", "tool history", "会话清理", "轮转", "工具历史"], "clock.arrow.circlepath"),
            .section(.advanced, .advancedDiagnosticsRepair, "settings_section_diagnostics_repair", "settings_search_desc_diagnostics", ["advanced", "settings_section_diagnostics_repair"], ["diagnostics", "repair", "export", "诊断", "修复", "导出"], "square.and.arrow.up"),

            .section(
                .about,
                .aboutUpdates,
                isHomebrewInstall ? "update_homebrew_managed_title" : "about_auto_update_section",
                "settings_search_desc_updates",
                ["about", isHomebrewInstall ? "update_homebrew_managed_title" : "about_auto_update_section"],
                isHomebrewInstall
                    ? ["updates", "homebrew", "brew", "cask", "更新", "自动更新"]
                    : ["updates", "sparkle", "software update", "更新", "自动更新"],
                isHomebrewInstall ? "terminal" : "arrow.triangle.2.circlepath"
            ),
            .section(.about, .aboutDiagnostics, "export_diagnostics", "settings_search_desc_about_diagnostics", ["about", "export_diagnostics"], ["diagnostics", "logs", "诊断", "日志"], "ladybug"),
        ]
    }

    private static func controls(isHomebrewInstall: Bool) -> [SettingsSearchEntry] {
        generalControls
            + notchControls
            + musicControls
            + airDropControls
            + sessionDisplayControls
            + mascotControls
            + soundControls
            + usageControls
            + integrationControls
            + advancedControls
            + aboutControls(isHomebrewInstall: isHomebrewInstall)
    }

    private static var generalControls: [SettingsSearchEntry] {
        [
            .control(.general, .generalCodingSessions, "coding_sessions", "settings_search_desc_coding_sessions", ["general", "coding_sessions"], ["coding mode", "product mode", "pause integrations", "hide coding settings", "编程会话", "隐藏编程设置"], "hammer"),
            .control(.general, .generalWelcomeGuide, "welcome_guide_open_settings", "settings_search_desc_welcome_guide", ["general", "welcome_guide_settings_section"], ["welcome guide", "open welcome guide", "onboarding", "setup assistant", "打开欢迎引导", "新手引导"], "sparkles"),
            .control(.general, .generalLanguage, "language", "settings_search_desc_language", ["general", "language"], ["English", "Chinese", "中文", "系统语言", "language picker"], "globe"),
            .control(.general, .generalStartup, "launch_at_login", "launch_at_login_desc", ["general", "settings_section_startup"], ["startup", "login item", "开机启动", "登录启动"], "power"),
        ]
    }

    private static var notchControls: [SettingsSearchEntry] {
        [
            .control(.notch, .notchDisplayChoice, "display", "settings_search_desc_notch_display", ["appearance", "display"], ["screen", "monitor", "built-in display", "显示器", "屏幕"], "display"),
            .control(.notch, .notchHorizontalDrag, "allow_horizontal_drag", "allow_horizontal_drag_desc", ["appearance", "display"], ["drag notch", "move island", "水平拖动", "移动灵动岛"], "arrow.left.and.right"),
            .control(.notch, .notchHideInFullscreen, "hide_in_fullscreen", "hide_in_fullscreen_desc", ["appearance", "settings_section_visibility"], ["fullscreen hide", "全屏隐藏"], "rectangle.on.rectangle.slash"),
            .control(.notch, .notchHideWhenIdle, "hide_when_no_session", "hide_when_no_session_desc", ["appearance", "settings_section_visibility"], ["hide idle", "hide when idle", "空闲隐藏", "无会话隐藏"], "eye.slash"),
            .control(.notch, .notchCollapseOnMouseLeave, "collapse_on_mouse_leave", "collapse_on_mouse_leave_desc", ["appearance", "settings_section_expansion"], ["auto collapse", "mouse leave", "鼠标移开", "自动收起"], "arrow.down.right.and.arrow.up.left"),
            .control(.notch, .notchHapticOnHover, "haptic_on_hover", "haptic_on_hover_desc", ["appearance", "settings_section_expansion"], ["haptic feedback", "trackpad", "触觉反馈", "震动"], "waveform.path"),
            .control(.notch, .notchHapticIntensity, "haptic_medium", "haptic_on_hover_desc", ["appearance", "settings_section_expansion"], ["haptic intensity", "light haptic", "strong haptic", "触觉强度"], "slider.horizontal.3", visible: hapticEnabled),
            .control(.notch, .notchIslandWidth, "collapsed_width_scale", "collapsed_width_scale_desc", ["appearance", "settings_section_size_layout"], ["island width", "collapsed width", "灵动岛宽度"], "ruler"),
            .control(.notch, .notchTopBarHeight, "notch_height_mode", "notch_height_mode_desc", ["appearance", "settings_section_size_layout"], ["top bar height", "custom height", "menu bar height", "顶部高度", "自定义高度"], "rectangle.topthird.inset.filled"),
            .control(.notch, .notchCustomHeight, "custom_notch_height", "notch_height_mode_desc", ["appearance", "settings_section_size_layout"], ["custom height", "自定义高度"], "slider.horizontal.3", priority: -5, visible: customNotchHeightVisible),
        ]
    }

    private static var musicControls: [SettingsSearchEntry] {
        [
            .control(.music, .musicShowMusicControls, "show_music_controls", "show_music_controls_desc", ["music", "music_controls_section"], ["music controls", "now playing", "qq music", "apple music", "音乐控制", "显示音乐"], "music.note"),
            .control(.music, .musicCompactBarPriority, "compact_bar_priority", "compact_bar_priority_desc", ["music", "music_controls_section"], ["music priority", "ai priority", "compact priority", "紧凑栏优先级", "音乐优先"], "arrow.up.arrow.down"),
        ]
    }

    private static var airDropControls: [SettingsSearchEntry] {
        [
            .control(.airDrop, .airDropEnabled, "airdrop_enabled", "airdrop_enabled_desc", ["airdrop_section"], ["airdrop", "drag to airdrop", "panel entry", "隔空投送", "拖拽投送"], "square.and.arrow.up"),
        ]
    }

    private static var sessionDisplayControls: [SettingsSearchEntry] {
        [
            .control(.sessionDisplay, .sessionDisplayAutoCollapseAfterJump, "auto_collapse_after_session_jump", "auto_collapse_after_session_jump_desc", ["session_display", "settings_section_expansion"], ["jump collapse", "session jump", "跳转后收起"], "arrow.turn.down.left"),
            .control(.sessionDisplay, .sessionDisplayAutoExpandOnCompletion, "auto_expand_on_completion", "auto_expand_on_completion_desc", ["session_display", "settings_section_expansion"], ["expand completion", "agent completion", "完成后展开"], "arrow.up.left.and.arrow.down.right"),
            .control(.sessionDisplay, .sessionDisplayMaxVisibleSessions, "max_visible_sessions", "max_visible_sessions_desc", ["session_display", "settings_section_session_list"], ["visible sessions", "session count", "可见会话数"], "number"),
            .control(.sessionDisplay, .sessionDisplayContentFontSize, "content_font_size", "settings_search_desc_notch_content", ["session_display", "content"], ["font size", "字体大小"], "textformat.size"),
            .control(.sessionDisplay, .sessionDisplayAIReplyLines, "ai_reply_lines", "settings_search_desc_notch_content", ["session_display", "content"], ["reply lines", "message lines", "回复行数"], "line.3.horizontal"),
            .control(.sessionDisplay, .sessionDisplayShowAgentDetails, "show_agent_details", "settings_search_desc_notch_content", ["session_display", "content"], ["agent details", "activity details", "智能体详情"], "person.text.rectangle"),
            .control(.sessionDisplay, .sessionDisplayShowToolStatus, "show_tool_status", "settings_search_desc_notch_content", ["session_display", "content"], ["tool status", "compact tool activity", "工具状态"], "hammer"),
        ]
    }

    private static var mascotControls: [SettingsSearchEntry] {
        [
            .control(.mascot, .mascotDefaultSource, "default_mascot", "default_mascot_desc", ["mascot", "default_mascot"], ["default source", "default character", "默认来源", "默认角色"], "person.crop.circle"),
            defaultMascotOption("Claude Code", aliases: ["claude mascot", "默认 Claude Code", "Claude 角色"]),
            defaultMascotOption("Codex", aliases: ["codex mascot", "默认 Codex", "Codex 角色"]),
            defaultMascotOption("Gemini", aliases: ["gemini mascot", "默认 Gemini"]),
            defaultMascotOption("Cursor", aliases: ["cursor mascot", "默认 Cursor"]),
            defaultMascotOption("Trae", aliases: ["trae mascot", "默认 Trae"]),
            defaultMascotOption("Copilot", aliases: ["copilot mascot", "默认 Copilot"]),
            defaultMascotOption("Qoder", aliases: ["qoder mascot", "默认 Qoder"]),
            defaultMascotOption("Factory", aliases: ["factory mascot", "droid mascot", "默认 Factory"]),
            defaultMascotOption("StepFun", aliases: ["stepfun mascot", "默认 StepFun"]),
            defaultMascotOption("AntiGravity", aliases: ["antigravity mascot", "默认 AntiGravity"]),
            defaultMascotOption("Hermes", aliases: ["hermes mascot", "默认 Hermes"]),
            defaultMascotOption("Qwen Code", aliases: ["qwen mascot", "默认 Qwen"]),
            defaultMascotOption("Kimi Code CLI", aliases: ["kimi mascot", "默认 Kimi"]),
            defaultMascotOption("OpenCode", aliases: ["opencode mascot", "默认 OpenCode"]),
            .control(.mascot, .mascotPreviewStatus, "preview_status", "settings_search_desc_mascot_preview", ["mascot", "preview"], ["preview state", "working idle approval", "预览状态"], "play.rectangle"),
            .control(.mascot, .mascotAnimationSpeed, "mascot_speed", "settings_search_desc_mascot_animation", ["mascot", "settings_section_animation"], ["animation speed", "mascot speed", "动画速度"], "speedometer"),
        ]
    }

    private static var soundControls: [SettingsSearchEntry] {
        [
            .control(.sound, .soundEnable, "enable_sound", "settings_search_desc_sound_master", ["sound", "settings_section_sound_master"], ["sound effects", "enable sound", "音效开关"], "speaker.wave.2"),
            .control(.sound, .soundVolume, "volume", "settings_search_desc_sound_master", ["sound", "settings_section_sound_master"], ["sound volume", "音量"], "speaker.wave.3", visible: soundEnabled),
            .control(.sound, .soundSessionStart, "session_start", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["session sound", "new session sound", "会话开始音"], "play.circle", visible: soundEnabled),
            .control(.sound, .soundTaskComplete, "task_complete", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["complete sound", "completion sound", "完成音"], "checkmark.circle", visible: soundEnabled),
            .control(.sound, .soundTaskError, "task_error", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["error sound", "failure sound", "错误音"], "exclamationmark.triangle", visible: soundEnabled),
            .control(.sound, .soundApprovalNeeded, "approval_needed", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["approval sound", "permission sound", "审批音"], "hand.raised", visible: soundEnabled),
            .control(.sound, .soundPromptSubmit, "task_confirmation", "settings_search_desc_sound_events", ["sound", "settings_section_sound_events"], ["submit sound", "prompt submit", "发送音"], "paperplane", visible: soundEnabled),
            .control(.sound, .soundBoot, "boot_sound", "boot_sound_desc", ["sound", "settings_section_sound_events"], ["boot sound", "startup sound", "启动音"], "power", visible: soundEnabled),
        ]
    }

    private static var usageControls: [SettingsSearchEntry] {
        [
            .control(.usageNotifications, .usageDataSourcePicker, "data_source_status", "settings_search_desc_usage_data_source", ["usage_notifications", "usage_data_section"], ["provider picker", "selected provider", "Codex", "Claude Code", "数据源", "切换来源"], "arrow.left.arrow.right"),
            .control(.usageNotifications, .usageRefresh, "refresh", "settings_search_desc_usage_refresh", ["usage_notifications", "usage_data_section"], ["refresh usage", "reload quota", "刷新用量", "重新读取"], "arrow.clockwise"),
            .control(.usageNotifications, .usageDisplayCodex, "settings_search_usage_display_codex", "settings_search_desc_usage_display_codex", ["usage_notifications", "usage_provider_controls_section"], ["show codex usage", "display codex usage", "codex usage", "显示 Codex 用量", "显示codex用量", "codex 用量", "隐藏 codex"], "eye"),
            .control(.usageNotifications, .usageDisplayClaudeCode, "settings_search_usage_display_claude_code", "settings_search_desc_usage_display_claude_code", ["usage_notifications", "usage_provider_controls_section"], ["show claude code usage", "display claude usage", "claude usage", "显示 Claude Code 用量", "显示claude用量"], "eye"),
            .control(.usageNotifications, .usageStatisticsCodex, "settings_search_usage_statistics_codex", "settings_search_desc_usage_statistics_codex", ["usage_notifications", "usage_provider_controls_section"], ["collect codex statistics", "codex statistics", "统计 Codex 用量", "收集 Codex 统计"], "chart.bar.doc.horizontal"),
            .control(.usageNotifications, .usageStatisticsClaudeCode, "settings_search_usage_statistics_claude_code", "settings_search_desc_usage_statistics_claude_code", ["usage_notifications", "usage_provider_controls_section"], ["collect claude code statistics", "claude code statistics", "统计 Claude Code 用量", "收集 Claude Code 统计"], "chart.bar.doc.horizontal"),
            .control(.usageNotifications, .usageMonitorEnable, "usage_monitor_action_enable", "settings_search_desc_usage_monitor", ["usage_notifications", "usage_monitor_section"], ["enable background monitor", "启用后台监控"], "play.circle", priority: 90),
            .control(.usageNotifications, .usageMonitorDisable, "usage_monitor_action_disable", "settings_search_desc_usage_monitor", ["usage_notifications", "usage_monitor_section"], ["disable background monitor", "关闭后台监控"], "pause.circle", priority: 90),
            .control(.usageNotifications, .usageMonitorRepair, "usage_monitor_action_repair", "settings_search_desc_usage_monitor", ["usage_notifications", "usage_monitor_section"], ["repair background monitor", "后台监控修复", "修复后台监控"], "wrench.adjustable", priority: 90),
            .control(.usageNotifications, .usageMonitorUninstall, "usage_monitor_action_uninstall", "settings_search_desc_usage_monitor", ["usage_notifications", "usage_monitor_section"], ["uninstall background monitor", "卸载后台监控"], "trash", priority: 90),
            .control(.usageNotifications, .usageRecoveryCodexFiveHour, .literal("Codex 5h recovery notifications"), .key("settings_search_desc_usage_recovery"), [.key("usage_notifications"), .key("usage_notifications_section")], ["codex 5h recovery", "codex recovery reminder", "Codex 5h 恢复通知"], "bell.badge"),
            .control(.usageNotifications, .usageRecoveryCodexWeekly, .literal("Codex weekly recovery notifications"), .key("settings_search_desc_usage_recovery"), [.key("usage_notifications"), .key("usage_notifications_section")], ["codex weekly recovery", "Codex 周配额恢复通知"], "bell.badge"),
            .control(.usageNotifications, .usageRecoveryClaudeFiveHour, .literal("Claude Code 5h recovery notifications"), .key("settings_search_desc_usage_recovery"), [.key("usage_notifications"), .key("usage_notifications_section")], ["claude 5h recovery", "Claude Code 5h 恢复通知"], "bell.badge"),
            .control(.usageNotifications, .usageRecoveryClaudeWeekly, .literal("Claude Code weekly recovery notifications"), .key("settings_search_desc_usage_recovery"), [.key("usage_notifications"), .key("usage_notifications_section")], ["claude weekly recovery", "Claude Code 周配额恢复通知"], "bell.badge"),
            .control(.usageNotifications, .usageRecoveryRepair, "usage_notifications_action_repair", "settings_search_desc_usage_recovery", ["usage_notifications", "usage_notifications_section"], ["repair notifications", "request notification permission", "修复通知权限"], "wrench.adjustable"),
            .control(.usageNotifications, .usageRecoveryOpenSettings, "usage_notifications_action_open_settings", "settings_search_desc_usage_recovery", ["usage_notifications", "usage_notifications_section"], ["open notification settings", "打开通知设置"], "gear"),
            .control(.usageNotifications, .usageThresholdMaster, "usage_notifications_threshold_master_toggle_label", "settings_search_desc_usage_threshold", ["usage_notifications", "usage_notifications_threshold_section_title"], ["threshold notifications", "quota alerts", "用量阈值通知"], "bell.and.waves.left.and.right"),
            .control(.usageNotifications, .usageThresholdCodex, "usage_notifications_threshold_per_tool_codex_label", "settings_search_desc_usage_threshold", ["usage_notifications", "usage_notifications_threshold_section_title"], ["codex threshold", "codex quota alert", "Codex 阈值"], "bell"),
            .control(.usageNotifications, .usageThresholdClaudeCode, "usage_notifications_threshold_per_tool_claude_code_label", "settings_search_desc_usage_threshold", ["usage_notifications", "usage_notifications_threshold_section_title"], ["claude threshold", "claude quota alert", "Claude Code 阈值"], "bell"),
            .control(.usageNotifications, .usageThresholdRepair, "usage_notifications_action_repair", "settings_search_desc_usage_threshold", ["usage_notifications", "usage_notifications_threshold_section_title"], ["repair threshold notifications", "阈值通知修复"], "wrench.adjustable"),
        ]
    }

    private static var integrationControls: [SettingsSearchEntry] {
        localToolControls + [
            .control(.integrations, .integrationsCustomCLIName, .literal("Custom CLI name"), .key("settings_search_desc_setting_control"), [.key("integrations"), .key("settings_custom_clis_section")], ["custom cli name", "自定义 CLI 名称"], "text.cursor"),
            .control(.integrations, .integrationsCustomCLISource, .literal("Custom CLI source"), .key("settings_search_desc_setting_control"), [.key("integrations"), .key("settings_custom_clis_section")], ["custom cli source", "自定义 CLI 来源"], "tag"),
            .control(.integrations, .integrationsCustomCLIPath, .literal("Custom CLI config path"), .key("settings_search_desc_setting_control"), [.key("integrations"), .key("settings_custom_clis_section")], ["custom cli path", "config path", "自定义 CLI 路径"], "folder"),
            .control(.integrations, .integrationsCustomCLIKey, .literal("Custom CLI config key"), .key("settings_search_desc_setting_control"), [.key("integrations"), .key("settings_custom_clis_section")], ["custom cli key", "hook key", "自定义 CLI key"], "key"),
            .control(.integrations, .integrationsCustomCLIFormat, "settings_custom_clis_template_picker", "settings_search_desc_setting_control", ["integrations", "settings_custom_clis_section"], ["custom cli format", "hook format", "自定义 CLI 模板"], "square.stack.3d.up"),
            .control(.integrations, .integrationsCustomCLIAdd, "settings_custom_clis_add_button", "settings_search_desc_action_button", ["integrations", "settings_custom_clis_section"], ["add custom cli", "添加自定义 CLI"], "plus"),
            .control(.integrations, .integrationsRemoteName, "remote_name", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["remote name", "远程名称"], "text.cursor"),
            .control(.integrations, .integrationsRemoteHost, "remote_host", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["ssh host", "remote address", "远程主机地址"], "network"),
            .control(.integrations, .integrationsRemoteUser, "remote_user", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["ssh user", "remote user", "远程用户"], "person"),
            .control(.integrations, .integrationsRemotePort, "remote_port", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["ssh port", "远程端口"], "number"),
            .control(.integrations, .integrationsRemoteIdentity, "remote_identity", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["ssh key", "identity file", "密钥文件"], "key"),
            .control(.integrations, .integrationsRemoteAuthSocket, "remote_auth_socket", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["ssh auth socket", "认证 socket"], "point.3.connected.trianglepath.dotted"),
            .control(.integrations, .integrationsRemoteAutoConnect, "remote_auto_connect", "settings_search_desc_setting_control", ["integrations", "remote_hosts"], ["auto connect ssh", "自动连接"], "bolt"),
            .control(.integrations, .integrationsRemoteAdd, "remote_add_button", "settings_search_desc_action_button", ["integrations", "remote_hosts"], ["add remote host", "添加远程主机"], "plus"),
            .control(.integrations, .integrationsWebhookEnabled, "webhook_enable", "webhook_desc", ["integrations", "webhook_title"], ["enable webhook", "webhook forwarding", "启用 webhook"], "point.3.connected.trianglepath.dotted"),
            .control(.integrations, .integrationsWebhookURL, .literal("Webhook URL"), .key("webhook_desc"), [.key("integrations"), .key("webhook_title")], ["webhook url", "webhook endpoint", "Webhook 地址"], "link", visible: webhookEnabled),
            .control(.integrations, .integrationsWebhookFilter, .literal("Webhook event filter"), .key("webhook_filter_hint"), [.key("integrations"), .key("webhook_title")], ["webhook filter", "event filter", "Webhook 过滤"], "line.3.horizontal.decrease.circle", visible: webhookEnabled),
            .control(.integrations, .integrationsReinstallHooks, "reinstall", "settings_search_desc_action_button", ["integrations", "management"], ["reinstall hooks", "repair integrations", "重新安装本地集成"], "arrow.clockwise"),
            .control(.integrations, .integrationsUninstallHooks, "uninstall", "settings_search_desc_action_button", ["integrations", "management"], ["uninstall hooks", "remove integrations", "卸载本地集成"], "trash"),
        ]
    }

    private static var localToolControls: [SettingsSearchEntry] {
        [
            localTool("Claude Code", .integrationsLocalToolClaude, aliases: ["claude integration", "Claude Code 集成"]),
            localTool("Codex", .integrationsLocalToolCodex, aliases: ["codex integration", "Codex 集成"]),
            localTool("Gemini", .integrationsLocalToolGemini, aliases: ["gemini integration", "Gemini 集成"]),
            localTool("Cursor", .integrationsLocalToolCursor, aliases: ["cursor integration", "Cursor 集成"]),
            localTool("Trae", .integrationsLocalToolTrae, aliases: ["trae integration", "Trae 集成"]),
            localTool("Trae CN", .integrationsLocalToolTraeCN, aliases: ["trae cn integration", "Trae CN 集成"]),
            localTool("TraeCli", .integrationsLocalToolTraeCLI, aliases: ["traecli integration", "TraeCli 集成"]),
            localTool("Qoder", .integrationsLocalToolQoder, aliases: ["qoder integration", "Qoder 集成"]),
            localTool("Factory", .integrationsLocalToolFactory, aliases: ["factory integration", "droid integration", "Factory 集成"]),
            localTool("StepFun", .integrationsLocalToolStepFun, aliases: ["stepfun integration", "StepFun 集成"]),
            localTool("AntiGravity", .integrationsLocalToolAntiGravity, aliases: ["antigravity integration", "AntiGravity 集成"]),
            localTool("Hermes", .integrationsLocalToolHermes, aliases: ["hermes integration", "Hermes 集成"]),
            localTool("Qwen Code", .integrationsLocalToolQwen, aliases: ["qwen integration", "Qwen 集成"]),
            localTool("Copilot", .integrationsLocalToolCopilot, aliases: ["copilot integration", "Copilot 集成"]),
            localTool("Kimi Code CLI", .integrationsLocalToolKimi, aliases: ["kimi integration", "Kimi 集成"]),
            localTool("Kiro", .integrationsLocalToolKiro, aliases: ["kiro integration", "Kiro 集成"]),
            localTool("OpenCode", .integrationsLocalToolOpenCode, aliases: ["opencode integration", "OpenCode 集成"]),
        ]
    }

    private static var advancedControls: [SettingsSearchEntry] {
        [
            autoApprove("TaskCreate", .advancedAutoApproveTaskCreate),
            autoApprove("TaskUpdate", .advancedAutoApproveTaskUpdate),
            autoApprove("TaskGet", .advancedAutoApproveTaskGet),
            autoApprove("TaskList", .advancedAutoApproveTaskList),
            autoApprove("TaskOutput", .advancedAutoApproveTaskOutput),
            autoApprove("TaskStop", .advancedAutoApproveTaskStop),
            autoApprove("TodoRead", .advancedAutoApproveTodoRead),
            autoApprove("TodoWrite", .advancedAutoApproveTodoWrite),
            autoApprove("EnterPlanMode", .advancedAutoApproveEnterPlanMode),
            autoApprove("ExitPlanMode", .advancedAutoApproveExitPlanMode),
            .control(.advanced, .advancedExcludedHookPaths, "excluded_hook_cwd_title", "excluded_hook_cwd_desc", ["advanced", "excluded_hook_cwd_title"], ["ignored paths", "excluded cwd", "hook filter", "忽略路径"], "line.3.horizontal.decrease.circle"),
            .control(.advanced, .advancedSessionCleanup, "session_cleanup", "session_cleanup_desc", ["advanced", "settings_section_session_handling"], ["idle cleanup", "session timeout", "会话清理"], "timer"),
            .control(.advanced, .advancedRotationInterval, "rotation_interval", "rotation_interval_desc", ["advanced", "settings_section_session_handling"], ["session rotation", "轮转间隔"], "arrow.triangle.2.circlepath"),
            .control(.advanced, .advancedToolHistoryLimit, "tool_history_limit", "tool_history_limit_desc", ["advanced", "settings_section_session_handling"], ["tool history", "history limit", "工具历史"], "clock"),
            .control(.advanced, .advancedPluginSessions, "plugin_session_mode", "plugin_session_mode_desc", ["advanced", "settings_section_session_handling"], ["plugin sessions", "sub sessions", "插件会话"], "square.stack.3d.up"),
            .control(.advanced, .advancedExportDiagnostics, "export_diagnostics", "export_diagnostics_desc", ["advanced", "settings_section_diagnostics_repair"], ["export logs", "diagnostics", "导出诊断"], "square.and.arrow.up"),
        ]
    }

    private static func aboutControls(isHomebrewInstall: Bool) -> [SettingsSearchEntry] {
        [
            .control(.about, .aboutGitHub, .literal("GitHub"), .key("settings_search_desc_page_about"), [.key("about")], ["repository", "repo", "github 仓库"], "chevron.left.forwardslash.chevron.right"),
            .control(.about, .aboutIssues, .literal("Issues"), .key("settings_search_desc_page_about"), [.key("about")], ["github issues", "bug report", "问题反馈"], "ladybug"),
            .control(.about, .aboutAutoUpdate, "about_auto_update_toggle", "settings_search_desc_updates", ["about", "about_auto_update_section"], ["automatic updates", "自动更新"], "arrow.triangle.2.circlepath", visible: { !isHomebrewInstall }),
            .control(.about, .aboutCheckForUpdates, "check_for_updates", "settings_search_desc_updates", ["about", "about_auto_update_section"], ["check update", "software update", "检查更新"], "arrow.triangle.2.circlepath", visible: { !isHomebrewInstall }),
            .control(.about, .aboutUpdateNow, "update_now", "settings_search_desc_updates", ["about", "about_auto_update_section"], ["install update", "update now", "立即更新"], "arrow.down.to.line", visible: { !isHomebrewInstall }),
            .control(.about, .aboutUpdateCopyCommand, "update_copy_command", "settings_search_desc_updates", ["about", "update_homebrew_managed_title"], ["copy update command", "homebrew update", "brew upgrade", "复制更新命令"], "doc.on.doc", visible: { isHomebrewInstall }),
            .control(.about, .aboutDiagnostics, "export_diagnostics", "settings_search_desc_about_diagnostics", ["about", "export_diagnostics"], ["export diagnostics", "logs", "导出诊断"], "ladybug"),
        ]
    }
}

private extension SettingsSearchCatalog {
    static func defaultMascotOption(_ title: String, aliases: [String]) -> SettingsSearchEntry {
        .control(.mascot, .mascotDefaultSource, .literal("Default mascot: \(title)"), .key("default_mascot_desc"), [.key("mascot"), .key("default_mascot")], aliases + ["default mascot \(title)"], "person.crop.circle", priority: 4)
    }

    static func localTool(_ title: String, _ targetID: SettingsTargetID, aliases: [String]) -> SettingsSearchEntry {
        .control(.integrations, targetID, .literal(title), .key("settings_search_desc_local_tools"), [.key("integrations"), .key("settings_section_local_ai_tools")], aliases + ["local tool \(title)", "\(title) hooks"], "terminal", priority: 2)
    }

    static func autoApprove(_ toolName: String, _ targetID: SettingsTargetID) -> SettingsSearchEntry {
        .control(.advanced, targetID, .literal("Auto-approve \(toolName)"), .key("auto_approve_tools_desc"), [.key("advanced"), .key("auto_approve_tools")], ["auto approve \(toolName)", "自动批准 \(toolName)", L10n.shared["auto_approve_\(toolName)"]], "bolt.badge.checkmark")
    }

    static func defaultBool(_ key: String, _ fallback: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    static func defaultString(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static func soundEnabled() -> Bool {
        defaultBool(SettingsKey.soundEnabled, SettingsDefaults.soundEnabled)
    }

    static func hapticEnabled() -> Bool {
        defaultBool(SettingsKey.hapticOnHover, SettingsDefaults.hapticOnHover)
    }

    static func webhookEnabled() -> Bool {
        defaultBool(SettingsKey.webhookEnabled, SettingsDefaults.webhookEnabled)
    }

    static func customNotchHeightVisible() -> Bool {
        defaultString(SettingsKey.notchHeightMode, SettingsDefaults.notchHeightMode) == NotchHeightMode.custom.rawValue
    }

}

private extension SettingsSearchEntry {
    static func page(
        _ page: SettingsPage,
        _ titleKey: String,
        _ descriptionKey: String,
        _ pathKeys: [String],
        _ aliases: [String],
        _ symbolName: String
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: "\(page.rawValue).page",
            page: page,
            targetID: page.pageTargetID,
            kind: .page,
            title: .key(titleKey),
            description: .key(descriptionKey),
            path: pathKeys.map(SettingsSearchText.key),
            aliases: aliases,
            symbolName: symbolName,
            priority: 0,
            isVisible: { true }
        )
    }

    static func section(
        _ page: SettingsPage,
        _ targetID: SettingsTargetID,
        _ titleKey: String,
        _ descriptionKey: String,
        _ pathKeys: [String],
        _ aliases: [String],
        _ symbolName: String,
        visible: @escaping () -> Bool = { true }
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: "\(page.rawValue).\(targetID.rawValue)",
            page: page,
            targetID: targetID,
            kind: .section,
            title: .key(titleKey),
            description: .key(descriptionKey),
            path: pathKeys.map(SettingsSearchText.key),
            aliases: aliases,
            symbolName: symbolName,
            priority: 0,
            isVisible: visible
        )
    }

    static func control(
        _ page: SettingsPage,
        _ targetID: SettingsTargetID,
        _ titleKey: String,
        _ descriptionKey: String,
        _ pathKeys: [String],
        _ aliases: [String],
        _ symbolName: String,
        priority: Int = 0,
        visible: @escaping () -> Bool = { true }
    ) -> SettingsSearchEntry {
        .control(
            page,
            targetID,
            .key(titleKey),
            .key(descriptionKey),
            pathKeys.map(SettingsSearchText.key),
            aliases,
            symbolName,
            priority: priority,
            visible: visible
        )
    }

    static func control(
        _ page: SettingsPage,
        _ targetID: SettingsTargetID,
        _ title: SettingsSearchText,
        _ description: SettingsSearchText,
        _ path: [SettingsSearchText],
        _ aliases: [String],
        _ symbolName: String,
        priority: Int = 0,
        visible: @escaping () -> Bool = { true }
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: "\(page.rawValue).\(targetID.rawValue).\(title.localized)",
            page: page,
            targetID: targetID,
            kind: .control,
            title: title,
            description: description,
            path: path,
            aliases: aliases,
            symbolName: symbolName,
            priority: priority,
            isVisible: visible
        )
    }
}
