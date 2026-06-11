import AppKit
import SwiftUI
import os.log
import BoughCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let log = Logger(subsystem: "com.dgpisces.bough", category: "AppDelegate")

    var panelController: PanelWindowController?
    private var hookServer: HookServer?
    private var hookRecoveryTimer: Timer?
    private var hookInstallTask: Task<Void, Never>?
    private var statusLineRetirementTask: Task<Void, Never>?
    private var codingSessionsPreferenceObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastHookCheck: Date = .distantPast
    private var lastCodingSessionsEnabled = SettingsDefaults.codingSessionsEnabled
    private var globalShortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shouldAutoOpenWelcomeGuide = WelcomeGuideSettings.shouldAutoOpenOnLaunch()

        installMainMenu()
        ProcessInfo.processInfo.disableAutomaticTermination("Bough must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Pre-set app icon so Dock/menu bar use the packaged bundle icon.
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()
        SettingsWindowController.shared.configure(appState: appState)
        StatusItemController.shared.startObserving()
        RemoteManager.shared.onDisconnect = { [weak appState] hostId in
            appState?.removeRemoteSessions(hostId: hostId)
        }
        observeCodingSessionsPreference()
        if CodingSessionsSettings.isEnabled() {
            startCodingRuntime()
        } else {
            stopCodingRuntimeForDisabledMode()
        }

        panelController = PanelWindowController(appState: appState)
        panelController?.showPanel()

        #if DEBUG
        // Preview mode: inject mock data if --preview flag is present
        if let scenario = DebugHarness.requestedScenario() {
            Self.log.debug("Loading scenario: \(scenario.rawValue)")
            DebugHarness.apply(scenario, to: appState)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !scenario.rawValue.hasPrefix("airdrop-") else { return }
                if appState.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        appState.surface = .sessionList
                    }
                }
            }
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--welcome-guide") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                WelcomeGuideWindowController.shared.show()
            }
        } else {
            scheduleWelcomeGuideAutoOpenIfNeeded(shouldAutoOpenWelcomeGuide)
        }
        #else
        scheduleWelcomeGuideAutoOpenIfNeeded(shouldAutoOpenWelcomeGuide)
        #endif

        // Sparkle runs scheduled checks itself on the cadence declared in
        // Info.plist (SUScheduledCheckInterval). Start the updater once — it
        // no-ops for Homebrew-installed builds (brew owns those upgrades).
        UpdateChecker.shared.start()
        Task {
            if let store = try? UsageContinuityStore() {
                let service = UsageNotificationService(
                    copy: .localized(),
                    thresholdCopy: .localized(),
                    providerEnabled: { tool in
                        let key = SettingsKey.usageStatisticsEnabled(tool.rawValue)
                        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
                        return UserDefaults.standard.bool(forKey: key)
                    }
                )
                await service.sendPendingNotifications(from: store)
                await service.sendPendingThresholdNotifications(from: store)
            }
        }

        SoundManager.shared.playBoot()
        setupGlobalShortcut()

        // Boot animation: brief expand to confirm app is running
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard CodingSessionsSettings.isEnabled() else { return }
            guard appState.surface == .collapsed else { return }
            withAnimation(NotchAnimation.pop) {
                appState.surface = .sessionList
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .sessionList = appState.surface {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let settingsItem = NSMenuItem(
            title: L10n.shared["settings_ellipsis"],
            action: #selector(openSettingsFromMainMenu),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.shared["quit"],
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMainMenu() {
        SettingsWindowController.shared.show()
    }

    private func scheduleWelcomeGuideAutoOpenIfNeeded(_ shouldAutoOpen: Bool) {
        guard shouldAutoOpen else { return }
        WelcomeGuideSettings.markAutoOpenConsumed()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            WelcomeGuideWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = codingSessionsPreferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            codingSessionsPreferenceObserver = nil
        }
        stopHookRecovery()
        hookInstallTask?.cancel()
        hookInstallTask = nil
        statusLineRetirementTask?.cancel()
        statusLineRetirementTask = nil
        teardownGlobalShortcut()
        if CodingSessionsSettings.isEnabled() {
            appState.saveSessions()
        }
        RemoteManager.shared.shutdown()
        hookServer?.stop()
        hookServer = nil
        appState.stopCodexAppServerWatcher()
        appState.stopSessionDiscovery()
    }

    private func observeCodingSessionsPreference() {
        lastCodingSessionsEnabled = CodingSessionsSettings.isEnabled()
        codingSessionsPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCodingSessionsPreferenceIfNeeded()
            }
        }
    }

    private func applyCodingSessionsPreferenceIfNeeded() {
        let enabled = CodingSessionsSettings.isEnabled()
        guard enabled != lastCodingSessionsEnabled else { return }
        lastCodingSessionsEnabled = enabled

        if enabled {
            startCodingRuntime()
        } else {
            stopCodingRuntimeForDisabledMode()
        }
    }

    private func startCodingRuntime() {
        guard CodingSessionsSettings.isEnabled() else { return }
        appState.resumeCodingSessionsForEnabledMode()
        restoreUsageMonitorAfterCodingSessionsOnIfNeeded()

        // Start HookServer BEFORE installing hooks so fresh CLI configs never point
        // PermissionRequest hooks at a missing socket.
        if hookServer == nil {
            hookServer = HookServer(appState: appState)
            hookServer?.start()
        }

        startHookInstallTask()
        startStatusLineRetirementTask()
        appState.startSessionDiscovery()
        appState.startCodexAppServerWatcher()
        // Direct-OAuth usage channels run independently of the app-server
        // watcher. startCodingRuntime covers both the launch path and the
        // coding-sessions re-enable path; the disable path stops the channels
        // via suspendCodingSessionsForDisabledMode →
        // pauseCodingSessionCollectionForDisabledMode → stopUsageChannels.
        appState.startUsageChannels()
        RemoteManager.shared.startup()
        startHookRecovery()
    }

    private func stopCodingRuntimeForDisabledMode() {
        hookInstallTask?.cancel()
        hookInstallTask = nil
        statusLineRetirementTask?.cancel()
        statusLineRetirementTask = nil
        stopHookRecovery()
        RemoteManager.shared.shutdown()
        hookServer?.stop(removeSocketAfterDelay: false)
        hookServer = nil
        appState.suspendCodingSessionsForDisabledMode()
        UsageMonitorService().disableForCodingSessionsOff()
    }

    private func restoreUsageMonitorAfterCodingSessionsOnIfNeeded() {
        do {
            _ = try UsageMonitorService().restoreAfterCodingSessionsOnIfNeeded()
        } catch {
            Self.log.warning("Failed to restore usage monitor after Coding Sessions was enabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startHookInstallTask() {
        hookInstallTask?.cancel()
        hookInstallTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard CodingSessionsSettings.isEnabled(), !Task.isCancelled else { return }
            if ConfigInstaller.install() {
                Self.log.info("Hooks installed")
            } else {
                Self.log.warning("Failed to install hooks")
            }

            guard CodingSessionsSettings.isEnabled(), !Task.isCancelled else { return }
            let healthy = ConfigInstaller.claudeCodeHookHealthCheck()
            if !healthy {
                Self.log.warning("DIAG-01: Claude Code hook health check failed — socket absent or hooks missing")
                await MainActor.run { [weak self] in
                    guard CodingSessionsSettings.isEnabled() else { return }
                    self?.appState.usageStore.markClaudeCodeHookDisconnected()
                }
            }
        }
    }

    /// Spec §7: one-time upgrade migration that retires the legacy statusLine
    /// bridge/wrapper. Replaces the former first-launch chain auto-install task
    /// — usage now arrives via OAuth, so the statusline channel is removed.
    private func startStatusLineRetirementTask() {
        statusLineRetirementTask?.cancel()
        statusLineRetirementTask = Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let flagKey = SettingsKey.hasRetiredClaudeCodeStatusLine
            guard !defaults.bool(forKey: flagKey), !Task.isCancelled else { return }
            defaults.set(true, forKey: flagKey)  // gate first (T-21-12 pattern: set the flag, then do the work)
            _ = ConfigInstaller.retireClaudeCodeStatusLineIfInstalled()
            // Retirement can refuse (e.g. corrupt wrapper sentinel) and leave
            // settings.json pointing at the Bough wrapper. Clear the flag so
            // the next launch retries — retire is idempotent and cheap, so a
            // bounded one-attempt-per-launch retry is acceptable. The refusal
            // semantics are covered at the ConfigInstaller level
            // (ConfigInstallerClaudeCodeTests); this task is a thin wrapper.
            if ConfigInstaller.isBoughClaudeCodeStatusLineCommand(
                ConfigInstaller.currentClaudeCodeStatusLineCommand()
            ) {
                defaults.set(false, forKey: flagKey)
            }
        }
    }

    private func startHookRecovery() {
        guard hookRecoveryTimer == nil else { return }
        hookRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.checkAndRepairHooks()
            }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.checkAndRepairHooks()
            }
        }
    }

    private func stopHookRecovery() {
        hookRecoveryTimer?.invalidate()
        hookRecoveryTimer = nil
        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceActivationObserver = nil
        }
    }

    // MARK: - Global Shortcuts

    func setupGlobalShortcut() {
        teardownGlobalShortcut()

        // Collect all enabled shortcut bindings, skip duplicates (first wins)
        var bindings: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, action: ShortcutAction)] = []
        var seen: Set<String> = []
        for action in ShortcutAction.allCases {
            guard action.isEnabled else { continue }
            let b = action.binding
            let key = "\(b.keyCode)-\(b.modifiers.rawValue)"
            guard seen.insert(key).inserted else { continue }
            bindings.append((b.keyCode, b.modifiers, action))
        }
        guard !bindings.isEmpty else { return }

        let handler: (NSEvent) -> Bool = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for b in bindings where event.keyCode == b.keyCode && eventMods == b.mods {
                Task { @MainActor in self?.executeShortcut(b.action) }
                return true
            }
            return false
        }

        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handler(event)
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    private func teardownGlobalShortcut() {
        if let m = globalShortcutMonitor { NSEvent.removeMonitor(m) }
        if let m = localShortcutMonitor { NSEvent.removeMonitor(m) }
        globalShortcutMonitor = nil
        localShortcutMonitor = nil
    }

    private func executeShortcut(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            if appState.surface.isExpanded {
                withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
            } else {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .sessionList
                    appState.cancelCompletionQueue()
                    if appState.activeSessionId == nil {
                        appState.activeSessionId = appState.sessions.keys.sorted().first
                    }
                }
            }
        case .approve:
            appState.approvePermission()
        case .approveAlways:
            appState.approvePermission(always: true)
        case .deny:
            appState.denyPermission()
        case .skipQuestion:
            appState.skipQuestion()
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

    private func checkAndRepairHooks() {
        guard CodingSessionsSettings.isEnabled() else { return }
        guard Date().timeIntervalSince(lastHookCheck) > 60 else { return }
        lastHookCheck = Date()
        // verifyAndRepair walks every enabled CLI and rewrites settings on
        // disk — keep it off the main thread so the activation observer (fires
        // on every app switch) can't stutter the UI. See #139.
        Task.detached(priority: .background) {
            guard CodingSessionsSettings.isEnabled() else { return }
            let repaired = ConfigInstaller.verifyAndRepair()
            if !repaired.isEmpty {
                Self.log.info("Auto-repaired hooks for: \(repaired.joined(separator: ", "))")
            }
        }
    }

}
