import XCTest
@testable import Bough

@MainActor
final class AirDropSettingsAndDemoTests: XCTestCase {
    func testAirDropSettingDefaultsOnAndBlocksEntryWhenDisabled() {
        let suiteName = "AirDropSettingsAndDemoTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(AirDropSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: SettingsKey.airDropEnabled)
        XCTAssertFalse(AirDropSettings.isEnabled(defaults: defaults))

        let state = AppState()
        state.airDropEnabledProvider = { false }
        state.beginAirDrop(
            payload: AirDropPasteboardPayload(fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")]),
            source: .drag
        )

        XCTAssertEqual(state.surface, .collapsed)
        XCTAssertEqual(state.airDropState, .idle)
    }

    func testAllAirDropPreviewScenariosAreReachableByLaunchArgumentName() {
        let rawValues = Set(PreviewScenario.allCases.map(\.rawValue))
        let expected = [
            "airdrop-magnet",
            "airdrop-dropzone",
            "airdrop-file-ready",
            "airdrop-url-ready",
            "airdrop-text-confirm",
            "airdrop-unavailable",
            "airdrop-failed",
            "airdrop-cleanup-error",
            "airdrop-completion-overlay",
            "airdrop-approval-blocked",
            "airdrop-question-blocked",
            "airdrop-disabled",
        ]

        XCTAssertEqual(AirDropDemoScenario.allCases.count, 12)
        for value in expected {
            XCTAssertTrue(rawValues.contains(value), "\(value) should be supported by --preview")
        }
    }

    func testAirDropApprovalBlockedPreviewRendersApprovalPayload() {
        let state = AppState()

        DebugHarness.applyAirDropDemo(.approvalBlocked, to: state)

        XCTAssertEqual(state.surface, .approvalCard(sessionId: "preview-approval"))
        XCTAssertEqual(state.previewPermissionEvent?.toolName, "Bash")
        XCTAssertNil(state.pendingPermission)
        XCTAssertFalse(state.canEnterAirDrop)
    }

    func testAirDropSettingsCopyDescribesSharingSwitch() {
        TestHelpers.processStateLock.lock()
        let savedLanguage = L10n.shared.language
        let savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        L10n.shared.language = "en"
        defer {
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
            TestHelpers.processStateLock.unlock()
        }

        XCTAssertEqual(L10n.shared["airdrop_enabled"], "Enable AirDrop")
        XCTAssertTrue(L10n.shared["airdrop_enabled_desc"].contains("files, folders, links, and selected text"))

        L10n.shared.language = "zh"
        XCTAssertEqual(L10n.shared["airdrop_enabled"], "启用 AirDrop")
        XCTAssertTrue(L10n.shared["airdrop_enabled_desc"].contains("文件、文件夹、链接"))
    }

    func testSourceWiresSettingsSectionDebugDemoControlAndNoFormalAirDropLogs() throws {
        let settings = try sourceFile("Sources/Bough/Settings.swift")
        let settingsView = try sourceFile("Sources/Bough/SettingsView.swift")
        let search = try sourceFile("Sources/Bough/Settings/SettingsSearchIndex.swift")
        let l10n = try sourceFile("Sources/Bough/L10n.swift")
        let panel = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let overlay = try sourceFile("Sources/Bough/AirDropDragOverlay.swift")
        let airDropFlow = try sourceFile("Sources/Bough/AirDropFlow.swift")
        let airDropPanel = try sourceFile("Sources/Bough/AirDropPanelView.swift")
        let appStateAirDrop = try sourceFile("Sources/Bough/AppState+AirDrop.swift")

        XCTAssertTrue(settings.contains("static let airDropEnabled = \"airDropEnabled\""))
        XCTAssertTrue(settings.contains("static let airDropEnabled = true"))
        XCTAssertTrue(settings.contains("SettingsKey.airDropEnabled: SettingsDefaults.airDropEnabled"))
        XCTAssertTrue(settingsView.contains("private struct AirDropSettingsPage"))
        XCTAssertTrue(settingsView.contains("SettingsTargetSection(\n                title: l10n[\"airdrop_section\"]"))
        XCTAssertTrue(settingsView.contains("Toggle(l10n[\"airdrop_enabled\"], isOn: $airDropEnabled)"))
        XCTAssertTrue(settingsView.contains("#if DEBUG"))
        XCTAssertTrue(settingsView.contains("Toggle(l10n[\"airdrop_demo_scenarios\"], isOn: $airDropDemoScenariosEnabled)"))
        XCTAssertTrue(search.contains(".page(.airDrop, \"airdrop_section\""))
        XCTAssertTrue(search.contains(".section(.airDrop, .airDropEnabled"))
        XCTAssertTrue(search.contains(".control(.airDrop, .airDropEnabled"))
        XCTAssertTrue(l10n.contains("\"airdrop_enabled\""))
        XCTAssertTrue(l10n.contains("\"settings_search_desc_page_airdrop\""))
        XCTAssertTrue(panel.contains("@AppStorage(SettingsKey.airDropEnabled)"))
        XCTAssertTrue(panel.contains("if onlySessionId == nil, airDropEnabled"))
        XCTAssertTrue(overlay.contains("appState.canEnterAirDrop"))
        XCTAssertTrue(airDropPanel.contains("AirDropDemoControlPanel"))
        XCTAssertTrue(airDropPanel.contains("openAirDropItemPicker()"))
        XCTAssertTrue(appStateAirDrop.contains("guard airDropEnabledProvider() else { return false }"))
        XCTAssertTrue(appStateAirDrop.contains("func enterAirDropMode()"))
        XCTAssertTrue(appStateAirDrop.contains("makeKeyAndOrderFront(nil)"))

        XCTAssertFalse(overlay.contains("Logger("))
        XCTAssertFalse(overlay.contains("os.log"))
        XCTAssertFalse(airDropFlow.contains("Logger("))
        XCTAssertFalse(airDropFlow.contains("os.log"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
