import Foundation
import TonearmWatchProtocol

/// The watch app's `WatchConnectivityObserver`: it turns everything the link reports into local
/// SwiftData truth and answers back with the watch's actual manifest.
///
/// §10 legacy replacement map — "`WatchSyncHandler` … Delete; responsibilities move to
/// `WatchSyncActor` and file installer." It owns no UI. The coordinator is held weakly because the
/// coordinator also holds this object (as its observer); the assembly keeps both alive.
public actor WatchSyncActor: WatchConnectivityObserver {
    private let repository: WatchLibraryRepository
    private let installer: WatchFileInstaller
    private let artworkInstaller: WatchArtworkInstaller?
    private let diagnostics: WatchDiagnosticsRecorder?
    private weak var coordinator: WatchConnectivityCoordinator?

    /// Fired when the phone's paired-library identity differs from the bound one (A-08). The UI
    /// presents the choice and calls `coordinator.confirmPairedLibraryReplacement()`.
    private let onPairedLibraryChange: @Sendable (WatchPairedLibraryID, WatchPairedLibraryID) async -> Void
    /// Fired after any change to local truth so a `@MainActor` view model can refresh its snapshots.
    private let onLibraryChanged: @Sendable () async -> Void

    public init(repository: WatchLibraryRepository,
                installer: WatchFileInstaller,
                artworkInstaller: WatchArtworkInstaller? = nil,
                coordinator: WatchConnectivityCoordinator? = nil,
                diagnostics: WatchDiagnosticsRecorder? = nil,
                onPairedLibraryChange: @escaping @Sendable (WatchPairedLibraryID, WatchPairedLibraryID) async -> Void = { _, _ in },
                onLibraryChanged: @escaping @Sendable () async -> Void = {}) {
        self.repository = repository
        self.installer = installer
        self.artworkInstaller = artworkInstaller
        self.diagnostics = diagnostics
        self.coordinator = coordinator
        self.onPairedLibraryChange = onPairedLibraryChange
        self.onLibraryChanged = onLibraryChanged
    }

    public func setCoordinator(_ coordinator: WatchConnectivityCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Downloads

    public func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async {
        for root in payload.roots {
            await applyRoot(root, revision: payload.revision)
        }
        await installer.retryDeferred()
        await onLibraryChanged()
        await publishManifest()
    }

    private func applyRoot(_ root: WatchDownloadRootDescriptor, revision: Int64) async {
        switch root.kind {
        case .playlist:
            let summaries = await hydrate(.playlist(WatchPlaylistID(root.sourceID)))
            await upsert(summaries, revision: revision)
            _ = try? await repository.upsertPlaylist(
                .init(playlistID: root.sourceID, title: displayTitle(root.title, fallback: "Playlist"),
                      trackIDs: root.trackIDs.map(\.rawValue), phoneRevision: revision),
                desiredOnWatch: true)

        case .albumBatch:
            let summaries = await hydrate(.album(WatchAlbumID(root.sourceID)))
            if summaries.isEmpty {
                // Offline or the phone could not enumerate — keep the IDs as bare rows so a later
                // reconciliation can fill them; they stay nonplayable until an asset installs.
                for id in root.trackIDs {
                    _ = try? await repository.upsertTrack(.init(trackID: id.rawValue, title: id.rawValue,
                                                               phoneRevision: revision))
                }
            } else {
                await upsert(summaries, revision: revision)
            }

        case .track:
            // A single-track root carries the track's own title in `title` (§5.3 file metadata is
            // ID-only, so the descriptor is the one place the name can ride).
            for id in root.trackIDs {
                _ = try? await repository.upsertTrack(
                    .init(trackID: id.rawValue,
                          title: displayTitle(root.title, fallback: id.rawValue),
                          phoneRevision: revision))
            }
        }
    }

    /// Page a collection from the phone. Returns `[]` on any fault (offline, superseded, gone) —
    /// the caller degrades rather than failing the whole root batch.
    private func hydrate(_ ref: WatchCollectionRef) async -> [WatchTrackSummary] {
        guard let coordinator else { return [] }
        var collected: [WatchTrackSummary] = []
        var token: String? = nil
        var guardRail = 0
        repeat {
            guard case .success(let response) = await coordinator.collection(ref, pageToken: token) else {
                return collected
            }
            collected.append(contentsOf: response.tracks)
            token = response.nextPageToken
            guardRail += 1
        } while token != nil && guardRail < 40
        return collected
    }

    private func upsert(_ summaries: [WatchTrackSummary], revision: Int64) async {
        for summary in summaries {
            _ = try? await repository.upsertTrack(.init(
                trackID: summary.trackID.rawValue,
                title: displayTitle(summary.title, fallback: summary.trackID.rawValue),
                artist: summary.artist, albumTitle: summary.albumTitle,
                durationSeconds: summary.durationSeconds, artworkID: summary.artworkID,
                coverArtworkID: summary.coverArtworkID, customArtworkID: summary.customArtworkID,
                phoneRevision: revision))
        }
    }

    // MARK: - Removal / reconciliation

    public func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async {
        _ = try? await repository.removeTracks(payload.trackIDs.map(\.rawValue))
        await onLibraryChanged()
        await publishManifest()
    }

    public func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async {
        await reconcileAndAdopt()
        await onLibraryChanged()
        await publishManifest()
    }

    public func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async {
        let outcome = await installer.install(stagedURL: stagedURL, metadata: metadata)
        await recordInstall(outcome)
        await onLibraryChanged()
        await publishManifest()
    }

    public func didReceiveArtworkFile(at stagedURL: URL, metadata: [String: String]) async {
        if let artworkInstaller { _ = await artworkInstaller.install(stagedURL: stagedURL, metadata: metadata) }
        await onLibraryChanged()
        await publishManifest()
    }

    /// §12 install-result diagnostics: the outcome kind and, when the file landed, its byte count.
    /// The track ID never leaves the installer — only the shape of what happened.
    private func recordInstall(_ outcome: WatchInstallOutcome) async {
        guard let diagnostics else { return }
        switch outcome {
        case .installed(_, _, let bytes):
            await diagnostics.record(.installResult, "installed", byteCount: bytes)
        case .duplicateIgnored:
            await diagnostics.record(.installResult, "duplicateIgnored")
        case .deferredAwaitingMetadata:
            await diagnostics.record(.installResult, "deferredAwaitingMetadata")
        case .rejected(_, let fault):
            await diagnostics.record(.installResult, fault.code.rawValue)
        }
    }

    public func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                        incoming: WatchPairedLibraryID) async {
        await onPairedLibraryChange(current, incoming)
    }

    public func didNegotiate(_ session: WatchNegotiatedSession) async {
        // A fresh negotiation is the moment to prove the offline library still matches disk and to
        // report where the watch actually stands.
        await reconcileAndAdopt()
        await onLibraryChanged()
        await publishManifest()
    }

    // MARK: - Helpers

    private func reconcileAndAdopt() async {
        try? await repository.reconcileArtworkFiles()
        guard let snapshot = try? await repository.reconcileFiles() else { return }
        let tracks = (try? await repository.tracks(readyOnly: false)) ?? []
        for orphan in snapshot.orphans {
            // Adopt an orphan only where a track's declared checksum/bytes match it exactly;
            // `adoptOrphan` throws on any mismatch, so a wrong pairing just moves to the next track.
            for track in tracks where track.localFilename == nil {
                do {
                    try await repository.adoptOrphan(orphan, forTrackID: track.id)
                    break
                } catch {
                    continue
                }
            }
        }
        await installer.retryDeferred()
    }

    private func publishManifest() async {
        guard let coordinator else { return }
        guard let snapshot = try? await repository.manifest() else { return }
        let storage = try? await repository.storage()
        let payload = WatchManifestPayload(
            manifestID: snapshot.manifestID,
            readyTrackIDs: snapshot.readyTrackIDs.map(WatchTrackID.init),
            installedBytes: snapshot.installedBytes,
            capacityBytes: storage?.capacityBytes ?? 0,
            freeBytes: storage?.freeBytes ?? 0,
            installedArtworkIDs: snapshot.installedArtworkIDs)
        await coordinator.sendManifest(payload)
        // §12 manifest-convergence diagnostics: each time the watch reports where it stands, log the
        // ready count and installed bytes. Watching `count` climb toward the desired set across a
        // soak is how convergence is verified without a title ever being recorded.
        await diagnostics?.record(.manifestConvergence, "reported",
                                  byteCount: snapshot.installedBytes,
                                  count: snapshot.readyTrackIDs.count)
    }

    private func displayTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
