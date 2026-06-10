import Foundation
import XCTest
@testable import Bough

final class PhysicalBuddyDefaultsCleanupTests: XCTestCase {
    func testCleanupHelperDeclaresInjectedOneTimeLegacyKeyCleanupContract() throws {
        let cleanupSource = try cleanupSource()

        XCTAssertContains(
            cleanupSource,
            "UserDefaults",
            "Cleanup must operate against injected UserDefaults so tests can use an isolated suite."
        )
        XCTAssertContains(
            cleanupSource,
            "defaults: UserDefaults",
            "Cleanup must accept an injected defaults store instead of hard-coding .standard."
        )
        XCTAssertContains(
            cleanupSource,
            "physicalBuddyDefaultsCleanup",
            "Cleanup must persist a one-time sentinel so legacy key removal is idempotent."
        )
        XCTAssertContains(
            cleanupSource,
            "removeObject(forKey:",
            "Cleanup must remove the exact stale physical Buddy defaults."
        )
        XCTAssertContains(
            cleanupSource,
            "set(true",
            "Cleanup must mark the one-time sentinel after stale keys are removed."
        )

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            XCTAssertContains(
                cleanupSource,
                "\"\(key)\"",
                "Cleanup must list \(key) as a raw legacy key."
            )
        }
    }

    func testActiveSettingsDefaultsNoLongerRegisterPhysicalBuddyKeys() throws {
        let settingsSource = try sourceFile("Sources/Bough/Settings.swift")

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            XCTAssertFalse(
                settingsSource.contains("static let \(key)"),
                "\(key) should not remain an active SettingsKey."
            )
            XCTAssertFalse(
                settingsSource.contains("SettingsKey.\(key):"),
                "\(key) should not remain in SettingsDefaults.registeredDefaults."
            )
            XCTAssertFalse(
                settingsSource.contains("SettingsDefaults.\(key)"),
                "\(key) should not remain as an active default value."
            )
        }
    }

    func testCleanupContractPreservesUnrelatedPreferencesAndMusicDefault() throws {
        let cleanupSource = try cleanupSource()
        let settingsSource = try sourceFile("Sources/Bough/Settings.swift")

        XCTAssertEqual(SettingsKey.showMusicControls, "showMusicControls")
        XCTAssertEqual(SettingsDefaults.showMusicControls, true)
        XCTAssertTrue(
            settingsSource.contains("SettingsKey.showMusicControls"),
            "Music controls must remain registered after physical Buddy defaults are removed."
        )

        for key in Self.unrelatedDefaultKeys {
            XCTAssertFalse(
                cleanupSource.contains("\"\(key)\""),
                "Cleanup must not remove unrelated preference \(key)."
            )
        }
    }

    func testTemporaryDefaultsSuiteIsolatedForCleanupContract() throws {
        let suiteName = "PhysicalBuddyDefaultsCleanupTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Expected to create isolated UserDefaults suite.")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            defaults.set("legacy", forKey: key)
        }
        defaults.set(false, forKey: SettingsKey.showMusicControls)

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            XCTAssertEqual(
                defaults.string(forKey: key),
                "legacy",
                "Fixture for \(key) should be isolated and readable before cleanup runs."
            )
        }
        XCTAssertFalse(
            defaults.bool(forKey: SettingsKey.showMusicControls),
            "Unrelated defaults can coexist in the isolated suite before cleanup."
        )
    }

    func testCleanupRemovesLegacyPhysicalBuddyDefaultsAndMarksSentinel() throws {
        let suiteName = "PhysicalBuddyDefaultsCleanupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            defaults.set("legacy", forKey: key)
        }
        defaults.set(false, forKey: SettingsKey.showMusicControls)
        defaults.set("codex", forKey: SettingsKey.usageSelectedProvider)

        PhysicalBuddyDefaultsCleanup.runIfNeeded(defaults: defaults)

        for key in Self.legacyPhysicalBuddyDefaultKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be removed by cleanup.")
        }
        XCTAssertTrue(defaults.bool(forKey: "physicalBuddyDefaultsCleanup"))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showMusicControls))
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageSelectedProvider), "codex")
    }

    func testCleanupIsOneTimeAndDoesNotRepeatedlyMutateDefaults() throws {
        let suiteName = "PhysicalBuddyDefaultsCleanupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PhysicalBuddyDefaultsCleanup.runIfNeeded(defaults: defaults)
        defaults.set("post-cleanup", forKey: "esp32BridgeEnabled")

        PhysicalBuddyDefaultsCleanup.runIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "esp32BridgeEnabled"), "post-cleanup")
        XCTAssertTrue(defaults.bool(forKey: "physicalBuddyDefaultsCleanup"))
    }

    private func cleanupSource() throws -> String {
        try sourceFile("Sources/Bough/Settings/PhysicalBuddyDefaultsCleanup.swift")
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        _ = try XCTUnwrap(exists ? url : nil, "\(relativePath) must exist.")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func XCTAssertContains(
        _ source: String,
        _ token: String,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(source.contains(token), message(), file: file, line: line)
    }

    private var repoRoot: URL {
        TestHelpers.repoRoot(from: #filePath)
    }

    private static let legacyPhysicalBuddyDefaultKeys = [
        "esp32BridgeEnabled",
        "esp32HeartbeatSeconds",
        "buddyScreenBrightnessPercent",
        "buddyScreenOrientation",
        "selectedBuddyIdentifier",
        "selectedBuddyName",
    ]

    private static let unrelatedDefaultKeys = [
        "showMusicControls",
        "soundEnabled",
        "webhookEnabled",
        "defaultTerminal",
        "notchVisualizationStyle",
        "autoInstallUpdates",
    ]
}
