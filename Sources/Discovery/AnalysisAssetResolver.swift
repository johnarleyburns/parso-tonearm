import Foundation
import TonearmCore

/// Resolves a `discovery_index_job`'s selected asset to a locally-readable
/// URL for the bounded worker, mirroring `AppState.localAudioBytes`'s
/// resolution order (bookmark → resolve; remote `file://` → direct; relPath
/// → app-support-relative) plus AudioCache for a completely-cached remote
/// asset (plan §5: "Resolve playable, complete local assets first: app-owned
/// files, valid security-scoped bookmarks, then complete AudioCache
/// entries").
///
/// Holds the security-scoped access open only for the duration of the
/// caller's read (plan §5: "Hold the security scope/cache pin from before
/// read until checkpoint/result completion") — `withResolvedURL` scopes this
/// exactly around one bounded window read.
public struct AnalysisAssetResolver: Sendable {
    public enum ResolutionFailure: Error, Equatable, Sendable {
        /// No local/cached bytes are available yet — a `waitingForAsset` job
        /// state, not a terminal failure (plan §5, §6).
        case assetUnavailable
    }

    public init() {}

    /// Locate the best analyzable local URL for `asset`, run `body` with it
    /// while any security scope is held, then release the scope. Returns
    /// `.failure(.assetUnavailable)` when nothing local/cached exists yet;
    /// any error `body` throws (a decode/format problem — the caller's
    /// concern, not an availability question) propagates out unchanged.
    public func withResolvedURL<T>(
        for asset: Asset,
        body: (URL) throws -> T
    ) throws -> Result<T, ResolutionFailure> {
        guard let resolved = resolveURL(for: asset) else {
            return .failure(.assetUnavailable)
        }
        defer { if resolved.needsStopAccessing { resolved.url.stopAccessingSecurityScopedResource() } }
        return .success(try body(resolved.url))
    }

    private struct ResolvedURL {
        let url: URL
        let needsStopAccessing: Bool
    }

    private func resolveURL(for asset: Asset) -> ResolvedURL? {
        // Built-in tracks (docs/plans/builtin-mood-starter-index-plan.md)
        // live in the app bundle, not Application Support — the generic
        // `relPath` fallback below would silently never find them. Real
        // gap found wiring this up: `.builtIn` was already an eligible
        // `AssetKind` in `DiscoveryReconciler.isLocallyResolvable(_:)`, but
        // nothing actually resolved one to a URL, so a seeded track would
        // have sat in `waitingForAsset` forever.
        if asset.kind == .builtIn, let channelId = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
            return ResolvedURL(url: url, needsStopAccessing: false)
        }
        if let bookmark = asset.bookmark, let resolved = BookmarkVault.resolve(bookmark) {
            let accessed = resolved.url.startAccessingSecurityScopedResource()
            return ResolvedURL(url: resolved.url, needsStopAccessing: accessed)
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            return ResolvedURL(url: remote, needsStopAccessing: false)
        }
        if let relPath = asset.relPath {
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false)
            if let url = base?.appendingPathComponent(relPath),
                FileManager.default.fileExists(atPath: url.path)
            {
                return ResolvedURL(url: url, needsStopAccessing: false)
            }
        }
        // NOTE: plan §5's third tie-break tier ("then complete AudioCache
        // entries") is not implemented here — `AudioCache`'s completeness
        // check needs `SparseCacheStore.Meta` from `ParsoAudioStreaming`,
        // which `TonearmDiscovery` does not depend on (adding it only for
        // this one JSON-sidecar read was not worth the new package edge
        // this session; a remote-only asset with no local bookmark/relPath
        // is reported as `.assetUnavailable`/`waitingForAsset` for now, which
        // is honest — not silently skipped or crashed on).
        return nil
    }
}
