import Foundation

/// Injectable library access for Keep Playing.
///
/// Production keeps `LibraryStore.shared`; tests can use `.empty` or a small
/// in-memory resolver. Without this seam a Keep Playing test that expects
/// "nothing compatible" can accidentally hydrate tracks another concurrent
/// test inserted into the shared database, which is exactly the kind of
/// cross-suite interference the Swift Testing migration is removing.
public struct KeepPlayingLibrary: Sendable {
    public var allTrackRows: @Sendable () async -> [TrackRow]
    public var tracksForSource: @Sendable (Int64) async -> [TrackRow]
    public var trackRow: @Sendable (Int64) async -> TrackRow?
    public var excludedTrackIDs: @Sendable () async -> Set<Int64>
    public var djLoadTrackInfo: @Sendable ([Int64]) async -> [Int64: DJLoadTrackInfo]

    public init(
        allTrackRows: @escaping @Sendable () async -> [TrackRow] = {
            (try? await LibraryStore.shared.allTrackRows()) ?? []
        },
        tracksForSource: @escaping @Sendable (Int64) async -> [TrackRow] = { sourceId in
            (try? await LibraryStore.shared.tracks(forSource: sourceId)) ?? []
        },
        trackRow: @escaping @Sendable (Int64) async -> TrackRow? = { id in
            try? await LibraryStore.shared.trackRow(id: id)
        },
        excludedTrackIDs: @escaping @Sendable () async -> Set<Int64> = {
            (try? await LibraryStore.shared.excludedTrackIDs()) ?? []
        },
        djLoadTrackInfo: @escaping @Sendable ([Int64]) async -> [Int64: DJLoadTrackInfo] = { ids in
            (try? await LibraryStore.shared.djLoadTrackInfo(trackIds: ids)) ?? [:]
        }
    ) {
        self.allTrackRows = allTrackRows
        self.tracksForSource = tracksForSource
        self.trackRow = trackRow
        self.excludedTrackIDs = excludedTrackIDs
        self.djLoadTrackInfo = djLoadTrackInfo
    }

    public static let live = KeepPlayingLibrary()

    /// No tracks, no exclusions: the deterministic "nothing to continue with"
    /// library for exhaustion tests.
    public static let empty = KeepPlayingLibrary(
        allTrackRows: { [] },
        tracksForSource: { _ in [] },
        trackRow: { _ in nil },
        excludedTrackIDs: { [] },
        djLoadTrackInfo: { _ in [:] }
    )
}
