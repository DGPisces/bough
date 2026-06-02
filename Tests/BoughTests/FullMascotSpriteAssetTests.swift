import AppKit
import XCTest
@testable import Bough

final class FullMascotSpriteAssetTests: XCTestCase {
    private let phase80Sources = [
        "gemini",
        "trae",
        "copilot",
        "qoder",
        "droid",
        "codebuddy",
        "stepfun",
        "antigravity",
        "workbuddy",
        "hermes",
        "qwen",
        "kimi",
        "opencode",
    ]
    private let expectedFiles = [
        "alert-sheet.png",
        "icon.png",
        "idle-sheet.png",
        "work-sheet.png",
    ]
    private var allSources: [String] {
        (phase80Sources + ["codex", "claude", "cursor"]).sorted()
    }
    private let closedEyeSamplePoints: [String: [(Int, Int)]] = [
        "antigravity": [(11, 16), (19, 16)],
        "claude": [(12, 16), (19, 16)],
        "codebuddy": [(11, 15), (19, 15)],
        "codex": [(13, 16), (19, 16)],
        "copilot": [(9, 16), (19, 16)],
        "cursor": [(11, 19), (19, 19)],
        "droid": [(11, 15), (21, 15)],
        "gemini": [(11, 15), (22, 15)],
        "hermes": [(10, 16), (20, 16)],
        "kimi": [(16, 16)],
        "opencode": [(10, 15)],
        "qoder": [(17, 16)],
        "qwen": [(17, 16)],
        "stepfun": [(11, 15), (18, 15)],
        "trae": [(13, 15), (19, 15)],
        "workbuddy": [(15, 15)],
    ]

