import AppKit
import XCTest
@testable import Bough

final class BoughMascotViewTests: XCTestCase {
    func testBoughMascotUsesLayerBackedPlaybackInsteadOfTimelineView() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/Bough/BoughMascotView.swift"))

        XCTAssertTrue(source.contains("LayerBackedBoughMascotView(fixedFrame: fixedFrame, frameSize: frameSize)"))
        XCTAssertTrue(source.contains("private struct LayerBackedBoughMascotView: NSViewRepresentable"))
        XCTAssertTrue(source.contains("private final class LayerBackedBoughMascotNSView: NSView"))
        XCTAssertTrue(source.contains("CAKeyframeAnimation(keyPath: \"contents\")"))
        XCTAssertFalse(source.contains("TimelineView("))
    }

    func testIdleSheetResolvableViaAppModule() {
        // Pro round-1 P3: cover the mascot bundle path the same way
        // FontRegistrationTests covers PixelifySans-Variable.ttf. Catches a
        // packaging regression (e.g., `.copy("Resources")` rule drift, or
        // someone moves the file) that would otherwise only surface as a
        // gray-rectangle fallback in production at runtime.
        let url = Bundle.appModule.url(
            forResource: "idle-sheet",
            withExtension: "png",
            subdirectory: "Resources/bough-mascot"
        )
        XCTAssertNotNil(
            url,
            "idle-sheet.png is not resolvable via Bundle.appModule.url(forResource:..., subdirectory: \"Resources/bough-mascot\"). The mascot will silently render as a gray placeholder in production .app builds."
        )
    }

    func testIdleSheetHasTransparentBackground() throws {
        let url = try XCTUnwrap(Bundle.appModule.url(
            forResource: "idle-sheet",
            withExtension: "png",
            subdirectory: "Resources/bough-mascot"
        ))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))

        XCTAssertLessThan(
            try bitmap.alpha(atX: 0, y: 0),
            16,
            "idle-sheet.png must not bake the checkerboard preview background into the About mascot."
        )
    }

    func testAppIconMasterHasTransparentCorners() throws {
        // After debug session bough-dock-icon-white-edge, the canonical 1024×1024
        // icon master lives at Platform/Apple/icon-source/icon-master-1024.png and feeds
        // Tools/Build/regenerate-app-icon.sh. Its corners must stay transparent so the
        // notch icon and other surfaces render without a hard square edge.
        let url = Self.repoRoot
            .appendingPathComponent("Platform/Apple/icon-source/icon-master-1024.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))

        XCTAssertLessThan(
            try bitmap.alpha(atX: 0, y: 0),
            16,
            "Platform/Apple/icon-source/icon-master-1024.png should have transparent corners so the notch icon has no white border."
        )
    }

    // Phase 19's `testAppIconMasterTransparentPixelsHaveBlackMatte` was removed
    // intentionally. It enforced a black RGB-zero matte on transparent pixels
    // because the old Xcode 26 `.icon` pipeline composited the foreground over
    // a `"fill": "system-light"` tile — the matte hack masked that leak.
    // Bough no longer uses the .icon format (see Tools/Build/regenerate-app-icon.sh
    // and debug session bough-dock-icon-white-edge.md); the new
    // .appiconset pipeline doesn't composite any tile fill, so a black matte
    // is no longer load-bearing. The stronger replacement is
    // BrandAssetPixelSamplingTests.testAppIconHasNoWhiteHaloAtRoundedRectPerimeter,
    // which scans the actual baked .icns at every size.

    func testShippedAppIconHasNoLightOpaqueOuterRing() throws {
        // NEW — reads the committed Sources/Bough/Resources/AppIcon.icns directly,
        // which is the same file actool writes. Avoids Bundle.appModule caching stale bytes.
        let url = Self.repoRoot
            .appendingPathComponent("Sources/Bough/Resources/AppIcon.icns")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.max {
            $0.pixelsWide < $1.pixelsWide
        })
        var lightOuterPixels = 0
        let outerBand = max(1, bitmap.pixelsWide / 16)

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard x < outerBand || y < outerBand || x >= bitmap.pixelsWide - outerBand || y >= bitmap.pixelsHigh - outerBand else {
                    continue
                }
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.7 else {
                    continue
                }
                if color.redComponent > 0.66, color.greenComponent > 0.66, color.blueComponent > 0.66 {
                    lightOuterPixels += 1
                }
            }
        }

        XCTAssertEqual(
            lightOuterPixels,
            0,
            "Resources/AppIcon.icns must not include a light opaque outer rim; the app icon should not render with a white ring in the notch or Settings surfaces."
        )
    }

    private static let repoRoot = TestHelpers.repoRoot(from: #filePath)

    func testFrameIndexCyclesEveryFourFrames() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0), 0)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(0.4)), 1)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(0.8)), 2)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(1.2)), 3)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(1.6)), 0)
    }

    func testFrameIndexBoundaryBehaviour() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(0.39)), 0)
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(0.41)), 1)
        // Floor semantics: 0.3995 must STAY in frame 0 — it has not crossed the
        // 0.4 s boundary yet. Earlier ms-domain `.rounded()` mapped this to
        // frame 1 prematurely (Codex P2). Microsecond resolution preserves
        // floor-style frame edges.
        XCTAssertEqual(BoughMascotView.frameIndex(for: t0.addingTimeInterval(0.3995)), 0)
    }

    func testFrameIndexNormalizesNegativeDates() {
        // Dates before the Apple reference epoch (2001-01-01) produce negative
        // `timeIntervalSinceReferenceDate`. Without `(x % cycle + cycle) % cycle`
        // normalization, the function returns -1/-2/-3 for these inputs and the
        // sprite() builder silently clamps them to frame 0 (Codex P3).
        let beforeReference = Date(timeIntervalSinceReferenceDate: -0.4)
        XCTAssertEqual(
            BoughMascotView.frameIndex(for: beforeReference), 3,
            "Negative phase must normalize into 0..<4 — t=-0.4s = 1.2s into the inverse cycle = frame 3"
        )
        let muchEarlier = Date(timeIntervalSinceReferenceDate: -1.6)
        XCTAssertEqual(
            BoughMascotView.frameIndex(for: muchEarlier), 0,
            "Negative phase exactly one cycle back must wrap to frame 0"
        )
    }
}

private extension NSBitmapImageRep {
    func alpha(atX x: Int, y: Int) throws -> CGFloat {
        let color = try XCTUnwrap(colorAt(x: x, y: y), "Missing bitmap color at \(x),\(y)")
        return color.alphaComponent * 255
    }
}
