#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

public enum QueueSource: Equatable {
    case source(Source)
    case playlist(Playlist)
    case library
    case ambient
    case none

    public var label: String {
        switch self {
        case .source(let s): return "From Library: \(s.title)"
        case .playlist(let p): return "From Playlist: \(p.title)"
        case .library: return "From Music"
        case .ambient: return "Ambient"
        case .none: return ""
        }
    }
}

#endif
