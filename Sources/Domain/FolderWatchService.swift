import Foundation

/// Folder watch: rescans watched folders when the app returns to the
/// foreground and adds any new audio files to the library without a relaunch.
/// Two representations are watched side by side: `Playlist.watch` +
/// `folderBookmark` (folders imported before folder imports stopped creating a
/// playlist — real report: "do not add any of the files shown to a playlist
/// automatically") and `Source.watch` + `Source.folderBookmark` (every import
/// since). Both feed the same `IngestService` ingestion path.
public actor FolderWatchService {
    public static let shared = FolderWatchService()

    private var presenters: [FolderPresenter] = []

    /// Pure diff: audio files present on disk that are not already tracked. Keyed
    /// by resolved absolute path so re-adds and reorders don't duplicate. Exposed
    /// for unit testing without touching the database.
    public nonisolated static func newFiles(scanned: [URL], existing: Set<String>) -> [URL] {
        scanned.filter { !existing.contains($0.standardizedFileURL.path) }
    }

    /// Rescans every watched folder (legacy playlist-backed and current
    /// source-backed alike) and ingests new files into the same source.
    /// Returns the number of files added. Safe to call on foreground.
    @discardableResult
    public func rescanWatchedFolders(store: LibraryStore) async -> Int {
        var added = 0
        if let playlists = try? await store.allPlaylists() {
            for playlist in playlists where playlist.kind == .folder && playlist.watch {
                added += await rescan(sourceId: playlist.sourceId, bookmark: playlist.folderBookmark, store: store)
            }
        }
        if let sources = try? await store.allSources() {
            for source in sources where source.kind == .local && source.localIsFolder && (source.watch ?? false) {
                added += await rescan(sourceId: source.id, bookmark: source.folderBookmark, store: store)
            }
        }
        return added
    }

    private func rescan(sourceId: Int64?, bookmark: Data?, store: LibraryStore) async -> Int {
        guard let bookmark, let (folderURL, _) = BookmarkVault.resolve(bookmark) else { return 0 }
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let scanned = IngestService().scanFolder(folderURL, includeSubfolders: true).map { $0.url }
        guard let sid = sourceId else { return 0 }
        let existingRows = (try? await store.tracks(forSource: sid)) ?? []
        let existingPaths = Set(existingRows.compactMap { row -> String? in
            guard let urlString = row.asset?.remoteURL, let url = URL(string: urlString) else { return nil }
            return url.standardizedFileURL.path
        })

        let fresh = Self.newFiles(scanned: scanned, existing: existingPaths)
        guard !fresh.isEmpty else { return 0 }
        await IngestService().addFiles(fresh, toSourceId: sid, into: store)
        return fresh.count
    }

    /// Installs an `NSFilePresenter` per watched folder (both representations,
    /// see above) so the system notifies us of changes while active.
    /// Presenters are torn down on `stopPresenting`.
    public func startPresenting(store: LibraryStore, onChange: @escaping @Sendable () -> Void) async {
        await stopPresenting()
        if let playlists = try? await store.allPlaylists() {
            for playlist in playlists where playlist.kind == .folder && playlist.watch {
                guard let bookmark = playlist.folderBookmark,
                      let (folderURL, _) = BookmarkVault.resolve(bookmark) else { continue }
                let presenter = FolderPresenter(url: folderURL, onChange: onChange)
                NSFileCoordinator.addFilePresenter(presenter)
                presenters.append(presenter)
            }
        }
        if let sources = try? await store.allSources() {
            for source in sources where source.kind == .local && source.localIsFolder && (source.watch ?? false) {
                guard let bookmark = source.folderBookmark,
                      let (folderURL, _) = BookmarkVault.resolve(bookmark) else { continue }
                let presenter = FolderPresenter(url: folderURL, onChange: onChange)
                NSFileCoordinator.addFilePresenter(presenter)
                presenters.append(presenter)
            }
        }
    }

    public func stopPresenting() async {
        for presenter in presenters { NSFileCoordinator.removeFilePresenter(presenter) }
        presenters.removeAll()
    }
}

/// Minimal `NSFilePresenter` that reports subitem changes for a watched folder.
final class FolderPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange()
    }
}
