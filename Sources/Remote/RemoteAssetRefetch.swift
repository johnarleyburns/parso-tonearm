import Foundation

/// Builds a ready-to-fetch request for a persisted `.remote` `Asset`,
/// re-authenticating via the owning provider first whenever a real node
/// reference is available.
///
/// Real bug this fixes: `Asset.remoteURL`/`transientRemoteHeaders` — what
/// `AppState.makeOffline(source:)`/`download(rows:)` used to fetch with
/// directly — are only reliable at the moment a track was just resolved from
/// a live browse session. `transientRemoteHeaders` is never persisted at all
/// (empty on any DB-hydrated row), and for several providers the persisted
/// `remoteURL` string itself goes stale (Dropbox/pCloud issue short-lived
/// signed links; Google Drive/OneDrive need a refreshed OAuth bearer token;
/// WebDAV/Jellyfin/Plex need a header a plain URL never carries at all).
/// Traced during `docs/plans/remote-sparse-indexing.md`'s "Phase 0"
/// investigation — see that document for the full per-provider breakdown.
/// Pulled out as a small, pure, injectable unit (rather than inlined in
/// `AppState`) so it's testable without a live provider/network.
public enum RemoteAssetRefetch {
    /// `resolveNode` is normally `provider.resolve(node:)` for the asset's
    /// owning `RemoteLibraryProvider` — injected so tests can supply a fake
    /// without a real network or credentials.
    public static func request(
        for asset: Asset,
        resolveNode: (RemoteNode) async throws -> ResolvedAsset
    ) async -> URLRequest? {
        if let nodePath = asset.remoteNodePath {
            let node = RemoteNode(
                id: asset.remoteNodeID ?? "", title: "", path: nodePath, kind: .audio,
                sizeBytes: asset.sizeBytes)
            if let resolved = try? await resolveNode(node) {
                var request = URLRequest(url: resolved.url)
                for (field, value) in resolved.headers {
                    request.setValue(value, forHTTPHeaderField: field)
                }
                return request
            }
            // Re-resolution failed (offline, revoked credential, provider
            // temporarily unreachable) — fall through to the legacy
            // best-effort path below rather than failing outright. It won't
            // work for every provider, but it's strictly no worse than the
            // pre-fix behavior, and it's still correct for a provider like
            // Subsonic whose persisted URL is normally self-authenticating.
        }
        guard let rawURL = asset.remoteURL, let url = URL(string: rawURL) else { return nil }
        var request = URLRequest(url: url)
        for (field, value) in asset.transientRemoteHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
