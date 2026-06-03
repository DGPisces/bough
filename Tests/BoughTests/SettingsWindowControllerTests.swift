import XCTest

final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsEntryUsesAppKitWindowForStableLayout() throws {
        let app = try sourceFile("Sources/Bough/BoughApp.swift")
        let controller = try sourceFile("Sources/Bough/SettingsWindowController.swift")
        let panel = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(app.contains("SettingsWindowController.shared.show()"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(controller.contains("let window = NSWindow("))
        XCTAssertTrue(controller.contains("styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]"))
        XCTAssertTrue(controller.contains("SettingsView(appState: appState)"))
        XCTAssertTrue(controller.contains("if let window = window"))
        XCTAssertFalse(controller.contains("SettingsSceneOpener"))
        XCTAssertFalse(controller.contains("OpenSettingsAction"))
        XCTAssertFalse(panel.contains("SettingsSceneOpenerInstaller"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
