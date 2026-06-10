import AppKit
import XCTest
import BoughCore
@testable import Bough

final class SpriteMascotRuntimeTests: XCTestCase {
    private let approvedSources = [
        "antigravity",
        "claude",
        "codebuddy",
        "codex",
        "copilot",
        "cursor",
        "droid",
        "gemini",
        "hermes",
        "kimi",
        "opencode",
        "qoder",
        "qwen",
        "stepfun",
        "trae",
        "workbuddy",
    ]

    func testCatalogReturnsAllApprovedBuiltInSourcesAndAliases() {
        for source in approvedSources {
            XCTAssertNotNil(MascotSpriteCatalog.spec(source: source, status: .idle), source)
            XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID(" \(source.uppercased()) "), source)
        }

        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("traecn"), "trae")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("traecli"), "trae")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("codybuddycn"), "codebuddy")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("cursor-cli"), "cursor")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("qoder-cli"), "qoder")
        XCTAssertEqual(MascotSpriteCatalog.spec(source: "traecli", status: .processing)?.sourceID, "trae")
        XCTAssertEqual(MascotSpriteCatalog.spec(source: "codybuddycn", status: .waitingApproval)?.sourceID, "codebuddy")
        XCTAssertEqual(MascotSpriteCatalog.spec(source: "cursor-cli", status: .waitingQuestion)?.sourceID, "cursor")
        XCTAssertEqual(MascotSpriteCatalog.spec(source: "qoder-cli", status: .running)?.sourceID, "qoder")

        XCTAssertNil(MascotSpriteCatalog.spec(source: "cline", status: .idle))
        XCTAssertNil(MascotSpriteCatalog.spec(source: "kiro", status: .running))
        XCTAssertNil(MascotSpriteCatalog.spec(source: "pi", status: .processing))
        XCTAssertNil(MascotSpriteCatalog.spec(source: "unknown", status: .waitingQuestion))
    }

    func testCatalogMapsStatusesToRuntimeStates() throws {
        XCTAssertEqual(try XCTUnwrap(MascotSpriteCatalog.spec(source: "codex", status: .idle)).state, .idle)
        XCTAssertEqual(try XCTUnwrap(MascotSpriteCatalog.spec(source: "codex", status: .processing)).state, .work)
        XCTAssertEqual(try XCTUnwrap(MascotSpriteCatalog.spec(source: "codex", status: .running)).state, .work)
        XCTAssertEqual(try XCTUnwrap(MascotSpriteCatalog.spec(source: "codex", status: .waitingApproval)).state, .alert)
        XCTAssertEqual(try XCTUnwrap(MascotSpriteCatalog.spec(source: "codex", status: .waitingQuestion)).state, .alert)
    }

    func testCatalogLocksFrameSpecs() throws {
        let idle = try XCTUnwrap(MascotSpriteCatalog.spec(source: "claude", status: .idle))
        XCTAssertEqual(idle.filename, "idle-sheet.png")
        XCTAssertEqual(idle.frameCount, 24)
        XCTAssertEqual(idle.frameInterval, 0.05)
        XCTAssertEqual(idle.dimensions, CGSize(width: 768, height: 32))

        let work = try XCTUnwrap(MascotSpriteCatalog.spec(source: "claude", status: .running))
        XCTAssertEqual(work.filename, "work-sheet.png")
        XCTAssertEqual(work.frameCount, 32)
        XCTAssertEqual(work.frameInterval, 0.01)
        XCTAssertEqual(Double(work.frameCount) * work.frameInterval, 0.32, accuracy: 0.001)
        XCTAssertEqual(work.dimensions, CGSize(width: 1024, height: 32))

        let alert = try XCTUnwrap(MascotSpriteCatalog.spec(source: "claude", status: .waitingQuestion))
        XCTAssertEqual(alert.filename, "alert-sheet.png")
        XCTAssertEqual(alert.frameCount, 32)
        XCTAssertEqual(alert.frameInterval, 0.03)
        XCTAssertEqual(Double(alert.frameCount) * alert.frameInterval, 0.96, accuracy: 0.001)
        XCTAssertEqual(alert.dimensions, CGSize(width: 1024, height: 32))
        XCTAssertEqual(alert.frameInterval / work.frameInterval, 3.0, accuracy: 0.001)
    }

    @MainActor
    func testFrameCacheSharesDecodedFramesForSameSourceStateAndScale() throws {
        let spec = try XCTUnwrap(MascotSpriteCatalog.spec(source: "cursor", status: .waitingApproval))
        MascotSpriteFrameCache.shared.clearForTesting()

        let firstLoad = try XCTUnwrap(MascotSpriteFrameCache.shared.frames(for: spec, pointSize: 32, scale: 2))
        let secondLoad = try XCTUnwrap(MascotSpriteFrameCache.shared.frames(for: spec, pointSize: 32, scale: 2))

        XCTAssertEqual(firstLoad.count, 32)
        XCTAssertEqual(firstLoad[0].width, 64)
        XCTAssertEqual(firstLoad[0].height, 64)
        XCTAssertEqual(ObjectIdentifier(firstLoad[0]), ObjectIdentifier(secondLoad[0]))
    }

    func testPlaybackPolicyStopsForHiddenSpeedOffAndReduceMotion() {
        XCTAssertEqual(
            MascotSpritePlaybackPolicy.mode(
                isVisible: false,
                mascotSpeed: 1,
                accessibilityReduceMotion: false,
                frameCount: 32
            ),
            .staticFrame
        )
        XCTAssertEqual(
            MascotSpritePlaybackPolicy.mode(
                isVisible: true,
                mascotSpeed: 0,
                accessibilityReduceMotion: false,
                frameCount: 32
            ),
            .staticFrame
        )
        XCTAssertEqual(
            MascotSpritePlaybackPolicy.mode(
                isVisible: true,
                mascotSpeed: 1,
                accessibilityReduceMotion: true,
                frameCount: 32
            ),
            .staticFrame
        )
        XCTAssertEqual(
            MascotSpritePlaybackPolicy.mode(
                isVisible: true,
                mascotSpeed: 1,
                accessibilityReduceMotion: false,
                frameCount: 32
            ),
            .animated
        )
    }

    func testMascotViewRoutesApprovedSourcesThroughSpriteAndKeepsSpriteFallback() throws {
        let source = try sourceFile("Sources/Bough/MascotView.swift")

        XCTAssertContains(source, "if let spec = MascotSpriteCatalog.spec(source: source, status: status)")
        XCTAssertContains(source, "?? MascotSpriteCatalog.fallbackSpec(status: status)")
        XCTAssertContains(source, "SpriteMascotView(spec: spec, size: size, mascotSpeed: speed)")
        XCTAssertFalse(source.contains("LayerBackedMascotView"))
        XCTAssertFalse(source.contains("layerBackedSource"))
    }

    func testCatalogResolvesMascotIconsFromApprovedResourceDirectoriesOnly() {
        for source in approvedSources {
            XCTAssertNotNil(MascotSpriteCatalog.iconURL(source: source), source)
        }
        XCTAssertNotNil(MascotSpriteCatalog.iconURL(source: "traecn"))
        XCTAssertNotNil(MascotSpriteCatalog.iconURL(source: "codybuddycn"))
        XCTAssertNotNil(MascotSpriteCatalog.iconURL(source: "cursor-cli"))
        XCTAssertNotNil(MascotSpriteCatalog.iconURL(source: "qoder-cli"))
        XCTAssertNil(MascotSpriteCatalog.iconURL(source: "pi"))
        XCTAssertNil(MascotSpriteCatalog.iconURL(source: "custom"))
    }

    func testSpriteMascotViewContainsLowPowerRuntimeHooks() throws {
        let source = try sourceFile("Sources/Bough/SpriteMascotView.swift")

        XCTAssertContains(source, "CAKeyframeAnimation(keyPath: \"contents\")")
        XCTAssertContains(source, "isHidden")
        XCTAssertContains(source, "window.isVisible")
        XCTAssertContains(source, "NSApplication.didHideNotification")
        XCTAssertContains(source, "NSApplication.didUnhideNotification")
        XCTAssertContains(source, "NSWindow.didChangeOcclusionStateNotification")
        XCTAssertContains(source, "mascotSpeed == 0")
        XCTAssertContains(source, "accessibilityReduceMotion")
        XCTAssertContains(source, ".nearest")
        XCTAssertContains(source, "removeAnimation")
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
