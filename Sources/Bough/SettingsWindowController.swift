import AppKit
import SwiftUI

@MainActor
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var appState: AppState?

    private var closeObserver: NSObjectProtocol?
    private var resizeGuard: SettingsWindowResizeGuard?

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    func show() {
        guard let appState else {
            assertionFailure("SettingsWindowController.configure(appState:) must run during app launch")
            return
        }

        // Switch to regular activation policy so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        // Use the actual bundle app icon so Dock matches the packaged asset catalog icon.
        NSApp.applicationIconImage = Self.bundleAppIcon()

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appState: appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(660, screenW * 0.5)
        let winH = min(540, screenH * 0.6)

        // styleMask MUST include .resizable for the user to drag the window
        // corners. Round 3+4 of regression had attempted to fix this
        // via SwiftUI `.windowResizability(.contentMinSize)` on the
        // `Settings { }` scene in BoughApp.swift — but Bough's settings
        // window is actually constructed here via AppKit (the SwiftUI
        // Settings scene is unused for the visible window), so those
        // modifiers never applied. The fix lives in this styleMask.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["settings_title"]
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        // Regression guard: round-6 set both `contentMinSize` and
        // `minSize` on this window, but the user could still drag below
        // 560×420 on macOS 26.5 (Tahoe). Investigation found two contributing
        // factors:
        //   (a) AppKit can quietly reset `minSize` during initial window
        //       reorder — values stamped before `makeKeyAndOrderFront` are
        //       not always honored on Tahoe.
        //   (b) `contentMinSize` clamps the inner hosting area but a
        //       SwiftUI `Form { ... }.formStyle(.grouped)` can still report
        //       a smaller intrinsic size during a live-resize drag, which
        //       NSWindow uses as the floor unless an `NSWindowDelegate`
        //       actively rejects the proposed size each frame.
        // Round-7 fix: install an `NSWindowDelegate` that vetoes any
        // `windowWillResize(_:to:)` proposal below the minimum on every
        // live-resize event. The delegate is the authoritative resize gate
        // regardless of AppKit's internal minSize state, and works
        // identically on macOS 13–26.x. We still set `contentMinSize` /
        // `minSize` (defense in depth) but the delegate is what makes the
        // bug go away.
        let minContent = NSSize(width: min(560, screenW * 0.4), height: min(420, screenH * 0.4))
        window.contentMinSize = minContent
        window.minSize = minContent
        let guardObj = SettingsWindowResizeGuard(minimum: minContent)
        window.delegate = guardObj
        self.resizeGuard = guardObj
        window.toolbar = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Round-7 belt-and-suspenders: re-stamp minSize AFTER makeKeyAndOrderFront
        // because some macOS releases reset it during the initial reorder.
        // The delegate already enforces the floor, but keeping these synced
        // means tooling that reads `window.minSize` (e.g. accessibility
        // probes) sees the correct value.
        window.contentMinSize = minContent
        window.minSize = minContent

        // Revert to accessory policy after close without hiding the entire app.
        // Hiding here causes the panel to blink even though only the settings
        // window is being dismissed.
        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
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

    static func bundleAppIcon() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 256, height: 256)
        return image
    }
}

/// Regression guard: NSWindowDelegate that enforces a hard
/// minimum on every live-resize event. AppKit's `minSize` /
/// `contentMinSize` are advisory in some configurations (SwiftUI hosting
/// views, macOS 26.x Tahoe) — the delegate's `windowWillResize` callback
/// is the authoritative resize gate and clamps the proposed frame size to
/// the configured minimum before AppKit commits it to the live drag.
@MainActor
final class SettingsWindowResizeGuard: NSObject, NSWindowDelegate {
    let minimum: NSSize

    init(minimum: NSSize) {
        self.minimum = minimum
        super.init()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, minimum.width),
            height: max(frameSize.height, minimum.height)
        )
    }
}
