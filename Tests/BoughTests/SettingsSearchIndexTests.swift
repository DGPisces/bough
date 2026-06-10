import XCTest

@testable import Bough

final class SettingsSearchIndexTests: XCTestCase {
    private var savedLanguage: String!
    private var savedLanguageDefaultValue: Any?
    private var savedCodingSessionsEnabled: Any?
    private var lockedProcessState = false

    override func setUp() {
        super.setUp()
        TestHelpers.processStateLock.lock()
        lockedProcessState = true
        savedLanguage = L10n.shared.language
        savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        savedCodingSessionsEnabled = UserDefaults.standard.object(forKey: SettingsKey.codingSessionsEnabled)
        UserDefaults.standard.removeObject(forKey: SettingsKey.codingSessionsEnabled)
        L10n.shared.language = "en"
    }

    override func tearDown() {
        if lockedProcessState {
            TestHelpers.restoreUserDefaultsValue(savedCodingSessionsEnabled, forKey: SettingsKey.codingSessionsEnabled)
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
        }
        savedLanguage = nil
        savedLanguageDefaultValue = nil
        savedCodingSessionsEnabled = nil
        if lockedProcessState {
            TestHelpers.processStateLock.unlock()
            lockedProcessState = false
        }
        super.tearDown()
    }

    func testMusicSearchPrefersMusicPageBeforeSound() {
        let results = SettingsSearchIndex.search("music controls")

        XCTAssertEqual(results.first?.page, .music)
        XCTAssertEqual(results.first?.targetID, .musicShowMusicControls)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testOffModeFiltersCodingSessionSearchResults() {
        let usageResults = SettingsSearchIndex.search("show codex usage", codingSessionsEnabled: false)
        let soundResults = SettingsSearchIndex.search("sound effects", codingSessionsEnabled: false)
        let musicResults = SettingsSearchIndex.search("music controls", codingSessionsEnabled: false)
        let airDropResults = SettingsSearchIndex.search("drag to airdrop", codingSessionsEnabled: false)

        XCTAssertTrue(usageResults.isEmpty)
        XCTAssertTrue(soundResults.isEmpty)
        XCTAssertEqual(musicResults.first?.page, .music)
        XCTAssertEqual(airDropResults.first?.page, .airDrop)
        XCTAssertEqual(airDropResults.first?.targetID, .airDropEnabled)
    }

    func testAirDropSearchRoutesToStandalonePage() {
        let results = SettingsSearchIndex.search("drag to airdrop")

        XCTAssertEqual(results.first?.page, .airDrop)
        XCTAssertEqual(results.first?.targetID, .airDropEnabled)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testWelcomeGuideSearchRoutesToGeneralOpenAction() {
        let results = SettingsSearchIndex.search("open welcome guide")

        XCTAssertEqual(results.first?.page, .general)
        XCTAssertEqual(results.first?.targetID, .generalWelcomeGuide)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testChineseSearchFindsWelcomeGuideOpenAction() {
        L10n.shared.language = "zh"

        let results = SettingsSearchIndex.search("打开欢迎引导")

        XCTAssertEqual(results.first?.page, .general)
        XCTAssertEqual(results.first?.targetID, .generalWelcomeGuide)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testSmartSuppressIsNotSearchable() {
        XCTAssertTrue(SettingsSearchIndex.search("smart suppress").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.search("智能抑制").isEmpty)
    }

    func testChineseSearchFindsBackgroundMonitor() {
        L10n.shared.language = "zh"

        let results = SettingsSearchIndex.search("后台监控")

        XCTAssertEqual(results.first?.page, .usageNotifications)
        XCTAssertEqual(results.first?.targetID, .usageBackgroundMonitor)
    }

    func testChineseSearchFindsBackgroundMonitorRepairAction() {
        L10n.shared.language = "zh"

        let results = SettingsSearchIndex.search("后台监控修复")

        XCTAssertEqual(results.first?.page, .usageNotifications)
        XCTAssertEqual(results.first?.targetID, .usageMonitorRepair)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testChineseSearchFindsConcreteCodexUsageDisplayToggleWithoutSpaces() {
        L10n.shared.language = "zh"

        let results = SettingsSearchIndex.search("显示codex用量")

        XCTAssertEqual(results.first?.page, .usageNotifications)
        XCTAssertEqual(results.first?.targetID, .usageDisplayCodex)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testSearchFindsCheckForUpdatesAction() {
        L10n.shared.language = "zh"

        let results = SettingsSearchIndex.search("检查更新")

        XCTAssertEqual(results.first?.page, .about)
        XCTAssertEqual(results.first?.targetID, .aboutCheckForUpdates)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testHomebrewSearchHidesSparkleUpdateActionsAndShowsCopyCommand() {
        L10n.shared.language = "zh"

        let checkResults = SettingsSearchIndex.search("检查更新", isHomebrewInstall: true)
        let updateNowResults = SettingsSearchIndex.search("立即更新", isHomebrewInstall: true)
        let copyResults = SettingsSearchIndex.search("homebrew update", isHomebrewInstall: true)

        XCTAssertFalse(checkResults.contains { $0.targetID == .aboutCheckForUpdates })
        XCTAssertFalse(updateNowResults.contains { $0.targetID == .aboutUpdateNow })
        XCTAssertEqual(copyResults.first?.page, .about)
        XCTAssertEqual(copyResults.first?.targetID, .aboutUpdateCopyCommand)
        XCTAssertEqual(copyResults.first?.kind, .control)
    }

    func testDmgSearchKeepsSparkleUpdateActionsAndHidesHomebrewCopyCommand() {
        let checkResults = SettingsSearchIndex.search("check update", isHomebrewInstall: false)
        let copyResults = SettingsSearchIndex.search("homebrew update", isHomebrewInstall: false)

        XCTAssertEqual(checkResults.first?.targetID, .aboutCheckForUpdates)
        XCTAssertFalse(copyResults.contains { $0.targetID == .aboutUpdateCopyCommand })
    }

    func testCustomHeightSearchFollowsCurrentVisibility() {
        let hiddenResults = SettingsSearchIndex.search("custom height", notchHeightMode: .matchNotch)

        XCTAssertEqual(hiddenResults.first?.page, .notch)
        XCTAssertEqual(hiddenResults.first?.targetID, .notchTopBarHeight)
        XCTAssertFalse(hiddenResults.contains { $0.targetID == .notchCustomHeight })

        let visibleResults = SettingsSearchIndex.search("custom height", notchHeightMode: .custom)

        XCTAssertEqual(visibleResults.first?.page, .notch)
        XCTAssertEqual(visibleResults.first?.targetID, .notchCustomHeight)
        XCTAssertEqual(visibleResults.first?.kind, .control)
    }

    func testControlResultRanksBeforeSectionAndPage() {
        let results = SettingsSearchIndex.search("sound effects")

        XCTAssertEqual(results.first?.page, .sound)
        XCTAssertEqual(results.first?.targetID, .soundEnable)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testEnglishSearchFindsConcreteCodexUsageDisplayToggle() {
        let results = SettingsSearchIndex.search("show codex usage")

        XCTAssertEqual(results.first?.page, .usageNotifications)
        XCTAssertEqual(results.first?.targetID, .usageDisplayCodex)
        XCTAssertEqual(results.first?.kind, .control)
    }

    func testRemovedPhysicalHardwareNameIsNotSearchable() {
        let physicalHardwareName = "bud" + "dy"

        XCTAssertTrue(SettingsSearchIndex.search(physicalHardwareName).isEmpty)
    }

}
