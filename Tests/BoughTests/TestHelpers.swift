import Darwin
import Foundation
@testable import Bough
@testable import BoughCore
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
    static let processEnvironmentLock = TestProcessStateLock()
    static let processStateLock = processEnvironmentLock

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

    static func restoreUserDefaultsValue(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func restoreSharedLanguage(_ language: String, savedDefaultValue: Any?) {
        L10n.shared.language = language
        restoreUserDefaultsValue(savedDefaultValue, forKey: SettingsKey.appLanguage)
    }

    /// Polls `predicate` on the main actor until it returns true, failing the
    /// test and throwing if `timeout` elapses first. Throwing aborts the test
    /// immediately: continuing after a timed-out wait would act on state that
    /// never arrived and could await a continuation that never resumes.
    @MainActor
    static func waitUntil(
        timeout: TimeInterval = 5.0,
        intervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        if predicate() { return }
        XCTFail("waitUntil timed out after \(timeout)s", file: file, line: line)
        throw WaitUntilTimeoutError()
    }
}

/// Thrown by `TestHelpers.waitUntil` on timeout so the failing test aborts
/// instead of running follow-up actions against state that never arrived.
struct WaitUntilTimeoutError: Error {}

final class TestProcessStateLock {
    private static let lockName = "dev.dgpisces.bough.tests.process-state"
    private let localLock = NSLock()
    private let handle: FileHandle

    init() {
        let filename = Self.lockName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).lock")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            preconditionFailure("Failed to open test process-state lock \(url.path): \(error)")
        }
    }

    func lock() {
        localLock.lock()
        while flock(handle.fileDescriptor, LOCK_EX) == -1 {
            if errno != EINTR {
                localLock.unlock()
                preconditionFailure("Failed to lock test process-state file")
            }
        }
    }

    func unlock() {
        precondition(flock(handle.fileDescriptor, LOCK_UN) == 0, "Failed to unlock test process-state file")
        localLock.unlock()
    }
}
