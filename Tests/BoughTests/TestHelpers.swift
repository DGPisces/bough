import Foundation
import XCTest

/// Resolves the repository root from a test file's `#filePath` literal.
///
/// Test files live at `Tests/BoughTests/<File>.swift` — three levels up from
/// the file's directory is the repo root. Passing `#filePath` as a parameter
/// (rather than computing it inside this function) is required because Swift
/// expands `#filePath` to the *call site* source path, not to this file's path.
///
/// Usage:
/// ```swift
/// private static let repoRoot = TestHelpers.repoRoot(from: #filePath)
/// ```
enum TestHelpers {
    static func repoRoot(from filePath: String) -> URL {
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()   // BoughTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        // Fail loudly at test startup if the depth assumption is wrong.
        // A path mismatch (e.g., after a Tests/ rename) produces a clear
        // assertion rather than a cryptic "file not found" deep inside a test.
        assert(
            FileManager.default.fileExists(atPath: root.path),
            "TestHelpers.repoRoot: resolved path does not exist — " +
            "check deletingLastPathComponent() depth. Path: \(root.path)"
        )
        return root
    }
}
