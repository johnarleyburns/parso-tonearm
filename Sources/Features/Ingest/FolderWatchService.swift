import Foundation
import UIKit

/// Folder watch: rescans watched folders when the app returns to the
/// foreground and adds any new audio files to the library without a relaunch.
/// Builds on the existing `Playlist.watch` + `folderBookmark` fields and the
/// `IngestService` ingestion path.
actor FolderWatchService {
    static let shared = FolderWatchService()

    private var presenters: [FolderPresenter] = []

    /// Pure diff: audio files present on disk that are not already tracked. Keyed
    /// by resolved absolute path so re-adds and reorders don't duplicate. Exposed
    /// for unit testing without touching the database.
    nonisolated static func newFiles(scanned: [URL], existing: Set<String>) -> [URL] {
        scanned.filter { !existing.contains($0.standardizedFileURL.path) }
    }

    /// Rescans every watched folder playlist and ingests new files into the same
    /// source. Returns the number of files added. Safe to call on foreground.
    @discardableResult
    func rescanWatchedFolders(store: LibraryStore) async -> Int {
        guard let playlists = try? await store.allPlaylists() else { return 0 }
        var added = 0
        for playlist in playlists where playlist.kind == .folder && playlist.watch {
            added += await rescan(playlist: playlist, store: store)
        }
        return added
    }

    private func rescan(playlist: Playlist, store: LibraryStore) async -> Int {
        guard let bookmark = playlist.folderBookmark,
              let (folderURL, _) = BookmarkVault.resolve(bookmark) else { return 0 }
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let scanned = IngestService().scanFolder(folderURL, includeSubfolders: true).map { $0.url }
        // Source that backs this folder playlist (matched by title).
        guard let source = try? await store.firstSource(title: playlist.title, kind: .local),
              let sid = source.id else { return 0 }
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

    /// Installs an `NSFilePresenter` per watched folder so the system notifies us
    /// of changes while active. Presenters are torn down on `stopPresenting`.
    func startPresenting(store: LibraryStore, onChange: @escaping @Sendable () -> Void) async {
        await stopPresenting()
        guard let playlists = try? await store.allPlaylists() else { return }
        for playlist in playlists where playlist.kind == .folder && playlist.watch {
            guard let bookmark = playlist.folderBookmark,
                  let (folderURL, _) = BookmarkVault.resolve(bookmark) else { continue }
            let presenter = FolderPresenter(url: folderURL, onChange: onChange)
            NSFileCoordinator.addFilePresenter(presenter)
            presenters.append(presenter)
        }
    }

    func stopPresenting() async {
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
