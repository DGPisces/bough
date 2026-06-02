import XCTest

@testable import Bough
@testable import BoughCore

final class SettingsBuddyVisibilityTests: XCTestCase {
    func testBuddyPageIsNotVisibleInSettingsSidebar() {
        XCTAssertFalse(SettingsSidebarModel.visiblePages.contains { $0.rawValue == Self.physicalHardwareRouteRawValue })
        XCTAssertNil(SettingsPage(rawValue: Self.physicalHardwareRouteRawValue))
    }

    func testSettingsSidebarGroupsKeepExactOrder() {
        XCTAssertEqual(
            SettingsSidebarModel.pages(
                inGroup: SettingsSidebarModel.nonCodingGroupTitleKey,
                codingSessionsEnabled: true
            ),
            [
                .general,
                .music,
                .airDrop,
                .notch,
                .about,
            ]
        )
        XCTAssertEqual(
            SettingsSidebarModel.pages(
                inGroup: SettingsSidebarModel.codingGroupTitleKey,
                codingSessionsEnabled: true
            ),
            [
                .sessionDisplay,
                .mascot,
                .sound,
                .usageNotifications,
                .integrations,
                .advanced,
            ]
        )
        XCTAssertEqual(SettingsSidebarModel.visiblePages(codingSessionsEnabled: true), [
            .general,
            .music,
            .airDrop,
            .notch,
            .about,
            .sessionDisplay,
            .mascot,
            .sound,
            .usageNotifications,
            .integrations,
            .advanced,
        ])
    }

    func testCodingSessionGroupIsHiddenWhenProductModeIsOff() {
        XCTAssertEqual(SettingsSidebarModel.sidebarGroups(codingSessionsEnabled: false).map(\.title), [
            SettingsSidebarModel.nonCodingGroupTitleKey,
        ])
        XCTAssertEqual(SettingsSidebarModel.visiblePages(codingSessionsEnabled: false), [
            .general,
            .music,
            .airDrop,
            .notch,
            .about,
        ])
    }

    func testSettingsPageNavigationMetadataStaysStable() {
        let expected: [(SettingsPage, String, String, String)] = [
            (.general, "general", "gearshape.fill", "gray"),
            (.sessionDisplay, "session_display", "rectangle.split.2x1.fill", "indigo"),
            (.notch, "notch", "display", "blue"),
            (.music, "music", "music.note", "mint"),
            (.airDrop, "airdrop", "square.and.arrow.up", "blue"),
            (.mascot, "mascot", "person.2.fill", "pink"),
            (.sound, "sound", "speaker.wave.2.fill", "green"),
            (.usageNotifications, "usage_notifications", "chart.line.uptrend.xyaxis", "teal"),
            (.integrations, "integrations", "link.circle.fill", "purple"),
            (.advanced, "advanced", "wrench.and.screwdriver.fill", "orange"),
            (.about, "about", "info.circle.fill", "cyan"),
        ]

        for (page, rawValue, icon, color) in expected {
            XCTAssertEqual(page.rawValue, rawValue)
            XCTAssertEqual(page.icon, icon)
            XCTAssertEqual(String(describing: page.color), color)
        }
    }

    func testCodeBuddySourcesRemainKnownDisplayNames() {
        var codeBuddy = SessionSnapshot()
        codeBuddy.source = "codebuddy"
        XCTAssertEqual(codeBuddy.sourceLabel, "CodeBuddy")
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("codebuddy"))

        var codyBuddyCN = SessionSnapshot()
        codyBuddyCN.source = "codybuddycn"
        XCTAssertEqual(codyBuddyCN.sourceLabel, "CodyBuddyCN")
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("codybuddycn"))

        var workBuddy = SessionSnapshot()
        workBuddy.source = "workbuddy"
        XCTAssertEqual(workBuddy.sourceLabel, "WorkBuddy")
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("workbuddy"))
    }

    private static let physicalHardwareRouteRawValue = "bud" + "dy"
}
