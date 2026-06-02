import XCTest

@testable import Bough

final class SettingsSearchIndexTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.codingSessionsEnabled)
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
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

    func testCustomHeightSearchFollowsCurrentVisibility() {
        UserDefaults.standard.set(NotchHeightMode.matchNotch.rawValue, forKey: SettingsKey.notchHeightMode)

        let hiddenResults = SettingsSearchIndex.search("custom height")

        XCTAssertEqual(hiddenResults.first?.page, .notch)
        XCTAssertEqual(hiddenResults.first?.targetID, .notchTopBarHeight)
        XCTAssertFalse(hiddenResults.contains { $0.targetID == .notchCustomHeight })

        UserDefaults.standard.set(NotchHeightMode.custom.rawValue, forKey: SettingsKey.notchHeightMode)

        let visibleResults = SettingsSearchIndex.search("custom height")

        XCTAssertEqual(visibleResults.first?.page, .notch)
        XCTAssertEqual(visibleResults.first?.targetID, .notchCustomHeight)
        XCTAssertEqual(visibleResults.first?.kind, .control)
        UserDefaults.standard.removeObject(forKey: SettingsKey.notchHeightMode)
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
