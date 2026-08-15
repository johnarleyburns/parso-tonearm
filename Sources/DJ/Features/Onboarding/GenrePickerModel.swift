import Foundation
import TonearmCore

/// The §41.1a genre picker's session VM (mockup `ipad/15-genre-picker.html`,
/// plan 5.6, FR-LIB-10). Owns the curated genre tree, the multi-select, the
/// lazily-fetched catalogue counts, and the "create one library per selected
/// genre" action. **Free tier; no account is requested** (§18A.2).
///
/// The catalogue probe is the honesty rule in §18A.6: an unreachable catalogue
/// reports an honest error (`catalogueError`) — it never renders as an empty
/// library. A transient transport failure just drops the count line.
@MainActor
public final class GenrePickerModel: ObservableObject {

    /// A genre the user selected. `path` is the §18A.3 source identity
    /// (`electronic/techno`), so a sub-genre is a distinct library from its
    /// parent.
    public struct Selection: Equatable, Hashable, Sendable, Identifiable {
        public let path: String
        public let name: String
        public var id: String { path }
    }

    @Published public private(set) var roots: [JamendoGenreNode]
    @Published public private(set) var selectedPaths: Set<String> = []
    /// genre path → catalogue `fullcount`, fetched lazily when a node is
    /// expanded. Absent = not yet known (the count line just doesn't show).
    @Published public private(set) var counts: [String: Int] = [:]
    /// The honest failure state (per §18A.6): a reachability probe failed.
    @Published public private(set) var catalogueError: String?
    @Published public var isAdding = false

    /// The §18A.2 optional-credentials checkbox — collapsed, gates nothing,
    /// and in M5 carries no account flow. Toggling it changes nothing.
    @Published public var showsAccountOption = false

    /// Creates a `Source` for a selected genre. Set by the host (app-side);
    /// `nil` until then.
    public var createSource: ((Selection) async throws -> Void)?

    private let api: JamendoAPI

    public init(api: JamendoAPI? = nil) {
        self.api = api ?? JamendoAPI(clientID: JamendoAppConfig.clientID,
                                     baseURL: JamendoAppConfig.baseURL)
        self.roots = JamendoGenreTree.roots
    }

    public var selectedGenres: [Selection] {
        JamendoGenreTree.all
            .filter { selectedPaths.contains($0.path) }
            .map { Selection(path: $0.path, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    public func isSelected(_ node: JamendoGenreNode) -> Bool {
        selectedPaths.contains(node.path)
    }

    public func toggle(_ node: JamendoGenreNode) {
        if selectedPaths.contains(node.path) {
            selectedPaths.remove(node.path)
        } else {
            selectedPaths.insert(node.path)
        }
        catalogueError = nil
    }

    /// Fetch the catalogue count for a node, used when a genre is expanded.
    /// A permanent failure (an unconfigured build) sets the honest error once;
    /// a transient failure just leaves the count unknown.
    public func loadCount(for node: JamendoGenreNode) async {
        guard counts[node.path] == nil else { return }
        do {
            counts[node.path] = try await catalogueCount(node: node)
        } catch let failure as JamendoGenreError where failure == .notConfigured {
            catalogueError = failure.errorDescription
        } catch {
            // transient — the count line simply stays absent
        }
    }

    /// Create one `Source` per selected genre, through the host's seam.
    /// Returns `false` (with an honest error) if any creation fails.
    @discardableResult
    public func addSelected() async -> Bool {
        guard !selectedGenres.isEmpty else { return false }
        guard createSource != nil else {
            catalogueError = "Can't add genres yet — the library store isn't connected."
            return false
        }
        isAdding = true
        defer { isAdding = false }
        for genre in selectedGenres {
            do {
                try await createSource?(genre)
            } catch let failure {
                catalogueError = (failure as? LocalizedError)?.errorDescription
                    ?? failure.localizedDescription
                return false
            }
        }
        return true
    }

    private func catalogueCount(node: JamendoGenreNode) async throws -> Int {
        let provider = JamendoGenreProvider(clientID: api.clientID,
                                            session: api.session,
                                            sourcePath: node.path)
        return try await provider.catalogueCount(path: node.path)
    }
}
