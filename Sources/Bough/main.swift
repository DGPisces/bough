import AppKit

MainActor.assumeIsolated {
    BoughFonts.registerBundledFonts()

    let appDelegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.run()
}
