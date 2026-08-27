// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TonearmCore",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "TonearmCore", targets: ["TonearmCore"]),
        .library(name: "TonearmDJ", targets: ["TonearmDJ"]),
        .library(name: "TonearmWatchProtocol", targets: ["TonearmWatchProtocol"]),
        .library(name: "TonearmWatchCore", targets: ["TonearmWatchCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "TonearmCore",
            dependencies: [
                "TonearmWatchProtocol",
                "TonearmWatchCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: ".",
            exclude: [
                ".build",
                "CLAUDE.md",
                ".github",
                "docs",
                "docker-compose.remote-test.yml",
                "docker-compose.ui-regression.yml",
                "ExportOptions.plist",
                "IMPLEMENTATION_PLAN.md",
                "LICENSE",
                "Makefile",
                "Package.resolved",
                "README.md",
                "Resources/splash_screen.jpg",
                "Resources/Models",
                "Resources/CLAP",
                "ShareExtension",
                "Sources/App",
                "Sources/CSQLiteVec",
                "Sources/DesignSystem",
                "Sources/DJ",
                "Sources/Features",
                "Sources/Media",
                "Sources/Widgets",
                "splash_screen.jpg",
                "TONEARM-TEST-ARCHITECTURE.md",
                "Tests",
                "Tonearm.xcodeproj",
                "UITests",
                "UIRegressionTests",
                "WatchApp",
                "WatchUITests",
                "WidgetsExtension",
                "project.yml",
                "scripts",
                "tools",
                "current_status.md",
                "Resources/Assets.xcassets",
                "Resources/Tonearm.storekit",
                "Sources/WatchProtocol",
                "Sources/WatchCore"
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
                "Sources/WatchExports.swift",
                "Sources/WatchSync"
            ],
            resources: [
                .copy("Resources/Audio"),
                .copy("Resources/Video")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TonearmWatchProtocol",
            path: "Sources/WatchProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TonearmWatchCore",
            dependencies: ["TonearmWatchProtocol"],
            path: "Sources/WatchCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CSQLiteVec",
            path: "Sources/CSQLiteVec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [.define("SQLITE_CORE", to: "1")]
        ),
        .target(
            name: "TonearmDJ",
            dependencies: [
                "TonearmCore",
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/DJ",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "TonearmCoreTests",
            dependencies: [
                "TonearmCore",
                "TonearmWatchProtocol",
                "TonearmWatchCore"
            ],
            path: "Tests",
            exclude: [
                // Helper process used by optional integration smoke tests.
                "Support",
                // DJ tests live in their own target (TonearmDJTests).
                "DJTests"
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TonearmDJTests",
            dependencies: ["TonearmDJ"],
            path: "Tests/DJTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
