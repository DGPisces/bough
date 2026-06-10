import XCTest

@testable import Bough

final class StatusItemControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var savedLanguage: String!
    private var savedLanguageDefaultValue: Any?
    private var lockedProcessState = false

    override func setUp() {
        super.setUp()
        TestHelpers.processStateLock.lock()
        lockedProcessState = true
        savedLanguage = L10n.shared.language
        savedLanguageDefaultValue = UserDefaults.standard.object(forKey: SettingsKey.appLanguage)
        suiteName = "StatusItemControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if lockedProcessState {
            TestHelpers.restoreSharedLanguage(savedLanguage, savedDefaultValue: savedLanguageDefaultValue)
        }
        savedLanguage = nil
        savedLanguageDefaultValue = nil
        if lockedProcessState {
            TestHelpers.processStateLock.unlock()
            lockedProcessState = false
        }
        super.tearDown()
    }

    func testVisibilityPolicyDependsOnlyOnHideWhenIdle() {
        XCTAssertTrue(StatusItemVisibilityPolicy.shouldShowStatusItem(
            hideWhenNoSession: true,
            codingSessionsEnabled: true
        ))
        XCTAssertTrue(StatusItemVisibilityPolicy.shouldShowStatusItem(
            hideWhenNoSession: true,
            codingSessionsEnabled: false
        ))
        XCTAssertFalse(StatusItemVisibilityPolicy.shouldShowStatusItem(
            hideWhenNoSession: false,
            codingSessionsEnabled: true
        ))
        XCTAssertFalse(StatusItemVisibilityPolicy.shouldShowStatusItem(
            hideWhenNoSession: false,
            codingSessionsEnabled: false
        ))
    }

    func testMenuModelShowsOnlyReverseCodingSessionsAction() {
        L10n.shared.language = "en"

        XCTAssertEqual(
            StatusItemMenuModel.codingSessionsTitleKey(isEnabled: true),
            "turn_off_coding_sessions"
        )
        XCTAssertEqual(
            StatusItemMenuModel.codingSessionsTitleKey(isEnabled: false),
            "turn_on_coding_sessions"
        )
        XCTAssertEqual(
            L10n.shared[StatusItemMenuModel.codingSessionsTitleKey(isEnabled: true)],
            "Turn Off Coding Sessions"
        )
        XCTAssertEqual(
            L10n.shared[StatusItemMenuModel.codingSessionsTitleKey(isEnabled: false)],
            "Turn On Coding Sessions"
        )
    }

    func testMenuToggleWritesCodingSessionsPreferenceDirectly() {
        CodingSessionsSettings.setEnabled(true, defaults: defaults)

        XCTAssertFalse(StatusItemMenuModel.toggleCodingSessions(defaults: defaults))
        XCTAssertFalse(CodingSessionsSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SettingsKey.codingSessionsEnabled) as? Bool, false)

        XCTAssertTrue(StatusItemMenuModel.toggleCodingSessions(defaults: defaults))
        XCTAssertTrue(CodingSessionsSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SettingsKey.codingSessionsEnabled) as? Bool, true)
    }

    func testStatusItemControllerWiresModeMenuWithoutReplacingSettingsAndQuit() throws {
        let source = try sourceFile("Sources/Bough/StatusItemController.swift")

        XCTAssertTrue(source.contains("NSMenuDelegate"))
        XCTAssertTrue(source.contains("StatusItemVisibilityPolicy.shouldShowStatusItem"))
        XCTAssertTrue(source.contains("StatusItemMenuModel.codingSessionsTitleKey()"))
        XCTAssertTrue(source.contains("#selector(toggleCodingSessionsMode)"))
        XCTAssertTrue(source.contains("StatusItemMenuModel.toggleCodingSessions()"))
        XCTAssertTrue(source.contains("SettingsWindowController.shared.show()"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
