import Foundation

/// Resolves "Play" at any browse depth by descending a remote library's tree
/// to the first run of playable audio nodes.
///
/// - Library level (artists): first artist → first album → its tracks.
/// - Artist level (albums): first album → its tracks.
/// - Album level (tracks): the tracks directly.
/// - Folder hierarchies (WebDAV/SMB/cloud): the first folder chain that yields audio.
///
/// The search is depth-first and picks the first sibling branch that produces
/// audio, so an empty first artist or album falls through to the next one and
/// playback still starts. It is bounded by `maxDepth` and a visited-path set,
/// and a failing `browse` is treated as an empty branch.
public enum RemoteScopePlayback {
    public static func firstAudioNodes(in provider: any RemoteLibraryProvider,
                                       path: String,
                                       maxDepth: Int = 5) async -> [RemoteNode] {
        var visited: Set<String> = []
        return await descend(in: provider, path: path, visited: &visited,
                             depth: 0, maxDepth: maxDepth)
    }

    private static func descend(in provider: any RemoteLibraryProvider,
                                path: String,
                                visited: inout Set<String>,
                                depth: Int,
                                maxDepth: Int) async -> [RemoteNode] {
        guard depth <= maxDepth, !visited.contains(path) else { return [] }
        visited.insert(path)
        guard let nodes = try? await provider.browse(path: path) else { return [] }
        let audio = nodes.filter { $0.kind == .audio }
        if !audio.isEmpty { return audio }
        for node in nodes where node.kind != .audio {
            let found = await descend(in: provider, path: node.path, visited: &visited,
                                      depth: depth + 1, maxDepth: maxDepth)
            if !found.isEmpty { return found }
        }
        return []
    }
}
