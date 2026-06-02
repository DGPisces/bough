import XCTest
@testable import Bough
@testable import BoughCore

final class SettingsViewDurationTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    func testWindowDurationCompactFormatRows() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(windowDuration(resetIn: 2 * 3600 + 15 * 60, now: now, format: .compact), "2h 15m")
        XCTAssertEqual(windowDuration(resetIn: 24 * 3600 + 5 * 60, now: now, format: .compact), "24h 5m")
        XCTAssertEqual(windowDuration(resetIn: 3600 + 23 * 60, now: now, format: .compact), "1h 23m")
        XCTAssertEqual(windowDuration(resetIn: 100 * 3600, now: now, format: .compact), "4d 4h")
        XCTAssertEqual(windowDuration(resetIn: 100 * 3600 + 30 * 60, now: now, format: .compact), "4d 4h 30m")
    }

    func testWindowDurationFullDHMFormatRows() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(windowDuration(resetIn: 24 * 3600 + 2 * 3600 + 3 * 60, now: now, format: .fullDHM), "1d 2h 3m")
        XCTAssertEqual(windowDuration(resetIn: 5 * 60, now: now, format: .fullDHM), "0d 0h 5m")
        XCTAssertEqual(windowDuration(resetIn: 6 * 24 * 3600, now: now, format: .fullDHM), "6d 0h 0m")
    }

    func testLastRefreshTextPreservesSingleUnitLadder() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(lastRefreshText(elapsed: 30, now: now), "30s ago")
        XCTAssertEqual(lastRefreshText(elapsed: 3600 + 30 * 60, now: now), "1h ago")
        XCTAssertEqual(lastRefreshText(elapsed: 2 * 24 * 3600 + 5 * 3600, now: now), "2d ago")
    }

    private func windowDuration(resetIn: TimeInterval, now: Date, format: DurationFormat) -> String {
        UsageRelativeTimeFormatter.windowDuration(until: now.addingTimeInterval(resetIn), now: now, format: format)
    }

    private func lastRefreshText(elapsed: TimeInterval, now: Date) -> String {
        let five = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 10,
            resetsAt: now.addingTimeInterval(3600),
            windowDurationMins: 300,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: nil,
            fiveHour: .available(five),
            weekly: .loading,
            today: nil,
            availability: .available,
            lastRefresh: now.addingTimeInterval(-elapsed)
        )

        return UsageDetailsModel(snapshot: snapshot, now: now).lastRefresh
    }

    func testGeneralPagePlacesCodingSessionsSwitchBeforeLanguage() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")

        let switchIndex = try XCTUnwrap(source.range(of: "targetID: .generalCodingSessions")?.lowerBound)
        let guideIndex = try XCTUnwrap(source.range(of: "targetID: .generalWelcomeGuide")?.lowerBound)
        let languageIndex = try XCTUnwrap(source.range(of: "targetID: .generalLanguage")?.lowerBound)

        XCTAssertLessThan(switchIndex, languageIndex)
        XCTAssertLessThan(guideIndex, languageIndex)
        XCTAssertTrue(source.contains("@AppStorage(SettingsKey.codingSessionsEnabled)"))
        XCTAssertTrue(source.contains("CodingSessionsSettings.descriptionLocalizationKey"))
    }

    func testGeneralPageWiresWelcomeGuideReopenEntryWithoutSidebarBadge() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")
        let navigation = try sourceFile("Sources/Bough/Settings/SettingsNavigationModel.swift")
        let search = try sourceFile("Sources/Bough/Settings/SettingsSearchIndex.swift")

        XCTAssertTrue(source.contains("WelcomeGuideWindowController.shared.show()"))
        XCTAssertTrue(source.contains("@AppStorage(SettingsKey.welcomeGuideCompletedVersion)"))
        XCTAssertTrue(source.contains("welcomeGuideStatusText"))
        XCTAssertTrue(source.contains("welcome_guide_open_settings"))
        XCTAssertTrue(navigation.contains("case generalWelcomeGuide"))
        XCTAssertTrue(search.contains(".control(.general, .generalWelcomeGuide"))
        XCTAssertFalse(source.contains("welcomeGuideBadge"))
    }

    func testAppearancePageDoesNotContainCodingSessionControls() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private struct AppearancePage: View")?.lowerBound)
        let end = try XCTUnwrap(source[start...].range(of: "// MARK: - Music Page")?.lowerBound)
        let page = String(source[start..<end])

        XCTAssertFalse(page.contains("SettingsKey.maxVisibleSessions"))
        XCTAssertFalse(page.contains("SettingsKey.showAgentDetails"))
        XCTAssertFalse(page.contains("SettingsKey.showToolStatus"))
        XCTAssertFalse(page.contains("SettingsKey.autoCollapseAfterSessionJump"))
        XCTAssertFalse(page.contains("SettingsKey.autoExpandOnCompletion"))
        XCTAssertFalse(page.contains("SettingsKey.showMusicControls"))
        XCTAssertFalse(page.contains("smartSuppress"))
    }

    func testMascotRowsConstrainLayerBackedPreviews() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")
        let row = try XCTUnwrap(source.slice(
            from: "private struct MascotRow: View",
            to: "// MARK: - Sound Page"
        ))

        XCTAssertTrue(row.contains("MascotView(source: source, status: status, size: 40)"))
        XCTAssertTrue(row.contains(".frame(width: 40, height: 40)"))
        XCTAssertTrue(row.contains(".frame(width: 56, height: 56)"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
