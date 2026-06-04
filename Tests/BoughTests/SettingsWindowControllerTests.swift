import XCTest

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

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
