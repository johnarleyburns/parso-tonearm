#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

/// A queue source that can supply the next batch on demand. Remote browse
/// screens use this for ad-hoc queues whose selected track is not persisted in
/// the library yet (Jamendo is the first one).
@MainActor
public protocol QueueContinuationSource: AnyObject {
    func nextTracks(excluding: Set<Int64>, limit: Int) async -> [TrackRow]
}

public enum QueueSource {
    case source(Source)
    case playlist(Playlist)
    case library
    case ambient
    case continuation(any QueueContinuationSource)
    case none

    public var label: String {
        switch self {
        case .source(let s): return String(localized: "From Library: \(s.title)", bundle: .module)
        case .playlist(let p): return String(localized: "From Playlist: \(p.title)", bundle: .module)
        case .library: return String(localized: "From Music", bundle: .module)
        case .ambient: return String(localized: "Ambient", bundle: .module)
        case .continuation: return "Jamendo"
        case .none: return ""
        }
    }
}

extension QueueSource: Equatable {
    public static func == (lhs: QueueSource, rhs: QueueSource) -> Bool {
        switch (lhs, rhs) {
        case (.source(let a), .source(let b)): return a == b
        case (.playlist(let a), .playlist(let b)): return a == b
        case (.library, .library): return true
        case (.ambient, .ambient): return true
        case (.continuation(let a), .continuation(let b)): return a === b
        case (.none, .none): return true
        default: return false
        }
    }
}

#endif
