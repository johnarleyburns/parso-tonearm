import Foundation

/// How a track should be played on the watch.
public enum WatchPlayableSource: Equatable {
    /// A file already downloaded to the watch.
    case local(URL)
    /// A remote URL streamed directly over the network.
    case stream(URL)
}

/// Pure resolution of *how* to play a watch track. Kept free of any file-system
/// or network I/O so it is fully unit-testable: callers pass in whatever local
/// file they found (if any) and the track's remote URLs, and this decides
/// whether to play the local copy, stream a remote URL, or neither (in which
/// case the caller must fetch the file from the paired iPhone).
public enum WatchTrackResolver {

    /// The first streamable remote URL among the candidates, or nil. Only
    /// `http`/`https` URLs are considered streamable — a bare relative path or a
    /// `file:` URL is not something the watch can pull over the air.
    public static func streamURL(remoteURL: String?, altRemoteURL: String? = nil) -> URL? {
        for candidate in [remoteURL, altRemoteURL] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return url
        }
        return nil
    }

    /// Resolve the effective playback source for a track. A downloaded local file
    /// always wins (works offline, no latency); otherwise a streamable remote URL
    /// is used; otherwise `nil`, signalling the caller to request the file from
    /// the iPhone.
    public static func resolve(localURL: URL?,
                               remoteURL: String?,
                               altRemoteURL: String? = nil) -> WatchPlayableSource? {
        if let localURL { return .local(localURL) }
        if let stream = streamURL(remoteURL: remoteURL, altRemoteURL: altRemoteURL) {
            return .stream(stream)
        }
        return nil
    }

    /// Convenience: the URL to hand to the audio engine, regardless of whether it
    /// resolved to a local file or a stream.
    public static func playableURL(localURL: URL?,
                                   remoteURL: String?,
                                   altRemoteURL: String? = nil) -> URL? {
        switch resolve(localURL: localURL, remoteURL: remoteURL, altRemoteURL: altRemoteURL) {
        case .local(let url), .stream(let url): return url
        case nil: return nil
        }
    }
}
