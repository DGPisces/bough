import Foundation
import BoughCore
import Yams

// MARK: - Hook Identifiers

private enum HookId {
    static let current = "bough"
    static let legacyNames: [String] = []  // Bough has no legacy names yet; intentionally empty.
    static func isOurs(_ s: String) -> Bool {
        let lower = s.lowercased()
        if legacyNames.contains(where: lower.contains) { return true }
        if lower.contains("bough-hook-v1-start") || lower.contains("bough-hook-v1-end") {
            return true
        }
        if lower.contains("bough_hook_v1") { return true }
        if lower.contains("~/.bough/bough-hook.sh") || lower.contains("/.bough/bough-hook.sh") {
            return true
        }
        if lower.contains("~/.claude/hooks/bough-hook.sh")
            || lower.contains("/.claude/hooks/bough-hook.sh") {
            return true
        }
        if containsBoughBridgeCommand(lower) {
            return true
        }
        if lower.range(of: #"(^|[^a-z0-9_-])bough-bridge($|[^a-z0-9_-])"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"(^|/)bough-opencode\.js($|[?#])"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"^/tmp/bough-[0-9]+\.sock$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func containsBoughBridgeCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower == "bough-bridge"
            || lower.range(of: #"(^|[\/~])\.bough/(bin/)?bough-bridge($|[\s'";&|)])"#, options: .regularExpression) != nil
            || lower.range(of: #"(^|[\/~])\.claude/hooks/bough-bridge($|[\s'";&|)])"#, options: .regularExpression) != nil
            || lower.range(of: #"(^|[^a-z0-9_-])bough-bridge($|[\s'";&|)])"#, options: .regularExpression) != nil
    }

    static func containsSourceArgument(_ command: String, source: String) -> Bool {
        let expected = source.lowercased()
        let tokens = shellishTokens(command.lowercased())
        for (index, token) in tokens.enumerated() {
            if token == "--source" {
                return index + 1 < tokens.count && tokens[index + 1] == expected
            }
            if token.hasPrefix("--source=") {
                return String(token.dropFirst("--source=".count)) == expected
            }
        }
        return false
    }

    private static func shellishTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char.isWhitespace || char == ";" || char == "&" || char == "|" || char == "(" || char == ")" {
                flush()
            } else {
                current.append(char)
            }
        }
        if escaped {
            current.append("\\")
        }
        flush()
        return tokens
    }
}

// MARK: - Test surface
// internal: required by HookOwnershipTests via @testable
extension ConfigInstaller {
    /// internal: required by HookOwnershipTests via @testable
    static func testHookIdIsOurs(_ s: String) -> Bool {
        HookId.isOurs(s)
    }

    static func containsBoughBridgeCommand(_ command: String) -> Bool {
        HookId.containsBoughBridgeCommand(command)
    }

    static func containsSourceArgument(_ command: String, source: String) -> Bool {
        HookId.containsSourceArgument(command, source: source)
    }

    /// internal: required by HookOwnershipTests via @testable
    static func testMakeCLI(format: HookFormat, configPath: String) -> CLIConfig {
        CLIConfig(
            name: "test",
            source: "test",
            configPath: configPath,
            configKey: "hooks",
            format: format,
            events: [("PostToolUse", 5, false)]
        )
    }

    /// internal: required by HookOwnershipTests via @testable
    static func testInstallHooksForCLI(_ cli: CLIConfig) throws {
        switch cli.format {
        case .claude:
            _ = installClaudeHooks(cli: cli, fm: FileManager.default)
        case .traecli:
            let original = (try? String(contentsOfFile: cli.fullPath, encoding: .utf8)) ?? ""
            guard let merged = mergeTraecliHooksIfValid(into: original, source: cli.source) else {
                throw NSError(domain: "Bough.ConfigInstaller", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "TraeCli YAML is invalid; refusing to rewrite"
                ])
            }
            try merged.write(toFile: cli.fullPath, atomically: true, encoding: .utf8)
        case .kimi:
            _ = installKimiHooks(cli: cli, fm: FileManager.default)
        default:
            _ = installExternalHooks(cli: cli, fm: FileManager.default)
        }
    }

    /// internal: required by HookOwnershipTests via @testable
    static func testUninstallHooksForCLI(_ cli: CLIConfig) throws {
        if cli.format == .traecli {
            let original = (try? String(contentsOfFile: cli.fullPath, encoding: .utf8)) ?? ""
            let cleaned = removeManagedTraecliHooks(from: original, source: cli.source)
            try cleaned.write(toFile: cli.fullPath, atomically: true, encoding: .utf8)
            return
        }
        uninstallHooks(cli: cli, fm: FileManager.default)
    }

    /// internal: required by HookOwnershipTests via @testable
    static var testBoughOpencodePluginFilename: String {
        opencodePluginFilename
    }

    /// internal: required by HookOwnershipTests via @testable
    static var testSharedHookScriptTemplate: String {
        hookScript
    }

    /// internal: required by ConfigInstallerCodexHooksMigrationTests via @testable
    static func testMigrateCodexHooksKey() -> Bool {
        migrateCodexHooksKey(fm: FileManager.default)
    }

    /// internal: required by ConfigInstallerCodexHooksMigrationTests via @testable
    static func testPreserveCodexHooksKeyAndAddHooks() -> Bool {
        preserveCodexHooksKeyAndAddHooks(fm: FileManager.default)
    }

    /// internal: required by ConfigInstallerCodexHooksMigrationTests via @testable.
    /// Bypasses live `detectCodexVersion()` call; pass nil to simulate detection failure.
    /// Includes the Plan 15-04 cleanup pass + D-15 short-circuit so the full funnel is exercised.
    static func testEnableCodexHooksConfigWithDetectedVersion(_ version: String?) -> Bool {
        // Mirror the real enableCodexHooksConfig body (Plan 15-04 addition).
        let cleanupOutcome = cleanupBoughHooksFromCodexConfigToml(fm: FileManager.default)
        if case .malformedRefused = cleanupOutcome { return false }
        if let version, !versionAtLeast(version, codexCLIMinimumHooksVersion) {
            return preserveCodexHooksKeyAndAddHooks(fm: FileManager.default)
        }
        return migrateCodexHooksKey(fm: FileManager.default)
    }

    /// internal: required by ConfigInstallerTests via @testable.
    static func testCodexVersionCandidatePaths(
        homeDirectory: String,
        shellResolvedPath: String?,
        appResourcesCodexPath: String
    ) -> [String] {
        codexVersionCandidatePaths(
            shellResolvedPath: shellResolvedPath,
            homeDirectory: homeDirectory,
            appResourcesCodexPath: appResourcesCodexPath,
            fileManager: FileManager.default
        )
    }

    /// internal: required by ConfigInstallerTests via @testable.
    static func testDetectCodexVersion(candidatePaths: [String]) -> String? {
        detectedCodexVersion(candidatePaths: candidatePaths)
    }

    /// internal: required by ConfigInstallerTests via @testable.
    static func testIsCodexGUIAppBinary(_ path: String) -> Bool {
        isCodexGUIAppBinary(path)
    }

    /// internal: required by ConfigInstallerTests via @testable.
    static func testInstallCodexHooksIfEnabled(defaults: UserDefaults = .standard) -> Bool {
        installCodexHooksIfEnabled(fm: FileManager.default, bridgeInstalled: true, defaults: defaults)
    }

    /// internal: required by ConfigInstallerCodexConfigTomlHygieneTests via @testable.
    static func testCleanupBoughHooksFromCodexConfigToml() -> CodexCleanupOutcome {
        cleanupBoughHooksFromCodexConfigToml(fm: FileManager.default)
    }
}

struct ConfigInstaller {
    private static let boughDir = NSHomeDirectory() + "/.bough"
    private static let bridgePath = boughDir + "/bough-bridge"
    private static let hookScriptPath = boughDir + "/bough-hook.sh"
    private static let hookCommand = "~/.bough/bough-hook.sh"
    /// Absolute path for external CLI hooks — avoids tilde expansion issues in IDE environments
    private static let bridgeCommand = boughDir + "/bough-bridge"
    private static let traecliConfigPath = NSHomeDirectory() + "/.trae/traecli.yaml"
    private static let claudeSettingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let statusLineBridgeResourceName = "bough-statusline-bridge"
    private static let statusLineBridgeResourceExtension = "sh"
    private static let claudeCodeStatusLineStableBridgePath = boughDir + "/bough-statusline-bridge.sh"
    /// Chain-safe wrapper destination (D-03 — Bough's namespace).
    private static let claudeCodeStatusLineWrapperPath = boughDir + "/bough-statusline-wrapper.sh"
    /// Wrapper template resource (Sources/Bough/Resources/bough-statusline-wrapper.sh.template).
    private static let statusLineWrapperTemplateResourceName = "bough-statusline-wrapper.sh"
    private static let statusLineWrapperTemplateResourceExtension = "template"

    enum ClaudeCodeStatusLineInstallResult: Equatable {
        case installed
        case conflict(existing: String, proposed: String)
        case failed(String)
        /// Phase 21 / D-02 chain-safe install: a Bough-owned wrapper script
        /// at `wrapperPath` now drives Claude Code's statusLine; it runs
        /// the user's previous `prevCmd` (under a 0.5s timeout) for visual
        /// fidelity and invokes the Bough bridge silently for data ingestion.
        case chained(prevCmd: String, wrapperPath: String)
    }

    // Legacy paths for migration cleanup (#32)
    private static let legacyBridgePath = NSHomeDirectory() + "/.claude/hooks/bough-bridge"
    private static let legacyHookScriptPath = NSHomeDirectory() + "/.claude/hooks/bough-hook.sh"

    // MARK: - Codex home resolution

