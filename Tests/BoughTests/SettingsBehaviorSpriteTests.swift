import AppKit
import XCTest
@testable import Bough

final class SettingsBehaviorSpriteTests: XCTestCase {
    func testApprovedSettingsBehaviorResourcesResolveViaAppModule() throws {
        for animation in SettingsBehaviorAnimation.allCases {
            let spec = try XCTUnwrap(SettingsBehaviorSpriteCatalog.spec(animation: animation))
            let parts = spec.filename.split(separator: ".", maxSplits: 1).map(String.init)
            let url = Bundle.appModule.url(
                forResource: parts[0],
                withExtension: parts[1],
                subdirectory: spec.resourceSubdirectory
            )

            XCTAssertNotNil(url, "\(spec.filename) should resolve from Bundle.appModule.")
        }
    }

    func testSettingsBehaviorCatalogLocksSpriteSpecs() throws {
        XCTAssertEqual(SettingsBehaviorAnimation.allCases.map(\.rawValue), [
            "hideFullscreen",
            "hideNoSession",
            "collapseMouseLeave",
            "clickJumpCollapse",
            "completionExpand",
            "hapticHover",
        ])

        for animation in SettingsBehaviorAnimation.allCases {
            let spec = try XCTUnwrap(SettingsBehaviorSpriteCatalog.spec(animation: animation))
            XCTAssertEqual(spec.filename, "\(animation.rawValue)-sheet.png")
            XCTAssertEqual(spec.resourceSubdirectory, "Resources/settings-animations")
            XCTAssertEqual(spec.frameSize, CGSize(width: 144, height: 96))
            XCTAssertEqual(spec.frameCount, 48)
            XCTAssertEqual(spec.frameInterval, 1.0 / 24.0)
            XCTAssertEqual(spec.dimensions, CGSize(width: 6912, height: 96))
        }
    }

    func testSettingsBehaviorSpriteSheetDimensionsAndLoopClosure() throws {
        for animation in SettingsBehaviorAnimation.allCases {
            let bitmap = try loadBitmap(animation: animation)

            XCTAssertEqual(bitmap.pixelsWide, 6912, "\(animation.rawValue) width")
            XCTAssertEqual(bitmap.pixelsHigh, 96, "\(animation.rawValue) height")
            XCTAssertTrue(hasTransparentPixel(bitmap), "\(animation.rawValue) should keep a transparent sprite-sheet background.")
            assertFirstFrameMatchesLastFrame(bitmap, "\(animation.rawValue)-sheet.png")
        }
    }

    @MainActor
    func testSettingsBehaviorFrameCacheSharesDecodedFramesForSameAnimationAndScale() throws {
        let spec = try XCTUnwrap(SettingsBehaviorSpriteCatalog.spec(animation: .hideNoSession))
        SettingsBehaviorSpriteFrameCache.shared.clearForTesting()

        let firstLoad = try XCTUnwrap(SettingsBehaviorSpriteFrameCache.shared.frames(
            for: spec,
            pointSize: CGSize(width: 144, height: 96),
            scale: 2
        ))
        let secondLoad = try XCTUnwrap(SettingsBehaviorSpriteFrameCache.shared.frames(
            for: spec,
            pointSize: CGSize(width: 144, height: 96),
            scale: 2
        ))

        XCTAssertEqual(firstLoad.count, 48)
        XCTAssertEqual(firstLoad[0].width, 288)
        XCTAssertEqual(firstLoad[0].height, 192)
        XCTAssertEqual(ObjectIdentifier(firstLoad[0]), ObjectIdentifier(secondLoad[0]))
    }

    func testSettingsBehaviorPlaybackPolicyStopsForHiddenAndReduceMotion() {
        XCTAssertEqual(
            SettingsBehaviorSpritePlaybackPolicy.mode(
                isVisible: false,
                accessibilityReduceMotion: false,
                frameCount: 48
            ),
            .staticFrame
        )
        XCTAssertEqual(
            SettingsBehaviorSpritePlaybackPolicy.mode(
                isVisible: true,
                accessibilityReduceMotion: true,
                frameCount: 48
            ),
            .staticFrame
        )
        XCTAssertEqual(
            SettingsBehaviorSpritePlaybackPolicy.mode(
                isVisible: true,
                accessibilityReduceMotion: false,
                frameCount: 1
            ),
            .staticFrame
        )
        XCTAssertEqual(
            SettingsBehaviorSpritePlaybackPolicy.mode(
                isVisible: true,
                accessibilityReduceMotion: false,
                frameCount: 48
            ),
            .animated
        )
    }

