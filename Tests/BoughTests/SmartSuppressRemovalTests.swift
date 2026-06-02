import XCTest

@testable import Bough

final class SmartSuppressRemovalTests: XCTestCase {
    func testRemovedSmartSuppressIdentifiersDoNotReturnToSources() throws {
        let bannedTokens = [
            "smartSuppress",
            "smart_suppress",
            "Smart Suppress",
            "smart suppress",
            "smart-suppress",
        ]
        let sources = try sourceFiles(under: "Sources/Bough")

        for source in sources {
            for token in bannedTokens {
                XCTAssertFalse(
                    source.contents.localizedCaseInsensitiveContains(token),
                    "\(source.relativePath) still contains removed token \(token)"
                )
            }
        }
    }

    func testCompletionAutoExpandNoLongerChecksTerminalVisibility() throws {
        let source = try sourceFile("Sources/Bough/AppState.swift")
        let showCompletion = try XCTUnwrap(source.slice(
            from: "private func showCompletion",
            to: "private func doShowCompletion"
        ))

        XCTAssertTrue(showCompletion.contains("doShowCompletion(sessionId)"))
        XCTAssertFalse(showCompletion.contains("TerminalVisibilityDetector"))
        XCTAssertFalse(showCompletion.contains("UserDefaults.standard.bool"))
    }

    func testTerminalVisibilityDetectorStillSupportsJumpVerificationOnly() throws {
        let panelSource = try sourceFile("Sources/Bough/NotchPanelView.swift")
        let controllerSource = try sourceFile("Sources/Bough/PanelWindowController.swift")

        XCTAssertTrue(panelSource.contains("TerminalVisibilityDetector.isSessionTabVisible(session)"))
        XCTAssertTrue(panelSource.contains("TerminalVisibilityDetector.isTerminalFrontmostForSession(session)"))
        XCTAssertFalse(controllerSource.contains("isActiveTerminalForeground"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceFiles(under relativePath: String) throws -> [SourceFile] {
        let root = TestHelpers.repoRoot(from: #filePath)
        let directory = root.appendingPathComponent(relativePath)
        let urls = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        return try urls
            .filter { $0.pathExtension == "swift" }
            .map { url in
                SourceFile(
                    relativePath: url.path.replacingOccurrences(of: root.path + "/", with: ""),
                    contents: try String(contentsOf: url, encoding: .utf8)
                )
            }
    }

    private struct SourceFile {
        let relativePath: String
        let contents: String
    }
}

private extension String {
    func slice(from startToken: String, to endToken: String) -> String? {
        guard let start = range(of: startToken)?.lowerBound,
              let end = self[start...].range(of: endToken)?.lowerBound else {
            return nil
        }
        return String(self[start..<end])
    }
}
