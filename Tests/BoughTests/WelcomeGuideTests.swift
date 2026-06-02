import XCTest
@testable import Bough

@MainActor
final class WelcomeGuideTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WelcomeGuideTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testVisibleStepsHideCodingSetupWhenCodingSessionsOff() {
        XCTAssertEqual(
            WelcomeGuideModel.visibleSteps(codingSessionsEnabled: true),
            [.welcome, .modeDisplay, .codingSetup, .sharingMusic, .finish]
        )
        XCTAssertEqual(
            WelcomeGuideModel.visibleSteps(codingSessionsEnabled: false),
            [.welcome, .modeDisplay, .sharingMusic, .finish]
        )
    }

    func testModeSelectionReconcilesCurrentStepWhenCodingSetupBecomesHidden() {
        let model = WelcomeGuideModel(defaults: defaults)
        model.selectedStep = .codingSetup

        model.selectCodingSessions(false)

        XCTAssertEqual(model.selectedStep, .sharingMusic)
        XCTAssertFalse(model.isShowingCodingSetup)
    }

    func testBackNextPreserveStagedSelectionsAcrossBranchChanges() {
        let model = WelcomeGuideModel(defaults: defaults)
        model.selectedStep = .codingSetup
        model.showCodexUsage = false
        model.enableThresholdAlerts = true

        model.selectCodingSessions(false)
        model.selectCodingSessions(true)
        model.selectedStep = .codingSetup

        XCTAssertFalse(model.showCodexUsage)
        XCTAssertTrue(model.enableThresholdAlerts)
    }

    func testFinishRequiresCodingModeAndDisplay() async {
        let model = WelcomeGuideModel(defaults: defaults)

        model.codingSessionsEnabled = nil
        XCTAssertFalse(model.canFinish)
        let missingModeFinished = await model.finish()
        XCTAssertFalse(missingModeFinished)

        model.codingSessionsEnabled = true
        model.displayChoice = nil
        XCTAssertFalse(model.canFinish)
        let missingDisplayFinished = await model.finish()
        XCTAssertFalse(missingDisplayFinished)

        model.displayChoice = "auto"
        XCTAssertTrue(model.canFinish)
    }

    func testFinishWritesCorePreferencesAndCompletionVersion() async {
        let model = WelcomeGuideModel(defaults: defaults, backendApply: { _, _, _ in })
        model.selectCodingSessions(false)
        model.displayChoice = "screen_0"
        model.airDropEnabled = false
        model.musicControlsEnabled = false
        model.compactBarPriority = .music
        model.showCodexUsage = false
        model.enableBackgroundMonitor = true
        model.enableRecoveryReminders = true
        model.enableThresholdAlerts = true

        let didFinish = await model.finish(date: Date(timeIntervalSince1970: 12))
        XCTAssertTrue(didFinish)

        XCTAssertFalse(CodingSessionsSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: SettingsKey.displayChoice), "screen_0")
        XCTAssertEqual(defaults.object(forKey: SettingsKey.airDropEnabled) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: SettingsKey.showMusicControls) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.compactBarPriority), CompactBarPriority.music.rawValue)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.welcomeGuideCompletedVersion), WelcomeGuideSettings.currentOnboardingVersion)
        XCTAssertEqual(defaults.double(forKey: SettingsKey.welcomeGuideCompletedAt), 12)

        XCTAssertNil(defaults.object(forKey: SettingsKey.usageDisplayEnabled("codex")))
        XCTAssertNil(defaults.object(forKey: SettingsKey.usageStatisticsEnabled("codex")))
        XCTAssertNil(defaults.object(forKey: SettingsKey.usageMonitorRestoreAfterCodingSessionsEnabled))
        XCTAssertNil(defaults.object(forKey: SettingsKey.notificationsThresholdMasterEnabled))
        XCTAssertNil(defaults.object(forKey: "cli_enabled_codex"))
        XCTAssertNil(defaults.object(forKey: "cli_enabled_claude"))
    }

    func testFinishAppliesBackendPlanForCodingSessions() async {
        var capturedPlan: WelcomeGuideBackendPlan?
        var capturedDefaults: UserDefaults?
        var capturedDate: Date?
        let model = WelcomeGuideModel(
            defaults: defaults,
            installedSources: ["claude", "codex"],
            backendApply: { plan, defaults, completedAt in
                capturedPlan = plan
                capturedDefaults = defaults
                capturedDate = completedAt
            }
        )
        model.selectCodingSessions(true)
        model.displayChoice = "auto"
        model.setToolSelected(source: "claude", isSelected: false)
        model.showCodexUsage = true
        model.showClaudeUsage = false
        model.enableBackgroundMonitor = false
        model.enableRecoveryReminders = true
        model.enableThresholdAlerts = true

        let completedAt = Date(timeIntervalSince1970: 34)
        let didFinish = await model.finish(date: completedAt)
        XCTAssertTrue(didFinish)

        XCTAssertEqual(
            capturedPlan,
            WelcomeGuideBackendPlan(
                codingSessionsEnabled: true,
                toolSelections: ["claude": false, "codex": true],
                showCodexUsage: true,
                showClaudeUsage: false,
                backgroundMonitorEnabled: false,
                recoveryRemindersEnabled: true,
                thresholdAlertsEnabled: true
            )
        )
        XCTAssertTrue(capturedDefaults === defaults)
        XCTAssertEqual(capturedDate, completedAt)
    }

    func testCompletionStatusDistinguishesMissingCompletedAndOlderVersion() {
        XCTAssertEqual(WelcomeGuideSettings.completionStatus(defaults: defaults), .notCompleted)

        WelcomeGuideSettings.markCompleted(defaults: defaults, date: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(WelcomeGuideSettings.completionStatus(defaults: defaults), .completed)

        defaults.set("legacy", forKey: SettingsKey.welcomeGuideCompletedVersion)
        XCTAssertEqual(WelcomeGuideSettings.completionStatus(defaults: defaults), .updateAvailable)
    }

    func testLaunchGateAutoOpensFreshInstallOnlyOnce() {
        XCTAssertTrue(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(defaults: defaults, persistentKeys: [])
        )

        WelcomeGuideSettings.markAutoOpenConsumed(defaults: defaults)

        XCTAssertFalse(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(defaults: defaults, persistentKeys: [])
        )
    }

    func testLaunchGateDoesNotAutoOpenForExistingUsers() {
        XCTAssertFalse(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(
                defaults: defaults,
                persistentKeys: [SettingsKey.codingSessionsEnabled]
            )
        )
        XCTAssertFalse(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(
                defaults: defaults,
                persistentKeys: ["physicalBuddyDefaultsCleanup"]
            )
        )
    }

    func testLaunchGateDoesNotAutoOpenCompletedOrOlderOnboarding() {
        WelcomeGuideSettings.markCompleted(defaults: defaults, date: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(defaults: defaults, persistentKeys: [])
        )

        defaults.set("legacy", forKey: SettingsKey.welcomeGuideCompletedVersion)
        XCTAssertFalse(
            WelcomeGuideSettings.shouldAutoOpenOnLaunch(defaults: defaults, persistentKeys: [])
        )
    }

    func testAppDelegateWiresWelcomeGuideAutoOpenOutsideDebugArgument() throws {
        let source = try sourceFile("Sources/Bough/AppDelegate.swift")

        XCTAssertTrue(source.contains("let shouldAutoOpenWelcomeGuide = WelcomeGuideSettings.shouldAutoOpenOnLaunch()"))
        XCTAssertTrue(source.contains("scheduleWelcomeGuideAutoOpenIfNeeded(shouldAutoOpenWelcomeGuide)"))
        XCTAssertTrue(source.contains("WelcomeGuideSettings.markAutoOpenConsumed()"))
        XCTAssertTrue(source.contains("WelcomeGuideWindowController.shared.show()"))
    }

    func testToolListMatchesApprovedOnboardingScope() {
        let names = WelcomeGuideModel.approvedToolItems.map(\.displayName)

        XCTAssertEqual(names, [
            "Claude Code", "Codex", "Gemini", "Cursor", "Trae", "Trae CN", "Trae CLI",
            "Qoder", "Factory", "StepFun", "AntiGravity", "Hermes", "Qwen",
            "GitHub Copilot", "Kimi", "Kiro", "OpenCode",
        ])
    }

    func testToolListOnlyShowsInstalledLocalTools() {
        let statuses = WelcomeGuideModel.defaultToolItems(installedSources: ["claude", "codex", "droid"])

        XCTAssertEqual(statuses.map(\.source), ["claude", "codex", "droid"])
        XCTAssertEqual(statuses.map(\.displayName), ["Claude Code", "Codex", "Factory"])
        XCTAssertTrue(statuses.allSatisfy(\.isSelected))
    }

    func testWelcomeGuideBackendIntegratorWiresRealMutationServices() throws {
        let source = try sourceFile("Sources/Bough/WelcomeGuideBackendIntegrator.swift")

        XCTAssertTrue(source.contains("WelcomeGuideBackendIntegrator"))
        XCTAssertTrue(source.contains("ChainInstallCoordinator.shared.install"))
        XCTAssertTrue(source.contains("ConfigInstaller.setEnabled"))
        XCTAssertTrue(source.contains("ConfigInstaller.uninstallClaudeCodeStatusLine"))
        XCTAssertTrue(source.contains("UsageStore(defaults: defaults"))
        XCTAssertTrue(source.contains("UsageMonitorService().enable"))
        XCTAssertTrue(source.contains("UsageMonitorService().disableForCodingSessionsOff"))
        XCTAssertTrue(source.contains("UsageNotificationService("))
        XCTAssertTrue(source.contains("requestAccessForExplicitUserAction"))
        XCTAssertFalse(source.contains("refreshUsage"))
    }

    func testWelcomeGuideSelectionsUseSettingsStyleSwitches() throws {
        let source = try sourceFile("Sources/Bough/WelcomeGuide.swift")

        XCTAssertTrue(source.contains("WelcomeGuideSwitchRow"))
        XCTAssertTrue(source.contains(".toggleStyle(.switch)"))
        XCTAssertTrue(source.contains(".controlSize(.mini)"))
        XCTAssertFalse(source.contains(".toggleStyle(.checkbox)"))
        XCTAssertFalse(source.contains("welcome_guide_ui_only_note"))
    }

    func testSidebarTitlesUseStableNonAnimatedTypography() throws {
        let source = try sourceFile("Sources/Bough/WelcomeGuide.swift")
        let rowSource = try XCTUnwrap(source.range(of: "private struct WelcomeGuideSidebarRow").map {
            String(source[$0.lowerBound...])
        })

        XCTAssertTrue(rowSource.contains("Text(title)"))
        XCTAssertTrue(rowSource.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertTrue(rowSource.contains(".lineLimit(1)"))
        XCTAssertTrue(rowSource.contains("transaction.animation = nil"))
        XCTAssertFalse(rowSource.contains(".font(.subheadline.weight(isSelected"))
    }

    func testLocalizationKeysExistInBothLanguages() {
        let keys = [
            "welcome_guide_window_title",
            "welcome_guide_welcome_title",
            "welcome_guide_mode_title",
            "welcome_guide_coding_title",
            "welcome_guide_sharing_title",
            "welcome_guide_finish_title",
            "welcome_guide_airdrop_title",
            "welcome_guide_finish_settings_note",
        ]

        for language in ["en", "zh"] {
            for key in keys {
                XCTAssertNotNil(L10n.strings[language]?[key], "\(language) missing \(key)")
            }
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
