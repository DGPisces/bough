import Foundation
import BoughCore

// MARK: - CLI Definitions

/// Hook entry format variants
enum HookFormat {
    /// Claude Code style: [{matcher, hooks: [{type, command, timeout, async}]}]
    case claude
    /// Codex/Gemini style: [{hooks: [{type, command, timeout}]}]  (no matcher)
    case nested
    /// Cursor style: [{command: "..."}]
    case flat
    /// TraeCli style: YAML managed block in ~/.trae/traecli.yaml
    case traecli
    /// GitHub Copilot CLI style: [{type, bash, timeoutSec}] with top-level version
    case copilot
    /// Kimi Code CLI style: TOML [[hooks]] arrays in ~/.kimi/config.toml
    case kimi
    /// Kiro CLI style: per-agent JSON file at ~/.kiro/agents/<name>.json
    /// with hooks keyed by camelCase event names and `timeout_ms` (#127).
    case kiroAgent

    var storageValue: String {
        switch self {
        case .claude: return "claude"
        case .nested: return "nested"
        case .flat: return "flat"
        case .traecli: return "traecli"
        case .copilot: return "copilot"
        case .kimi: return "kimi"
        case .kiroAgent: return "kiroAgent"
        }
    }

    init?(storageValue: String) {
        switch storageValue.lowercased() {
        case "claude": self = .claude
        case "nested": self = .nested
        case "flat": self = .flat
        case "traecli": self = .traecli
        case "copilot": self = .copilot
        case "kimi": self = .kimi
        case "kiroagent": self = .kiroAgent
        default: return nil
        }
    }
}

/// A CLI tool that supports hooks
struct CLIConfig {
    let name: String           // display name
    let source: String         // --source flag value
    let configPath: String     // path to config file (relative to home, or to rootOverride if set)
    let configKey: String      // top-level JSON key containing hooks ("hooks" for most)
    let format: HookFormat
    let events: [(String, Int, Bool)]  // (eventName, timeout, async)
    /// Events that require a minimum CLI version (eventName → minVersion like "2.1.89")
    var versionedEvents: [String: String] = [:]
    /// Optional root directory override. When set, `configPath` is resolved relative to this
    /// directory instead of the user's home (used by Codex to honor $CODEX_HOME).
    var rootOverride: (@Sendable () -> String)? = nil
    /// Optional override for the user-visible config path (e.g. "$CODEX_HOME/hooks.json").
    var displayPathOverride: (@Sendable () -> String)? = nil

    var fullPath: String {
        if let override = rootOverride {
            return override() + "/" + configPath
        }
        if configPath.hasPrefix("/") { return configPath }
        if configPath.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + configPath.dropFirst(2)
        }
        return NSHomeDirectory() + "/\(configPath)"
    }
    var dirPath: String { (fullPath as NSString).deletingLastPathComponent }
    var displayConfigPath: String {
        if let override = displayPathOverride { return override() }
        if configPath.hasPrefix("/") || configPath.hasPrefix("~/") { return configPath }
        return "~/\(configPath)"
    }
}

struct CustomCLIConfig: Codable, Identifiable, Equatable {
    var id: String { source }
    let name: String
    let source: String
    let configPath: String
    let format: String
    let configKey: String
}
extension ConfigInstaller {
    private static let customCLIConfigsKey = SessionSnapshot.customCLIConfigsKey

    // MARK: - All supported CLIs

