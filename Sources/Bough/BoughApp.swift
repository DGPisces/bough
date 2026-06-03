import SwiftUI

@main
struct BoughApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    init() {
        BoughFonts.registerBundledFonts()
    }

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState)
                .frame(minWidth: 660, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(l10n["settings_ellipsis"]) {
                    Task { @MainActor in
                        SettingsWindowController.shared.show()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // Regression guard: round-3 used
        // `.windowResizability(.contentSize)` which actually locks the window
        // to the content's intrinsic size and forbids user-drag resize on
        // macOS 14+. `.contentMinSize` is the correct modifier: SwiftUI
        // honors the `.frame(minWidth/minHeight:)` hints as the minimum, but
        // the user can drag the corner to grow the window larger when their
        // screen has room. The per-page ScrollView still covers the
        // minimum-height case.
        .windowResizability(.contentMinSize)
    }
}
