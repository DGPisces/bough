import XCTest
@testable import Bough

/// Static-grep parity tests for the Python helper embedded in `RemoteInstaller.swift`.
///
/// D-18 decision: no Python test harness in this repo — instead, read `RemoteInstaller.swift`
/// source text in a Swift test and assert structural properties of the embedded Python source.
/// This mirrors the HOOK-04 static-grep technique from `ConfigInstallerCodexConfigTomlHygieneTests`.
final class RemoteInstallerSourceHygieneTests: XCTestCase {

    // MARK: - Helper

    /// Loads `Sources/Bough/RemoteInstaller.swift` as a String by resolving the repo root
    /// from this test file's location via `#filePath` walking.
    private func loadRemoteInstallerSource(file: StaticString = #filePath, line: UInt = #line) -> String? {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // Tests/BoughTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Bough")
            .appendingPathComponent("RemoteInstaller.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("Could not load Sources/Bough/RemoteInstaller.swift — check repo root resolution", file: file, line: line)
            return nil
        }
        return source
    }

    // MARK: - Tests

    /// HOOK-04 invariant on the remote install surface: the Python helper embedded in
    /// `RemoteInstaller.swift` must not contain `[hooks.` or `[[hooks]]` literal substrings.
    /// Bough never writes any `[hooks.*]` block to config.toml via the Python path either.
    func testPythonHelperHasNoHooksTomlLiterals() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertFalse(source.contains("[hooks."),
                       "HOOK-04: RemoteInstaller.swift must not contain '[hooks.' literal (Python path invariant)")
        XCTAssertFalse(source.contains("[[hooks]]"),
                       "HOOK-04: RemoteInstaller.swift must not contain '[[hooks]]' literal (Python path invariant)")
    }

    /// Version-guard presence: the Python helper must invoke a resolved Codex candidate with
    /// `--version` via subprocess to gate the old-Codex compatibility branch.
    func testPythonHelperHasCodexVersionGuard() {
        guard let source = loadRemoteInstallerSource() else { return }
        // Assert subprocess is imported in the Python source.
        XCTAssertTrue(source.contains("subprocess"),
                      "Python helper must import subprocess for codex --version detection")
        XCTAssertTrue(source.contains("def _codex_candidate_paths"),
                      "Python helper must resolve executable Codex candidates before version probing")
        XCTAssertTrue(source.contains("\"--version\""),
                      "Python helper must invoke the resolved Codex candidate with --version")
    }

    func testPythonHelperHasDetectionFailureStripPolicyMarker() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertTrue(source.contains("Detection failure strips"),
                      "Python helper must document that unknown Codex versions strip the deprecated key")
        XCTAssertFalse(source.contains("Conservative fallback"),
                       "Python helper must not preserve codex_hooks on detection failure")
    }

    func testPythonHelperDiscoversNvmAndAppResourceCodexWithoutGuiBinary() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertTrue(source.contains("command -v codex"))
        XCTAssertTrue(source.contains(".nvm"))
        XCTAssertTrue(source.contains("Contents/Resources/codex"))
        XCTAssertTrue(source.contains("def _resolved_path"))
        XCTAssertTrue(source.contains("resolve(strict=False)"))
        XCTAssertTrue(source.contains("def _is_codex_gui_app_binary"))
        XCTAssertTrue(source.contains("str(_resolved_path(path)) == \"/Applications/Codex.app/Contents/MacOS/Codex\""))
        XCTAssertTrue(source.contains("not _is_codex_gui_app_binary(candidate)"))
    }

    func testPythonHelperValidatesTomlTableHeaderDottedKeys() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertTrue(source.contains("def _toml_dotted_key_is_valid"))
        XCTAssertTrue(source.contains("_toml_dotted_key_is_valid(header[2:-2])"))
        XCTAssertTrue(source.contains("_toml_dotted_key_is_valid(header[1:-1])"))
    }

    /// 5-second timeout: the Python helper must use `timeout=5` in the subprocess call, matching
    /// the Swift `detectCodexVersion` 5-second timeout for symmetry (T-15-06-02 mitigation).
    func testPythonHelperFiveSecondTimeout() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertTrue(source.contains("timeout=5"),
                      "Python helper must use timeout=5 in subprocess.run to match Swift 5-second detect timeout")
    }

    func testConfigureRemoteHooksBase64DecodeSupportsMacOSAndLinux() {
        guard let source = loadRemoteInstallerSource() else { return }
        XCTAssertTrue(source.contains("base64 -D 2>/dev/null"))
        XCTAssertTrue(source.contains("base64 -d 2>/dev/null"))
        XCTAssertTrue(source.contains("printf '%s'"))
    }

    func testRemoteHookUploadUsesPrivateDirectoryAndAtomicReplace() {
        guard let source = loadRemoteInstallerSource() else { return }

        XCTAssertTrue(source.contains("os.chmod(target.parent, 0o700)"))
        XCTAssertTrue(source.contains("tmp.write_bytes(base64.b64decode"))
        XCTAssertTrue(source.contains("os.chmod(tmp, 0o700)"))
        XCTAssertTrue(source.contains("os.replace(tmp, target)"))
        XCTAssertTrue(source.contains("os.chmod(target, 0o700)"))
    }
}