    private static let builtInCLIs: [CLIConfig] = [
        // Claude Code — uses hook script (with bridge dispatcher + nc fallback)
        CLIConfig(
            name: "Claude Code", source: "claude",
            configPath: ".claude/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("PermissionRequest", 86400, false),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ],
            versionedEvents: [
                "PostToolUseFailure": "2.1.89",
            ]
        ),
        // Codex — honors $CODEX_HOME (falls back to ~/.codex)
        CLIConfig(
            name: "Codex", source: "codex",
            configPath: "hooks.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                // Codex fires PermissionRequest before shell escalation /
                // managed-network approvals. Without this hook the panel
                // stays in "running" and the approval sound never plays —
                // see issue #145 and developers.openai.com/codex/hooks.
                ("PermissionRequest", 86400, false),
                ("Stop", 5, false),
            ],
            rootOverride: { ConfigInstaller.codexHome() },
            displayPathOverride: { ConfigInstaller.displayCodexPath(filename: "hooks.json") }
        ),
        // Gemini CLI — timeout in milliseconds
        CLIConfig(
            name: "Gemini", source: "gemini",
            configPath: ".gemini/settings.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 10000, false),
                ("SessionEnd", 10000, false),
                ("BeforeTool", 10000, false),
                ("AfterTool", 10000, false),
                ("BeforeAgent", 10000, false),
                ("AfterAgent", 10000, false),
            ]
        ),
        // Cursor
        CLIConfig(
            name: "Cursor", source: "cursor",
            configPath: ".cursor/hooks.json", configKey: "hooks",
            format: .flat,
            events: [
                ("beforeSubmitPrompt", 5, false),
                ("beforeShellExecution", 5, false),
                ("afterShellExecution", 5, false),
                ("beforeReadFile", 5, false),
                ("afterFileEdit", 5, false),
                ("beforeMCPExecution", 5, false),
                ("afterMCPExecution", 5, false),
                ("afterAgentThought", 5, false),
                ("afterAgentResponse", 5, false),
                ("stop", 5, false),
            ]
        ),
        // Trae
        CLIConfig(
            name: "Trae", source: "trae",
            configPath: ".trae/hooks.json", configKey: "hooks",
            format: .flat,
            events: defaultEvents(for: .flat)
        ),
        // Trae CN
        CLIConfig(
            name: "Trae CN", source: "traecn",
            configPath: ".trae-cn/hooks.json", configKey: "hooks",
            format: .flat,
            events: defaultEvents(for: .flat)
        ),
        // TraeCli
        CLIConfig(
            name: "TraeCli", source: "traecli",
            configPath: ".trae/traecli.yaml", configKey: "hooks",
            format: .traecli,
            events: defaultEvents(for: .traecli)
        ),
        // Qoder — Claude Code fork
        CLIConfig(
            name: "Qoder", source: "qoder",
            configPath: ".qoder/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Factory — Claude Code fork (uses "droid" as source identifier)
        CLIConfig(
            name: "Factory", source: "droid",
            configPath: ".factory/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // CodeBuddy — Claude Code fork
        CLIConfig(
            name: "CodeBuddy", source: "codebuddy",
            configPath: ".codebuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // CodyBuddyCN — CodeBuddy CN variant
        CLIConfig(
            name: "CodyBuddyCN", source: "codybuddycn",
            configPath: ".codybuddycn/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // StepFun — Claude Code fork
        CLIConfig(
            name: "StepFun", source: "stepfun",
            configPath: ".stepfun/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // AntiGravity — Claude Code fork
        CLIConfig(
            name: "AntiGravity", source: "antigravity",
            configPath: ".antigravity/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // WorkBuddy — Claude Code fork
        CLIConfig(
            name: "WorkBuddy", source: "workbuddy",
            configPath: ".workbuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Hermes — Claude Code fork
        CLIConfig(
            name: "Hermes", source: "hermes",
            configPath: ".hermes/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Qwen Code — timeout in milliseconds
        CLIConfig(
            name: "Qwen Code", source: "qwen",
            configPath: ".qwen/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5000, true),
                ("PreToolUse", 5000, false),
                ("PostToolUse", 5000, true),
                ("PostToolUseFailure", 5000, true),
                ("PermissionRequest", 86400000, false),
                ("Stop", 5000, true),
                ("SubagentStart", 5000, true),
                ("SubagentStop", 5000, true),
                ("SessionStart", 5000, false),
                ("SessionEnd", 5000, true),
                ("Notification", 86400000, false),
                ("PreCompact", 5000, true),
            ]
        ),
        // GitHub Copilot CLI
        CLIConfig(
            name: "Copilot", source: "copilot",
            configPath: ".copilot/hooks/bough.json", configKey: "hooks",
            format: .copilot,
            events: [
                ("sessionStart", 5, false),
                ("sessionEnd", 5, true),
                ("userPromptSubmitted", 5, false),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("errorOccurred", 5, true),
            ]
        ),
        // Kimi Code CLI — TOML hooks in ~/.kimi/config.toml
        CLIConfig(
            name: "Kimi Code CLI", source: "kimi",
            configPath: ".kimi/config.toml", configKey: "hooks",
            format: .kimi,
            events: defaultEvents(for: .kimi)
        ),
        // Kiro CLI — agent-scoped JSON at ~/.kiro/agents/bough.json.
        // User must launch with `kiro --agent bough` for hooks to fire (#127).
        CLIConfig(
            name: "Kiro", source: "kiro",
            configPath: ".kiro/agents/bough.json", configKey: "hooks",
            format: .kiroAgent,
            events: defaultEvents(for: .kiroAgent)
        ),
    ]

    static var allCLIs: [CLIConfig] {
        builtInCLIs + customCLIs()
    }

    /// Non-Claude CLIs (installed via bridge binary directly)
    static var externalCLIs: [CLIConfig] {
        allCLIs.filter { $0.source != "claude" }
    }

    static func defaultEvents(for format: HookFormat) -> [(String, Int, Bool)] {
        switch format {
        case .claude:
            return [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        case .nested:
            return [
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ]
        case .flat:
            return [
                ("beforeSubmitPrompt", 5, false),
                ("beforeShellExecution", 5, false),
                ("afterShellExecution", 5, false),
                ("beforeReadFile", 5, false),
                ("afterFileEdit", 5, false),
                ("beforeMCPExecution", 5, false),
                ("afterMCPExecution", 5, false),
                ("afterAgentThought", 5, false),
                ("afterAgentResponse", 5, false),
                ("stop", 5, false),
            ]
        case .traecli:
            return [
                ("session_start", 5, false),
                ("session_end", 5, true),
                ("user_prompt_submit", 5, true),
                ("pre_tool_use", 5, false),
                ("post_tool_use", 5, true),
                ("post_tool_use_failure", 5, true),
                ("permission_request", 86400, false),
                ("notification", 86400, false),
                ("subagent_start", 5, true),
                ("subagent_stop", 5, true),
                ("stop", 5, true),
                ("pre_compact", 5, true),
                ("post_compact", 5, true),
            ]
        case .copilot:
            return [
                ("sessionStart", 5, false),
                ("sessionEnd", 5, true),
                ("userPromptSubmitted", 5, false),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("errorOccurred", 5, true),
            ]
        case .kimi:
            // Kimi Code CLI limits: max timeout 600, no PermissionRequest event
            return [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 600, false),
                ("PreCompact", 5, true),
            ]
        case .kiroAgent:
            // Kiro CLI hook events (camelCase). Timeouts are stored in seconds here
            // and converted to `timeout_ms` at install time.
            return [
                ("agentSpawn", 5, false),
                ("userPromptSubmit", 5, true),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("stop", 5, true),
            ]
        }
    }

    static func customCLIConfigs() -> [CustomCLIConfig] {
        guard let data = UserDefaults.standard.data(forKey: customCLIConfigsKey),
              let items = try? JSONDecoder().decode([CustomCLIConfig].self, from: data) else {
            return []
        }
        return items
    }

    private static func saveCustomCLIConfigs(_ items: [CustomCLIConfig]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: customCLIConfigsKey)
    }

    static func customCLIs() -> [CLIConfig] {
        customCLIConfigs().compactMap { item in
            guard let format = HookFormat(storageValue: item.format) else { return nil }
            return CLIConfig(
                name: item.name,
                source: item.source,
                configPath: item.configPath,
                configKey: item.configKey,
                format: format,
                events: defaultEvents(for: format)
            )
        }
    }

    static func addCustomCLI(
        name: String,
        source: String,
        configPath: String,
        format: HookFormat,
        configKey: String = "hooks"
    ) -> (ok: Bool, message: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedConfigPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfigKey = configKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty else { return (false, "Name cannot be empty") }
        guard !normalizedSource.isEmpty else { return (false, "Source cannot be empty") }
        guard normalizedSource.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return (false, "Source must use [a-z0-9_-]")
        }
        guard !normalizedConfigPath.isEmpty else { return (false, "Config path cannot be empty") }
        guard !normalizedConfigKey.isEmpty else { return (false, "Config key cannot be empty") }

        let builtInSources = Set(builtInCLIs.map(\.source))
        guard !builtInSources.contains(normalizedSource) else {
            return (false, "Source '\(normalizedSource)' is already built-in")
        }

        var items = customCLIConfigs()
        let entry = CustomCLIConfig(
            name: normalizedName,
            source: normalizedSource,
            configPath: normalizedConfigPath,
            format: format.storageValue,
            configKey: normalizedConfigKey
        )
        if let idx = items.firstIndex(where: { $0.source == normalizedSource }) {
            items[idx] = entry
        } else {
            items.append(entry)
        }
        saveCustomCLIConfigs(items)
        return (true, "Custom CLI saved")
    }

    @discardableResult
    static func removeCustomCLI(source: String) -> Bool {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = customCLIConfigs()
        let originalCount = items.count
        items.removeAll { $0.source == normalizedSource }
        guard items.count != originalCount else { return false }
        saveCustomCLIConfigs(items)
        return true
    }
}
