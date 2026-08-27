import Foundation

enum WatchFeatureFlags {
    static var swiftDataWatchArchitecture: Bool {
        ProcessInfo.processInfo.arguments.contains("-swiftDataWatchArchitecture")
    }
}
