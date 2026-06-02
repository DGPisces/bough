import AppKit
import XCTest
@testable import Bough

final class PilotMascotSpriteAssetTests: XCTestCase {
    private let sources = ["codex", "claude", "cursor"]
    private let expectedFiles = [
        "alert-sheet.png",
        "icon.png",
        "idle-sheet.png",
        "work-sheet.png",
    ]

    func testPilotMascotResourcesContainOnlyExpectedFiles() throws {
        let resourcesRoot = TestHelpers.repoRoot(from: #filePath)
            .appendingPathComponent("Sources/Bough/Resources/mascots")

        for source in sources {
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

    func testPilotMascotPNGsResolveViaAppModule() throws {
        for source in sources {
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

    func testPilotMascotSpriteSheetDimensions() throws {
        let expectedSizes: [String: CGSize] = [
            "icon.png": CGSize(width: 32, height: 32),
            "idle-sheet.png": CGSize(width: 768, height: 32),
            "work-sheet.png": CGSize(width: 1024, height: 32),
            "alert-sheet.png": CGSize(width: 1024, height: 32),
        ]

        for source in sources {
            for filename in expectedFiles {
                let bitmap = try loadBitmap(source: source, filename: filename)
                let expected = try XCTUnwrap(expectedSizes[filename])

                XCTAssertEqual(bitmap.pixelsWide, Int(expected.width), "\(source)/\(filename) width")
                XCTAssertEqual(bitmap.pixelsHigh, Int(expected.height), "\(source)/\(filename) height")
            }
        }
    }

    func testPilotMascotSpriteSheetsHaveTransparentFirstFrameCorners() throws {
        for source in sources {
            for filename in expectedFiles {
                let bitmap = try loadBitmap(source: source, filename: filename)

                XCTAssertLessThan(bitmap.alpha(atX: 0, y: 0), 16, "\(source)/\(filename) first-frame top-left should be transparent.")
                XCTAssertLessThan(bitmap.alpha(atX: 31, y: 0), 16, "\(source)/\(filename) first-frame top-right should be transparent.")
                XCTAssertLessThan(bitmap.alpha(atX: 0, y: 31), 16, "\(source)/\(filename) first-frame bottom-left should be transparent.")
                XCTAssertLessThan(bitmap.alpha(atX: 31, y: 31), 16, "\(source)/\(filename) first-frame bottom-right should be transparent.")
            }
        }
    }

    func testPilotMascotSpriteSheetsCloseLoops() throws {
        for source in sources {
            for filename in ["idle-sheet.png", "work-sheet.png", "alert-sheet.png"] {
                let bitmap = try loadBitmap(source: source, filename: filename)
                assertFirstFrameMatchesLastFrame(bitmap, "\(source)/\(filename)")
            }
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

    private func assertFirstFrameMatchesLastFrame(
        _ bitmap: NSBitmapImageRep,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lastFrameX = bitmap.pixelsWide - 32
        for y in 0..<32 {
            for x in 0..<32 {
                let first = bitmap.rgbColor(atX: x, y: y)
                let last = bitmap.rgbColor(atX: lastFrameX + x, y: y)
                XCTAssertEqual(first.redComponent, last.redComponent, accuracy: 0.001, "\(message()) red @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.greenComponent, last.greenComponent, accuracy: 0.001, "\(message()) green @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.blueComponent, last.blueComponent, accuracy: 0.001, "\(message()) blue @ \(x),\(y)", file: file, line: line)
                XCTAssertEqual(first.alphaComponent, last.alphaComponent, accuracy: 0.001, "\(message()) alpha @ \(x),\(y)", file: file, line: line)
            }
        }
    }
}

private extension NSBitmapImageRep {
    func alpha(atX x: Int, y: Int) -> CGFloat {
        rgbColor(atX: x, y: y).alphaComponent * 255
    }

    func rgbColor(atX x: Int, y: Int) -> NSColor {
        colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
    }
}
