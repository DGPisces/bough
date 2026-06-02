import XCTest

@testable import Bough

/// Phase 21 / Plan 21-03 (WR-1 fold-in): unit tests for the four-state UI classifier.
/// Plan-checker flagged the SettingsView classifier as the most fragile part of the
/// phase because it ties three independent disk-read surfaces (settings.json,
/// wrapper sentinel, bundle bridge path) into a single enum the UI renders against.
/// The classifier was extracted into a pure function (`classifyClaudeCodeStatusLineUIState`)
/// so these tests cover every branch without spinning up SwiftUI.
final class ClaudeCodeStatusLineUIStateTests: XCTestCase {

    private let bridgePath = "/Apps/Bough.app/Contents/Resources/Bough_Bough.bundle/Resources/bough-statusline-bridge.sh"
    private let wrapperPath = "/Users/u/.bough/bough-statusline-wrapper.sh"

    // MARK: - .notInstalledEmpty

    func testClassifier_notInstalledEmpty_whenCurrentCommandIsNil() {
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: nil,
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .notInstalledEmpty)
    }

    func testClassifier_notInstalledEmpty_whenCurrentCommandIsEmptyString() {
        // Edge case — settings.json with `"statusLine": {"command": ""}`. Treat as empty.
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: "",
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .notInstalledEmpty)
    }

    // MARK: - .installedBoughOnly

    func testClassifier_installedBoughOnly_whenCurrentEqualsBridgePath() {
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: bridgePath,
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .installedBoughOnly)
    }

    // MARK: - .installedChained

    func testClassifier_installedChained_decodesSentinelBasename() {
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: wrapperPath,
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: "/usr/local/bin/starship"
        )
        XCTAssertEqual(state, .installedChained(prevCmdBasename: "starship"))
    }

    func testClassifier_installedChained_fallsBackToWrapperBasenameOnCorruptSentinel() {
        // T-21-13 mitigation: if sentinel is corrupt (nil), do NOT spoof a fake basename.
        // Fall back to the wrapper's own basename so the UI never displays a prev_cmd
        // that uninstall would not actually restore.
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: wrapperPath,
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .installedChained(prevCmdBasename: "bough-statusline-wrapper.sh"))
    }

    // MARK: - .otherToolActive

    func testClassifier_otherToolActive_whenStarshipIsCurrent() {
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: "/usr/local/bin/starship",
            proposedBridgePath: bridgePath,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .otherToolActive(prevCmdBasename: "starship"))
    }

    func testClassifier_otherToolActive_whenBridgePathUnresolvable() {
        // If Bundle.module lookup fails (proposed == nil), a third-party command must
        // still classify as .otherToolActive — never as .installedBoughOnly.
        let state = classifyClaudeCodeStatusLineUIState(
            currentCommand: "/usr/local/bin/ccusage",
            proposedBridgePath: nil,
            wrapperPath: wrapperPath,
            wrapperPrevCmd: nil
        )
        XCTAssertEqual(state, .otherToolActive(prevCmdBasename: "ccusage"))
    }
}
