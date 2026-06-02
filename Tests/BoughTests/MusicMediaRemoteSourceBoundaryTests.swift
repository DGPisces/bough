import Foundation
import XCTest
@testable import Bough

final class MusicMediaRemoteSourceBoundaryTests: XCTestCase {
    func testMediaRemoteSymbolsAreConfinedToSingleAppTargetAdapter() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let allowedFiles: Set<String> = [
            "Sources/Bough/Music/MediaRemoteNowPlayingService.swift",
        ]
        let forbiddenTokens = ["MediaRemote", "MRMediaRemote", "dlopen", "dlsym"]

        for path in try swiftFiles(under: repoRoot.appendingPathComponent("Sources")) {
            let relativePath = path.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let source = try String(contentsOf: path, encoding: .utf8)
            guard forbiddenTokens.contains(where: source.contains) else {
                continue
            }
            XCTAssertTrue(allowedFiles.contains(relativePath), "Unexpected private music token in \(relativePath)")
        }
    }

    func testMediaRemoteDoesNotReachCoreHelpersScriptsOrPackage() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let scannedPaths = [
            "Package.swift",
            "Sources/BoughCore",
            "Sources/BoughBridge",
            "Sources/BoughUsageMonitor",
        ]
        for relativePath in scannedPaths {
            let url = repoRoot.appendingPathComponent(relativePath)
            let source = try sourceText(at: url)
            XCTAssertFalse(source.contains("MediaRemote"), relativePath)
            XCTAssertFalse(source.contains("MRMediaRemote"), relativePath)
            XCTAssertFalse(source.contains("dlopen"), relativePath)
            XCTAssertFalse(source.contains("dlsym"), relativePath)
        }
    }

    func testPackageKeepsMediaRemoteOutOfLinkedDependencies() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertFalse(package.contains("MediaRemote"))
        XCTAssertFalse(package.contains("PrivateFrameworks"))
    }

    func testIslandSurfaceDoesNotAddMusicCase() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let source = try sourceText(at: repoRoot.appendingPathComponent("Sources/Bough/IslandSurface.swift"))

        XCTAssertFalse(source.contains("IslandSurface.music"))
        XCTAssertFalse(source.contains("case music"))
    }

    func testAppStateInjectsAdapterBehindMusicServiceProtocol() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let appState = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/AppState.swift"), encoding: .utf8)
        let adapter = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"), encoding: .utf8)

        XCTAssertTrue(appState.contains("var musicStore = MusicNowPlayingStore.live()"))
        XCTAssertTrue(adapter.contains("static func live() -> MusicNowPlayingStore"))
        XCTAssertTrue(adapter.contains("MusicNowPlayingStore(service: MediaRemoteNowPlayingService())"))
    }

    func testAdapterDoesNotCallUnsafeMediaRemoteDisplayNameABI() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let adapter = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"), encoding: .utf8)

        XCTAssertFalse(adapter.contains("MRMediaRemoteGetNowPlayingApplicationDisplayName"))
        XCTAssertTrue(adapter.contains("objectValue(from: client, selector: \"displayName\")"))
    }

    func testAdapterUsesNowPlayingRequestMetadataBeforeLegacyPlaybackQueue() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let adapter = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"), encoding: .utf8)

        XCTAssertTrue(adapter.contains("NSClassFromString(\"MRNowPlayingRequest\")"))
        XCTAssertTrue(adapter.contains("Bundle(path: frameworkBundlePath)?.load()"))
        XCTAssertTrue(adapter.contains("localNowPlayingItem"))
        XCTAssertTrue(adapter.contains("localNowPlayingPlayerPath"))
        XCTAssertTrue(adapter.contains("requestPayload.hasDisplayableMediaRemoteMetadata"))
    }

    func testAdapterFallsBackThroughOSAScriptWhenBundledProcessIsDeniedMetadata() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let adapter = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"), encoding: .utf8)

        XCTAssertTrue(adapter.contains("OSAScriptNowPlayingPayloadReader"))
        XCTAssertTrue(adapter.contains("URL(fileURLWithPath: \"/usr/bin/osascript\")"))
        XCTAssertTrue(adapter.contains("JSONDecoder().decode(DecodedPayload.self"))
        XCTAssertTrue(adapter.contains("playbackStateValue: numberFromValue(unwrap(request.localPlaybackState))"))
        XCTAssertTrue(adapter.contains("QQMusicArtworkResolver"))
        XCTAssertTrue(adapter.contains("albumMidCache"))
        XCTAssertFalse(adapter.contains("prefersScriptPayload"))

        let nativeRange = try XCTUnwrap(adapter.range(of: "if let requestPayload = currentRequestPayload()"))
        let scriptRange = try XCTUnwrap(
            adapter.range(of: "if let scriptPayload = await scriptPayloadReader.currentPayload(")
        )
        XCTAssertLessThan(
            adapter.distance(from: adapter.startIndex, to: nativeRange.lowerBound),
            adapter.distance(from: adapter.startIndex, to: scriptRange.lowerBound)
        )
    }

    func testAdapterUsesDedicatedMediaRemoteQueue() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let adapter = try String(contentsOf: repoRoot.appendingPathComponent("Sources/Bough/Music/MediaRemoteNowPlayingService.swift"), encoding: .utf8)

        XCTAssertTrue(adapter.contains("DispatchQueue(label: \"dev.dgpisces.bough.media-remote\")"))
        XCTAssertTrue(adapter.contains("getInfo(mediaRemoteQueue, block)"))
        XCTAssertTrue(adapter.contains("function(mediaRemoteQueue, block)"))
        XCTAssertTrue(adapter.contains("getApplicationPlaybackState(mediaRemoteQueue, block)"))
        XCTAssertFalse(adapter.contains("getInfo(.main, block)"))
        XCTAssertFalse(adapter.contains("getApplicationPlaybackState(.main, block)"))
    }

    func testNoMusicMetadataPersistenceKeysAreAdded() throws {
        let repoRoot = TestHelpers.repoRoot(from: #filePath)
        let scannedPaths = [
            "Sources/Bough/Settings.swift",
            "Sources/Bough/DiagnosticsExporter.swift",
            "Sources/BoughBridge",
            "Sources/BoughUsageMonitor",
        ]
        let forbidden = [
            "musicTitle",
            "musicArtist",
            "musicAlbum",
            "musicArtwork",
            "musicLyric",
            "playerBundleIdentifier",
            "musicCommandHistory",
        ]

        for relativePath in scannedPaths {
            let source = try sourceText(at: repoRoot.appendingPathComponent(relativePath))
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(token) in \(relativePath)")
            }
        }
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return result
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private func sourceText(at url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ""
        }
        if !isDirectory.boolValue {
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
            return ""
        }
        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
