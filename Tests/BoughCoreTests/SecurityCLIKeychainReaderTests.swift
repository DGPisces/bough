import XCTest
@testable import BoughCore

final class SecurityCLIKeychainReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 写一个假 security 脚本并 chmod +x，返回其路径。
    private func fakeBinary(script: String) throws -> String {
        let url = tempDir.appendingPathComponent("security-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testMissingBinaryMapsToDenied() {
        let result = SecurityCLIKeychainReader.readCredentialsData(
            service: "svc", binaryPath: tempDir.appendingPathComponent("nope").path)
        XCTAssertEqual(result, .failure(.denied(status: -1)))
    }

    func testSuccessTrimsTrailingNewlines() throws {
        let bin = try fakeBinary(script: #"printf '{"k":"v"}\n'"#)
        let result = SecurityCLIKeychainReader.readCredentialsData(service: "svc", binaryPath: bin)
        XCTAssertEqual(result, .success(Data(#"{"k":"v"}"#.utf8)))
    }

    func testItemNotFoundExitCodeMapsToItemNotFound() throws {
        // security find-generic-password 未找到 item 时退出码 44（errSecItemNotFound 的 CLI 映射）。
        let bin = try fakeBinary(script: "exit 44")
        let result = SecurityCLIKeychainReader.readCredentialsData(service: "svc", binaryPath: bin)
        XCTAssertEqual(result, .failure(.itemNotFound))
    }

    func testOtherNonZeroExitMapsToDeniedWithStatus() throws {
        let bin = try fakeBinary(script: "exit 51")
        let result = SecurityCLIKeychainReader.readCredentialsData(service: "svc", binaryPath: bin)
        XCTAssertEqual(result, .failure(.denied(status: 51)))
    }

    func testTimeoutKillsProcessAndMapsToDenied() throws {
        let bin = try fakeBinary(script: "sleep 60")
        let started = Date()
        let result = SecurityCLIKeychainReader.readCredentialsData(
            service: "svc", binaryPath: bin, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(result, .failure(.denied(status: -1)))
    }

    func testEmptyOutputMapsToDenied() throws {
        let bin = try fakeBinary(script: "exit 0")
        let result = SecurityCLIKeychainReader.readCredentialsData(service: "svc", binaryPath: bin)
        XCTAssertEqual(result, .failure(.denied(status: -1)))
    }

    func testReadModificationDateParsesMdatLine() throws {
        // 真实输出片段（security find-generic-password -s <svc>，不带 -w）。
        let bin = try fakeBinary(script: """
        cat <<'EOF'
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
        attributes:
            "mdat"<timedate>=0x32303236303730393034343335355A00  "20260709044355Z\\000"
            "svce"<blob>="Claude Code-credentials"
        EOF
        """)
        let date = SecurityCLIKeychainReader.readModificationDate(service: "svc", binaryPath: bin)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 9, hour: 4, minute: 43, second: 55))
        XCTAssertEqual(date, expected)
    }

    func testReadModificationDateReturnsNilWithoutMdat() throws {
        let bin = try fakeBinary(script: "echo no-attrs-here")
        XCTAssertNil(SecurityCLIKeychainReader.readModificationDate(service: "svc", binaryPath: bin))
    }
}
