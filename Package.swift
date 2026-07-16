// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TonearmCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
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
            path: "Sources",
            exclude: [
                "App",
                "DesignSystem",
                "Features",
                "Widgets",
                "Media"
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
                "SpectrogramDetectorTests.swift",
                "WidgetSnapshotTests.swift",
                "PlatformSupportTests.swift"
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
