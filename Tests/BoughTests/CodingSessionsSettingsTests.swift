import XCTest

@testable import Bough

final class CodingSessionsSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CodingSessionsSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToOnWhenPreferenceIsMissing() {
        XCTAssertTrue(SettingsDefaults.codingSessionsEnabled)
        XCTAssertTrue(CodingSessionsSettings.isEnabled(defaults: defaults))
    }

    func testExplicitOffPersists() {
        CodingSessionsSettings.setEnabled(false, defaults: defaults)

        XCTAssertFalse(CodingSessionsSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SettingsKey.codingSessionsEnabled) as? Bool, false)
    }

    func testExplicitOnRestoresAfterOff() {
        CodingSessionsSettings.setEnabled(false, defaults: defaults)
        CodingSessionsSettings.setEnabled(true, defaults: defaults)

        XCTAssertTrue(CodingSessionsSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SettingsKey.codingSessionsEnabled) as? Bool, true)
    }

    func testModeToggleDoesNotRemoveExistingCodingPreferences() {
        defaults.set("codex", forKey: SettingsKey.usageSelectedProvider)
        defaults.set("claude", forKey: SettingsKey.defaultSource)
        defaults.set(false, forKey: SettingsKey.showMusicControls)

        CodingSessionsSettings.setEnabled(false, defaults: defaults)
        CodingSessionsSettings.setEnabled(true, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageSelectedProvider), "codex")
        XCTAssertEqual(defaults.string(forKey: SettingsKey.defaultSource), "claude")
        XCTAssertEqual(defaults.object(forKey: SettingsKey.showMusicControls) as? Bool, false)
    }

    func testCopyKeysResolveToPreservationContract() {
        TestHelpers.processStateLock.lock()
        let savedLanguage = L10n.shared.language
        let savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        L10n.shared.language = "en"
        defer {
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
            TestHelpers.processStateLock.unlock()
        }

        XCTAssertEqual(CodingSessionsSettings.titleLocalizationKey, "coding_sessions")

        let description = L10n.shared[CodingSessionsSettings.descriptionLocalizationKey]
        XCTAssertTrue(description.contains("pauses coding integrations"))
        XCTAssertTrue(description.contains("hides coding-session settings"))
        XCTAssertTrue(description.contains("preserving your CLI config"))
        XCTAssertTrue(description.contains("usage data"))
        XCTAssertTrue(description.contains("history"))
        XCTAssertTrue(description.contains("preferences"))
        XCTAssertFalse(description.contains(CodingSessionsSettings.descriptionLocalizationKey))
    }
}
