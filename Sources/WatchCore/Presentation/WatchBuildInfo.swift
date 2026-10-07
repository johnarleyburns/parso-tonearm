import Foundation

/// The build label shown in the watch app's About screen. Keeping formatting here makes the
/// installed-build contract testable without booting SwiftUI or relying on a particular bundle.
public enum WatchBuildInfo {
    public static func label(version: String?, build: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (version.isEmpty, build.isEmpty) {
        case (false, false): return "Version \(version) (\(build))"
        case (false, true): return "Version \(version)"
        case (true, false): return "Build \(build)"
        case (true, true): return "Build unavailable"
        }
    }
}
