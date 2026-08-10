import Foundation
import Combine

/// View model for the Library screen (§41.2). Owns the live `DJTrackRow`
/// observation and the folder-import action; the view renders `filteredRows`
/// and never talks to the database directly.
@MainActor
public final class LibraryModel: ObservableObject {
    @Published public private(set) var rows: [DJTrackRow] = []
    @Published public var searchText: String = ""
    @Published public private(set) var isImporting = false
    @Published public private(set) var lastImport: ImportSummary?
    @Published public private(set) var importError: String?

    public let store: DJLibraryStore
    private var observation: Task<Void, Never>?

    public init(store: DJLibraryStore = .shared) {
        self.store = store
    }

    /// Client-side literal filter on top of the live rows. Cheap for the bare
    /// list; the repository's own `LibraryQuery` filter backs the unit tests.
    public var filteredRows: [DJTrackRow] {
        guard !searchText.isEmpty else { return rows }
        return rows.filter { row in
            row.title.localizedCaseInsensitiveContains(searchText)
                || row.artistNames.localizedCaseInsensitiveContains(searchText)
                || (row.albumTitle?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    public func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            guard let self else { return }
            let stream = self.store.observeTracks(LibraryQuery())
            for await newRows in stream {
                self.rows = newRows
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    public func importFolder(_ url: URL) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            lastImport = try await store.importFolder(url)
        } catch {
            importError = error.localizedDescription
        }
    }
}