    /// Resolve Codex's config directory. Honors $CODEX_HOME (with a leading `~` expanded);
    /// falls back to `~/.codex`. Whitespace-only or empty values are treated as unset.
    static func codexHome() -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() + "/.codex" }
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw
    }

    /// User-visible form of a Codex config path (uses `$CODEX_HOME/...` when the env var
    /// is set, otherwise `~/.codex/...`).
    static func displayCodexPath(filename: String) -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~/.codex/\(filename)" : "$CODEX_HOME/\(filename)"
    }

    /// Hook script version — bump this when the script template changes
    private static let hookScriptVersion = 6

    /// Hook script for Claude Code (dispatcher: bridge binary → nc fallback)
    private static let hookScript = """
        #!/bin/bash
        # bough-hook-v1-start
        # Bough hook v\(hookScriptVersion) — native bridge with shell fallback
        BRIDGE="$HOME/.bough/bough-bridge"
        if [ -x "$BRIDGE" ]; then
          exec "$BRIDGE" "$@"
        fi
        # Fallback: original shell approach (no binary installed yet)
        SOCK="/tmp/bough-$(id -u).sock"
        [ -S "$SOCK" ] || exit 0
        INPUT=$(cat)
        _ITERM_GUID="${ITERM_SESSION_ID##*:}"
        TERM_INFO="\\"_term_app\\":\\"${TERM_PROGRAM:-}\\",\\"_iterm_session\\":\\"${_ITERM_GUID:-}\\",\\"_tty\\":\\"$(tty 2>/dev/null || true)\\",\\"_ppid\\":$PPID"
        PATCHED="${INPUT%\\}},${TERM_INFO}}"
        if echo "$INPUT" | grep -q '"PermissionRequest"'; then
          echo "$PATCHED" | nc -U -w 120 "$SOCK" 2>/dev/null || true
        else
          echo "$PATCHED" | nc -U -w 2 "$SOCK" 2>/dev/null || true
        fi
        # bough-hook-v1-end
        """

    // MARK: - OpenCode plugin paths

    private static let opencodePluginDir = NSHomeDirectory() + "/.config/opencode/plugins"
    private static let opencodePluginFilename = "bough-opencode.js"
    private static let opencodePluginPath = NSHomeDirectory() + "/.config/opencode/plugins/\(opencodePluginFilename)"
    private static let opencodeConfigPath = NSHomeDirectory() + "/.config/opencode/config.json"
    private static let opencodeConfigPathNew = NSHomeDirectory() + "/.config/opencode/opencode.json"
    // OpenCode recommends opencode.jsonc (with-comments). When the user already
    // has it we should merge our plugin entry there instead of resurrecting
    // opencode.json. See issue #132.
    private static let opencodeConfigPathJsonc = NSHomeDirectory() + "/.config/opencode/opencode.jsonc"

    static func opencodeEffectiveConfigPath(fm: FileManager = .default) -> String {
        opencodeEffectiveConfigPath(
            configDir: (opencodeConfigPath as NSString).deletingLastPathComponent,
            fm: fm
        )
    }

    static func opencodeEffectiveConfigPath(configDir: String, fm: FileManager = .default) -> String {
        let jsonc = "\(configDir)/opencode.jsonc"
        if fm.fileExists(atPath: jsonc) { return jsonc }
        let json = "\(configDir)/opencode.json"
        if fm.fileExists(atPath: json) { return json }
        let legacy = "\(configDir)/config.json"
        if fm.fileExists(atPath: legacy) { return legacy }
        return json
    }

    static func opencodeEffectiveDisplayConfigPath(fm: FileManager = .default) -> String {
        let path = opencodeEffectiveConfigPath(fm: fm)
        return displayPathForHomePath(path)
    }

    static func opencodePluginInstallPath() -> String {
        opencodePluginPath
    }

    static func opencodePluginDisplayPath() -> String {
        displayPathForHomePath(opencodePluginPath)
    }

    private static func displayPathForHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Install / Uninstall

    static func install() -> Bool {
        let fm = FileManager.default

        // Ensure ~/.bough directory
        try? BoughPrivateStorage.ensurePrivateDirectory(
            at: URL(fileURLWithPath: boughDir),
            fileManager: fm
        )

        // Clean up legacy paths at ~/.claude/hooks/ (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        // Install hook script + bridge binary (shared by all CLIs)
        let hookScriptInstalled = installHookScript(fm: fm)
        let bridgeInstalled = installBridgeBinary(fm: fm)

        // Install hooks for each enabled CLI
        var ok = true
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            if cli.source == "codex" { continue }
            if cli.source == "claude" {
                guard hookScriptInstalled else { ok = false; continue }
                if !installClaudeHooks(cli: cli, fm: fm) { ok = false }
            } else if cli.source == "traecli" {
                guard bridgeInstalled else { ok = false; continue }
                if !installTraecliHooks(fm: fm) { ok = false }
            } else {
                guard bridgeInstalled else { ok = false; continue }
                if !installExternalHooks(cli: cli, fm: fm) { ok = false }
            }
        }

        // Codex requires the current hooks feature flag in config.toml.
        if !installCodexHooksIfEnabled(fm: fm, bridgeInstalled: bridgeInstalled) { ok = false }

        // Install OpenCode plugin
        if isEnabled(source: "opencode") {
            guard bridgeInstalled else { return false }
            if !installOpencodePlugin(fm: fm) { ok = false }
        }

        return ok
    }

    private static func installCodexHooksIfEnabled(
        fm: FileManager,
        bridgeInstalled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard isEnabled(source: "codex", defaults: defaults) else { return true }
        return installCodexHooks(fm: fm, bridgeInstalled: bridgeInstalled)
    }

    private static func installCodexHooks(fm: FileManager, bridgeInstalled: Bool) -> Bool {
        guard bridgeInstalled else { return false }
        guard enableCodexHooksConfig(fm: fm),
              let codexCLI = allCLIs.first(where: { $0.source == "codex" }) else {
            return false
        }
        return installExternalHooks(cli: codexCLI, fm: fm) && isHooksInstalled(for: codexCLI, fm: fm)
    }

    static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: hookScriptPath)
        try? fm.removeItem(atPath: bridgePath)
        // Also clean up legacy paths (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        for cli in allCLIs {
            if cli.source == "traecli" {
                uninstallTraecliHooks(fm: fm)
            } else {
                uninstallHooks(cli: cli, fm: fm)
            }
        }

        uninstallOpencodePlugin(fm: fm)
    }

    /// Check if Claude Code hooks are installed.
    /// Uses an explicit source filter instead of a positional index so the result
    /// is not sensitive to the ordering of builtInCLIs (WR-01).
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard let claudeCLI = allCLIs.first(where: { $0.source == "claude" }) else { return false }
        return runtimeExecutableInstalled(for: claudeCLI, fm: fm)
            && isHooksInstalled(for: claudeCLI, fm: fm)
    }

    /// DIAG-01: Launch-time health check. Returns true iff both (a) the bough-bridge
    /// socket file exists and (b) Claude Code hooks are installed in settings.json.
    /// Uses FileManager.default.fileExists — no connect attempt, no polling.
    static func claudeCodeHookHealthCheck() -> Bool {
        claudeCodeHookHealthCheck(socketPath: SocketPath.path)
    }

    /// Internal implementation that accepts a socket path parameter for testability.
    private static func claudeCodeHookHealthCheck(socketPath: String) -> Bool {
        let fm = FileManager.default
        let socketExists = fm.fileExists(atPath: socketPath)
        let hooksInstalled = isInstalled()
        return socketExists && hooksInstalled
    }

    /// Check if a specific CLI's hooks are installed
    static func isInstalled(source: String) -> Bool {
        let fm = FileManager.default
        if source == "opencode" {
            return isExecutableFile(at: bridgePath, fm: fm)
                && isOpencodePluginInstalled(fm: fm)
        }
        if source == "traecli" {
            return isExecutableFile(at: bridgePath, fm: fm)
                && isTraecliHooksInstalled(fm: fm)
        }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return runtimeExecutableInstalled(for: cli, fm: fm)
            && isHooksInstalled(for: cli, fm: fm)
    }

    /// Check if CLI directory exists (tool is installed on this machine)
    static func cliExists(source: String) -> Bool {
        if source == "opencode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/opencode") }
        if source == "copilot" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.copilot") }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return FileManager.default.fileExists(atPath: cli.dirPath)
    }

    // Keep backward compat
    static func isCodexInstalled() -> Bool { isInstalled(source: "codex") }

    /// Whether a CLI is enabled by user (UserDefaults). Default: true.
    /// `defaults` is injectable so tests can use an isolated suite instead of
    /// `.standard`, which is shared across `swift test --parallel` worker processes.
    static func isEnabled(source: String, defaults: UserDefaults = .standard) -> Bool {
        let key = "cli_enabled_\(source)"
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    /// Toggle a single CLI on/off: installs or uninstalls its hooks.
    @discardableResult
    static func setEnabled(source: String, enabled: Bool, defaults: UserDefaults = .standard) -> Bool {
        let key = "cli_enabled_\(source)"
        let fm = FileManager.default
        if enabled {
            let hookScriptInstalled = installHookScript(fm: fm)
            let bridgeInstalled = installBridgeBinary(fm: fm)
            let ok: Bool
            if source == "opencode" {
                ok = bridgeInstalled && installOpencodePlugin(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                if cli.source == "claude" {
                    ok = hookScriptInstalled
                        && installClaudeHooks(cli: cli, fm: fm)
                        && isHooksInstalled(for: cli, fm: fm)
                } else if cli.source == "traecli" {
                    ok = bridgeInstalled
                        && installTraecliHooks(fm: fm)
                        && isTraecliHooksInstalled(fm: fm)
                } else if cli.source == "codex" {
                    defaults.set(false, forKey: key)
                    ok = installCodexHooks(fm: fm, bridgeInstalled: bridgeInstalled)
                } else {
                    ok = bridgeInstalled
                        && installExternalHooks(cli: cli, fm: fm)
                        && isHooksInstalled(for: cli, fm: fm)
                }
            } else {
                ok = false
            }
            defaults.set(ok, forKey: key)
            return ok
        } else {
            defaults.set(false, forKey: key)
            if source == "opencode" {
                uninstallOpencodePlugin(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                if cli.source == "traecli" {
                    uninstallTraecliHooks(fm: fm)
                } else {
                    uninstallHooks(cli: cli, fm: fm)
                }
            }
            return true
        }
    }

    static func codexHooksFeatureDisabled() -> Bool {
        codexHooksFeatureDisabled(fm: FileManager.default)
    }

    static func currentClaudeCodeStatusLineCommand() -> String? {
        currentClaudeCodeStatusLineCommand(fm: FileManager.default, settingsPath: claudeSettingsPath)
    }

    static func currentClaudeCodeStatusLineCommand(settingsPath: String, fm: FileManager = .default) -> String? {
        currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath)
    }

    static func proposedClaudeCodeStatusLineCommand() -> String? {
        bundledClaudeCodeStatusLineBridgePath()
    }

    static func claudeCodeStatusLineStableBridgeInstallPath() -> String {
        claudeCodeStatusLineStableBridgePath
    }

    /// Phase 21 / D-07: public accessor for the chain wrapper's sentinel-encoded prev_cmd.
    /// Returns the decoded prev_cmd when ~/.bough/bough-statusline-wrapper.sh exists and
    /// carries a valid `# RESTORE:` base64 sentinel; nil otherwise. Used by SettingsView's
    /// state classifier to surface "chained with <basename>" when the wrapper is active.
    static func currentClaudeCodeStatusLineChainPrevCmd() -> String? {
        parseStatusLineWrapperSentinel(path: claudeCodeStatusLineWrapperPath, fm: FileManager.default)
    }

    /// Phase 21 / D-07: exposes the wrapper path so SettingsView's state classifier can
    /// detect "current command points at the Bough wrapper" without re-hardcoding the path.
    static func claudeCodeStatusLineWrapperInstallPath() -> String {
        claudeCodeStatusLineWrapperPath
    }

    static func isBoughClaudeCodeStatusLineCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        if command == claudeCodeStatusLineWrapperPath { return true }
        if command == claudeCodeStatusLineStableBridgePath { return true }
        if let proposed = proposedClaudeCodeStatusLineCommand(), command == proposed { return true }
        return isBoughStatusLineBridgePath(command)
    }

    // Retained for migration tests: retirement reuses the uninstall/restore half.
    // No production caller installs the statusLine anymore (spec §7) — the
    // install→uninstall round-trip tests validate the restore logic that
    // `retireClaudeCodeStatusLineIfInstalled` depends on.
    @discardableResult
    static func installClaudeCodeStatusLine(replaceExisting: Bool = false) -> ClaudeCodeStatusLineInstallResult {
        guard let bundledBridgePath = bundledClaudeCodeStatusLineBridgePath() else {
            return .failed("Bundled Claude Code statusLine bridge not found")
        }
        guard installStableClaudeCodeStatusLineBridge(from: bundledBridgePath, to: claudeCodeStatusLineStableBridgePath, fm: .default) else {
            return .failed("Could not install Bough statusLine bridge")
        }
        let proposed = claudeCodeStatusLineStableBridgePath
        // Phase 21 / D-02: the default install path is chain-aware so Bough
        // coexists with starship / gsd / ccusage / etc. without surfacing a
        // conflict sheet. `replaceExisting: true` preserves the original
        // direct-install UX — it represents an explicit user choice to
        // override their prev tool from the conflict-sheet "Replace" button.
        if replaceExisting {
            return installClaudeCodeStatusLine(
                replaceExisting: true,
                fm: FileManager.default,
                settingsPath: claudeSettingsPath,
                proposedBridgePath: proposed
            )
        }
        return installClaudeCodeStatusLineChainAware(
            fm: FileManager.default,
            settingsPath: claudeSettingsPath,
            proposedBridgePath: proposed,
            wrapperPath: claudeCodeStatusLineWrapperPath
        )
    }

    @discardableResult
    static func uninstallClaudeCodeStatusLine() -> Bool {
        let ok = uninstallClaudeCodeStatusLine(
            fm: FileManager.default,
            settingsPath: claudeSettingsPath,
            proposedBridgePath: bundledClaudeCodeStatusLineBridgePath(),
            wrapperPath: claudeCodeStatusLineWrapperPath
        )
        // Regression guard: also remove the statusLine data file
        // (~/.bough/claude-usage.json) so the data-source row immediately
        // reports .absent. Without this, the freshness window (10 minutes)
        // keeps the green Connected dot lit even after uninstall, because
        // round-6 bound the indicator to the file's mtime instead of hook
        // presence. Removal is best-effort — an existing-but-old file would
        // be evaluated as stale anyway, but deleting it gives the user
        // instant feedback (.absent) and avoids confusing transitions.
        let usagePath = NSHomeDirectory() + "/.bough/claude-usage.json"
        try? FileManager.default.removeItem(atPath: usagePath)
        return ok
    }

    /// One-time upgrade migration (spec §7): if settings.json's statusLine points
    /// at Bough's bridge/wrapper, uninstall it (restoring the user's prev_cmd via
    /// the chain sentinel) and remove the bridge scripts from ~/.bough. Idempotent;
    /// never touches a non-Bough statusLine.
    @discardableResult
    static func retireClaudeCodeStatusLineIfInstalled() -> Bool {
        retireClaudeCodeStatusLineIfInstalled(
            fm: FileManager.default,
            settingsPath: claudeSettingsPath,
            stableBridgePath: claudeCodeStatusLineStableBridgePath,
            wrapperPath: claudeCodeStatusLineWrapperPath
        )
    }

    /// Parameterized seam (mirrors the uninstall seams above) so tests can drive
    /// the retirement against temp fixtures. The zero-arg entry delegates here
    /// with live defaults.
    @discardableResult
    static func retireClaudeCodeStatusLineIfInstalled(
        fm: FileManager,
        settingsPath: String,
        stableBridgePath: String,
        wrapperPath: String
    ) -> Bool {
        var uninstalled = false
        let current = currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath)
        let pointsAtBough = isBoughClaudeCodeStatusLineCommand(current)
            || current == stableBridgePath
            || current == wrapperPath
        if pointsAtBough {
            uninstalled = uninstallClaudeCodeStatusLine(
                fm: fm,
                settingsPath: settingsPath,
                proposedBridgePath: stableBridgePath,
                wrapperPath: wrapperPath
            )
        }
        // Only remove the scripts when settings.json no longer points at a Bough
        // command. If uninstall refused (e.g. corrupt wrapper sentinel — the wrapper
        // has no valid `# RESTORE:` line so the prev_cmd cannot be recovered),
        // settings.json still references the wrapper; deleting it here would leave
        // the user's statusLine pointing at a nonexistent file.
        let afterCurrent = currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath)
        let stillPointsAtBough = isBoughClaudeCodeStatusLineCommand(afterCurrent)
            || afterCurrent == stableBridgePath
            || afterCurrent == wrapperPath
        guard !stillPointsAtBough else { return false }
        try? fm.removeItem(atPath: stableBridgePath)
        try? fm.removeItem(atPath: wrapperPath)
        return uninstalled
    }

    static func testCurrentClaudeCodeStatusLineCommand(settingsPath: String) -> String? {
        currentClaudeCodeStatusLineCommand(fm: FileManager.default, settingsPath: settingsPath)
    }

    @discardableResult
    static func testInstallClaudeCodeStatusLine(
        settingsPath: String,
        proposedBridgePath: String,
        replaceExisting: Bool = false
    ) -> ClaudeCodeStatusLineInstallResult {
        installClaudeCodeStatusLine(
            replaceExisting: replaceExisting,
            fm: FileManager.default,
            settingsPath: settingsPath,
            proposedBridgePath: proposedBridgePath
        )
    }

    @discardableResult
    static func testInstallClaudeCodeStatusLineUsingStableBridge(
        settingsPath: String,
        bundledBridgePath: String,
        stableBridgePath: String,
        replaceExisting: Bool = false
    ) -> ClaudeCodeStatusLineInstallResult {
        guard installStableClaudeCodeStatusLineBridge(
            from: bundledBridgePath,
            to: stableBridgePath,
            fm: FileManager.default
        ) else {
            return .failed("Could not install Bough statusLine bridge")
        }
        return installClaudeCodeStatusLine(
            replaceExisting: replaceExisting,
            fm: FileManager.default,
            settingsPath: settingsPath,
            proposedBridgePath: stableBridgePath
        )
    }

    @discardableResult
    static func testUninstallClaudeCodeStatusLine(
        settingsPath: String,
        proposedBridgePath: String? = nil
    ) -> Bool {
        uninstallClaudeCodeStatusLine(
            fm: FileManager.default,
            settingsPath: settingsPath,
            proposedBridgePath: proposedBridgePath
        )
    }

    /// Phase 21 / D-02 chain-aware install test seam (mirrors
    /// `testInstallClaudeCodeStatusLine` pattern). Routes through
    /// `installClaudeCodeStatusLineChainAware` with the wrapper path
    /// injected from the test's temp dir.
    @discardableResult
    static func testInstallClaudeCodeStatusLineChainAware(
        settingsPath: String,
        proposedBridgePath: String,
        wrapperPath: String
    ) -> ClaudeCodeStatusLineInstallResult {
        installClaudeCodeStatusLineChainAware(
            fm: FileManager.default,
            settingsPath: settingsPath,
            proposedBridgePath: proposedBridgePath,
            wrapperPath: wrapperPath
        )
    }

    /// Phase 21 / D-02 chain-aware uninstall test seam.
    @discardableResult
    static func testUninstallClaudeCodeStatusLineWithWrapper(
        settingsPath: String,
        proposedBridgePath: String? = nil,
        wrapperPath: String
    ) -> Bool {
        uninstallClaudeCodeStatusLine(
            fm: FileManager.default,
            settingsPath: settingsPath,
            proposedBridgePath: proposedBridgePath,
            wrapperPath: wrapperPath
        )
    }

    /// DIAG-01: Test surface for claudeCodeHookHealthCheck with an injected socket path.
    /// Allows tests to assert the socket-absent path without depending on whether the
    /// real bough-bridge socket happens to be running in the test environment.
    static func testClaudeCodeHookHealthCheck(socketPath: String) -> Bool {
        claudeCodeHookHealthCheck(socketPath: socketPath)
    }

    /// Calls installClaudeHooks against a settings file at the given path.
    /// Used by tests to exercise Claude Code hook install without touching ~/.claude.
    @discardableResult
    static func testInstallClaudeCodeHooks(settingsPath: String) -> Bool {
        guard var cli = allCLIs.first(where: { $0.source == "claude" }) else { return false }
        // settingsPath = <tempRoot>/.claude/settings.json — strip two components to get tempRoot.
        let tempRoot = ((settingsPath as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        cli.rootOverride = { tempRoot }
        return installClaudeHooks(cli: cli, fm: FileManager.default)
    }

    /// Check all installed CLIs and repair missing hooks. Returns names of repaired CLIs.
    static func verifyAndRepair() -> [String] {
        let fm = FileManager.default
        // Ensure bridge binary and hook script are current
        let bridgeInstalled = installBridgeBinary(fm: fm)
        let hookScriptInstalled = installHookScript(fm: fm)

        var repaired: [String] = []
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            let dirExists = cli.format == .copilot
                ? fm.fileExists(atPath: NSHomeDirectory() + "/.copilot")
                : fm.fileExists(atPath: cli.dirPath)
            guard dirExists else { continue }
            if cli.source == "traecli" {
                guard bridgeInstalled else { continue }
                if isTraecliHooksInstalled(fm: fm) { continue }
                if installTraecliHooks(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if cli.source == "codex" {
                guard bridgeInstalled else { continue }
                let hooksPresent = isHooksInstalled(for: cli, fm: fm)
                let configPath = codexHome() + "/config.toml"
                let configBefore = fm.contents(atPath: configPath).flatMap { String(data: $0, encoding: .utf8) }
                let configInstalled = enableCodexHooksConfig(fm: fm)
                let configAfter = fm.contents(atPath: configPath).flatMap { String(data: $0, encoding: .utf8) }
                let configChanged = configBefore != configAfter
                if hooksPresent {
                    if configInstalled && configChanged {
                        repaired.append(cli.name)
                    }
                    continue
                }
                if installExternalHooks(cli: cli, fm: fm),
                   configInstalled,
                   isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            if cli.source == "claude" {
                guard hookScriptInstalled else { continue }
                if installClaudeHooks(cli: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            } else {
                guard bridgeInstalled else { continue }
                _ = installExternalHooks(cli: cli, fm: fm)
                if isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            }
        }
        // OpenCode plugin
        if isEnabled(source: "opencode"),
           bridgeInstalled,
           fm.fileExists(atPath: (opencodeConfigPath as NSString).deletingLastPathComponent),
           !isOpencodePluginInstalled(fm: fm) {
            if installOpencodePlugin(fm: fm) { repaired.append("OpenCode") }
        }
        return repaired
    }

    // MARK: - JSONC Support

    /// Strip // and /* */ comments from JSONC, preserving strings
    static func stripJSONComments(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex

        while i < end {
            let c = input[i]
            if c == "\"" {
                result.append(c)
                i = input.index(after: i)
                while i < end {
                    let sc = input[i]
                    result.append(sc)
                    if sc == "\\" {
                        i = input.index(after: i)
                        if i < end { result.append(input[i]) }
                    } else if sc == "\"" {
                        break
                    }
                    i = input.index(after: i)
                }
                if i < end { i = input.index(after: i) }
                continue
            }
            let next = input.index(after: i)
            if c == "/" && next < end {
                let nc = input[next]
                if nc == "/" {
                    i = input.index(after: next)
                    while i < end && input[i] != "\n" { i = input.index(after: i) }
                    continue
                } else if nc == "*" {
                    i = input.index(after: next)
                    while i < end {
                        let bi = input.index(after: i)
                        if input[i] == "*" && bi < end && input[bi] == "/" {
                            i = input.index(after: bi)
                            break
                        }
                        i = input.index(after: i)
                    }
                    continue
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }

    static func parseJSONCFile(at path: String, fm: FileManager = .default) -> [String: Any]? {
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return parseJSONCString(str)
    }

    private static func parseJSONCString(_ str: String) -> [String: Any]? {
        let stripped = stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return nil }
        return json
    }

    /// Parse a JSON file, stripping JSONC comments first
    private static func parseJSONFile(at path: String, fm: FileManager) -> [String: Any]? {
        parseJSONCFile(at: path, fm: fm)
    }

    // MARK: - CLI Version Detection

    /// Detect installed Claude Code version by running `claude --version`.
    /// Cache is guarded by a lock held for the full operation (WR-03): two concurrent callers
    /// that both pass a pre-lock cache check would otherwise each spawn a subprocess, doubling
    /// wall time. The subprocess is bounded by a 5-second timeout so the worst-case lock hold
    /// time is acceptable given this path already runs on a Task.detached thread.
    private static var cachedClaudeVersion: String?
    private static let cachedClaudeVersionLock = NSLock()
    private static func detectClaudeVersion() -> String? {
        cachedClaudeVersionLock.lock()
        defer { cachedClaudeVersionLock.unlock() }
        if let cached = cachedClaudeVersion { return cached }

        // Find claude binary — GUI apps don't inherit user's shell PATH
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // 5s timeout: a stuck `claude --version` used to freeze app launch (#139).
        guard let data = ProcessRunner.run(path: claudePath, args: ["--version"], timeout: 5),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Parse "2.1.92 (Claude Code)" → "2.1.92"
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").first ?? ""
        guard !version.isEmpty else { return nil }
        cachedClaudeVersion = version
        return version
    }

    /// Compare semver strings: returns true if `installed` >= `required`
    static func versionAtLeast(_ installed: String, _ required: String) -> Bool {
        let i = installed.split(separator: ".").compactMap { Int($0) }
        let r = required.split(separator: ".").compactMap { Int($0) }
        for idx in 0..<max(i.count, r.count) {
            let iv = idx < i.count ? i[idx] : 0
            let rv = idx < r.count ? r[idx] : 0
            if iv > rv { return true }
            if iv < rv { return false }
        }
        return true // equal
    }

    static func codexVersion(fromVersionOutput output: String) -> String? {
        let pattern = #"\b([0-9]+\.[0-9]+\.[0-9]+)\b"#
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }

    // MARK: Codex CLI version detection

    /// Minimum Codex CLI version that supports Bough's `[features]` hooks table (D-05).
    /// Locally confirmed working build; upstream changelog audit is out of scope for Phase 15.
    static let codexCLIMinimumHooksVersion = "0.130.0"

    /// Mirrors `cachedClaudeVersion` / `cachedClaudeVersionLock` for Codex.
    private static var cachedCodexVersion: String?
    private static let cachedCodexVersionLock = NSLock()

    /// Detect installed Codex CLI version by running `codex --version`.
    /// Lock is held for the full operation (WR-03, mirrors detectClaudeVersion fix): prevents
    /// concurrent callers from each spawning a subprocess when both pass the pre-lock cache check.
    /// Pitfall-15 mitigation: a stuck `codex --version` cannot freeze the app beyond 5 seconds.
    /// Call sites: `enableCodexHooksConfig` (Plan 15-03, same file) and `UsagePage`
    /// in SettingsView.swift (Plan 15-05). The function is intentionally internal (not private)
    /// so cross-file consumers within the `Bough` module can reach it — matches the visibility
    /// of the existing `versionAtLeast(_:_:)` helper above.
    static func detectCodexVersion() -> String? {
        cachedCodexVersionLock.lock()
        defer { cachedCodexVersionLock.unlock() }
        if let cached = cachedCodexVersion { return cached }

        let detected = detectedCodexVersion(candidatePaths: codexVersionCandidatePaths())
        if let detected {
            cachedCodexVersion = detected
        }
        return detected
    }

    static func detectedCodexVersion(candidatePaths: [String]) -> String? {
        var versions: [String] = []

        for codexPath in candidatePaths {
            // 5s timeout: mirrors `detectClaudeVersion` Pitfall-15 guard (#139).
            guard let data = ProcessRunner.run(path: codexPath, args: ["--version"], timeout: 5),
                  let output = String(data: data, encoding: .utf8),
                  let version = codexVersion(fromVersionOutput: output) else {
                continue
            }
            versions.append(version)
        }

        guard !versions.isEmpty else { return nil }
        return versions.first { versionAtLeast($0, codexCLIMinimumHooksVersion) } ?? versions[0]
    }

    static func codexVersionCandidatePaths(
        shellResolvedPath: String? = shellResolvedCodexPath(),
        homeDirectory: String = NSHomeDirectory(),
        appResourcesCodexPath: String = "/Applications/Codex.app/Contents/Resources/codex",
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates: [String] = []
        if let shellResolvedPath, !shellResolvedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(shellResolvedPath)
        }
        candidates += [
            homeDirectory + "/.local/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        candidates += nvmCodexCandidatePaths(homeDirectory: homeDirectory, fileManager: fileManager)
        candidates.append(appResourcesCodexPath)

        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard seen.insert(path).inserted else { continue }
            guard !isCodexGUIAppBinary(path) else { continue }
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            result.append(path)
        }
        return result
    }

    private static func isCodexGUIAppBinary(_ path: String) -> Bool {
        let guiBinaryPath = "/Applications/Codex.app/Contents/MacOS/Codex"
        if URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path == guiBinaryPath {
            return true
        }

        guard let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return false
        }
        let destinationPath: String
        if symlinkDestination.hasPrefix("/") {
            destinationPath = symlinkDestination
        } else {
            destinationPath = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent(symlinkDestination)
                .path
        }
        return URL(fileURLWithPath: destinationPath)
            .standardizedFileURL
            .path == guiBinaryPath
    }

    private static func shellResolvedCodexPath() -> String? {
        for shell in ["/bin/zsh", "/bin/sh"] where FileManager.default.isExecutableFile(atPath: shell) {
            guard let data = ProcessRunner.run(path: shell, args: ["-lc", "command -v codex"], timeout: 5),
                  let output = String(data: data, encoding: .utf8) else {
                continue
            }
            if let firstLine = output
                .split(whereSeparator: { $0.isNewline })
                .map(String.init)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !firstLine.isEmpty {
                return firstLine
            }
        }
        return nil
    }

    private static func nvmCodexCandidatePaths(homeDirectory: String, fileManager: FileManager) -> [String] {
        let nodeRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".nvm")
            .appendingPathComponent("versions")
            .appendingPathComponent("node")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: nodeRoot.path) else {
            return []
        }
        return entries.sorted().map {
            nodeRoot
                .appendingPathComponent($0)
                .appendingPathComponent("bin")
                .appendingPathComponent("codex")
                .path
        }
    }

    /// Filter events based on installed CLI version
    private static func compatibleEvents(for cli: CLIConfig) -> [(String, Int, Bool)] {
        guard !cli.versionedEvents.isEmpty else { return cli.events }

        // Only Claude Code needs version checking for now
        guard cli.source == "claude" else { return cli.events }
        let version = detectClaudeVersion()

        return cli.events.filter { (event, _, _) in
            guard let minVer = cli.versionedEvents[event] else { return true }
            guard let version else { return false } // can't detect version → skip risky events
            return versionAtLeast(version, minVer)
        }
    }

    // MARK: - Claude Code (special: uses hook script)

    private static func installClaudeHooks(
        cli: CLIConfig,
        fm: FileManager
    ) -> Bool {
        let dir = cli.dirPath
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Read raw text (preserved verbatim for minimal-diff write-back).
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 — protect user data).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let settings = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = settings[cli.configKey] as? [String: Any] ?? [:]
        let events = compatibleEvents(for: cli)

        let alreadyInstalled = events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String) == hookCommand }
            }
        }
        if alreadyInstalled && !hasStaleAsyncKey(hooks) { return true }

        // Remove all managed hooks first, including legacy managed entries.
        hooks = removeManagedHookEntries(from: hooks)

        // Re-install only compatible events
        for (event, timeout, _) in events {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            let hookEntry: [String: Any] = [
                "type": "command", "command": hookCommand, "timeout": timeout,
            ]
            eventHooks.append(["matcher": "", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }

        guard let merged = mergedJSONWithKey(
            cli: cli,
            originalText: originalText,
            key: cli.configKey,
            value: hooks
        ) else { return false }

        return fm.createFile(atPath: cli.fullPath, contents: Data(merged.utf8))
    }

    /// Minimal-diff write of a single top-level key, preserving user comments / key order / escaping.
    /// Creates the file fresh if `originalText` is nil. Returns false on any failure (caller-side #89 guard).
    private static func writeJSONWithKey(
        cli: CLIConfig,
        originalText: String?,
        key: String,
        value: Any,
        fm: FileManager
    ) -> Bool {
        guard let merged = mergedJSONWithKey(cli: cli, originalText: originalText, key: key, value: value) else {
            return false
        }
        return fm.createFile(atPath: cli.fullPath, contents: Data(merged.utf8))
    }

    private static func mergedJSONWithKey(
        cli: CLIConfig,
        originalText: String?,
        key: String,
        value: Any
    ) -> String? {
        let source: String = {
            if let t = originalText, !t.isEmpty { return t }
            return "{}\n"
        }()
        return JSONMinimalEditor.setTopLevelValue(in: source, key: key, value: value)
    }

    // MARK: - External CLIs (use bridge binary directly)

    @discardableResult
    private static func installExternalHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .kimi {
            // Kimi: do not create ~/.kimi or config files unless there is already
            // evidence of an existing Kimi installation/configuration.
            let rootDir = NSHomeDirectory() + "/.kimi"
            let sessionsDir = rootDir + "/sessions"
            let hasKimiPresence =
                fm.fileExists(atPath: cli.dirPath) ||
                fm.fileExists(atPath: rootDir) ||
                fm.fileExists(atPath: sessionsDir)
            guard hasKimiPresence else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
            return installKimiHooks(cli: cli, fm: fm)
        }

        if cli.format == .copilot {
            // Copilot: check root ~/.copilot exists, create hooks subdir if needed
            let rootDir = NSHomeDirectory() + "/.copilot"
            guard fm.fileExists(atPath: rootDir) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else if cli.format == .kiroAgent {
            // Kiro: check ~/.kiro exists; create agents/ subdir if needed.
            let kiroRoot = NSHomeDirectory() + "/.kiro"
            guard fm.fileExists(atPath: kiroRoot) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else {
            guard fm.fileExists(atPath: cli.dirPath) else { return true } // CLI not installed, skip OK
        }

        // Read raw text for minimal-diff write-back.
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 safety guard).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let root = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = root[cli.configKey] as? [String: Any] ?? [:]
        let baseCommand = bridgeHookCommand(source: cli.source)

        for (event, timeout, _) in cli.events {
            var eventEntries = hooks[event] as? [[String: Any]] ?? []
            // Remove old hooks before adding fresh ones (ensures reinstall works)
            eventEntries.removeAll { containsOurHook($0) }

            let entry: [String: Any]
            switch cli.format {
            case .claude:
                // Qwen Code (a Claude fork) reuses this format and NEEDS timeout per entry
                // — otherwise long-running PermissionRequest hooks hang the agent (#103).
                entry = ["matcher": "*", "hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .nested:
                entry = ["hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .flat:
                entry = ["command": baseCommand]
            case .traecli:
                // Treat like flat for custom JSON hook configs; built-in TraeCli uses YAML install path.
                entry = ["command": baseCommand]
            case .copilot:
                // Copilot CLI stdin lacks session_id/hook_event_name — pass event name via flag
                let copilotCommand = "\(baseCommand) --event \(event)"
                entry = ["type": "command", "bash": copilotCommand, "timeoutSec": timeout]
            case .kimi:
                // Handled earlier in the function; should never reach here
                return false
            case .kiroAgent:
                // Kiro entries: { command, matcher: "*", timeout_ms }. Caller declares
                // timeout in seconds for consistency with other CLIs; convert to ms here.
                entry = ["command": baseCommand, "matcher": "*", "timeout_ms": timeout * 1000]
            }
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        // Seed file if missing — ensure Copilot's required "version" key lands first so the key-order
        // for downstream readers stays stable across installs.
        var seeded = originalText
        if cli.format == .copilot, (originalText == nil || originalText?.isEmpty == true) {
            seeded = "{\n  \"version\": 1\n}\n"
        } else if cli.format == .copilot, root["version"] == nil {
            // Only insert `version` when the user hasn't set one themselves — don't clobber a
            // user-bumped schema version in case Copilot ships v2+ in the future.
            if let t = originalText, let withVer = JSONMinimalEditor.setTopLevelValue(in: t, key: "version", value: 1) {
                seeded = withVer
            }
        } else if cli.format == .kiroAgent, (originalText == nil || originalText?.isEmpty == true) {
            // Kiro agent JSON requires at minimum a "name" field. Seed a minimal agent
            // skeleton so the file is a valid Kiro agent the user can launch with
            // `kiro --agent bough`.
            seeded = """
            {
              "name": "bough",
              "description": "Auto-generated by Bough — relays Kiro hook events to the macOS Dynamic Island. Launch with `kiro --agent bough`."
            }
            """
        }

        return writeJSONWithKey(
            cli: cli,
            originalText: seeded,
            key: cli.configKey,
            value: hooks,
            fm: fm
        )
    }

    private static func managedTraecliHookObject(source: String = "traecli") -> [String: Any] {
        let command = bridgeHookCommand(source: source)

        let events = defaultEvents(for: .traecli)
        let timeout = events.map { $0.1 }.max() ?? 5

        let matchers: [[String: Any]] = events.map { (event, _, _) in
            ["event": event]
        }

        return [
            "type": "command",
            "command": command,
            "timeout": "\(timeout)s",
            "matchers": matchers,
        ]
    }

    /// Render the managed hook block as YAML text (2-space indent, list-item form).
    /// Used by the surgical merge path that preserves user comments/key order.
    private static func renderManagedTraecliHooksText(source: String = "traecli") -> String {
        let escapedCommand = bridgeHookCommand(source: source).replacingOccurrences(of: "'", with: "''")

        let events = defaultEvents(for: .traecli)
        let timeout = events.map { $0.1 }.max() ?? 5

        var lines: [String] = ["  # bough-hook-v1-start", "  - type: command"]
        lines.append("    command: '\(escapedCommand)'")
        lines.append("    timeout: '\(timeout)s'")
        lines.append("    matchers:")
        for (event, _, _) in events {
            lines.append("      - event: \(event)")
        }
        lines.append("  # bough-hook-v1-end")
        return lines.joined(separator: "\n")
    }

    private static func asStringKeyedDict(_ any: Any) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let d = any as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d {
                guard let ks = k as? String else { continue }
                out[ks] = v
            }
            return out
        }
        return nil
    }

    /// Best-effort repair for invalid YAML produced by mixed indentation under `hooks:`.
    ///
    /// This is only used as a recovery step when YAML parsing fails, to make the file
    /// parseable so it can be re-serialized via Yams.
    private static func normalizeTraecliHooksListIndentation(_ contents: String) -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let hooksIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line == trimmed else { return false } // top-level only
            return trimmed.hasPrefix("hooks:")
        }) else {
            return normalized
        }

        // Determine the intended indentation for *hook items* under hooks:
        // Only consider "- type:" / "- command:" so we don't confuse nested matcher lists.
        var hookIndent: Int?
        var i = hooksIndex + 1
        var indents: [Int] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            // Stop if we hit another top-level key.
            if line == trimmed, trimmed.contains(":"), !trimmed.hasPrefix("hooks:") {
                break
            }
            if trimmed.hasPrefix("- type:") || trimmed.hasPrefix("- command:") {
                indents.append(line.prefix { $0 == " " }.count)
            }
            i += 1
        }
        hookIndent = indents.min()
        guard let baseIndent = hookIndent else { return normalized }

        var out = lines
        i = hooksIndex + 1
        while i < out.count {
            let line = out[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            // Stop when leaving hooks section (top-level key).
            if line == trimmed, trimmed.contains(":"), !trimmed.hasPrefix("hooks:") {
                break
            }

            if (trimmed.hasPrefix("- type:") || trimmed.hasPrefix("- command:")) {
                let indent = line.prefix { $0 == " " }.count
                if indent > baseIndent {
                    let delta = indent - baseIndent
                    // Shift the whole list item block left by delta spaces.
                    var j = i
                    while j < out.count {
                        let next = out[j]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        let nextIndent = next.prefix { $0 == " " }.count

                        if j != i {
                            // Next item in the same list at the original indent ends the block.
                            if nextIndent == indent && nextTrimmed.hasPrefix("- ") {
                                break
                            }
                            // Leaving this list item (less indent + non-empty) ends the block.
                            if nextIndent < indent && !nextTrimmed.isEmpty {
                                break
                            }
                        }

                        if next.hasPrefix(String(repeating: " ", count: delta)) {
                            out[j] = String(next.dropFirst(delta))
                        }
                        j += 1
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }

        return out.joined(separator: "\n")
    }

    private static func isTraecliCommandListItemStart(_ trimmed: String) -> Bool {
        // Accept exact "- type: command" and variants with trailing whitespace/comments.
        let prefix = "- type: command"
        guard trimmed.hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count)
        if rest.isEmpty { return true }
        guard let c = rest.first else { return true }
        return c == " " || c == "\t" || c == "#"
    }

    private static func parseYAMLScalar(_ raw: String) -> String {
        // Handles simple single-line YAML scalars used by TraeCli config.
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            // Minimal escape handling
            return inner
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return s
    }

    private static func extractTraecliCommand(from blockLines: ArraySlice<String>) -> String? {
        for line in blockLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command:") else { continue }
            let raw = trimmed.dropFirst("command:".count)
            return parseYAMLScalar(String(raw))
        }
        return nil
    }

    private static func normalizeTraecliCommandForCompare(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !s.isEmpty else { return s }

        // Parse first token, allowing quoted path with spaces.
        var first = ""
        var rest = ""
        if s.hasPrefix("\"") {
            let afterQuote = s.index(after: s.startIndex)
            if let endQuote = s[afterQuote...].firstIndex(of: "\"") {
                first = String(s[afterQuote..<endQuote])
                rest = String(s[s.index(after: endQuote)...])
            } else {
                first = s
                rest = ""
            }
        } else {
            if let space = s.firstIndex(of: " ") {
                first = String(s[..<space])
                rest = String(s[space...])
            } else {
                first = s
                rest = ""
            }
        }

        first = first.trimmingCharacters(in: .whitespaces)
        rest = rest.trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("~/") {
            first = NSHomeDirectory() + "/" + first.dropFirst(2)
        }
        // Normalize home prefix
        let home = NSHomeDirectory()
        if first.hasPrefix(home + "/") {
            // Keep absolute; just ensure no double slashes
            first = first.replacingOccurrences(of: "//", with: "/")
        }
        if !rest.isEmpty {
            rest = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return "\(first) \(rest)"
        }
        return first
    }

    private static func expectedTraecliCommandCandidates(source: String) -> [String] {
        let abs = "\(bridgeCommand) --source \(source)"
        let absQuoted = "\"\(bridgeCommand)\" --source \(source)"
        let tilde = "~/.bough/bough-bridge --source \(source)"
        let tildeQuoted = "\"~/.bough/bough-bridge\" --source \(source)"
        let actualRendered = bridgeHookCommand(source: source)
        return [actualRendered, abs, absQuoted, tilde, tildeQuoted]
    }

    private static func isOurTraecliInjectedCommand(_ command: String, source: String) -> Bool {
        let normalized = normalizeTraecliCommandForCompare(command)
        for candidate in expectedTraecliCommandCandidates(source: source) {
            if normalized == normalizeTraecliCommandForCompare(candidate) {
                return true
            }
        }
        return false
    }

    private static func removeManagedTraecliHooksLegacy(from contents: String, source: String = "traecli") -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [String] = []
        result.reserveCapacity(lines.count)

        // Legacy compatibility: previous versions could leave extra comment lines around our hook.
        // We do NOT key off any marker token. Instead, when removing a hook by command match,
        // we also remove contiguous same-indent comment lines adjacent to that hook.

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect a YAML list item start like "  - type: command" (indent may vary).
            if isTraecliCommandListItemStart(trimmed) {
                let indent = line.prefix { $0 == " " }.count

                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    let nextIndent = next.prefix { $0 == " " }.count

                    // Next item in the same list (same indent + "- ") => current block ends.
                    if nextIndent == indent && nextTrimmed.hasPrefix("- ") {
                        break
                    }
                    // Leaving the list block (less indent + non-empty) => current block ends.
                    if nextIndent < indent && !nextTrimmed.isEmpty {
                        break
                    }
                    j += 1
                }

                // Remove only if the command matches what we inject.
                if let cmd = extractTraecliCommand(from: lines[i..<j]), isOurTraecliInjectedCommand(cmd, source: source) {
                    // Expand deletion to include adjacent same-indent comment lines.
                    var start = i
                    while start > 0 {
                        let prev = lines[start - 1]
                        let prevTrimmed = prev.trimmingCharacters(in: .whitespaces)
                        let prevIndent = prev.prefix { $0 == " " }.count
                        if prevIndent == indent && prevTrimmed.hasPrefix("#") {
                            start -= 1
                            continue
                        }
                        break
                    }

                    var end = j
                    while end < lines.count {
                        let next = lines[end]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        let nextIndent = next.prefix { $0 == " " }.count
                        if nextIndent == indent && nextTrimmed.hasPrefix("#") {
                            end += 1
                            continue
                        }
                        break
                    }

                    // Remove the already-appended leading comment lines (if any).
                    let removeCount = i - start
                    if removeCount > 0, result.count >= removeCount {
                        result.removeLast(removeCount)
                    }
                    i = end
                    continue
                }
                result.append(contentsOf: lines[i..<j])
                i = j
                continue
            }

            result.append(line)
            i += 1
        }

        while result.count >= 2 && result.suffix(2).allSatisfy({ $0.isEmpty }) {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    static func removeManagedTraecliHooks(from contents: String, source: String = "traecli") -> String {
        // Fast path: empty file.
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contents
        }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let surgical = removeManagedTraecliHooksLegacy(from: normalized, source: source)
        if surgical != normalized {
            do {
                _ = try Yams.load(yaml: surgical)
                return surgical
            } catch {
                // Fall through to the parsed round-trip remover below.
            }
        }

        let parseInputs = [normalized, normalizeTraecliHooksListIndentation(normalized)]
        for input in parseInputs {
            do {
                guard let loaded = try Yams.load(yaml: input) else { continue }
                guard var root = asStringKeyedDict(loaded) else { continue }
                guard let hooksAny = root["hooks"] else { return contents }
                guard let hooks = hooksAny as? [Any] else { return contents }

                var didRemove = false
                var cleaned: [Any] = []
                cleaned.reserveCapacity(hooks.count)
                for item in hooks {
                    guard let hook = asStringKeyedDict(item),
                          let command = hook["command"] as? String,
                          isOurTraecliInjectedCommand(command, source: source)
                    else {
                        cleaned.append(item)
                        continue
                    }
                    didRemove = true
                }

                guard didRemove else { return contents }
                root["hooks"] = cleaned

                var dumped = try Yams.dump(object: root)
                if !dumped.hasSuffix("\n") { dumped.append("\n") }
                return dumped
            } catch {
                continue
            }
        }

        // YAML still unparseable — fall back to the legacy remover (best effort).
        return removeManagedTraecliHooksLegacy(from: contents, source: source)
    }

    static func mergeTraecliHooks(into contents: String, source: String = "traecli") -> String {
        mergeTraecliHooksIfValid(into: contents, source: source) ?? contents
    }

    private static func mergeTraecliHooksIfValid(into contents: String, source: String = "traecli") -> String? {
        // Path A — surgical string-level write. Preserves user comments + key
        // ordering. Validated by re-parsing through Yams; if the result is
        // invalid (e.g. user file has mixed indentation), fall through to B.
        if let surgical = trySurgicalMergeTraecliHooks(into: contents, source: source) {
            return surgical
        }

        // Path B — Yams round-trip. Re-serializes the whole file, so comments
        // and key order are lost, but the output is guaranteed to be valid YAML.
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let parseInputs = [normalized, normalizeTraecliHooksListIndentation(normalized)]

        for input in parseInputs {
            do {
                let loaded = try Yams.load(yaml: input)
                var root: [String: Any] = loaded.flatMap(asStringKeyedDict) ?? [:]

                let hooksAny = root["hooks"]
                var hooks: [Any] = []
                if let existing = hooksAny as? [Any] {
                    hooks = existing
                }

                // Remove existing managed hook(s) and then prepend the fresh one.
                hooks.removeAll { item in
                    guard let hook = asStringKeyedDict(item),
                          let command = hook["command"] as? String
                    else { return false }
                    return isOurTraecliInjectedCommand(command, source: source)
                }
                hooks.insert(managedTraecliHookObject(source: source), at: 0)
                root["hooks"] = hooks

                var dumped = try Yams.dump(object: root)
                if !dumped.hasSuffix("\n") { dumped.append("\n") }
                return dumped
            } catch {
                continue
            }
        }

        // Still unparseable: last resort, do not clobber user data.
        return nil
    }

    /// Surgical merge: drop existing managed block via string scan (preserves
    /// surrounding comments + key order), then insert a freshly-rendered one
    /// under the `hooks:` key. Returns `nil` if the result fails Yams validation,
    /// signaling the caller to fall back to the round-trip path.
    private static func trySurgicalMergeTraecliHooks(into contents: String, source: String) -> String? {
        let cleaned = removeManagedTraecliHooksLegacy(from: contents, source: source)
        let managedLines = renderManagedTraecliHooksText(source: source).components(separatedBy: "\n")
        var lines = cleaned.components(separatedBy: "\n")

        if let hooksIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line == trimmed else { return false }  // top-level only
            return trimmed.range(of: #"^hooks:\s*(\[\s*\]|\{\s*\}|null|~)?\s*(#.*)?$"#, options: .regularExpression) != nil
        }) {
            let trimmed = lines[hooksIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^hooks:\s*(\[\s*\]|\{\s*\}|null|~)\s*(#.*)?$"#, options: .regularExpression) != nil {
                lines[hooksIndex] = "hooks:"
            }
            lines.insert(contentsOf: managedLines, at: hooksIndex + 1)
        } else {
            while !lines.isEmpty && lines.last == "" {
                lines.removeLast()
            }
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("hooks:")
            lines.append(contentsOf: managedLines)
        }

        var merged = lines.joined(separator: "\n")
        if !merged.hasSuffix("\n") { merged.append("\n") }

        // Validate: must parse, and contain exactly one of our managed hooks.
        do {
            guard let loaded = try Yams.load(yaml: merged),
                  let root = asStringKeyedDict(loaded),
                  let hooks = root["hooks"] as? [Any] else { return nil }
            let managedCount = hooks.filter { item in
                guard let hook = asStringKeyedDict(item),
                      let command = hook["command"] as? String else { return false }
                return isOurTraecliInjectedCommand(command, source: source)
            }.count
            guard managedCount == 1 else { return nil }
        } catch {
            return nil
        }

        return merged
    }

    @discardableResult
    private static func installTraecliHooks(fm: FileManager) -> Bool {
        let configDir = (traecliConfigPath as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: configDir) else { return true }

        var original = ""
        if fm.fileExists(atPath: traecliConfigPath) {
            guard let data = fm.contents(atPath: traecliConfigPath) else { return false }
            // Never clobber existing file contents if decoding fails.
            guard let decoded = String(data: data, encoding: .utf8) else { return false }
            original = decoded
        }

        guard let merged = mergeTraecliHooksIfValid(into: original) else { return false }
        guard let data = merged.data(using: .utf8) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: traecliConfigPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func uninstallTraecliHooks(fm: FileManager) {
        guard fm.fileExists(atPath: traecliConfigPath),
              let original = try? String(contentsOfFile: traecliConfigPath, encoding: .utf8)
        else { return }

        let cleaned = removeManagedTraecliHooks(from: original, source: "traecli")
        guard cleaned != original, let data = cleaned.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: traecliConfigPath), options: .atomic)
    }

    private static func isTraecliHooksInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: traecliConfigPath),
              let contents = try? String(contentsOfFile: traecliConfigPath, encoding: .utf8)
        else { return false }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        return removeManagedTraecliHooks(from: normalized, source: "traecli") != normalized
    }

    private static func bundledClaudeCodeStatusLineBridgePath() -> String? {
        // SwiftPM places target resources inside a nested bundle
        // (`Bough.app/Contents/Resources/Bough_Bough.bundle/Resources/`) for signed
        // .app layout, and in `Bundle.module` for SPM dev builds. `Bundle.main`
        // resolves at the .app level and cannot see either location — use the
        // codebase's canonical `Bundle.appModule` accessor (see BundleExtension.swift).
        // Two-step lookup mirrors RemoteInstaller.remoteHookSource() (see RemoteInstaller.swift:45-50).
        let resolved: URL? = {
            if let url = Bundle.appModule.url(
                forResource: statusLineBridgeResourceName,
                withExtension: statusLineBridgeResourceExtension,
                subdirectory: "Resources"
            ) {
                return url
            }
            if let url = Bundle.appModule.url(
                forResource: statusLineBridgeResourceName,
                withExtension: statusLineBridgeResourceExtension
            ) {
                return url
            }
            return nil
        }()
        guard let url = resolved else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private static func installStableClaudeCodeStatusLineBridge(
        from sourcePath: String,
        to destinationPath: String,
        fm: FileManager
    ) -> Bool {
        if sourcePath == destinationPath {
            guard fm.fileExists(atPath: destinationPath) else { return false }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
            return true
        }

        guard fm.fileExists(atPath: sourcePath) else { return false }
        do {
            let destinationURL = URL(fileURLWithPath: destinationPath)
            try BoughPrivateStorage.ensurePrivateDirectoryForFile(at: destinationURL, fileManager: fm)
            let tmpURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: tmpURL)
            try fm.copyItem(at: URL(fileURLWithPath: sourcePath), to: tmpURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpURL.path)
            if fm.fileExists(atPath: destinationPath) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: destinationURL)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
            return true
        } catch {
            return false
        }
    }

    /// Resolves the chain wrapper template bundled under
    /// `Sources/Bough/Resources/bough-statusline-wrapper.sh.template` and
    /// performs literal-string substitution of the `__BOUGH_PREV_CMD_B64__`
    /// and `__BOUGH_BRIDGE_PATH__` placeholders. Returns the fully rendered
    /// shell script body, or nil on any resolve / read / encode failure.
    ///
    /// `prevCmd` is base64-encoded so user previous statusLine commands
    /// containing quotes, backslashes, `#`, or newlines round-trip safely
    /// through the wrapper sentinel and the uninstall restore path.
    /// `bridgePath` is substituted as a literal absolute path; it is
    /// expected to come from `bundledClaudeCodeStatusLineBridgePath()`.
    private static func renderClaudeCodeStatusLineWrapper(
        prevCmd: String,
        bridgePath: String
    ) -> String? {
        // Two-step Bundle.appModule lookup mirrors the bridge lookup
        // (signed `.app` `.copy("Resources")` layout, then SPM dev fallback).
        let resolved: URL? = {
            if let url = Bundle.appModule.url(
                forResource: statusLineWrapperTemplateResourceName,
                withExtension: statusLineWrapperTemplateResourceExtension,
                subdirectory: "Resources"
            ) {
                return url
            }
            if let url = Bundle.appModule.url(
                forResource: statusLineWrapperTemplateResourceName,
                withExtension: statusLineWrapperTemplateResourceExtension
            ) {
                return url
            }
            return nil
        }()
        guard let url = resolved,
              let template = try? String(contentsOf: url, encoding: .utf8),
              let prevData = prevCmd.data(using: .utf8)
        else { return nil }

        guard let quotedBridgePath = shellSingleQuotedLiteral(bridgePath) else { return nil }

        let prevB64 = prevData.base64EncodedString()
        return template
            .replacingOccurrences(of: "__BOUGH_PREV_CMD_B64__", with: prevB64)
            .replacingOccurrences(of: "__BOUGH_BRIDGE_PATH__", with: quotedBridgePath)
    }

    private static func shellSingleQuotedLiteral(_ value: String) -> String? {
        guard !value.contains("\n"), !value.contains("\u{0}") else { return nil }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Phase 21 / D-02 chain-aware install entry point.
    ///
    /// Decision tree:
    /// 1. No existing `statusLine.command`           → direct install (returns `.installed`).
    /// 2. Existing command equals the bridge path    → idempotent no-op (returns `.installed`).
    /// 3. Existing command equals the wrapper path   → recover TRUE prev_cmd from
    ///                                                  the wrapper's sentinel (NOT from
    ///                                                  settings.json, which would cause
    ///                                                  wrapper-wraps-wrapper recursion).
    ///                                                  If sentinel parse fails, abort the
    ///                                                  chain re-render rather than corrupt
    ///                                                  the user's setup.
    /// 4. Existing command is anything else (starship, gsd, ccusage, …)
    ///                                                → use it as the prev_cmd.
    ///
    /// With `truePrevCmd` resolved (cases 3 + 4), render the wrapper template,
    /// write it to `wrapperPath` atomically with mode 0o755, then point
    /// `settings.json.statusLine.command` at the wrapper via the existing
    /// `installClaudeCodeStatusLine(replaceExisting: true, …)` helper. Returns
    /// `.chained(prevCmd:wrapperPath:)`.
    ///
    /// `replaceExisting == true` is NOT a parameter here; the conflict-sheet
    /// "Replace" UX still routes through the original direct-install path so
    /// the user's explicit "override my prev tool" choice is preserved.
    private static func installClaudeCodeStatusLineChainAware(
        fm: FileManager,
        settingsPath: String,
        proposedBridgePath: String,
        wrapperPath: String
    ) -> ClaudeCodeStatusLineInstallResult {
        let existing = currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath)

        // Case 1: no prev command → direct install (chain is opportunistic).
        guard let existing else {
            return installClaudeCodeStatusLine(
                replaceExisting: false,
                fm: fm,
                settingsPath: settingsPath,
                proposedBridgePath: proposedBridgePath
            )
        }

        // Case 2: settings.json already points at the bridge directly → no-op.
        if existing == proposedBridgePath {
            return .installed
        }

        if isBoughStatusLineBridgePath(existing) {
            return installClaudeCodeStatusLine(
                replaceExisting: true,
                fm: fm,
                settingsPath: settingsPath,
                proposedBridgePath: proposedBridgePath
            )
        }

        // Resolve the TRUE prev command.
        let truePrevCmd: String
        if existing == wrapperPath {
            // Case 3: settings.json points at our wrapper. Recover the TRUE
            // prev from the wrapper's sentinel — using the wrapper path
            // itself would cause wrapper-wraps-wrapper recursion (T-21-08).
            guard let recovered = parseStatusLineWrapperSentinel(path: wrapperPath, fm: fm) else {
                return .failed("Existing Bough wrapper has a corrupt RESTORE sentinel")
            }
            truePrevCmd = recovered
        } else {
            // Case 4: a third-party statusLine — that IS the prev_cmd.
            truePrevCmd = existing
        }

        // Render and write the wrapper.
        guard let rendered = renderClaudeCodeStatusLineWrapper(
            prevCmd: truePrevCmd,
            bridgePath: proposedBridgePath
        ) else {
            return .failed("Could not render Bough statusLine wrapper template")
        }
        do {
            try fm.createDirectory(
                atPath: (wrapperPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(rendered.utf8).write(to: URL(fileURLWithPath: wrapperPath), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
        } catch {
            return .failed("Could not write Bough statusLine wrapper: \(error.localizedDescription)")
        }

        // Point settings.json at the wrapper (replaceExisting: true is safe
        // here because the chain decision tree above already established
        // that we own this slot).
        let installResult = installClaudeCodeStatusLine(
            replaceExisting: true,
            fm: fm,
            settingsPath: settingsPath,
            proposedBridgePath: wrapperPath
        )
        switch installResult {
        case .installed:
            return .chained(prevCmd: truePrevCmd, wrapperPath: wrapperPath)
        case .conflict, .failed, .chained:
            // .conflict is impossible with replaceExisting: true; .chained is
            // impossible because installClaudeCodeStatusLine never returns it.
            // Forward any .failed so the caller can surface it.
            return installResult
        }
    }

    /// Parse the `# RESTORE: <base64>` sentinel line from a wrapper file.
    /// Returns the decoded UTF-8 prev command, or nil on any open / read /
    /// missing-line / base64-decode / utf8-decode failure (D-02
    /// trust-boundary-2: refuse rather than corrupt).
    private static func parseStatusLineWrapperSentinel(path: String, fm: FileManager) -> String? {
        guard fm.fileExists(atPath: path),
              let body = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("# RESTORE: ") else { continue }
            let payload = line
                .dropFirst("# RESTORE: ".count)
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = Data(base64Encoded: payload),
                  let decoded = String(data: data, encoding: .utf8),
                  !decoded.isEmpty
            else { return nil }
            return decoded
        }
        return nil
    }

    private static func installClaudeCodeStatusLine(
        replaceExisting: Bool,
        fm: FileManager,
        settingsPath: String,
        proposedBridgePath: String
    ) -> ClaudeCodeStatusLineInstallResult {
        if let existing = currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath),
           existing != proposedBridgePath,
           !replaceExisting {
            return .conflict(existing: existing, proposed: proposedBridgePath)
        }

        let original = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "{}"
        if fm.fileExists(atPath: settingsPath),
           !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           parseJSONFile(at: settingsPath, fm: fm) == nil {
            return .failed("Malformed Claude Code settings.json")
        }
        // Claude Code requires `"type": "command"` in the
        // statusLine block; a block without it is silently ignored, which
        // means the wrapper (and the chained user statusLine inside it) is
        // never invoked. Both keys are emitted explicitly.
        guard let merged = JSONMinimalEditor.setTopLevelValue(
            in: original,
            key: "statusLine",
            value: ["type": "command", "command": proposedBridgePath]
        ) else {
            return .failed("Malformed Claude Code settings.json")
        }

        do {
            let settingsDir = (settingsPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            let preflightURL = URL(fileURLWithPath: settingsDir)
                .appendingPathComponent(".settings.json.bough-preflight-\(UUID().uuidString)")
            try Data(merged.utf8).write(to: preflightURL, options: .atomic)
            try? fm.removeItem(at: preflightURL)
            if fm.fileExists(atPath: settingsPath), merged != original {
                backupClaudeSettings(original: original, settingsPath: settingsPath, fm: fm)
            }
            try Data(merged.utf8).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func currentClaudeCodeStatusLineCommand(fm: FileManager, settingsPath: String) -> String? {
        guard fm.fileExists(atPath: settingsPath),
              let root = parseJSONFile(at: settingsPath, fm: fm),
              let statusLine = root["statusLine"] as? [String: Any]
        else { return nil }
        return statusLine["command"] as? String
    }

    private static func uninstallClaudeCodeStatusLine(
        fm: FileManager,
        settingsPath: String,
        proposedBridgePath: String?,
        wrapperPath: String? = nil
    ) -> Bool {
        guard fm.fileExists(atPath: settingsPath),
              let original = try? String(contentsOfFile: settingsPath, encoding: .utf8),
              let current = currentClaudeCodeStatusLineCommand(fm: fm, settingsPath: settingsPath)
        else { return false }

        // Phase 21 / D-02 wrapper-aware uninstall: if settings.json points
        // at the Bough wrapper, parse its sentinel and restore the prev
        // command. Sentinel parse failure → refuse to touch settings.json
        // (trust-boundary-2 mitigation).
        if let wrapperPath, current == wrapperPath {
            guard let truePrevCmd = parseStatusLineWrapperSentinel(path: wrapperPath, fm: fm) else {
                return false
            }
            guard let restored = JSONMinimalEditor.setTopLevelValue(
                in: original,
                key: "statusLine",
                // Restore the user's prev_cmd with the Claude-Code-required
                // `"type": "command"` field; without it Claude Code silently
                // ignores the block and the restored statusLine never runs.
                value: ["type": "command", "command": truePrevCmd]
            ) else {
                return false
            }
            do {
                if restored != original {
                    backupClaudeSettings(original: original, settingsPath: settingsPath, fm: fm)
                }
                try Data(restored.utf8).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
                // Best-effort wrapper removal — settings.json no longer
                // references it, so an orphaned wrapper file is harmless.
                try? fm.removeItem(atPath: wrapperPath)
                return true
            } catch {
                return false
            }
        }

        if let proposedBridgePath,
           current != proposedBridgePath,
           !isOldBoughStatusLineBridgePath(current) {
            return false
        }

        if let backupPath = firstClaudeSettingsBackup(settingsPath: settingsPath, fm: fm),
           let backup = try? String(contentsOfFile: backupPath, encoding: .utf8) {
            guard let merged = restoreStatusLine(fromBackup: backup, into: original) else {
                return false
            }
            if merged != original {
                do {
                    backupClaudeSettings(original: original, settingsPath: settingsPath, fm: fm)
                    try Data(merged.utf8).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
                    return true
                } catch {
                    return false
                }
            }
            return true
        }

        guard
              let merged = JSONMinimalEditor.deleteTopLevelKey(in: original, key: "statusLine")
        else { return false }
        do {
            backupClaudeSettings(original: original, settingsPath: settingsPath, fm: fm)
            try Data(merged.utf8).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func isOldBoughStatusLineBridgePath(_ command: String) -> Bool {
        isBoughStatusLineBridgePath(command)
    }

    private static func isBoughStatusLineBridgePath(_ command: String) -> Bool {
        if command == claudeCodeStatusLineStableBridgePath { return true }
        let marker = "/Bough.app/Contents/Resources/"
        guard let markerRange = command.range(of: marker) else { return false }
        let suffix = command[markerRange.upperBound...]
        return suffix == "bough-statusline-bridge.sh"
            || suffix.hasSuffix("/bough-statusline-bridge.sh")
    }

    private static func backupClaudeSettings(original: String, settingsPath: String, fm: FileManager) {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let existingBackups = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        guard !existingBackups.contains(where: { $0.hasPrefix("settings.json.bough.bak.") }) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupPath = "\(settingsPath).bough.bak.\(stamp)"
        fm.createFile(atPath: backupPath, contents: Data(original.utf8))
    }

    private static func firstClaudeSettingsBackup(settingsPath: String, fm: FileManager) -> String? {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("settings.json.bough.bak.") }
            .sorted()
            .first
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    private static func restoreStatusLine(fromBackup backup: String, into current: String) -> String? {
        guard let backupRoot = parseJSONCString(backup) else {
            return nil
        }
        guard let oldStatusLine = backupRoot["statusLine"] else {
            return JSONMinimalEditor.deleteTopLevelKey(in: current, key: "statusLine")
        }
        return JSONMinimalEditor.setTopLevelValue(in: current, key: "statusLine", value: oldStatusLine)
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func bridgeHookCommand(
        source: String,
        bridgeCommand: String = ConfigInstaller.bridgeCommand
    ) -> String {
        "\(shellQuoteCommandTokenIfNeeded(bridgeCommand)) --source \(shellQuoteCommandTokenIfNeeded(source))"
    }

    private static func shellQuoteCommandTokenIfNeeded(_ value: String) -> String {
        let safeScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) else {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func tomlBasicString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - Kimi Code CLI (TOML hooks)

    internal static func installKimiHooks(
        cli: CLIConfig,
        fm: FileManager,
        bridgeCommand: String = ConfigInstaller.bridgeCommand
    ) -> Bool {
        let path = cli.fullPath
        var contents = ""
        if fm.fileExists(atPath: path) {
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            contents = existing
        }

        contents = removeKimiHooks(from: contents)
        // Comment out legacy scalar `hooks = ...` assignments that conflict with TOML array-of-tables
        // so they can be restored on uninstall instead of being permanently lost.
        contents = commentOutTopLevelKimiHooksScalar(in: contents)

        let baseCommand = bridgeHookCommand(source: cli.source, bridgeCommand: bridgeCommand)

        var hookBlocks: [String] = ["# bough-hook-v1-start"]
        for (event, timeout, _) in cli.events {
            var block = [
                "[[hooks]]",
                "event = \(tomlBasicString(event))",
                "command = \(tomlBasicString(baseCommand))",
                "timeout = \(timeout)"
            ].joined(separator: "\n")
            if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
                block += "\nmatcher = \(tomlBasicString(".*"))"
            }
            hookBlocks.append(block)
        }
        hookBlocks.append("# bough-hook-v1-end")

        if !contents.isEmpty && !contents.hasSuffix("\n") {
            contents += "\n"
        }
        if !contents.isEmpty {
            contents += "\n"
        }
        contents += hookBlocks.joined(separator: "\n\n") + "\n"

        return fm.createFile(atPath: path, contents: contents.data(using: .utf8))
    }

    static func removeKimiHooks(from contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "# bough-hook-v1-start" {
                i += 1
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces) != "# bough-hook-v1-end" {
                    i += 1
                }
                if i < lines.count { i += 1 }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "[[hooks]]" {
                var blockLines: [String] = [line]
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j]
                    let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
                        break
                    }
                    blockLines.append(nextLine)
                    j += 1
                }
                let blockText = blockLines.joined(separator: "\n")
                if !containsBoughBridgeCommand(blockText) {
                    result.append(contentsOf: blockLines)
                }
                i = j
            } else {
                result.append(line)
                i += 1
            }
        }
        // Trim trailing blank lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    static func commentOutTopLevelKimiHooksScalar(in contents: String) -> String {
        var inTopLevelScope = true
        return contents
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    inTopLevelScope = false
                }
                if inTopLevelScope,
                   trimmed.range(of: #"^hooks\s*="#, options: .regularExpression) != nil {
                    return "# [Bough] commented out legacy scalar hooks to avoid TOML conflict\n# \(line)"
                }
                return line
            }
            .joined(separator: "\n")
    }

    static func restoreKimiCommentedLegacyScalars(in contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        var restored: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# [Bough] commented out legacy scalar hooks to avoid TOML conflict",
               i + 1 < lines.count {
                let next = lines[i + 1]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.range(of: #"^#\s*hooks\s*="#, options: .regularExpression) != nil {
                    restored.append(next.replacingOccurrences(
                        of: #"^#\s*"#,
                        with: "",
                        options: .regularExpression
                    ))
                    i += 2
                    continue
                }
            }
            restored.append(line)
            i += 1
        }
        return restored.joined(separator: "\n")
    }

    private static func isKimiHooksInstalled(cli: CLIConfig, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: cli.fullPath),
              let data = fm.contents(atPath: cli.fullPath),
              let contents = String(data: data, encoding: .utf8) else { return false }

        return cli.events.allSatisfy { (event, _, _) in
            contentsContainsKimiHook(contents, event: event)
        }
    }

    static func contentsContainsKimiHook(_ contents: String, event: String) -> Bool {
        let lines = contents.components(separatedBy: "\n")
        var inHookBlock = false
        var currentEvent: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[hooks]]" {
                inHookBlock = true
                currentEvent = nil
                continue
            }
            if inHookBlock && (trimmed.hasPrefix("[[") || trimmed.hasPrefix("[")) {
                inHookBlock = false
                currentEvent = nil
                continue
            }
            if inHookBlock {
                if trimmed.hasPrefix("event = ") {
                    let val = trimmed.dropFirst("event = ".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentEvent = val
                }
                if currentEvent == event && containsBoughBridgeCommand(trimmed) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Uninstall (generic)

    internal static func uninstallHooks(cli: CLIConfig, fm: FileManager) {
        if cli.format == .kimi {
            guard fm.fileExists(atPath: cli.fullPath),
                  let data = fm.contents(atPath: cli.fullPath),
                  var contents = String(data: data, encoding: .utf8) else { return }
            contents = removeKimiHooks(from: contents)

            // Restore commented-out legacy scalar hooks
            var restored = restoreKimiCommentedLegacyScalars(in: contents)
                .components(separatedBy: "\n")
            while let last = restored.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                restored.removeLast()
            }
            contents = restored.joined(separator: "\n")

            fm.createFile(atPath: cli.fullPath, contents: contents.data(using: .utf8))
            return
        }

        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              var hooks = root[cli.configKey] as? [String: Any],
              let originalText = fm.contents(atPath: cli.fullPath).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        let containsManagedHook = hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
        guard containsManagedHook else { return }

        let wholeFileOwnership = generatedWholeFileConfigOwnership(cli: cli, root: root)
        if shouldRemoveBoughOwnedWholeFileConfig(cli: cli, root: root, hooks: hooks) {
            do {
                try fm.removeItem(atPath: cli.fullPath)
                return
            } catch {
                // Fall back to entry-level cleanup so uninstall still removes
                // Bough hooks if the whole-file delete fails.
            }
        }

        if let wholeFileOwnership,
           containsAnyStrictBoughBridgeHook(in: hooks, source: wholeFileOwnership.strictSource) == false {
            return
        }

        hooks = removeManagedHookEntries(from: hooks, strictSource: wholeFileOwnership?.strictSource)

        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: cli.configKey)
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: cli.configKey, value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            fm.createFile(atPath: cli.fullPath, contents: data)
        }
    }

    // MARK: - Detection helpers

    static func removeManagedHookEntries(from hooks: [String: Any], strictSource: String? = nil) -> [String: Any] {
        var cleaned = hooks
        for (event, value) in cleaned {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                if let strictSource {
                    return containsStrictBoughBridgeHook(entry, source: strictSource)
                }
                return containsOurHook(entry)
            }
            if entries.isEmpty {
                cleaned.removeValue(forKey: event)
            } else {
                cleaned[event] = entries
            }
        }
        return cleaned
    }

    private static func shouldRemoveBoughOwnedWholeFileConfig(
        cli: CLIConfig,
        root: [String: Any],
        hooks: [String: Any]
    ) -> Bool {
        guard let ownership = generatedWholeFileConfigOwnership(cli: cli, root: root) else {
            return false
        }

        guard Set(root.keys).isSubset(of: ownership.allowedKeys) else { return false }

        return hooks.values.allSatisfy { value in
            guard let entries = value as? [[String: Any]], !entries.isEmpty else { return false }
            return entries.allSatisfy { containsStrictBoughBridgeHook($0, source: ownership.strictSource) }
        }
    }

    private static func generatedWholeFileConfigOwnership(
        cli: CLIConfig,
        root: [String: Any]
    ) -> (allowedKeys: Set<String>, strictSource: String)? {
        switch (cli.source, cli.format, cli.configPath) {
        case ("copilot", .copilot, ".copilot/hooks/bough.json"):
            return (["version", cli.configKey], "copilot")
        case ("kiro", .kiroAgent, ".kiro/agents/bough.json"):
            guard root["name"] as? String == "bough",
                  (root["description"] as? String)?.contains("Auto-generated by Bough") == true
            else { return nil }
            return (["name", "description", cli.configKey], "kiro")
        default:
            return nil
        }
    }

    private static func containsAnyStrictBoughBridgeHook(in hooks: [String: Any], source: String) -> Bool {
        hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { containsStrictBoughBridgeHook($0, source: source) }
        }
    }

    private static func containsStrictBoughBridgeHook(_ entry: [String: Any], source: String) -> Bool {
        commandStrings(in: entry).contains { command in
            HookId.containsBoughBridgeCommand(command)
                && HookId.containsSourceArgument(command, source: source)
        }
    }

    private static func commandStrings(in entry: [String: Any]) -> [String] {
        var commands: [String] = []
        if let command = entry["command"] as? String {
            commands.append(command)
        }
        if let command = entry["bash"] as? String {
            commands.append(command)
        }
        if let hookList = entry["hooks"] as? [[String: Any]] {
            commands.append(contentsOf: hookList.compactMap { $0["command"] as? String })
        }
        return commands
    }

    private static func isHooksInstalled(for cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .kimi {
            return isKimiHooksInstalled(cli: cli, fm: fm)
        }

        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              let hooks = root[cli.configKey] as? [String: Any] else { return false }
        let requiredEvents = cli.format == .claude ? compatibleEvents(for: cli) : cli.events
        // Check that ALL currently compatible required events have our hook installed, not just any one.
        let allPresent = requiredEvents.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
        guard allPresent else { return false }
        // Also check for stale "async" keys that need cleanup
        if hasStaleAsyncKey(hooks) { return false }
        return true
    }

    /// Detect legacy hook entries with invalid "async" key
    private static func hasStaleAsyncKey(_ hooks: [String: Any]) -> Bool {
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries where containsOurHook(entry) {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    if hookList.contains(where: { $0["async"] != nil }) { return true }
                }
            }
        }
        return false
    }

    /// Check if a hook entry contains our hook command
    private static func containsOurHook(_ entry: [String: Any]) -> Bool {
        // Claude/nested format: entry.hooks[].command
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains {
                let cmd = $0["command"] as? String ?? ""
                return HookId.isOurs(cmd)
            }
        }
        // Flat format: entry.command
        if let cmd = entry["command"] as? String, HookId.isOurs(cmd) { return true }
        // Copilot format: entry.bash
        if let cmd = entry["bash"] as? String, HookId.isOurs(cmd) { return true }
        return false
    }

    // MARK: - Bridge & Hook Script

    private static func installHookScript(fm: FileManager) -> Bool {
        do {
            try BoughPrivateStorage.ensurePrivateDirectory(at: URL(fileURLWithPath: boughDir), fileManager: fm)
        } catch {
            return false
        }
        let needsUpdate: Bool
        if fm.fileExists(atPath: hookScriptPath) {
            if let existing = fm.contents(atPath: hookScriptPath),
               let str = String(data: existing, encoding: .utf8) {
                // Update if script doesn't contain bridge dispatcher OR version is outdated
                let hasCurrentVersion = str.contains("# Bough hook v\(hookScriptVersion)")
                needsUpdate = !hasCurrentVersion
            } else {
                needsUpdate = true
            }
        } else {
            needsUpdate = true
        }
        if needsUpdate {
            guard fm.createFile(atPath: hookScriptPath, contents: Data(hookScript.utf8)) else {
                return false
            }
            chmod(hookScriptPath, 0o755)
        } else if !fm.isExecutableFile(atPath: hookScriptPath) {
            chmod(hookScriptPath, 0o755)
        }
        return fm.isExecutableFile(atPath: hookScriptPath)
    }

    private static func installBridgeBinary(fm: FileManager) -> Bool {
        do {
            try BoughPrivateStorage.ensurePrivateDirectory(at: URL(fileURLWithPath: boughDir), fileManager: fm)
        } catch {
            return false
        }
        guard let execPath = Bundle.main.executablePath else {
            return isExecutableFile(at: bridgePath, fm: fm)
        }
        let execDir = (execPath as NSString).deletingLastPathComponent
        let contentsDir = (execDir as NSString).deletingLastPathComponent
        var srcPath = contentsDir + "/Helpers/bough-bridge"
        if !fm.fileExists(atPath: srcPath) { srcPath = execDir + "/bough-bridge" }
        guard fm.fileExists(atPath: srcPath) else {
            return isExecutableFile(at: bridgePath, fm: fm)
        }

        // Atomic replace: copy to temp file first, then rename (overwrites atomically)
        let tmpPath = bridgePath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try? fm.removeItem(atPath: tmpPath)
            try fm.copyItem(atPath: srcPath, toPath: tmpPath)
            chmod(tmpPath, 0o755)
            // Strip quarantine xattr so Gatekeeper won't block the binary
            stripQuarantine(tmpPath)
            if fm.fileExists(atPath: bridgePath) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: bridgePath), withItemAt: URL(fileURLWithPath: tmpPath))
            } else {
                try fm.moveItem(atPath: tmpPath, toPath: bridgePath)
            }
        } catch {
            try? fm.removeItem(atPath: tmpPath)
            return false
        }
        // Ensure final binary is free of quarantine (covers both paths above)
        stripQuarantine(bridgePath)
        chmod(bridgePath, 0o755)
        return isExecutableFile(at: bridgePath, fm: fm)
    }

    private static func runtimeExecutableInstalled(for cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .claude {
            return isExecutableFile(at: hookScriptPath, fm: fm)
        }
        return isExecutableFile(at: bridgePath, fm: fm)
    }

    private static func isExecutableFile(at path: String, fm: FileManager) -> Bool {
        fm.isExecutableFile(atPath: path)
    }

    /// Remove com.apple.quarantine xattr so Gatekeeper won't block the binary.
    /// Copied binaries inherit quarantine from the source app bundle.
    private static func stripQuarantine(_ path: String) {
        removexattr(path, "com.apple.quarantine", 0)
    }

    // MARK: - OpenCode Plugin

    /// The JS plugin source — embedded as resource or bundled alongside
    private static func opencodePluginSource() -> String? {
        // Try SPM resource bundle (where build actually places it)
        if let url = Bundle.appModule.url(forResource: "bough-opencode", withExtension: "js", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        // Fallback: try without subdirectory
        if let url = Bundle.appModule.url(forResource: "bough-opencode", withExtension: "js"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    /// Merge our plugin reference into an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the original contents
    /// are present but unparseable / not a JSON object — in that case the caller
    /// MUST NOT overwrite the file (see issue #89). Uses minimal-diff editing so
    /// user comments, key order, and whitespace are preserved (#105/#106).
    static func mergeOpencodePluginRef(
        originalContents: String?,
        pluginRef: String,
        identifier: String
    ) -> String? {
        // Brand-new file — emit a minimal canonical document.
        guard let contents = originalContents, !contents.isEmpty else {
            let config: [String: Any] = [
                "$schema": "https://opencode.ai/config.json",
                "plugin": [pluginRef],
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            ), var merged = String(data: data, encoding: .utf8) else { return nil }
            if !merged.hasSuffix("\n") { merged += "\n" }
            return merged
        }

        // Verify parseable and dedup plugin entries against the parsed view.
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var plugins = parsed["plugin"] as? [String] ?? []
        plugins.removeAll { isManagedOpencodePluginRef($0, identifier: identifier) }
        plugins.append(pluginRef)

        // Replace the plugin array in-place, preserving surrounding text exactly.
        guard var merged = JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins) else {
            return nil
        }
        // Add $schema if missing — minimal-diff insertion at end of object.
        if parsed["$schema"] == nil {
            guard let withSchema = JSONMinimalEditor.setTopLevelValue(
                in: merged, key: "$schema", value: "https://opencode.ai/config.json"
            ) else { return merged }
            merged = withSchema
        }
        return merged
    }

    /// Remove our plugin reference from an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the file is absent,
    /// unparseable, or does not currently reference us (nothing to do).
    static func removeOpencodePluginRef(
        originalContents: String?,
        identifier: String
    ) -> String? {
        guard let contents = originalContents else { return nil }
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard var plugins = parsed["plugin"] as? [String],
              plugins.contains(where: { isManagedOpencodePluginRef($0, identifier: identifier) }) else {
            return nil
        }
        plugins.removeAll { isManagedOpencodePluginRef($0, identifier: identifier) }
        if plugins.isEmpty {
            return JSONMinimalEditor.deleteTopLevelKey(in: contents, key: "plugin")
        }
        return JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins)
    }

    private static func isManagedOpencodePluginRef(_ pluginRef: String, identifier: String) -> Bool {
        if identifier == HookId.current {
            return HookId.isOurs(pluginRef)
        }
        return pluginRef.contains(identifier)
    }

    @discardableResult
    private static func installOpencodePlugin(fm: FileManager) -> Bool {
        // Only install if opencode config dir exists
        let configDir = (opencodeConfigPath as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: configDir) else { return true } // not installed, skip silently

        // Write plugin JS
        guard let source = opencodePluginSource() else { return false }
        try? fm.createDirectory(atPath: opencodePluginDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: opencodePluginPath, contents: Data(source.utf8)) else { return false }

        // OpenCode auto-loads local plugins from ~/.config/opencode/plugins/.
        // The config "plugin" array is for npm packages; remove older Bough
        // file:// registrations so the local plugin is not loaded twice.
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
            guard let contents = fm.contents(atPath: configPath)
                .flatMap({ String(data: $0, encoding: .utf8) }),
                  let cleaned = removeOpencodePluginRef(originalContents: contents, identifier: HookId.current)
            else { continue }
            backupOpencodeConfig(at: configPath, original: contents, fm: fm)
            fm.createFile(atPath: configPath, contents: Data(cleaned.utf8))
        }
        return true
    }

    private static func uninstallOpencodePlugin(fm: FileManager) {
        try? fm.removeItem(atPath: opencodePluginPath)
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
            guard let contents = fm.contents(atPath: configPath)
                .flatMap({ String(data: $0, encoding: .utf8) }),
                  let cleaned = removeOpencodePluginRef(originalContents: contents, identifier: HookId.current)
            else { continue }
            backupOpencodeConfig(at: configPath, original: contents, fm: fm)
            fm.createFile(atPath: configPath, contents: Data(cleaned.utf8))
        }
    }

    /// Write a timestamped backup next to the original config file the first
    /// time we mutate it. Subsequent writes skip backup if one already exists
    /// for the same path to avoid spamming the directory.
    private static func backupOpencodeConfig(at path: String, original: String, fm: FileManager) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // Skip if any previous bough backup exists for this file.
        if let entries = try? fm.contentsOfDirectory(atPath: dir),
           entries.contains(where: { $0.hasPrefix(name + ".bough.bak.") }) {
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupPath = "\(path).bough.bak.\(stamp)"
        fm.createFile(atPath: backupPath, contents: Data(original.utf8))
    }

    /// Current OpenCode plugin version — bump when bough-opencode.js changes
    private static let opencodePluginVersion = "v4"

    static func testIsOpencodePluginInstalled(pluginPath: String, configPaths: [String], fm: FileManager = .default) -> Bool {
        isOpencodePluginInstalled(fm: fm, pluginPath: pluginPath, configPaths: configPaths)
    }

    private static func isOpencodePluginInstalled(fm: FileManager) -> Bool {
        isOpencodePluginInstalled(
            fm: fm,
            pluginPath: opencodePluginPath,
            configPaths: [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath]
        )
    }

    private static func isOpencodePluginInstalled(fm: FileManager, pluginPath: String, configPaths: [String]) -> Bool {
        guard fm.fileExists(atPath: pluginPath),
              let existing = fm.contents(atPath: pluginPath),
              let pluginSource = String(data: existing, encoding: .utf8),
              pluginSource.contains("// version: \(opencodePluginVersion)") else {
            return false
        }

        // OpenCode auto-loads ~/.config/opencode/plugins/*.js; config refs are
        // legacy compatibility only and must not be required for installed-state.
        for configPath in configPaths {
            guard fm.fileExists(atPath: configPath) else { continue }
            guard let data = fm.contents(atPath: configPath),
                  let stripped = String(data: data, encoding: .utf8).map(stripJSONComments),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
                return true
            }
            if let plugins = parsed["plugin"] as? [String],
               plugins.contains(where: { isManagedOpencodePluginRef($0, identifier: HookId.current) }) {
                return true
            }
        }
        return true
    }
}
