import XCTest

/// Keychain 行为无法在 CI 单测（真实 ACL/授权对话框），退而治理源码不变量：
/// 两个查询必须走 no-UI 上下文；数据读取必须经 KeychainReadChain；
/// 裸的可交互查询只允许出现在 interactiveRead 分支。
final class ClaudeKeychainReaderGovernanceTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = TestHelpers.repoRoot(from: #filePath)
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testNoUIQueryAppliesInteractionNotAllowedAndUIFail() throws {
        let noUI = try source("Sources/Bough/KeychainNoUIQuery.swift")
        XCTAssertTrue(noUI.contains("interactionNotAllowed = true"))
        XCTAssertTrue(noUI.contains("kSecUseAuthenticationContext"))
        XCTAssertTrue(noUI.contains("kSecUseAuthenticationUIFail"))
        XCTAssertTrue(noUI.contains(#"u_AuthUIF"#))  // 冻结字面量，动态查找被治理测试禁止
        XCTAssertTrue(noUI.contains("Adapted from steipete/CodexBar"))
    }

    func testReaderRoutesThroughChainAndAppliesNoUI() throws {
        let reader = try source("Sources/Bough/ClaudeKeychainReader.swift")
        XCTAssertTrue(reader.contains("KeychainReadChain.run("))
        XCTAssertTrue(reader.contains("KeychainNoUIQuery.apply"))
        XCTAssertTrue(reader.contains("SecurityCLIKeychainReader.readCredentialsData"))
        // readModificationDate 也必须 no-UI 化（防未来回归成可弹窗探测）。
        XCTAssertTrue(reader.contains("static let readModificationDate"))
        // 委托刷新协调器在 reader 文件内构造（makeDelegatedRefresh）。
        XCTAssertTrue(reader.contains("ClaudeDelegatedRefreshCoordinator("))
        // 读取入口只有两个 SecItemCopyMatching 调用点：frameworkDataRead
        //（noUI/interactive 复用同一函数）与 readModificationDate 属性探测。
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
