import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    private let repoRoot = TestHelpers.repoRoot(from: #filePath)

    func testRepoRootMatchesApprovedPublicCandidateLayout() throws {
        let approvedRootEntries: Set<String> = [
            ".github",
            ".gitignore",
            "Assets",
            "CHANGELOG.md",
            "CONTRIBUTING.md",
            "CREDITS.md",
            "LICENSE",
            "Package.resolved",
            "Package.swift",
            "Platform",
            "README.md",
            "README.zh-CN.md",
            "Sources",
            "Tests",
            "Tools",
        ]

        let rootEntries = try publicCandidateRootEntries()

        let unexpectedEntries = rootEntries.subtracting(approvedRootEntries)
        XCTAssertTrue(unexpectedEntries.isEmpty, "Unexpected public candidate root entries: \(unexpectedEntries.sorted())")

        let requiredSourceRoots: Set<String> = [
            ".github",
            "Assets",
            "Package.swift",
            "Platform",
            "Sources",
            "Tests",
            "Tools",
        ]
        for root in requiredSourceRoots {
            XCTAssertTrue(rootEntries.contains(root), "Missing required public source root \(root)")
        }

        let forbiddenRootEntries: Set<String> = [
            planningRootName,
            "AGENTS.md",
            "CLAUDE.md",
            "HANDOFF.md",
            ["Distrib", "ution"].joined(),
            "apple",
            buildWrapperName,
            "docs",
            "install",
            "logo.png",
            "script",
            "scripts",
        ]
        XCTAssertTrue(
            rootEntries.isDisjoint(with: forbiddenRootEntries),
            "Non-public root entries remain: \(rootEntries.intersection(forbiddenRootEntries).sorted())"
        )
    }

    func testBoughCoreImportsOnlyCoreSafeDependencies() throws {
        let allowedImports: Set<String> = [
            "Darwin",
            "Foundation",
            "SQLite3",
            "UserNotifications",
        ]

        for file in try swiftFiles(under: repoRoot.appendingPathComponent("Sources/BoughCore")) {
            let relativePath = relativePath(for: file)
            let modules = importedModules(in: try sourceText(at: file))
            let unexpected = modules.subtracting(allowedImports)

            XCTAssertTrue(
                unexpected.isEmpty,
                "\(relativePath) imports app-layer or platform modules: \(unexpected.sorted())"
            )
        }
    }

    func testPublicGithubDirectoryContainsOnlyGovernanceAndWorkflows() throws {
        let githubFiles = try files(under: repoRoot.appendingPathComponent(".github"))
            .map(relativePath(for:))

        let allowedDirectFiles: Set<String> = [
            ".github/CODEOWNERS",
            ".github/dependabot.yml",
        ]
        let unexpected = githubFiles.filter { path in
            !allowedDirectFiles.contains(path) && !path.hasPrefix(".github/workflows/")
        }

        XCTAssertTrue(unexpected.isEmpty, "Unexpected public .github files: \(unexpected.sorted())")
        XCTAssertTrue(githubFiles.contains(".github/workflows/ci.yml"))
        XCTAssertTrue(githubFiles.contains(".github/workflows/release.yml"))
    }

    func testPublicCandidateTreeDoesNotCarryPrivateOnlyArtifacts() throws {
        let publicSyncRoot = ["Tools", ["Public", "Sync"].joined()].joined(separator: "/")
        let privateOnlyPaths: [String] = [
            "AGENTS.md",
            "CLAUDE.md",
            "HANDOFF.md",
            [["Distrib", "ution"].joined(), ["Internal", "Evidence"].joined()].joined(separator: "/"),
            publicSyncRoot,
            ["Tools", "Release", ["check", "release", "ledger"].joined(separator: "-") + ".sh"].joined(separator: "/"),
            ["Tools", "Build", ["dev", "hot", "restart"].joined(separator: "-") + ".sh"].joined(separator: "/"),
            buildWrapperName,
            ["docs", ["public", "repo", "development", "flow"].joined(separator: "-") + ".md"].joined(separator: "/"),
            ["scripts", ["app", "cast"].joined() + ".xml"].joined(separator: "/"),
            ".github/PULL_REQUEST_TEMPLATE.md",
            ".github/ISSUE_TEMPLATE",
            ".github/workflows/" + ["private", "ci"].joined(separator: "-") + ".yml",
        ]

        for relativePath in privateOnlyPaths {
            XCTAssertFalse(
                fileExists(relativePath),
                "Public candidate includes non-public artifact \(relativePath)"
            )
        }
    }

    func testGitignoreIsPublicNativeAndDoesNotHidePlanningState() throws {
        let gitignore = try sourceText(at: repoRoot.appendingPathComponent(".gitignore"))

        XCTAssertTrue(gitignore.contains(".DS_Store"))
        XCTAssertTrue(gitignore.contains(".build/"))
        XCTAssertTrue(gitignore.contains("dist/"))
        XCTAssertTrue(gitignore.contains("*.p12"))
        XCTAssertTrue(gitignore.contains(".codex/"))
        XCTAssertFalse(gitignore.contains(planningRootName))
        XCTAssertFalse(gitignore.contains(["cut", "over"].joined()))
        XCTAssertFalse(gitignore.contains(["bough", "internal"].joined(separator: "-")))
        XCTAssertFalse(gitignore.contains(["Imported", "from"].joined(separator: " ")))
    }

    func testPresentationLayerDoesNotDirectlyPerformExternalMutation() throws {
        let presentationFiles = try swiftFiles(under: repoRoot.appendingPathComponent("Sources/Bough"))
            .filter { file in
                let source = try sourceText(at: file)
                return source.contains(": View")
                    || source.contains(": NSViewRepresentable")
                    || source.contains(": ViewModifier")
                    || source.contains("some View")
                    || source.contains("@ViewBuilder")
            }

        XCTAssertFalse(presentationFiles.isEmpty)

        let forbiddenExternalAccessTokens = [
            "FileManager.default",
            "Data(contentsOf:",
            "String(contentsOf:",
            "write(to:",
            "createDirectory(",
            "removeItem(",
            "copyItem(",
            "moveItem(",
            "URLSession",
            "Process(",
            "Process()",
            "NWConnection",
            "NWListener",
        ]
        let allowedConfigMutationFiles: Set<String> = [
            "Sources/Bough/SettingsView.swift",
            "Sources/Bough/Settings/UsagePage.swift",
        ]
        let forbiddenConfigMutationTokens = [
            "ConfigInstaller.",
            "RemoteInstaller.",
            "UserDefaults.standard.set(",
            "UserDefaults.standard.removeObject(",
        ]

        for file in presentationFiles {
            let relativePath = relativePath(for: file)
            let source = try sourceText(at: file)
            for token in forbiddenExternalAccessTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) directly uses \(token)")
            }
            for token in forbiddenConfigMutationTokens where source.contains(token) {
                XCTAssertTrue(
                    allowedConfigMutationFiles.contains(relativePath),
                    "\(relativePath) directly mutates external config via \(token)"
                )
            }
        }
    }

    func testToolResponsibilityGroupsStaySeparated() throws {
        let toolsRoot = repoRoot.appendingPathComponent("Tools", isDirectory: true)
        let toolEntries = try FileManager.default.contentsOfDirectory(
            at: toolsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var toolGroups: Set<String> = []
        var directToolFiles: [String] = []
        for entry in toolEntries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                toolGroups.insert(entry.lastPathComponent)
            } else {
                directToolFiles.append(entry.lastPathComponent)
            }
        }

        XCTAssertEqual(toolGroups, ["Build", "Release", "Smoke"])
        XCTAssertTrue(directToolFiles.isEmpty, "Tools root must not own direct files: \(directToolFiles.sorted())")

        XCTAssertEqual(
            try relativeFilePaths(under: "Tools/Build"),
            [
                "build-app.sh",
                "build-dmg.sh",
                "regenerate-app-icon.sh",
            ]
        )
        XCTAssertEqual(
            try relativeFilePaths(under: "Tools/Release"),
            [
                "appcast.xml",
                "check-version-consistency.sh",
                "extract-changelog.sh",
                "release-flow.sh",
                "update-appcast.sh",
            ]
        )
        XCTAssertEqual(
            try relativeFilePaths(under: "Tools/Smoke"),
            [
                "smoke-packaged-usage-monitor.sh",
                "sparkle-upgrade-smoke.sh",
            ]
        )
    }

    private func publicCandidateRootEntries() throws -> Set<String> {
        let localOnlyRootEntries: Set<String> = [
            ".DS_Store",
            ".agents",
            ".build",
            ".claude",
            ".codex",
            ".git",
            ".swiftpm",
            ".superpowers",
            "DerivedData",
            "dist",
            planningRootName,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: repoRoot,
            includingPropertiesForKeys: nil
        )
        return Set(entries.map(\.lastPathComponent).filter { !localOnlyRootEntries.contains($0) })
    }

    private var planningRootName: String {
        ".pla" + "nning"
    }

    private var buildWrapperName: String {
        ["build", "sh"].joined(separator: ".")
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        try files(under: root).filter { $0.pathExtension == "swift" }
    }

    private func files(under root: URL) throws -> [URL] {
        let exists = FileManager.default.fileExists(atPath: root.path)
        _ = try XCTUnwrap(exists ? root : nil, "Missing source scan root: \(root.path)")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ), "Failed to enumerate source scan root: \(root.path)")
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                continue
            }
            result.append(url)
        }
        return result
    }

    private func relativeFilePaths(under relativeRoot: String) throws -> Set<String> {
        let root = repoRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        return Set(try files(under: root).map { $0.lastPathComponent })
    }

    private func importedModules(in source: String) -> Set<String> {
        var modules: Set<String> = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else {
                continue
            }
            let module = trimmed
                .dropFirst("import ".count)
                .split(separator: " ")
                .first
                .map(String.init)
            if let module {
                modules.insert(module)
            }
        }
        return modules
    }

    private func sourceText(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = repoRoot.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return filePath
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
