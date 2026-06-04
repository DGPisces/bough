import XCTest

final class PublicGitHubGovernanceTests: XCTestCase {
    private let repoRoot = TestHelpers.repoRoot(from: #filePath)

    func testCodeownersRequiresMaintainerReviewForAllPaths() throws {
        let codeowners = try repoText(".github/CODEOWNERS")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertEqual(codeowners, ["* @DGPisces"])
    }

    func testDependabotOnlyCreatesWeeklySwiftPackageUpdates() throws {
        let dependabot = try repoText(".github/dependabot.yml")

        XCTAssertTrue(dependabot.contains(#"package-ecosystem: "swift""#))
        XCTAssertTrue(dependabot.contains(#"directory: "/""#))
        XCTAssertTrue(dependabot.contains(#"interval: "weekly""#))
        XCTAssertTrue(dependabot.contains("open-pull-requests-limit: 5"))
        XCTAssertFalse(dependabot.contains("github-actions"))
        XCTAssertFalse(dependabot.localizedCaseInsensitiveContains("automerge"))
    }

    func testPublicCIUsesHostedArmMacAndNoSecrets() throws {
        let ci = try repoText(".github/workflows/ci.yml")

        XCTAssertTrue(ci.contains("name: ci"))
        XCTAssertTrue(ci.contains("pull_request:"))
        XCTAssertTrue(ci.contains("branches: [main]"))
        XCTAssertTrue(ci.contains("permissions:\n  contents: read"))
        XCTAssertTrue(ci.contains("name: ci / build-and-test"))
        XCTAssertTrue(ci.contains("name: ci / unsigned-packaging-smoke"))
        XCTAssertTrue(ci.contains("runs-on: macos-14"))
        XCTAssertTrue(ci.contains("runs-on: macos-26"))
        XCTAssertTrue(ci.contains("swift build"))
        XCTAssertTrue(ci.contains("swift test --parallel"))
        XCTAssertTrue(ci.contains("Tools/Release/check-version-consistency.sh"))
        XCTAssertTrue(ci.contains("BUILD_ARCH=arm64 SKIP_SIGN=1 SKIP_NOTARIZE=1 Tools/Build/build-dmg.sh"))
        XCTAssertTrue(ci.contains("Tools/Release/release-flow.sh _assert-macos-sdk --dmg .build/Bough.dmg"))
        XCTAssertTrue(ci.contains("Tools/Smoke/smoke-packaged-usage-monitor.sh"))
        XCTAssertFalse(ci.contains("self-hosted"))
        XCTAssertFalse(ci.contains("secrets."))
        XCTAssertFalse(ci.contains(Self.attributionTraceScriptName))
        XCTAssertFalse(ci.contains(Self.foundationProjectName))
    }

    func testReleaseWorkflowIsTagOnlyAndEnvironmentGated() throws {
        let release = try repoText(".github/workflows/release.yml")
        let updateAppcast = try repoText("Tools/Release/update-appcast.sh")

        XCTAssertTrue(release.contains("name: release"))
        XCTAssertTrue(release.contains("tags:"))
        XCTAssertTrue(release.contains(#"- "v*""#))
        XCTAssertFalse(release.contains("workflow_dispatch"))
        XCTAssertTrue(release.contains("runs-on: macos-26"))
        XCTAssertTrue(release.contains("environment: release"))
        XCTAssertTrue(release.contains("security create-keychain"))
        XCTAssertTrue(release.contains("security import \"$CERTIFICATE_PATH\""))
        XCTAssertTrue(release.contains("xcrun notarytool store-credentials"))
        XCTAssertTrue(release.contains("SPARKLE_EDDSA_PRIVATE_KEY"))
        XCTAssertTrue(release.contains("SPARKLE_EDDSA_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}"))
        XCTAssertTrue(updateAppcast.contains("SPARKLE_EDDSA_PRIVATE_KEY"))
        XCTAssertTrue(updateAppcast.contains("--ed-key-file -"))
        XCTAssertTrue(release.contains("BUILD_ARCH=universal"))
        XCTAssertTrue(release.contains("--repo DGPisces/bough"))
        XCTAssertTrue(release.contains(#"gh release edit "${release_args[@]}""#))
        XCTAssertTrue(release.contains(#"gh release upload "${upload_args[@]}""#))
        XCTAssertTrue(release.contains("(.browserDownloadUrl // .url)"))
        XCTAssertTrue(release.contains("BOUGH_HOMEBREW_TAP_TOKEN"))
        XCTAssertTrue(release.contains("Tools/Release/release-flow.sh open-tap-pr"))
        XCTAssertFalse(release.contains("gh pr merge"))
        XCTAssertFalse(release.contains("self-hosted"))
        XCTAssertFalse(release.contains("DGPisces/\(Self.legacyRepoName)"))
        XCTAssertFalse(release.contains("BOUGH_RELEASE_BOT_TOKEN"))
        XCTAssertFalse(release.contains(Self.attributionTraceScriptName))
    }

    func testReadmesExposeHomebrewAndDmgAsPrimaryInstallPaths() throws {
        let zh = try repoText("README.zh-CN.md")
        let en = try repoText("README.md")

        for readme in [zh, en] {
            XCTAssertTrue(readme.contains("brew tap DGPisces/tap"))
            XCTAssertTrue(readme.contains("brew install --cask bough"))
            XCTAssertTrue(readme.contains("brew install --cask DGPisces/tap/bough"))
            XCTAssertTrue(readme.contains("GitHub Releases"))
            XCTAssertTrue(readme.contains("Bough.dmg"))
            XCTAssertTrue(readme.contains("brew update"))
            XCTAssertTrue(readme.contains("brew upgrade --cask bough"))
        }
    }

    func testPublicGithubDirectoryHasNoTemplatesOrPrivateCI() throws {
        let files = try allFiles(under: ".github")

        XCTAssertTrue(files.contains(".github/CODEOWNERS"))
        XCTAssertTrue(files.contains(".github/dependabot.yml"))
        XCTAssertTrue(files.contains(".github/workflows/ci.yml"))
        XCTAssertTrue(files.contains(".github/workflows/release.yml"))
        XCTAssertFalse(files.contains(".github/workflows/\(Self.privateCIWorkflowName)"))
        XCTAssertFalse(files.contains(".github/PULL_REQUEST_TEMPLATE.md"))
        XCTAssertFalse(files.contains { $0.hasPrefix(".github/ISSUE_TEMPLATE/") })
    }

    private static var attributionTraceScriptName: String {
        "verify-no-" + foundationProjectName.lowercased() + "-traces"
    }

    private static var foundationProjectName: String {
        ["Code", "Island"].joined()
    }

    private static var legacyRepoName: String {
        ["bough", "internal"].joined(separator: "-")
    }

    private static var privateCIWorkflowName: String {
        ["private", "ci"].joined(separator: "-") + ".yml"
    }

    private func repoText(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func allFiles(under relativePath: String) throws -> Set<String> {
        let root = repoRoot.appendingPathComponent(relativePath)
        var result = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return result
        }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result.insert(url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))
            }
        }
        return result
    }
}
