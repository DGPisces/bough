import CoreGraphics
import ImageIO
import XCTest

final class DocsCreditsAssetAuditTests: XCTestCase {
    private let approvedSources = [
        "antigravity",
        "claude",
        "codebuddy",
        "codex",
        "copilot",
        "cursor",
        "droid",
        "gemini",
        "hermes",
        "kimi",
        "opencode",
        "qoder",
        "qwen",
        "stepfun",
        "trae",
        "workbuddy",
    ]

    func testReadmeMascotGIFsMatchApprovedSourcesAndSize() throws {
        let gifRoot = TestHelpers.repoRoot(from: #filePath)
            .appendingPathComponent("Assets/README/mascots")
        let names = try FileManager.default.contentsOfDirectory(
            at: gifRoot,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "gif" }
        .map(\.lastPathComponent)
        .sorted()

        XCTAssertEqual(names, approvedSources.map { "\($0).gif" })

        for source in approvedSources {
            let data = try Data(contentsOf: gifRoot.appendingPathComponent("\(source).gif"))
            XCTAssertGreaterThanOrEqual(data.count, 10)
            XCTAssertEqual(String(data: data.prefix(6), encoding: .ascii), "GIF89a")
            XCTAssertEqual(gifDimension(data[6], data[7]), 128, "\(source).gif width")
            XCTAssertEqual(gifDimension(data[8], data[9]), 128, "\(source).gif height")

            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let frameCount = CGImageSourceGetCount(imageSource)
            XCTAssertGreaterThan(frameCount, 1, "\(source).gif should decode as an animation")
            let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, frameCount - 1, nil))
            XCTAssertEqual(rgbaBytes(first), rgbaBytes(last), "\(source).gif first and last frames should match")
        }
    }

    func testReadmesUsePublicMediaAndSupportedToolsContract() throws {
        let root = TestHelpers.repoRoot(from: #filePath)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: root.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)
        let screenshotURL = root.appendingPathComponent("Assets/README/panel-session-music-airdrop.png")

        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotURL.path))
        let screenshotData = try Data(contentsOf: screenshotURL)
        let screenshotSource = try XCTUnwrap(CGImageSourceCreateWithData(screenshotData as CFData, nil))
        let screenshot = try XCTUnwrap(CGImageSourceCreateImageAtIndex(screenshotSource, 0, nil))
        XCTAssertGreaterThanOrEqual(screenshot.width, 1000)
        XCTAssertGreaterThanOrEqual(screenshot.height, 600)
        XCTAssertTrue(readme.contains("![Bough notch panel demo](Assets/README/panel-session-music-airdrop.png)"))
        XCTAssertTrue(readmeZH.contains("![Bough 刘海面板演示](Assets/README/panel-session-music-airdrop.png)"))
        XCTAssertTrue(readme.contains("<summary>Supported tools</summary>"))
        XCTAssertTrue(readmeZH.contains("<summary>支持的工具</summary>"))

        for provider in [
            "Codex",
            "Claude Code",
            "Cursor",
            "GitHub Copilot",
            "Gemini CLI",
            "OpenCode",
            "Qwen Code",
            "Kimi",
            "Trae",
            "Qoder",
            "Antigravity",
            "CodeBuddy",
            "WorkBuddy",
            "Droid",
            "Hermes",
            "StepFun",
        ] {
            XCTAssertTrue(readme.contains(provider), "README.md missing \(provider)")
            XCTAssertTrue(readmeZH.contains(provider), "README.zh-CN.md missing \(provider)")
        }

        let legacyImagePath = ["docs", "images"].joined(separator: "/")
        XCTAssertFalse(readme.contains(legacyImagePath))
        XCTAssertFalse(readmeZH.contains(legacyImagePath))
        XCTAssertFalse(readme.contains("official endorsement"))
        XCTAssertFalse(readmeZH.contains("不代表相关工具"))
    }

    func testLicenseCreditsContributingAndChangelogPublicContract() throws {
        let root = TestHelpers.repoRoot(from: #filePath)
        let license = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        let credits = try String(contentsOf: root.appendingPathComponent("CREDITS.md"), encoding: .utf8)
        let contributing = try String(contentsOf: root.appendingPathComponent("CONTRIBUTING.md"), encoding: .utf8)
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)

        XCTAssertTrue(license.contains("Copyright (c) 2026 DGPisces"))
        XCTAssertFalse(license.contains("wxtsky"))

        XCTAssertTrue(credits.contains("Thanks to [CodeIsland](https://github.com/wxtsky/CodeIsland) for providing the foundation."))
        XCTAssertTrue(credits.contains("Copyright (c) 2026 wxtsky"))
        XCTAssertTrue(credits.contains("Sparkle"))
        XCTAssertTrue(credits.contains("Yams"))
        XCTAssertTrue(credits.contains("TOMLKit"))
        XCTAssertTrue(credits.contains("Pixelify Sans"))
        XCTAssertFalse(credits.contains("antigravity"))
        XCTAssertFalse(credits.contains("codex.gif"))

        XCTAssertTrue(contributing.contains("GitHub private vulnerability reporting"))
        XCTAssertFalse(contributing.contains("@"))

        XCTAssertTrue(changelog.contains("## [v1.0.0-rc.1] - 2026-06-02"))
        XCTAssertFalse(changelog.contains(["0", "1", "0"].joined(separator: ".")))
    }

    func testRuntimeResourcesKeepPublicSafeRequiredAssetsOnly() throws {
        let root = TestHelpers.repoRoot(from: #filePath)
        let resources = root.appendingPathComponent("Sources/Bough/Resources")

        for absent in [
            ".DS_Store",
            "Assets.car",
            "Fonts/PixelifySans-README.html",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: resources.appendingPathComponent(absent).path),
                "Generated or non-required resource remains: \(absent)"
            )
        }

        for required in [
            "8bit_approval.wav",
            "8bit_boot.wav",
            "8bit_complete.wav",
            "8bit_error.wav",
            "8bit_start.wav",
            "8bit_submit.wav",
            "AppIcon.icns",
            "Fonts/PixelifySans-OFL.txt",
            "Fonts/PixelifySans-Variable.ttf",
            "bough-mascot/idle-sheet.png",
            "bough-opencode.js",
            "bough-pi.ts",
            "bough-remote-hook.py",
            "bough-statusline-bridge.sh",
            "bough-statusline-wrapper.sh.template",
            "settings-animations/clickJumpCollapse-sheet.png",
            "settings-animations/collapseMouseLeave-sheet.png",
            "settings-animations/completionExpand-sheet.png",
            "settings-animations/hapticHover-sheet.png",
            "settings-animations/hideFullscreen-sheet.png",
            "settings-animations/hideNoSession-sheet.png",
        ] {
            let url = resources.appendingPathComponent(required)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing required resource: \(required)")
            XCTAssertGreaterThan((try Data(contentsOf: url)).count, 0, "Required resource is empty: \(required)")
        }

        for source in approvedSources {
            for asset in ["alert-sheet.png", "icon.png", "idle-sheet.png", "work-sheet.png"] {
                let relativePath = "mascots/\(source)/\(asset)"
                let url = resources.appendingPathComponent(relativePath)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing mascot asset: \(relativePath)")
                XCTAssertGreaterThan((try Data(contentsOf: url)).count, 0, "Mascot asset is empty: \(relativePath)")
            }
        }
    }

    func testPublicDocsDoNotContainBlockedPrivateTransitionTerms() throws {
        let root = TestHelpers.repoRoot(from: #filePath)
        let docNames = [
            "README.zh-CN.md",
            "README.md",
            "LICENSE",
            "CREDITS.md",
            "CONTRIBUTING.md",
            "CHANGELOG.md",
        ]
        let forbidden: [String] = [
            ["internal", "beta"].joined(separator: " "),
            ["private", "stable"].joined(separator: " "),
            ["public", ["cut", "over"].joined()].joined(separator: " "),
            ["cut", "over"].joined(),
            ["bough", "internal"].joined(separator: "-"),
            ["private", "repo"].joined(separator: " "),
            ["Home", "brew"].joined(),
            ["brew", "install"].joined(separator: " "),
            ["SECURITY", "md"].joined(separator: "."),
            ["CODE", "OF", "CONDUCT"].joined(separator: "_"),
            ["Code", "of", "Conduct"].joined(separator: " "),
            ["0", "4", ""].joined(separator: "."),
            ["0", "3", ""].joined(separator: "."),
            ["0", "2", ""].joined(separator: "."),
            ["0", "1", "0"].joined(separator: "."),
            ["private", "PAT"].joined(separator: " "),
            ["app", "cast"].joined(),
        ]

        for docName in docNames {
            var content = try String(contentsOf: root.appendingPathComponent(docName), encoding: .utf8)
            content = content.replacingOccurrences(of: "GitHub private vulnerability reporting", with: "")
            for term in forbidden {
                XCTAssertFalse(content.contains(term), "\(docName) contains forbidden term: \(term)")
            }
            XCTAssertNil(content.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]), "\(docName) contains an email address")
        }
    }

    private func gifDimension(_ low: UInt8, _ high: UInt8) -> Int {
        Int(low) + (Int(high) << 8)
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.interpolationQuality = .none
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
