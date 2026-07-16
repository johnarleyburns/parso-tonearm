// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TonearmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
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
                ".github",
                "docs",
                "docker-compose.remote-test.yml",
                "ExportOptions.plist",
                "LICENSE",
                "Makefile",
                "Package.resolved",
                "README.md",
                "ShareExtension",
                "Sources/App",
                "Sources/DesignSystem",
                "Sources/Features",
                "Sources/Media",
                "Sources/Widgets",
                "TONEARM-TEST-ARCHITECTURE.md",
                "Tests",
                "Tonearm.xcodeproj",
                "UITests",
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
                "Sources/Sync"
            ],
            resources: [
                .copy("Resources/Audio"),
                .copy("Resources/Video")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TonearmCoreTests",
            dependencies: ["TonearmCore"],
            path: "Tests",
            exclude: [
                // Not host-runnable: these touch UIImage / WidgetKit / the app's
                // Bundle.main Info.plist, which don't exist under `swift test`.
                "BackgroundAddTests.swift",
                "SpectrogramDetectorTests.swift",
                "WidgetSnapshotTests.swift",
                "PlatformSupportTests.swift",
                "Support"
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
