import Foundation

enum PlaybackDecision: Equatable {
    case play
    case skipWiFiOnly
    case playFromCache
}

struct NetworkPolicy {
    enum AssetKind: Equatable {
        case local
        case remote
    }

    static func decide(assetKind: AssetKind,
                       isCached: Bool,
                       pathIsExpensive: Bool,
                       streamOnCellular: Bool) -> PlaybackDecision {
        if assetKind == .local { return .play }
        if isCached { return .playFromCache }
        if pathIsExpensive && !streamOnCellular { return .skipWiFiOnly }
        return .play
    }

    static func nextPlayableIndex(after currentIndex: Int,
                                  count: Int,
                                  repeatAll: Bool,
                                  decisionAt: (Int) -> PlaybackDecision) -> Int? {
        guard count > 0 else { return nil }
        var candidate = currentIndex
        var visited = 0
        while visited < count {
            if candidate < count - 1 {
                candidate += 1
            } else if repeatAll {
                candidate = 0
            } else {
                return nil
            }
            visited += 1
            if candidate == currentIndex { return nil }
            if decisionAt(candidate) != .skipWiFiOnly {
                return candidate
            }
        }
        return nil
    }
}
