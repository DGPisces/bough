import AppKit
import XCTest
@testable import Bough

final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsEntryUsesAppKitWindowForStableLayout() throws {
        let appMain = try sourceFile("Sources/Bough/main.swift")
        let appDelegate = try sourceFile("Sources/Bough/AppDelegate.swift")
        let controller = try sourceFile("Sources/Bough/SettingsWindowController.swift")
        let panel = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertTrue(appMain.contains("let appDelegate = AppDelegate()"))
        XCTAssertTrue(appMain.contains("app.run()"))
        XCTAssertFalse(appMain.contains("Settings {"))
        XCTAssertFalse(appMain.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(appDelegate.contains("installMainMenu()"))
        XCTAssertTrue(appDelegate.contains("#selector(openSettingsFromMainMenu)"))
        XCTAssertTrue(appDelegate.contains("SettingsWindowController.shared.show()"))
        XCTAssertTrue(appDelegate.contains("keyEquivalent: \",\""))
        XCTAssertTrue(controller.contains("let window = NSWindow("))
        XCTAssertTrue(controller.contains("styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]"))
        XCTAssertTrue(controller.contains("SettingsView(appState: appState)"))
        XCTAssertTrue(controller.contains("if let window = window"))
        XCTAssertFalse(appDelegate.contains("Settings {"))
        XCTAssertFalse(appDelegate.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertFalse(controller.contains("SettingsSceneOpener"))
        XCTAssertFalse(controller.contains("OpenSettingsAction"))
        XCTAssertFalse(panel.contains("SettingsSceneOpenerInstaller"))
    }

    func testPanelWindowHeightIsCappedToVisibleScreenArea() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 820)

        let height = PanelWindowMetrics.panelHeight(
            maxVisibleSessions: 20,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(height, 852)
        XCTAssertLessThanOrEqual(height, screenFrame.maxY - visibleFrame.minY)
    }

    func testPanelWindowKeepsDesiredHeightWhenItFits() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1728, height: 1072)

        let height = PanelWindowMetrics.panelHeight(
            maxVisibleSessions: 5,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(height, 510)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
