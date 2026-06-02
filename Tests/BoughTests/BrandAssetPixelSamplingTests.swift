import AppKit
import XCTest
@testable import Bough

/// BRAND-04 automated pixel-sampling regression guard for Assets/Brand/logo.png.
///
/// Reads the 40-sample JSON ledger produced by Phase 10 and asserts each coordinate
/// against the current `Assets/Brand/logo.png` bytes. This is the XCTest that was missing after
/// Phase 10 (verification existed only as a manual script and JSON record).
///
/// JSON ledger: Tests/BoughTests/Fixtures/10-pixel-samples.json
/// Semantic categories: forest_ink_bounds (10), amber_wordmark (14),
///                      closed_glyph_counters (8), chick_rim (8) — 40 total.
///
/// NOTE: this fixture covers the 1600×400 wordmark only. The dock-icon halo
/// regression (debug session bough-dock-icon-white-edge) is guarded by the
/// separate `testAppIconHasNoWhiteHaloAtRoundedRectPerimeter` below.
final class BrandAssetPixelSamplingTests: XCTestCase {

    func testLogoPngPassesBrand04SampleSuite() throws {
        let logoURL = Self.repoRoot.appendingPathComponent("Assets/Brand/logo.png")
        let logoData = try XCTUnwrap(
            try? Data(contentsOf: logoURL),
            "Assets/Brand/logo.png not found at repo root. Path: \(logoURL.path)"
        )
        let rep = try XCTUnwrap(
            NSBitmapImageRep(data: logoData),
            "Assets/Brand/logo.png could not be loaded as NSBitmapImageRep (corrupt or wrong format)"
        )

        // Read ledger from the tracked Fixtures directory so CI and sparse checkouts
        // have deterministic brand samples.
        let jsonURL = Self.repoRoot
            .appendingPathComponent("Tests/BoughTests/Fixtures/10-pixel-samples.json")
        let jsonData = try XCTUnwrap(
            try? Data(contentsOf: jsonURL),
            "10-pixel-samples.json not found at \(jsonURL.path). Restore the tracked fixture before running brand tests."
        )
        // Decode as array of raw dictionaries to avoid AnyCodable dependency.
        let samples = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]],
            "10-pixel-samples.json could not be parsed as [[String: Any]]"
        )
        XCTAssertEqual(samples.count, 40, "BRAND-04 ledger must have exactly 40 samples")

        var failures: [String] = []

        for sample in samples {
            guard
                let x = sample["x"] as? Int,
                let y = sample["y"] as? Int,
                let expected = sample["expected"] as? [Int],
                expected.count == 3,
                let tolerance = sample["tolerance"] as? [String: Any],
                let rgbMaxDelta = tolerance["rgb_max_delta"] as? Int,
                let expectedAlpha = tolerance["alpha"] as? Int,
                let category = sample["semantic_category"] as? String
            else {
                XCTFail("Malformed sample record in 10-pixel-samples.json: \(sample)")
                continue
            }

            guard let color = rep.colorAt(x: x, y: y) else {
                failures.append("[\(category)] (\(x),\(y)): colorAt returned nil")
                continue
            }

            // NSBitmapImageRep.colorAt returns color components in the bitmap's native color
            // space. The Phase 10 ledger values were recorded from the same API without any
            // color space conversion, so read components directly. Avoid usingColorSpace(.deviceRGB)
            // here — that conversion applies gamma/linearization that shifts all channel values
            // upward by ~8 units and causes every sample to fail against the sRGB-recorded ledger.
            let actualR = Int((color.redComponent * 255).rounded())
            let actualG = Int((color.greenComponent * 255).rounded())
            let actualB = Int((color.blueComponent * 255).rounded())
            let actualA = Int((color.alphaComponent * 255).rounded())

            var sampleFailed = false
            if abs(actualR - expected[0]) > rgbMaxDelta { sampleFailed = true }
            if abs(actualG - expected[1]) > rgbMaxDelta { sampleFailed = true }
            if abs(actualB - expected[2]) > rgbMaxDelta { sampleFailed = true }
            if actualA != expectedAlpha { sampleFailed = true }

            if sampleFailed {
                failures.append(
                    "[\(category)] (\(x),\(y)): " +
                    "expected RGB(\(expected[0]),\(expected[1]),\(expected[2])) A=\(expectedAlpha) " +
                    "got RGB(\(actualR),\(actualG),\(actualB)) A=\(actualA) " +
                    "tolerance=\u{B1}\(rgbMaxDelta)"
                )
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "BRAND-04: \(failures.count)/40 pixel samples failed.\n" +
            failures.joined(separator: "\n")
        )
    }

    /// Regression guard for the dock-icon white-halo bug (debug session
    /// bough-dock-icon-white-edge.md).
    ///
    /// Background: Phase 19 tried to fix a "white ring" around the dock icon
    /// by zeroing RGB on transparent pixels of `icon-master.png`. That fix
    /// was incomplete — the actual halo came from the Xcode 26 `.icon`
    /// (Icon Composer) tile fill (`"fill": "system-light"`), which actool
    /// composites under the foreground design and leaks into the band between
    /// the design's bounding edge and the rounded-rect mask edge. Phase 19's
    /// BRAND-04 "PASS" only covered the 1600×400 wordmark, not the dock icon,
    /// so the regression shipped unguarded.
    ///
    /// This test:
    ///  1. Asserts the .icns contains every required size (16/16@2x .. 512/512@2x).
    ///     A pre-Phase-21 actool run only emitted 4 sizes; CI must reject that.
    ///  2. Scans the rounded-rect perimeter of every size and fails if any
    ///     pixel inside the design region is near-white. We scan a band that
    ///     covers the AA edge of the rounded-rect mask — exactly where the
    ///     `system-light` halo manifested.
    func testAppIconHasNoWhiteHaloAtRoundedRectPerimeter() throws {
        let icnsURL = Self.repoRoot
            .appendingPathComponent("Sources/Bough/Resources/AppIcon.icns")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: icnsURL.path),
            "AppIcon.icns not found at \(icnsURL.path)"
        )

        // Use `iconutil` to unpack the .icns into individual PNGs we can inspect.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bough-icon-halo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let iconset = tmpDir.appendingPathComponent("AppIcon.iconset")
        let process = Process()
        process.launchPath = "/usr/bin/iconutil"
        process.arguments = ["-c", "iconset", icnsURL.path, "-o", iconset.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0,
            "iconutil failed to unpack \(icnsURL.path)"
        )

        // Required sizes — every size shipped in a complete macOS .icns.
        let requiredSizes = [
            "icon_16x16.png", "icon_16x16@2x.png",
            "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png",
            "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png"
        ]

        // (1) Completeness check — fail clearly and separately from halo check.
        var missingSizes: [String] = []
        for size in requiredSizes {
            let pngURL = iconset.appendingPathComponent(size)
            if !FileManager.default.fileExists(atPath: pngURL.path) {
                missingSizes.append(size)
            }
        }
        XCTAssertTrue(
            missingSizes.isEmpty,
            "AppIcon.icns is missing required sizes: \(missingSizes.joined(separator: ", ")). " +
            "Re-run Tools/Build/regenerate-app-icon.sh to bake all 10 sizes."
        )

        // (2) Halo check — scan rounded-rect perimeter band across each present size.
        var haloFailures: [String] = []

        for size in requiredSizes {
            let pngURL = iconset.appendingPathComponent(size)
            guard let data = try? Data(contentsOf: pngURL),
                  let rep = NSBitmapImageRep(data: data) else {
                // Missing-size failure already reported above; skip here.
                continue
            }

            let w = rep.pixelsWide, h = rep.pixelsHigh

            // The mask inset for the macOS app-icon shape is ~7-8% of canvas; we scan
            // a band a few pixels deep from each edge so we cover the mask AA region
            // without dipping into central design content. Skip the very corners
            // (they are fully transparent by mask).
            let bandDepth = max(2, w / 8) // 12.5% of canvas
            let cornerSkip = max(2, w / 16)

            for y in [bandDepth / 2, h - 1 - bandDepth / 2] {
                for x in cornerSkip..<(w - cornerSkip) {
                    if let f = checkPixelForHalo(rep: rep, x: x, y: y, in: size) {
                        haloFailures.append(f)
                    }
                }
            }
            for x in [bandDepth / 2, w - 1 - bandDepth / 2] {
                for y in cornerSkip..<(h - cornerSkip) {
                    if let f = checkPixelForHalo(rep: rep, x: x, y: y, in: size) {
                        haloFailures.append(f)
                    }
                }
            }
        }

        XCTAssertTrue(
            haloFailures.isEmpty,
            "AppIcon.icns has \(haloFailures.count) near-white pixels at the rounded-rect " +
            "perimeter (dock white-halo regression). Showing first 10:\n" +
            haloFailures.prefix(10).joined(separator: "\n")
        )
    }

    /// Returns a failure description if the pixel is opaque-ish AND near-white,
    /// otherwise nil. Near-white = all RGB channels > 200 with alpha > 64
    /// (catches both fully-white halo pixels and AA-blend pixels with substantial
    /// alpha that visibly contribute to a halo).
    private func checkPixelForHalo(rep: NSBitmapImageRep, x: Int, y: Int, in size: String) -> String? {
        guard let c = rep.colorAt(x: x, y: y) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        if a > 64 && r > 200 && g > 200 && b > 200 {
            return "[\(size)] (\(x),\(y)): RGBA(\(r),\(g),\(b),\(a)) — near-white at rounded-rect perimeter"
        }
        return nil
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
}
