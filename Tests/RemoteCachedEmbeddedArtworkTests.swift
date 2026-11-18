import Foundation
import Testing

/// `ArtworkService` lives under `Sources/Media/`, excluded from the `TonearmCore` SwiftPM target
/// in `Package.swift` — `swift test` cannot import or construct it. Source-inspection is the
/// established pattern for pinning this level of behavior (see `FavoriteAndHistoryGuardOrderingTests`
/// in `Tests/FavoriteAndHistoryTransientTrackTests.swift`). The cache-lookup primitive this new
/// code calls into (`AudioCache.cachedFileURL(forRemoteEmbeddedArtwork:)`) is real `Sources/Audio`
/// code and has its own executable coverage in `Tests/StreamingCacheTests.swift`.
///
/// Feature: two linked real reports drove this — "research how we can support jellyfin artwork"
/// (a Jellyfin item with no server-side `primaryImageTag` has nothing to show) and "make sure
/// embedded artwork ALSO works for jellyfin" / cloud-drive providers, which have no artwork
/// concept at all today (confirmed: `CloudDriveProvider` never builds a `RemoteTrackMetadata`).
/// The fix reads embedded ID3/MP4 tag artwork straight from the track's already-complete local
/// cache file, generically for any remote provider, rather than adding per-provider plumbing.
@Suite struct RemoteCachedEmbeddedArtworkTests {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func artworkServiceSource() throws -> String {
        try source("Sources/Media/ArtworkService.swift")
    }

    private func functionBody(_ source: String, signature: String) throws -> Substring {
        let function = try #require(source.range(of: signature),
            "expected to find \(signature) in ArtworkService.swift")
        let body = source[function.upperBound...]
        let closingBrace = try #require(body.range(of: "\n    }\n"))
        return body[..<closingBrace.lowerBound]
    }

    /// The new fallback must run after both `remoteProviderArtwork` (a provider's own artwork
    /// always wins when it has one) and the archive.org identifier cover, but before the
    /// local-embedded-tags step (which is unconditionally `!isRemote`-gated and would never run
    /// for a remote asset anyway) and the weak iTunes network fallback.
    @Test func testOrderingRunsAfterProviderArtworkAndBeforeTheWeakITunesFallback() throws {
        let src = try artworkServiceSource()
        let body = try functionBody(src, signature: "func trackArtwork(forTrackRow row: TrackRow) async -> (image: PlatformImage, persistable: Bool)? {")

        let providerArtwork = try #require(body.range(of: "await remoteProviderArtwork(asset: asset)"))
        let iaIdentifier = try #require(body.range(of: "row.album?.artworkId"))
        let cachedEmbedded = try #require(body.range(of: "await remoteCachedEmbeddedArtwork(asset: asset, trackId: trackId)"))
        let iTunesFallback = try #require(body.range(of: "await iTunesArtwork(trackId:"))

        #expect(providerArtwork.lowerBound < cachedEmbedded.lowerBound,
            "a provider's own artwork must be tried first")
        #expect(iaIdentifier.lowerBound < cachedEmbedded.lowerBound,
            "the archive.org identifier cover must be tried before the embedded-tag fallback")
        #expect(cachedEmbedded.lowerBound < iTunesFallback.lowerBound,
            "embedded tag artwork is a strong match and must be tried before the weak iTunes network fallback")
    }

    /// Must be gated on `isRemote` (never attempted for local files, which already have their
    /// own dedicated embedded-tag path two steps below) but NOT gated on any specific provider —
    /// this is the whole point: Jellyfin, Dropbox, Google Drive, pCloud, OneDrive and Box all
    /// reach the same generic fallback with no per-provider branching.
    @Test func testFallbackIsRemoteGatedButNotProviderSpecific() throws {
        let src = try artworkServiceSource()
        let body = try functionBody(src, signature: "func trackArtwork(forTrackRow row: TrackRow) async -> (image: PlatformImage, persistable: Bool)? {")
        #expect(body.contains("if isRemote, let asset = row.asset,"),
            "the call site must gate on isRemote, not a specific provider")
        #expect(body.contains("remoteCachedEmbeddedArtwork(asset: asset, trackId: trackId)"))

        let fnBody = try functionBody(src, signature: "private func remoteCachedEmbeddedArtwork(asset: Asset, trackId: Int64) async -> (image: PlatformImage, persistable: Bool)? {")
        for providerToken in [".jellyfin", ".box", ".dropbox", ".googleDrive", ".pCloud", ".oneDrive", "sourceKind", "SourceKind"] {
            #expect(!fnBody.contains(providerToken),
                "remoteCachedEmbeddedArtwork must stay provider-agnostic; found \(providerToken)")
        }
    }

    /// The fallback must ask `AudioCache` whether the track is already fully cached, never
    /// trigger a fresh network fetch just to peek at tags (that cost concern is exactly why this
    /// isn't attempted for every scrolling list row — only once the audio bytes are already on
    /// disk for some other reason, e.g. playback or an explicit download).
    @Test func testFallbackOnlyReadsAnAlreadyCompleteLocalCacheFile() throws {
        let src = try artworkServiceSource()
        let fnBody = try functionBody(src, signature: "private func remoteCachedEmbeddedArtwork(asset: Asset, trackId: Int64) async -> (image: PlatformImage, persistable: Bool)? {")
        #expect(fnBody.contains("AudioCache.cachedFileURL(forRemoteEmbeddedArtwork:"),
            "must reuse AudioCache's own completeness check rather than reimplementing it")
        #expect(!(fnBody.contains("URLSession") || fnBody.contains("session.data")),
            "must never issue a network request of its own")
    }

    /// Reuses the same bounded decode primitive the existing local-file embedded-artwork path
    /// (`liveLocalLoader`) already uses, rather than a second, divergent decode implementation.
    @Test func testFallbackReusesTheSharedEmbeddedArtworkDecoder() throws {
        let src = try artworkServiceSource()
        let fnBody = try functionBody(src, signature: "private func remoteCachedEmbeddedArtwork(asset: Asset, trackId: Int64) async -> (image: PlatformImage, persistable: Bool)? {")
        #expect(fnBody.contains("EmbeddedArtworkDownsampler.downsample(data)"))
        #expect(fnBody.contains(".commonKeyArtwork"))
    }
}
