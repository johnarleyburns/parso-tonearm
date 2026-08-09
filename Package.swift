// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TonearmCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "TonearmCore", targets: ["TonearmCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "TonearmCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: ".",
            exclude: [
                ".build",
                "CLAUDE.md",
                ".github",
                "docs",
                "docker-compose.remote-test.yml",
                "ExportOptions.plist",
                "IMPLEMENTATION_PLAN.md",
                "LICENSE",
                "Makefile",
                "Package.resolved",
                "README.md",
                "Resources/splash_screen.jpg",
                "ShareExtension",
                "Sources/App",
                "Sources/DesignSystem",
                "Sources/Features",
                "Sources/Media",
                "Sources/Widgets",
                "splash_screen.jpg",
                "TONEARM-TEST-ARCHITECTURE.md",
                "Tests",
                "Tonearm.xcodeproj",
                "UITests",
                "WatchApp",
                "WatchUITests",
                "WidgetsExtension",
                "project.yml",
                "scripts",
                "Resources/Assets.xcassets",
                "Resources/Tonearm.storekit"
            ],
            sources: [
                "Sources/Art",
                "Sources/Audio",
                "Sources/Data",
                "Sources/Domain",
                "Sources/IA",
                "Sources/Intents",
                "Sources/Pro",
                "Sources/Remote",
                "Sources/Share",
                "Sources/Snapshot",
                "Sources/Sync",
                "Sources/WatchPlayback",
                "Sources/WatchSync"
            ],
            resources: [
                .copy("Resources/Audio"),
                .copy("Resources/Video")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TonearmCoreTests",
            dependencies: ["TonearmCore"],
            path: "Tests",
            exclude: [
                // Helper process used by optional integration smoke tests.
                "Support"
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