    func testAllBuiltInMascotResourceDirectoriesExist() throws {
        let resourcesRoot = TestHelpers.repoRoot(from: #filePath)
            .appendingPathComponent("Sources/Bough/Resources/mascots")
        let names = try FileManager.default.contentsOfDirectory(
            at: resourcesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .map(\.lastPathComponent)

        let expected = Set(phase80Sources + ["codex", "claude", "cursor"])
        XCTAssertEqual(Set(names), expected)
    }

    func testPhase80MascotResourcesContainOnlyExpectedFiles() throws {
        let resourcesRoot = TestHelpers.repoRoot(from: #filePath)
            .appendingPathComponent("Sources/Bough/Resources/mascots")

        for source in phase80Sources {
            let sourceURL = resourcesRoot.appendingPathComponent(source)
            let names = try FileManager.default.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .sorted()

            XCTAssertEqual(names, expectedFiles, "\(source) should contain only runtime PNG assets.")
        }
    }

    func testPhase80MascotPNGsResolveViaAppModule() throws {
        for source in phase80Sources {
            for filename in expectedFiles {
                let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
                let url = Bundle.appModule.url(
                    forResource: parts[0],
                    withExtension: parts[1],
                    subdirectory: "Resources/mascots/\(source)"
                )

                XCTAssertNotNil(url, "\(source)/\(filename) should resolve from Bundle.appModule.")
            }
        }
    }

    func testPhase80MascotSpriteSheetDimensions() throws {
        let expectedSizes: [String: CGSize] = [
            "icon.png": CGSize(width: 32, height: 32),
            "idle-sheet.png": CGSize(width: 768, height: 32),
            "work-sheet.png": CGSize(width: 1024, height: 32),
            "alert-sheet.png": CGSize(width: 1024, height: 32),
        ]

        for source in phase80Sources {
            for filename in expectedFiles {
                let bitmap = try loadBitmap(source: source, filename: filename)
                let expected = try XCTUnwrap(expectedSizes[filename])

                XCTAssertEqual(bitmap.pixelsWide, Int(expected.width), "\(source)/\(filename) width")
                XCTAssertEqual(bitmap.pixelsHigh, Int(expected.height), "\(source)/\(filename) height")
            }
        }
    }

    func testPhase80MascotSpriteSheetsHaveTransparentFirstFrameCorners() throws {
        for source in phase80Sources {
            for filename in expectedFiles {
                let bitmap = try loadBitmap(source: source, filename: filename)

                XCTAssertLessThan(bitmap.phase80Alpha(atX: 0, y: 0), 16, "\(source)/\(filename) first-frame top-left should be transparent.")
                XCTAssertLessThan(bitmap.phase80Alpha(atX: 31, y: 0), 16, "\(source)/\(filename) first-frame top-right should be transparent.")
                XCTAssertLessThan(bitmap.phase80Alpha(atX: 0, y: 31), 16, "\(source)/\(filename) first-frame bottom-left should be transparent.")
                XCTAssertLessThan(bitmap.phase80Alpha(atX: 31, y: 31), 16, "\(source)/\(filename) first-frame bottom-right should be transparent.")
            }
        }
    }

    func testPhase80MascotSpriteSheetsCloseLoops() throws {
        for source in allSources {
            for filename in ["idle-sheet.png", "work-sheet.png", "alert-sheet.png"] {
                let bitmap = try loadBitmap(source: source, filename: filename)
                assertFirstFrameMatchesLastFrame(bitmap, "\(source)/\(filename)")
            }
        }
    }

    func testIdleMascotsWithEyesUseClosedEyeOverlay() throws {
        XCTAssertEqual(Set(closedEyeSamplePoints.keys), Set(allSources))

        for source in allSources {
            let icon = try loadBitmap(source: source, filename: "icon.png")
            let idle = try loadBitmap(source: source, filename: "idle-sheet.png")
            let points = try XCTUnwrap(closedEyeSamplePoints[source])

            for (x, y) in points {
                assertPixelChanged(
                    from: icon.phase80Color(atX: x, y: y),
                    to: idle.phase80Color(atX: x, y: y),
                    "\(source) idle closed-eye sample @ \(x),\(y)"
                )
            }
        }
    }

    func testWorkMascotsUseSubtleVerticalBobbing() throws {
        for source in allSources {
            let work = try loadBitmap(source: source, filename: "work-sheet.png")
            let sampledFrames = [0, 8, 16, 24, 31]
            let minYs = sampledFrames.compactMap { bodyMinY(in: work, frameIndex: $0) }
            let bobRange = (minYs.max() ?? 0) - (minYs.min() ?? 0)

            XCTAssertEqual(minYs.count, sampledFrames.count, "\(source)/work-sheet.png should have visible body pixels in sampled frames.")
            XCTAssertGreaterThan(Set(minYs).count, 1, "\(source)/work-sheet.png should bob vertically.")
            XCTAssertLessThanOrEqual(bobRange, 2, "\(source)/work-sheet.png bob should stay subtle.")
        }
    }

    private func loadBitmap(source: String, filename: String) throws -> NSBitmapImageRep {
        let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
        let url = try XCTUnwrap(Bundle.appModule.url(
            forResource: parts[0],
            withExtension: parts[1],
            subdirectory: "Resources/mascots/\(source)"
        ))
        let data = try Data(contentsOf: url)

        return try XCTUnwrap(NSBitmapImageRep(data: data), "\(source)/\(filename) should be readable PNG data.")
    }

    private func bodyMinY(in bitmap: NSBitmapImageRep, frameIndex: Int) -> Int? {
        let frameX = frameIndex * 32
        var minY: Int?

        for y in 0..<32 {
            for x in 0..<32 {
                if x >= 21 && y <= 13 {
                    continue
                }
                if bitmap.phase80Alpha(atX: frameX + x, y: y) >= 16 {
                    minY = min(minY ?? y, y)
                }
            }
        }

        return minY
    }

    private func assertFirstFrameMatchesLastFrame(
        _ bitmap: NSBitmapImageRep,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lastFrameX = bitmap.pixelsWide - 32
        for y in 0..<32 {
            for x in 0..<32 {
                let first = bitmap.phase80Color(atX: x, y: y)
                let last = bitmap.phase80Color(atX: lastFrameX + x, y: y)
                XCTAssertEqual(first.redComponent, last.redComponent, accuracy: 0.001, "\(message()) red @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.greenComponent, last.greenComponent, accuracy: 0.001, "\(message()) green @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.blueComponent, last.blueComponent, accuracy: 0.001, "\(message()) blue @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.alphaComponent, last.alphaComponent, accuracy: 0.001, "\(message()) alpha @ \(x),\(y)", file: file, line: line)
            }
        }
    }

    private func assertPixelChanged(
        from original: NSColor,
        to updated: NSColor,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let changed = abs(original.redComponent - updated.redComponent) > 0.001
            || abs(original.greenComponent - updated.greenComponent) > 0.001
            || abs(original.blueComponent - updated.blueComponent) > 0.001
            || abs(original.alphaComponent - updated.alphaComponent) > 0.001
        XCTAssertTrue(changed, message(), file: file, line: line)
    }
}

private extension NSBitmapImageRep {
    func phase80Alpha(atX x: Int, y: Int) -> CGFloat {
        phase80Color(atX: x, y: y).alphaComponent * 255
    }

    func phase80Color(atX x: Int, y: Int) -> NSColor {
        colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
    }
}
