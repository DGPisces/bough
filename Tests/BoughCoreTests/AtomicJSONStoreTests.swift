import XCTest
@testable import BoughCore

final class AtomicJSONStoreTests: XCTestCase {
    // Override $HOME for the duration of each test so AtomicJSONStore's
    // resolution of `~/.bough/<relativePath>` lands in a per-test temp
    // directory rather than the developer's real home. `FileManager
    // .homeDirectoryForCurrentUser` reads $HOME on macOS, so a setenv
    // override is sufficient — we do not need an internal init or a path
    // injection on AtomicJSONStore's public surface.
    private var tempHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicJSONStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
    }

    override func tearDownWithError() throws {
        if let original = originalHome {
            setenv("HOME", original, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: tempHome)
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

    func testWriteOverwritesExistingFileAtomically() throws {
        try AtomicJSONStore.write(["v": 1], to: "overwrite.json")
        try AtomicJSONStore.write(["v": 99], to: "overwrite.json")

        let loaded = AtomicJSONStore.read([String: Int].self, from: "overwrite.json")
        XCTAssertEqual(loaded, ["v": 99])
    }
}
