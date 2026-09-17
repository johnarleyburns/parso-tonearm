#if !os(watchOS)
import AVFoundation
import Foundation
import GRDB
import ParsoAudioStreaming
import TonearmCore

/// Turns a persisted `.remote` `Asset` into a playable-for-analysis
/// `AVURLAsset`, without ever downloading the whole file or touching the
/// app's real persistent cache — the "chosen approach" in
/// docs/plans/remote-sparse-indexing.md: reuse the same
/// `CachingResourceLoader`/`SparseCacheStore` infrastructure that already
/// streams remote playback (MP3 and MP4/M4A alike), pointed at a throwaway,
/// temp-rooted store instead of `AudioCache.shared`.
public enum RemoteSparseAssetResolver {
    /// Deliberately different from the live-playback scheme
    /// (`AudioCache.scheme`, `"tonearm-cache"`) so index-time and
    /// playback-time resource loading are trivially distinguishable in
    /// diagnostics, even though nothing requires it for correctness
    /// (`AVAssetResourceLoaderDelegate` registration is already per-`AVURLAsset`).
    public static let scheme = "tonearm-index-scratch"

    /// Comfortably above the ~180s/track worst case (`BoundedIndexWorker`'s
    /// embedding + musical-analysis windows) at a generous bitrate — the cap
    /// exists only to bound a single track's ephemeral store, never to limit
    /// how much of a window gets fetched.
    static let ephemeralStoreLimitBytes: Int64 = 24 * 1024 * 1024

    public enum ResolutionFailure: Error, Equatable, Sendable {
        /// Provider re-authentication failed (offline, revoked credential,
        /// temporarily unreachable) — retryable, not terminal.
        case reAuthenticationFailed
        /// This asset's provider/track/source can't be resolved at all
        /// (deleted source, unrecognized kind) — not retryable.
        case unsupportedProvider
        /// The provider doesn't support ranged reads for this asset — SMB
        /// (a mounted filesystem, not an HTTP object store — see the plan's
        /// "concrete no") always lands here; an HTTP provider that lied
        /// about `supportsByteRanges` would too, though
        /// `CachingResourceLoader`/`RemoteStreamingResponsePolicy` already
        /// degrades a live `200`/chunked response to a full-body fallback
        /// rather than failing outright.
        case rangesUnsupported
    }

    /// One track's worth of ephemeral streaming state — built once per job
    /// (not once per window) so the ~13 embedding/analysis window reads
    /// share one on-disk sparse cache and one re-authenticated URL, per the
    /// plan's design. Must be torn down via `shutdown()` when the job's
    /// work is done, success or failure — never left to accumulate.
    public struct Session: Sendable {
        public let avAsset: AVURLAsset
        let loader: CachingResourceLoader
        let store: SparseCacheStore
        let ephemeralRoot: URL
        let cacheKey: String

        /// Real, current bytes fetched for this session — the instrumentation
        /// the plan's own validation step needs (see "Specific risks and the
        /// validation step" in docs/plans/remote-sparse-indexing.md): compare
        /// this, after a full track's windows complete, against the
        /// theoretical minimum (`RemoteIndexingByteEstimate.perTrackBytes`)
        /// to see the real `AVAssetReader` over-fetch ratio for the scattered
        /// seek pattern this feature actually uses — never measured on a live
        /// device this session, so this is what lets the owner measure it
        /// from real usage instead.
        public func fetchedBytes() async -> Int64 {
            await store.totalCachedBytes()
        }

        /// Discards every fetched byte — nothing from this path may survive
        /// past the bounded work unit that created it (plan acceptance
        /// criteria). Idempotent; safe to call more than once.
        public func shutdown() async {
            loader.shutdown()
            await store.clearAll()
            try? FileManager.default.removeItem(at: ephemeralRoot)
        }
    }

    /// Re-authenticates `asset` via its owning provider (reconstructed from
    /// the track's `Source` row, using the persisted `remoteNodeID`/
    /// `remoteNodePath` — see the prerequisite work, commit `0a80ff8`), then
    /// builds a `Session`. The caller owns the session's lifetime and must
    /// call `shutdown()` on it when done with this track, in every code
    /// path (success, terminal failure, and — via the startup sweep below —
    /// a crash mid-job).
    public static func makeSession(
        for asset: Asset, writer: any DatabaseWriter, loaderQueue: DispatchQueue
    ) async -> Result<Session, ResolutionFailure> {
        guard asset.kind == .remote else { return .failure(.unsupportedProvider) }

        guard let track = try? await writer.read({ db in try Track.fetchOne(db, key: asset.trackId) })
        else { return .failure(.unsupportedProvider) }
        guard let source = try? await writer.read({ db in try Source.fetchOne(db, key: track.sourceId) })
        else { return .failure(.unsupportedProvider) }

        // SMB is a mounted filesystem, not an HTTP object store — this
        // resource-loader design doesn't apply to it (plan: "not a real
        // HTTP-range question at all"). A real SMB sparse read would use
        // direct `FileHandle` seeks against the mounted share, a separate,
        // simpler path not built here.
        guard source.kind != .smb else { return .failure(.rangesUnsupported) }

        guard let provider = try? RemoteLibraryProviderFactory.provider(for: source) else {
            return .failure(.unsupportedProvider)
        }
        guard
            let resolved = await RemoteAssetRefetch.resolve(
                for: asset, resolveNode: { node in try await provider.resolve(node: node) })
        else {
            return .failure(.reAuthenticationFailed)
        }
        guard resolved.supportsByteRanges else { return .failure(.rangesUnsupported) }

        let ephemeralRoot = Self.freshEphemeralRoot()
        let store = SparseCacheStore(evictableRoot: ephemeralRoot, limitBytes: ephemeralStoreLimitBytes)
        let config = CachingResourceLoaderConfig(scheme: scheme, headers: resolved.headers)
        let loader = CachingResourceLoader(originalURL: resolved.url, store: store, config: config)
        let cacheURL = CachingResourceLoader.cacheURL(for: resolved.url, scheme: scheme)
        let avAsset = AVURLAsset(url: cacheURL)
        avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        return .success(
            Session(
                avAsset: avAsset, loader: loader, store: store, ephemeralRoot: ephemeralRoot,
                cacheKey: loader.cacheKey))
    }

    static func rootDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tonearm-index-scratch", isDirectory: true)
    }

    private static func freshEphemeralRoot() -> URL {
        rootDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Removes every ephemeral session directory left behind by a prior
    /// process that crashed/force-quit mid-job (`Session.shutdown()` never
    /// ran) — the plan's acceptance criteria explicitly requires this to be
    /// verified "via a startup sweep, not just the happy-path cleanup".
    /// Safe to call every launch: a directory still in active use belongs to
    /// a UUID this process hasn't created yet, so there's no risk of
    /// colliding with a session the CURRENT process is using (each session
    /// gets its own fresh UUID subdirectory, never reused).
    public static func sweepStaleEphemeralDirectories() {
        let root = rootDirectory()
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
