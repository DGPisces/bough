import Darwin
import XCTest
@testable import BoughCore

enum CoreTestHelpers {
    static let processEnvironmentLock = CoreTestProcessStateLock()
}

final class CoreTestProcessStateLock {
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

final class AtomicJSONStoreTests: XCTestCase {
    // Override $HOME for the duration of each test so AtomicJSONStore's
    // resolution of `~/.bough/<relativePath>` lands in a per-test temp
    // directory rather than the developer's real home. `FileManager
    // .homeDirectoryForCurrentUser` reads $HOME on macOS, so a setenv
    // override is sufficient — we do not need an internal init or a path
    // injection on AtomicJSONStore's public surface.
    private var tempHome: URL!
    private var originalHome: String?
    private var lockedEnvironment = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicJSONStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        CoreTestHelpers.processEnvironmentLock.lock()
        lockedEnvironment = true
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
    }

    override func tearDownWithError() throws {
        if lockedEnvironment {
            if let original = originalHome {
                setenv("HOME", original, 1)
            } else {
                unsetenv("HOME")
            }
        }
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        if lockedEnvironment {
            CoreTestHelpers.processEnvironmentLock.unlock()
            lockedEnvironment = false
        }
        try super.tearDownWithError()
    }

    func testWriteAndReadRoundTrip() throws {
        let payload: [String: Int] = ["alpha": 1, "beta": 2, "gamma": 3]
        try AtomicJSONStore.write(payload, to: "round-trip.json")

        let loaded = AtomicJSONStore.read([String: Int].self, from: "round-trip.json")
        XCTAssertEqual(loaded, payload)
    }

    func testReadReturnsNilForMissingFile() {
        let loaded = AtomicJSONStore.read([String: Int].self, from: "does-not-exist.json")
        XCTAssertNil(loaded)
    }

    func testReadReturnsNilForCorruptJSON() throws {
        // Write garbage bytes directly to the resolved path, bypassing the encoder
        // so we can simulate a corrupted on-disk file.
        let boughDir = tempHome.appendingPathComponent(".bough", isDirectory: true)
        try FileManager.default.createDirectory(at: boughDir, withIntermediateDirectories: true)
        let fileURL = boughDir.appendingPathComponent("corrupt.json")
        try Data("{not-valid-json".utf8).write(to: fileURL)

        let loaded = AtomicJSONStore.read([String: Int].self, from: "corrupt.json")
        XCTAssertNil(loaded)
    }

    func testWriteCreatesBoughDirectoryWhenMissing() throws {
        // Confirm the .bough directory does not yet exist under the temp HOME.
        let boughDir = tempHome.appendingPathComponent(".bough", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: boughDir.path),
                       "Precondition: .bough/ should not exist before first write")

        try AtomicJSONStore.write(["k": 42], to: "first-write.json")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: boughDir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, ".bough/ should exist after first write")
        XCTAssertTrue(isDir.boolValue, ".bough should be a directory")

        let fileURL = boughDir.appendingPathComponent("first-write.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testWriteProtectsBoughDirectoryAndJSONFilePermissions() throws {
        let boughDir = tempHome.appendingPathComponent(".bough", isDirectory: true)
        try FileManager.default.createDirectory(at: boughDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: boughDir.path)

        try AtomicJSONStore.write(["secret": "value"], to: "private.json")

        let fileURL = boughDir.appendingPathComponent("private.json")
        XCTAssertEqual(try posixPermissions(at: boughDir), BoughPrivateStorage.directoryPermissions)
        XCTAssertEqual(try posixPermissions(at: fileURL), BoughPrivateStorage.filePermissions)
    }

    func testWriteOverwritesExistingFileAtomically() throws {
        try AtomicJSONStore.write(["v": 1], to: "overwrite.json")
        try AtomicJSONStore.write(["v": 99], to: "overwrite.json")

        let loaded = AtomicJSONStore.read([String: Int].self, from: "overwrite.json")
        XCTAssertEqual(loaded, ["v": 99])
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? Int) & 0o777
    }
}
