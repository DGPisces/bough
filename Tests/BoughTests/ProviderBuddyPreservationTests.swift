import Foundation
import XCTest
@testable import Bough
@testable import BoughCore

final class ProviderBuddyPreservationTests: XCTestCase {
    func testSessionSnapshotPreservesBuddyNamedProviderSourcesAndAliases() {
        let expectedSources = ["codebuddy", "codybuddycn", "workbuddy"]

        for source in expectedSources {
            XCTAssertTrue(
                SessionSnapshot.supportedSources.contains(source),
                "\(source) should remain a supported provider source."
            )
        }

        let aliasExpectations: [String: String] = [
            "codebuddy": "codebuddy",
            "CodeBuddy": "codebuddy",
            "codebuddycn": "codybuddycn",
            "codybuddycn": "codybuddycn",
            "codybuddy-cn": "codybuddycn",
            "workbuddy": "workbuddy",
            "WorkBuddy": "workbuddy",
            "work-buddy": "workbuddy",
            "workbody": "workbuddy",
            "work-body": "workbuddy",
        ]

        for (alias, canonical) in aliasExpectations {
            XCTAssertEqual(
                SessionSnapshot.normalizedSupportedSource(alias),
                canonical,
                "\(alias) should normalize to \(canonical)."
            )
        }

        let labelExpectations: [String: String] = [
            "codebuddy": "CodeBuddy",
            "codybuddycn": "CodyBuddyCN",
            "workbuddy": "WorkBuddy",
        ]

        for (source, label) in labelExpectations {
            var snapshot = SessionSnapshot()
            snapshot.source = source
            XCTAssertEqual(snapshot.sourceLabel, label)
        }
    }

    func testConfigInstallerPreservesBuddyNamedLocalCLIRows() {
        let expectedRows: [String: (name: String, configPath: String)] = [
            "codebuddy": ("CodeBuddy", ".codebuddy/settings.json"),
            "codybuddycn": ("CodyBuddyCN", ".codybuddycn/settings.json"),
            "workbuddy": ("WorkBuddy", ".workbuddy/settings.json"),
        ]

        for (source, expected) in expectedRows {
            let row = ConfigInstaller.allCLIs.first { $0.source == source }
            XCTAssertNotNil(row, "\(source) should remain in the local CLI catalog.")
            XCTAssertEqual(row?.name, expected.name)
            XCTAssertEqual(row?.configPath, expected.configPath)
        }
    }

    func testTerminalActivationMascotsAndProviderIconsRemainPresent() throws {
        let terminalActivator = try sourceFile("Sources/Bough/TerminalActivator.swift")
        let mascotView = try sourceFile("Sources/Bough/MascotView.swift")

        XCTAssertContains(terminalActivator, "\"codebuddy\": \"com.tencent.codebuddy\"")
        XCTAssertContains(terminalActivator, "\"codybuddycn\": \"com.tencent.codebuddy.cn\"")
        XCTAssertContains(terminalActivator, "\"workbuddy\": \"com.workbuddy.workbuddy\"")
        XCTAssertContains(terminalActivator, "\"com.tencent.codebuddy\": \"CodeBuddy\"")
        XCTAssertContains(terminalActivator, "\"com.tencent.codebuddy.cn\": \"CodyBuddyCN\"")
        XCTAssertContains(terminalActivator, "\"com.workbuddy.workbuddy\": \"WorkBuddy\"")
        XCTAssertContains(terminalActivator, "!hasTerminalEvidence(session)")

        XCTAssertContains(mascotView, "MascotSpriteCatalog.spec(source: source, status: status)")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("codebuddy"), "codebuddy")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("codybuddycn"), "codebuddy")
        XCTAssertEqual(MascotSpriteCatalog.normalizedApprovedSourceID("workbuddy"), "workbuddy")

        XCTAssertFileExists("Sources/Bough/Resources/mascots/codebuddy/icon.png")
        XCTAssertFileExists("Sources/Bough/Resources/mascots/workbuddy/icon.png")
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

    private func XCTAssertFileExists(
        _ relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path),
            "\(relativePath) should exist.",
            file: file,
            line: line
        )
    }

    private var repoRoot: URL {
        TestHelpers.repoRoot(from: #filePath)
    }
}
