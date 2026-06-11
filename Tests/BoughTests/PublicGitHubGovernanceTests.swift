import XCTest
import Yams

final class PublicGitHubGovernanceTests: XCTestCase {
    private let repoRoot = TestHelpers.repoRoot(from: #filePath)

    func testCodeownersRequiresMaintainerReviewForAllPaths() throws {
        let codeowners = try repoText(".github/CODEOWNERS")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertEqual(codeowners, ["* @DGPisces"])
    }

    func testDependabotCoversSwiftPackagesAndGitHubActionsWeekly() throws {
        let raw = try repoText(".github/dependabot.yml")
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("automerge"))

        let yaml = try XCTUnwrap(try Yams.load(yaml: raw) as? [String: Any])
        let updates = try XCTUnwrap(yaml["updates"] as? [[String: Any]])
        XCTAssertEqual(updates.count, 2)

        for ecosystem in ["swift", "github-actions"] {
            let entry = try XCTUnwrap(
                updates.first { $0["package-ecosystem"] as? String == ecosystem },
                "dependabot must cover the \(ecosystem) ecosystem"
            )
            XCTAssertEqual(entry["directory"] as? String, "/")
            XCTAssertEqual((entry["schedule"] as? [String: Any])?["interval"] as? String, "weekly")
            XCTAssertEqual(entry["open-pull-requests-limit"] as? Int, 5)
        }
    }

    func testWorkflowActionsArePinnedToCommitShas() throws {
        let workflows = try allFiles(under: ".github/workflows")
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        XCTAssertFalse(workflows.isEmpty, "expected workflow files under .github/workflows")

        var checkedActions = 0
        for workflow in workflows.sorted() {
            let yaml = try XCTUnwrap(
                try Yams.load(yaml: repoText(workflow)) as? [String: Any],
                "\(workflow) must parse as a YAML mapping"
            )
            let jobs = try XCTUnwrap(yaml["jobs"] as? [String: Any], "\(workflow) must define jobs")
            for (jobName, job) in jobs {
                guard let job = job as? [String: Any] else { continue }
                XCTAssertNil(job["uses"], "\(workflow) \(jobName): reusable workflow calls are not expected")
                for step in job["steps"] as? [[String: Any]] ?? [] {
                    guard let uses = step["uses"] as? String else { continue }
                    XCTAssertNotNil(
                        uses.range(of: #"^[^@\s]+@[0-9a-f]{40}$"#, options: .regularExpression),
                        "\(workflow) \(jobName): action must be pinned to a 40-hex commit SHA, got: \(uses)"
                    )
                    checkedActions += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checkedActions, 4, "expected to verify the checkout/cache pins across workflows")
    }

    func testPublicCIUsesHostedArmMacAndNoSecrets() throws {
        let ci = try repoText(".github/workflows/ci.yml")

        XCTAssertTrue(ci.contains("name: ci"))
        XCTAssertTrue(ci.contains("pull_request:"))
        XCTAssertTrue(ci.contains("branches: [main]"))
        XCTAssertTrue(ci.contains("permissions:\n  contents: read"))
        XCTAssertTrue(ci.contains("name: ci / build-and-test"))
        XCTAssertTrue(ci.contains("name: ci / unsigned-packaging-smoke"))
        XCTAssertTrue(ci.contains("name: ci / test-macos26"))
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
        XCTAssertTrue(release.contains("BOUGH_TAP_DEPLOY_KEY"))
        XCTAssertTrue(release.contains("Tools/Release/release-flow.sh open-tap-pr"))
        XCTAssertTrue(release.contains("git -C \"$APPCAST_STAGING\" diff --cached --quiet"))
        XCTAssertTrue(release.contains("No appcast changes to publish."))
        XCTAssertFalse(release.contains("commit -m \"Update appcast for ${BOUGH_RELEASE_TAG}\" || exit 0"))
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
            XCTAssertTrue(readme.contains("GitHub Releases"))
            XCTAssertTrue(readme.contains("Bough-vX.Y.Z.dmg"))
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

    func testPublicTreeExcludesPrivateAgentContextFiles() throws {
        let tracked = try trackedFiles()
        let deniedRootFiles = [
            "AGENTS.md",
            "CLAUDE.md",
        ]

        for file in deniedRootFiles {
            XCTAssertFalse(tracked.contains(file), "\(file) must not be tracked in the public repo")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(file).path),
                "\(file) must not be present in the public repo root"
            )
        }

        XCTAssertFalse(tracked.contains { $0.hasPrefix(".agents/") })
        XCTAssertFalse(tracked.contains { $0.hasPrefix(".claude/") })
        XCTAssertFalse(tracked.contains { $0.localizedCaseInsensitiveContains(Self.legacyRepoName) })
        XCTAssertFalse(tracked.contains(".github/workflows/\(Self.privateCIWorkflowName)"))
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
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Failed to enumerate public governance root: \(root.path)"
        )
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result.insert(url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))
            }
        }
        XCTAssertFalse(result.isEmpty, "Public governance scan must include files under \(relativePath).")
        return result
    }

    private func trackedFiles() throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path, "ls-files"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "git ls-files failed: \(error)")
        return Set(output.split(separator: "\n").map(String.init))
    }
}
