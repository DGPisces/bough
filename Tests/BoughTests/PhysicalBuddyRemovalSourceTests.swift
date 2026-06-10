import Foundation
import XCTest

final class PhysicalBuddyRemovalSourceTests: XCTestCase {
    func testRuntimePhysicalBuddyImplementationIsRemoved() throws {
        let forbiddenTokens = [
            "ESP32",
            "CoreBluetooth",
            "CBCentralManager",
            "CBPeripheral",
            "CBUUID",
            "CBCharacteristic",
            "BuddyLaunchPolicy",
            "BuddyLaunchCoordinator",
            "ESP32BridgeManager",
            "ESP32StatePublisher",
            "ESP32FocusCoordinator",
            "BuddyControlCommand",
            "BuddyUplinkEvent",
            "BuddyScreenOrientation",
        ]

        try assertNoForbiddenTokens(
            forbiddenTokens,
            in: [
                "Package.swift",
                "Sources/Bough",
                "Sources/BoughCore",
            ],
            reason: "Physical Buddy runtime, ESP32, CoreBluetooth, launch, publisher, focus, and control paths must be removed."
        )
    }

    func testSettingsAndPlatformPhysicalBuddySurfaceIsRemoved() throws {
        let forbiddenTokens = [
            "SettingsPage.buddy",
            "case buddy",
            ".buddy",
            "BuddyPage",
            "buddy_enable_bluetooth",
            "buddy_connection_status",
            "buddy_select_section",
            "buddy_screen_orientation",
            "NSBluetoothAlwaysUsageDescription",
            "com.apple.security.device.bluetooth",
            "ESP32BridgeManager",
            "ESP32StatePublisher",
            "CoreBluetooth",
            "BuddyScreenOrientation",
        ]

        try assertNoForbiddenTokens(
            forbiddenTokens,
            in: [
                "Sources/Bough/Settings/SettingsNavigationModel.swift",
                "Sources/Bough/Settings/SettingsSearchIndex.swift",
                "Sources/Bough/Settings/SettingsTargetHighlight.swift",
                "Sources/Bough/SettingsView.swift",
                "Platform/Apple/Info.plist",
                "Platform/Apple/Bough.entitlements",
            ],
            reason: "Settings route/UI/search/platform metadata must not expose physical Buddy or Bluetooth surface."
        )
    }

    func testPhysicalBuddyLocalizationAndTestsAreRemoved() throws {
        let removedPhysicalTestFiles = [
            "Tests/BoughTests/BuddyLaunchPolicyTests.swift",
            "Tests/BoughCoreTests/ESP32ProtocolTests.swift",
        ]

        for relativePath in removedPhysicalTestFiles {
            XCTAssertFalse(
                fileExists(relativePath),
                "\(relativePath) should be removed with the physical Buddy feature."
            )
        }

        let forbiddenTokens = [
            "\"buddy\"",
            "\"buddy_",
            "BuddyLaunchPolicy",
            "ESP32Protocol",
            "BuddyControlCommand",
            "BuddyUplinkEvent",
            "BuddyScreenOrientation",
        ]

        try assertNoForbiddenTokens(
            forbiddenTokens,
            in: [
                "Sources/Bough/L10n.swift",
                "Tests/BoughTests",
                "Tests/BoughCoreTests",
            ],
            reason: "Physical Buddy localization keys and hardware tests must be removed."
        )
    }

    func testLegacyPhysicalBuddyDefaultsAreOnlyInCleanupFiles() throws {
        let legacyKeys = [
            "esp32BridgeEnabled",
            "esp32HeartbeatSeconds",
            "buddyScreenBrightnessPercent",
            "buddyScreenOrientation",
            "selectedBuddyIdentifier",
            "selectedBuddyName",
        ]

        try assertNoForbiddenTokens(
            legacyKeys,
            in: [
                "Sources/Bough",
                "Sources/BoughCore",
                "Tests/BoughTests",
                "Tests/BoughCoreTests",
                "Package.swift",
            ],
            allowedRelativePaths: [
                "Sources/Bough/Settings/PhysicalBuddyDefaultsCleanup.swift",
                "Tests/BoughTests/PhysicalBuddyDefaultsCleanupTests.swift",
            ],
            reason: "Legacy physical Buddy UserDefaults keys may remain only as raw cleanup keys."
        )
    }

    private func assertNoForbiddenTokens(
        _ tokens: [String],
        in relativePaths: [String],
        allowedRelativePaths: Set<String> = [],
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var matches: [String] = []

        for sourceFile in try sourceFiles(in: relativePaths) {
            let relativePath = sourceFile.relativePath
            guard !allowedRelativePaths.contains(relativePath) else {
                continue
            }

            let source = try String(contentsOf: sourceFile.url, encoding: .utf8)
            for token in tokens where source.contains(token) {
                matches.append(contentsOf: lineMatches(
                    token: token,
                    source: source,
                    relativePath: relativePath
                ))
            }
        }

        XCTAssertTrue(
            matches.isEmpty,
            "\(reason)\nUnexpected matches:\n\(matches.prefix(80).joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    private func lineMatches(
        token: String,
        source: String,
        relativePath: String
    ) -> [String] {
        var matches: [String] = []
        var lineNumber = 0
        source.enumerateLines { line, stop in
            lineNumber += 1
            guard line.contains(token) else { return }
            matches.append("\(relativePath):\(lineNumber): \(token)")
            if matches.count >= 120 {
                stop = true
            }
        }
        return matches
    }

    private func sourceFiles(in relativePaths: [String]) throws -> [SourceFile] {
        let files = try relativePaths.flatMap { relativePath in
            try sourceFiles(at: repoRoot.appendingPathComponent(relativePath))
        }

        return files
            .filter { !isExcluded($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    private func sourceFiles(at url: URL) throws -> [SourceFile] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        _ = try XCTUnwrap(exists ? url : nil, "Missing source scan path: \(url.path)")

        if !isDirectory.boolValue {
            let scannable = isScannableSource(url)
            _ = try XCTUnwrap(scannable ? url : nil, "Unexpected non-scannable source path: \(url.path)")
            return [SourceFile(url: url.standardizedFileURL, relativePath: relativePath(for: url))]
        }

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ), "Failed to enumerate source scan root: \(url.path)")

        var files: [SourceFile] = []
        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL
            let relativePath = self.relativePath(for: standardized)
            if isExcluded(relativePath) {
                enumerator.skipDescendants()
                continue
            }

            let values = try standardized.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, isScannableSource(standardized) else {
                continue
            }
            files.append(SourceFile(url: standardized, relativePath: relativePath))
        }
        XCTAssertFalse(files.isEmpty, "Source scan must include files under \(url.path).")
        return files
    }

    private func isScannableSource(_ url: URL) -> Bool {
        if url.lastPathComponent == "Package.swift" {
            return true
        }
        switch url.pathExtension {
        case "swift", "plist", "entitlements":
            return true
        default:
            return false
        }
    }

    private func isExcluded(_ relativePath: String) -> Bool {
        let planningPrefix = ".pla" + "nning/"
        return relativePath == Self.sourceGuardRelativePath
            || relativePath.hasPrefix(planningPrefix)
            || relativePath.hasPrefix(".build/")
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path)
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = repoRoot.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return filePath
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private var repoRoot: URL {
        TestHelpers.repoRoot(from: #filePath)
    }

    private static let sourceGuardRelativePath = "Tests/BoughTests/PhysicalBuddyRemovalSourceTests.swift"

    private struct SourceFile {
        let url: URL
        let relativePath: String
    }
}