    func testSettingsViewUsesLayerBackedBehaviorSpritesAndCorrectCompletionMapping() throws {
        let source = try sourceFile("Sources/Bough/SettingsView.swift")

        XCTAssertContains(source, "SettingsBehaviorSpriteView(animation: animation, size: BehaviorToggleRowMetrics.previewSize)")
        XCTAssertContains(source, ".frame(width: BehaviorToggleRowMetrics.previewSize.width, height: BehaviorToggleRowMetrics.previewSize.height)")
        XCTAssertContains(source, ".padding(.leading, BehaviorToggleRowMetrics.secondaryControlLeadingPadding)")
        XCTAssertFalse(source.contains(".padding(.leading, 84)"))
        XCTAssertFalse(source.contains("NotchMiniAnim"))
        XCTAssertFalse(source.contains("TimelineView(.periodic"))
        assertSessionDisplayCompletionPreviewUsesCompletionExpand(source)
    }

    private func loadBitmap(animation: SettingsBehaviorAnimation) throws -> NSBitmapImageRep {
        let spec = try XCTUnwrap(SettingsBehaviorSpriteCatalog.spec(animation: animation))
        let parts = spec.filename.split(separator: ".", maxSplits: 1).map(String.init)
        let url = try XCTUnwrap(Bundle.appModule.url(
            forResource: parts[0],
            withExtension: parts[1],
            subdirectory: spec.resourceSubdirectory
        ))
        let data = try Data(contentsOf: url)

        return try XCTUnwrap(NSBitmapImageRep(data: data), "\(spec.filename) should be readable PNG data.")
    }

    private func hasTransparentPixel(_ bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where bitmap.settingsBehaviorColor(atX: x, y: y).alphaComponent < 0.001 {
                return true
            }
        }
        return false
    }

    private func assertFirstFrameMatchesLastFrame(
        _ bitmap: NSBitmapImageRep,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frameWidth = 144
        let lastFrameX = bitmap.pixelsWide - frameWidth
        for y in 0..<96 {
            for x in 0..<frameWidth {
                let first = bitmap.settingsBehaviorColor(atX: x, y: y)
                let last = bitmap.settingsBehaviorColor(atX: lastFrameX + x, y: y)
                XCTAssertEqual(first.redComponent, last.redComponent, accuracy: 0.001, "\(message()) red @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.greenComponent, last.greenComponent, accuracy: 0.001, "\(message()) green @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.blueComponent, last.blueComponent, accuracy: 0.001, "\(message()) blue @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.alphaComponent, last.alphaComponent, accuracy: 0.001, "\(message()) alpha @ \(x),\(y)", file: file, line: line)
            }
        }
    }

    private func assertSessionDisplayCompletionPreviewUsesCompletionExpand(
        _ source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let targetRange = source.range(of: "targetID: .sessionDisplayAutoExpandOnCompletion") else {
            return XCTFail("Expected session display completion target ID.", file: file, line: line)
        }
        let start = source.index(targetRange.lowerBound, offsetBy: -300, limitedBy: source.startIndex) ?? source.startIndex
        let block = String(source[start..<targetRange.lowerBound])

        XCTAssertContains(block, "animation: .completionExpand", file: file, line: line)
        XCTAssertFalse(block.contains("animation: .collapseMouseLeave"), file: file, line: line)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func XCTAssertContains(
        _ source: String,
        _ token: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(source.contains(token), "Expected source to contain \(token).", file: file, line: line)
    }
}

private extension NSBitmapImageRep {
    func settingsBehaviorColor(atX x: Int, y: Int) -> NSColor {
        colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
    }
}
