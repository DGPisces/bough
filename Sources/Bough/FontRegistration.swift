import Foundation
import CoreText
import os

/// Registers Bough's bundled custom fonts with Core Text at app launch.
/// Must be called once, before any `.font(.custom(...))` call resolves.
///
/// Pixelify Sans is the GA wordmark font. It is a variable font with the
/// `wght` axis; SwiftUI `.fontWeight(...)` on macOS 14+ drives the axis
/// to produce Bold / Medium / etc from the same registered font file.
enum BoughFonts {
    nonisolated private static let log = Logger(subsystem: "com.dgpisces.bough", category: "fonts")

    /// PostScript name of the registered Pixelify Sans variable font face.
    /// Variable fonts register under their default instance name (Regular).
    /// Read via `otfinfo --postscript-name PixelifySans-Variable.ttf`.
    /// SwiftUI `.font(.custom(...))` matches PostScript names case-sensitively.
    static let pixelifySansRegular = "PixelifySans-Regular"

    /// Default wordmark font (always Pixelify Sans Regular; the variable
    /// `wght` axis is driven via `.fontWeight(.bold)` at the call site).
    static let defaultWordmark = pixelifySansRegular

    /// Register all bundled fonts. Safe to call more than once
    /// (Core Text returns code 105 = "already registered", treated as success).
    ///
    /// Bundle: `Bundle.appModule` resolves to the SPM resource bundle inside
    /// a signed `.app` (Contents/Resources/Bough_Bough.bundle) and falls back
    /// to `Bundle.module` for SPM dev builds — see `BundleExtension.swift`.
    /// Project-wide convention used by `SoundManager` etc.
    static func registerBundledFonts() {
        let fonts: [(name: String, ext: String)] = [
            ("PixelifySans-Variable", "ttf"),
        ]
        for font in fonts {
            guard let url = Bundle.appModule.url(
                forResource: font.name,
                withExtension: font.ext,
                subdirectory: "Resources/Fonts"
            ) else {
                log.error("Bundled font missing: Resources/Fonts/\(font.name).\(font.ext)")
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok, let err = error?.takeRetainedValue() {
                let nsErr = err as Error as NSError
                if nsErr.code != 105 {
                    log.error("Font registration failed for \(font.name): \(err.localizedDescription)")
                }
            }
        }
    }

    /// Returns true iff a font with the given PostScript name is currently registered.
    /// Used by tests; not load-bearing in production.
    static func isRegistered(_ postScriptName: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 12)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let resolved = CTFontCopyPostScriptName(font) as String
        return resolved == postScriptName
    }
}
