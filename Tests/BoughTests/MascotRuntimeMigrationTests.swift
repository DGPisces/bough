import Foundation
import XCTest

final class MascotRuntimeMigrationTests: XCTestCase {
    func testMascotViewNoLongerRoutesThroughLegacyLayerBackedRenderer() throws {
        let mascotView = try sourceFile("Sources/Bough/MascotView.swift")

        XCTAssertContains(mascotView, "MascotSpriteCatalog.spec(source: source, status: status)")
        XCTAssertContains(mascotView, "MascotSpriteCatalog.fallbackSpec(status: status)")
        XCTAssertContains(mascotView, "SpriteMascotView(spec: spec, size: size, mascotSpeed: speed)")
        XCTAssertContains(mascotView, ".frame(width: size, height: size, alignment: .center)")
        XCTAssertFalse(mascotView.contains("LayerBackedMascotView"))
        XCTAssertFalse(mascotView.contains("TimelineView"))
        XCTAssertFalse(mascotView.contains("Canvas"))
        XCTAssertFalse(mascotView.contains("Timer"))
    }

    func testLegacyHandwrittenMascotViewsAreRemoved() {
        let removedFiles = [
            "AntiGravityView.swift",
            "BuddyView.swift",
            "CopilotView.swift",
            "CursorView.swift",
            "DexView.swift",
            "DroidView.swift",
            "GeminiView.swift",
            "HermesView.swift",
            "KimiView.swift",
            "LayerBackedMascotView.swift",
            "OpenCodeView.swift",
            "PixelCharacterView.swift",
            "QoderView.swift",
            "QwenView.swift",
            "StepFunView.swift",
            "TraeView.swift",
            "WorkBuddyView.swift",
        ]

        for filename in removedFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/Bough/\(filename)").path),
                "\(filename) should not remain after sprite runtime migration."
            )
        }
    }

    func testCliIconUsesMascotIconResourcesAndOldCliIconsAreRemoved() throws {
        let source = try sourceFile("Sources/Bough/NotchPanelView.swift")

        XCTAssertContains(source, "MascotSpriteCatalog.normalizedApprovedSourceID(source)")
        XCTAssertContains(source, "MascotSpriteCatalog.iconURL(source: source)")
        XCTAssertFalse(source.contains("cliIconFiles"))
        XCTAssertFalse(source.contains("Resources/cli-icons"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Sources/Bough/Resources/cli-icons").path),
            "Old cli-icons resource directory should be removed after mascot icon migration."
        )
    }

    func testNoDirectCallSitesBypassSpriteMascotRouter() throws {
        let sources = repoRoot.appendingPathComponent("Sources/Bough")
        let directMascotCalls = [
            "AntiGravityView(",
            "BuddyView(",
            "CopilotView(",
            "CursorView(",
            "DexView(",
            "DroidView(",
            "GeminiView(",
            "HermesView(",
            "KimiView(",
            "OpenCodeView(",
            "QoderView(",
            "QwenView(",
            "StepFunView(",
            "TraeView(",
            "WorkBuddyView(",
            "ClawdView(",
            "LayerBackedMascotView(",
        ]
        let urls = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var bypasses: [String] = []
        for url in urls {
            let source = try String(contentsOf: url, encoding: .utf8)
            for call in directMascotCalls where source.contains(call) {
                bypasses.append("\(url.path): \(call)")
            }
        }

        XCTAssertTrue(bypasses.isEmpty, "Mascots must render through MascotView/SpriteMascotView: \(bypasses)")
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
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

    private var repoRoot: URL {
        TestHelpers.repoRoot(from: #filePath)
    }
}
