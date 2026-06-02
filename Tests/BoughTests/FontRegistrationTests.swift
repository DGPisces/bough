import XCTest
@testable import Bough

final class FontRegistrationTests: XCTestCase {
    func testPixelifySansRegularIsRegistered() {
        BoughFonts.registerBundledFonts()
        XCTAssertTrue(
            BoughFonts.isRegistered(BoughFonts.pixelifySansRegular),
            "PixelifySans-Regular did not register. Most common cause: PostScript name string in BoughFonts.pixelifySansRegular does not match the actual .ttf. Run `otfinfo --postscript-name Sources/Bough/Resources/Fonts/PixelifySans-Variable.ttf` and update the constant."
        )
    }

    func testRegisterBundledFontsIsIdempotent() {
        // Calling twice should not crash and should not surface an error
        // (Core Text returns code 105 'already registered' on second call,
        // which BoughFonts.registerBundledFonts treats as success).
        BoughFonts.registerBundledFonts()
        BoughFonts.registerBundledFonts()
        XCTAssertTrue(BoughFonts.isRegistered(BoughFonts.pixelifySansRegular))
    }

    func testBundledFontFileResolvableViaAppModule() {
        // Codex P3: testPixelifySansRegularIsRegistered passes if the font is
        // ALREADY installed system-wide on the dev machine, even when bundle
        // pathing or Bundle.appModule resolution is broken — masking
        // packaging regressions on preconfigured runners. This test asserts
        // the bundled .ttf is resolvable directly from Bundle.appModule
        // (the project-canonical accessor for SPM resources inside both
        // `swift test` and a signed .app), independent of any system-installed
        // copy of Pixelify Sans.
        let url = Bundle.appModule.url(
            forResource: "PixelifySans-Variable",
            withExtension: "ttf",
            subdirectory: "Resources/Fonts"
        )
        XCTAssertNotNil(
            url,
            "PixelifySans-Variable.ttf is not resolvable via Bundle.appModule.url(forResource:..., subdirectory: \"Resources/Fonts\"). Either the asset is missing from the SPM bundle or the .copy(\"Resources\") rule in Package.swift has drifted. This packaging regression would silently fall through to the system font in production .app builds."
        )
    }
}
