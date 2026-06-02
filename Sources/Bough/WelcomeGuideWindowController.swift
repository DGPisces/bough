import AppKit
import SwiftUI

@MainActor
final class WelcomeGuideWindowController {
    static let shared = WelcomeGuideWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var resizeGuard: SettingsWindowResizeGuard?

    private init() {}

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func show(defaults: UserDefaults = .standard) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: WelcomeGuideView(defaults: defaults) { [weak self] in
            self?.window?.close()
        })

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(780, screenW * 0.62)
        let winH = min(560, screenH * 0.72)
        let minContent = NSSize(width: min(720, screenW * 0.55), height: min(520, screenH * 0.62))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["welcome_guide_window_title"]
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.contentMinSize = minContent
        window.minSize = minContent
        let guardObj = SettingsWindowResizeGuard(minimum: minContent)
        window.delegate = guardObj
        resizeGuard = guardObj
        window.toolbar = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window.contentMinSize = minContent
        window.minSize = minContent

        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.resizeGuard = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.window = window
    }
}
