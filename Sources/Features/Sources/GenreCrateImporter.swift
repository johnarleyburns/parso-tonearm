import Foundation
import TonearmCore
import TonearmDJ

/// Downloads a genre source's most-interesting tracks into the DJ library as a
/// **crate playlist** (§18A.4, plan 5.6, dj-regression-suite AT-MIX-1): browse
/// the genre's ordered track list, download each stream into a per-genre cache
/// directory, ingest them as ordinary `track`/`asset` rows (so FR-LIB-8 and the
/// decks treat them exactly like a folder import), and save-or-replace a
/// `DJPlaylist` named after the genre.
///
/// This is the app-side seam that turns a genre library into deck material —
/// the genre itself is just a browseable `Source`; the crate is how its tracks
/// reach the two decks.
@MainActor
final class GenreCrateImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(completed: Int, total: Int)
        case finished(playlistTitle: String, trackCount: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let source: Source
    private let store: DJLibraryStore
    /// How many of the genre's most-interesting tracks a crate holds. A genre
    /// catalogue is large (the live API pages 200 at a time) — a crate is the
    /// top of the order, not the whole library; 6 covers a set and bounds the
    /// download in the live lane.
    private let maxTracks: Int

    init(source: Source, store: DJLibraryStore = .shared, maxTracks: Int = 6) {
        self.source = source
        self.store = store
        self.maxTracks = maxTracks
    }

    var isBusy: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// The crate playlist's name — the source title without the connector
    /// suffix ("Techno (Jamendo)" → "Techno").
    var playlistTitle: String {
        let base = source.title
            .replacingOccurrences(of: " (Jamendo)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Crate" : base
    }

    func run() async {
        do {
            let provider = try RemoteLibraryProviderFactory.provider(for: source)
            let nodes = try await provider.browse(path: source.iaIdentifier ?? "")
            let audio = Array(nodes.filter { $0.kind == .audio }.prefix(maxTracks))
            guard !audio.isEmpty else {
                phase = .failed("No tracks found in this genre")
                return
            }

            let cacheDir = crateDirectory()
            try FileManager.default.createDirectory(at: cacheDir,
                                                    withIntermediateDirectories: true)
            var items: [DJLibraryStore.DownloadedTrackItem] = []
            items.reserveCapacity(audio.count)
            for (index, node) in audio.enumerated() {
                let resolved = try await provider.resolve(node: node)
                let localURL = cacheDir.appendingPathComponent(Self.fileName(for: node, url: resolved.url))
                if !FileManager.default.fileExists(atPath: localURL.path) {
                    try await Self.download(resolved.url, to: localURL)
                }
                items.append(DJLibraryStore.DownloadedTrackItem(
                    localURL: localURL,
                    title: node.metadata?.title ?? node.title,
                    artist: node.metadata?.artist,
                    durationSec: node.metadata?.durationSec ?? node.durationSec))
                phase = .downloading(completed: index + 1, total: audio.count)
            }

            let trackIDs = try await store.importDownloadedTracks(items)
            _ = try await store.saveCrate(title: playlistTitle, trackIDs: trackIDs)
            phase = .finished(playlistTitle: playlistTitle, trackCount: trackIDs.count)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func crateDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = (source.iaIdentifier ?? "").replacingOccurrences(of: "/", with: "-")
        return documents.appendingPathComponent("GenreCrates/\(safe)", isDirectory: true)
    }

    private static func fileName(for node: RemoteNode, url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let base = node.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        return "\(base).\(ext)"
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try data.write(to: destination, options: .atomic)
    }
}
