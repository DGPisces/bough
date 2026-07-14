import XCTest

/// Keychain 行为无法在 CI 单测（真实 ACL/授权对话框），退而治理源码不变量：
/// 静默读取必须走 /usr/bin/security（不弹窗）；进程内可弹窗读取只允许出现在
/// 可交互（interactiveRead）分支，绝不在静默路径。
final class ClaudeKeychainReaderGovernanceTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = TestHelpers.repoRoot(from: #filePath)
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSilentReadUsesSecurityCLINotInProcessFramework() throws {
        let reader = try source("Sources/Bough/ClaudeKeychainReader.swift")
        XCTAssertTrue(reader.contains("KeychainReadChain.run("))
        // The silent slot MUST be the security CLI — an in-process data read
        // blocks on the ACL dialog instead of failing closed.
        XCTAssertTrue(reader.contains("silentRead: { SecurityCLIKeychainReader.readCredentialsData"))
        XCTAssertTrue(reader.contains("interactiveRead: { frameworkDataRead() }"))
        // The disproven no-UI query helper must stay gone.
        XCTAssertFalse(reader.contains("KeychainNoUIQuery"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            TestHelpers.repoRoot(from: #filePath)
                .appendingPathComponent("Sources/Bough/KeychainNoUIQuery.swift").path))
        // readModificationDate stays an attribute-only read (never prompts).
        XCTAssertTrue(reader.contains("static let readModificationDate"))
        XCTAssertTrue(reader.contains("ClaudeDelegatedRefreshCoordinator("))
        // Two SecItemCopyMatching sites: the interactive frameworkDataRead and
        // the attribute-only mdat probe — never on the silent credential path.
        XCTAssertEqual(
            reader.components(separatedBy: "SecItemCopyMatching").count - 1, 2,
            "expected exactly 2 SecItemCopyMatching call sites: frameworkDataRead, attributes probe")
    }

    func testAppAndHelperInjectDelegatedRefreshAndCLIFallback() throws {
        let appState = try source("Sources/Bough/AppState.swift")
        XCTAssertTrue(appState.contains("delegatedRefresh: ClaudeKeychainReader.makeDelegatedRefresh()"))

        let helperMain = try source("Sources/BoughUsageMonitor/main.swift")
        XCTAssertTrue(helperMain.contains("SecurityCLIKeychainReader.readCredentialsData"))
        XCTAssertTrue(helperMain.contains("SecurityCLIKeychainReader.readModificationDate"))
        XCTAssertTrue(helperMain.contains("ClaudeDelegatedRefreshCoordinator("))
        XCTAssertFalse(helperMain.contains("keychainRead: nil"))
    }
}
