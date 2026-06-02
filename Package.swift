// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bough",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle — auto-update framework. Pinned to 2.6+ for stable
        // SPUStandardUpdaterController + ed25519 signature verification.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // TOMLKit — TOML 1.0 round-trip parser used only by the Bough executable
        // for [hooks.*] cleanup in ConfigInstaller (D-01, D-04). Wraps
        // marzer/tomlplusplus; MIT-licensed. Pinned at latest stable floor 0.6.0
        // targeting Swift 5.9 / macOS 14 (D-02).
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "BoughCore",
            path: "Sources/BoughCore"
        ),
        .executableTarget(
            name: "Bough",
            dependencies: [
                "BoughCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/Bough",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "bough-bridge",
            dependencies: ["BoughCore"],
            path: "Sources/BoughBridge"
        ),
        .executableTarget(
            name: "bough-usage-monitor",
            dependencies: ["BoughCore"],
            path: "Sources/BoughUsageMonitor"
        ),
        .testTarget(
            name: "BoughCoreTests",
            dependencies: ["BoughCore"],
            path: "Tests/BoughCoreTests"
        ),
        .testTarget(
            name: "BoughTests",
            dependencies: [
                "Bough",
                .product(name: "Yams", package: "Yams"),
                // TOMLKit listed explicitly so test files can import TOMLKit directly
                // without a build error (WR-04). Binary links correctly via "Bough" but
                // the explicit dep future-proofs direct imports in test code.
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Tests/BoughTests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
