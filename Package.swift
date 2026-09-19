// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TonearmCore",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "TonearmCore", targets: ["TonearmCore"]),
        .library(name: "TonearmDiscovery", targets: ["TonearmDiscovery"]),
        .library(name: "TonearmWatchProtocol", targets: ["TonearmWatchProtocol"]),
        .library(name: "TonearmWatchCore", targets: ["TonearmWatchCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Audio-engine unification (parso-audio-engine/docs/UNIFICATION_PLAN.md).
        // 1.1.0 ships the streaming cache-key fix for Internet Archive
        // playback (a URL with unencoded punctuation, e.g. a space or
        // parenthesis, previously hashed to a different cache key than the
        // one callers computed from the same raw URL, causing eviction/
        // offline-lookup mismatches — "shows cached, play does nothing").
        .package(url: "https://github.com/johnarleyburns/parso-audio-engine.git", exact: "1.2.0")
    ],
    targets: [
        .target(
            name: "TonearmCore",
            dependencies: [
                "TonearmWatchProtocol",
                "TonearmWatchCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine"),
                .product(name: "ParsoAudioPlayback", package: "parso-audio-engine")
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
                "Sources/Discovery",
                "Sources/Features",
                "Sources/Media",
                "Config",
                "data",
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
                "Sources/Support",
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
            cSettings: [
                .define("SQLITE_CORE", to: "1"),
                // sqlite-vec is vendored C code whose upstream integer-width
                // conversions are intentional for its SQLite ABI.
                .unsafeFlags(["-Wno-shorten-64-to-32"])
            ]
        ),
        .target(
            name: "CLAMEBridge",
            path: "Sources/CLAMEBridge",
            exclude: [
                "vendor/lame-3.100/COPYING",
                "vendor/lame-3.100/LICENSE",
                "vendor/lame-3.100/README"
            ],
            sources: ["src", "vendor/lame-3.100/libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/lame-3.100/include"),
                .headerSearchPath("vendor/lame-3.100/libmp3lame"),
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("vendor/lame-3.100"),
                // SwiftPM's debug configuration defines DEBUG for C targets;
                // libmp3lame gates a lot of stderr/stdout tracing on it
                // (bitstream.c "count1: real: ..." etc.) that has nothing to
                // do with this app's own debug builds — always off.
                .unsafeFlags(["-UDEBUG"]),
                // Xcode 26's explicit-modules build (used for the real
                // device Archive, unlike `swift build`'s own clang
                // invocation) treats libmp3lame's classic textual header
                // includes as module-invisible for stdint.h's types
                // (uint8_t/uint16_t "declaration here is not visible") —
                // force plain textual inclusion for this vendored C code.
                .unsafeFlags(["-fno-modules", "-fno-implicit-modules"])
            ]
        ),
        .target(
            name: "TonearmDiscovery",
            dependencies: [
                "TonearmCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ParsoAudioAnalysis", package: "parso-audio-engine"),
                .product(name: "ParsoAudioNeural", package: "parso-audio-engine"),
                // Remote sparse indexing (docs/plans/remote-sparse-indexing.md)
                // reuses the app's own streaming-cache infrastructure
                // (CachingResourceLoader/SparseCacheStore) pointed at a
                // throwaway, temp-rooted store instead of the real one.
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine")
            ],
            path: "Sources/Discovery",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TonearmCoreTests",
            dependencies: [
                "TonearmCore",
                "TonearmWatchProtocol",
                "TonearmWatchCore",
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine"),
                .product(name: "ParsoAudioPlayback", package: "parso-audio-engine")
            ],
            path: "Tests",
            exclude: [
                // Helper process used by optional integration smoke tests.
                "Support",
                // Discovery tests live in their own target (TonearmDiscoveryTests).
                "DiscoveryTests"
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TonearmDiscoveryTests",
            dependencies: [
                "TonearmDiscovery",
                "TonearmCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine")
            ],
            path: "Tests/DiscoveryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
