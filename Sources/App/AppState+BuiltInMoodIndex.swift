import Foundation
import GRDB
import TonearmCore
import TonearmDiscovery

extension AppState {
    /// Merges the bundled Mood Starter library (the starter DB, `StarterLibrary`) into the library:
    /// real source/album/artist/track/asset rows for each Jamendo/archive.org track, plus its
    /// precomputed CLAP embedding, a completed index job and its tempo/key/energy — so the
    /// reconciler never queues live remote indexing for these tracks, and Build a Mix can place
    /// them on a fresh install. Assets are `.remote` with the real stream URL: network use only
    /// happens when the user presses play (CLAUDE.md "no silent/magic background work").
    ///
    /// A starter-pack content change replaces only the prior Mood Starter source before it is
    /// reseeded. This intentionally discards retired starter embeddings while leaving every
    /// user-imported local or remote-library source untouched.
    ///
    /// Merged in chunks of `starterMergeChunk` tracks, each its own transaction, so the library
    /// stays readable while a large starter (tens of thousands of tracks) goes in; the progress
    /// shows in Settings → Library & Storage, where it can be paused and resumed. Every chunk is
    /// idempotent, so an interrupted merge simply continues on the next launch.
    func seedBuiltInMoodIndexIfNeeded() async {
        guard starterMerge == nil || starterMerge?.paused == true else { return }
        guard let starter = StarterLibrary.shared else { return }
        let key = "builtin.starterLibrary.mergedVersion"
        let previousVersion = UserDefaults.standard.string(forKey: key)
        let alreadyMerged = previousVersion == starter.contentVersion
        let source = try? await store.firstSource(title: Self.moodIndexSourceTitle, kind: .local)
        let sourcePresent = source != nil
        guard !(alreadyMerged && sourcePresent) else { return }
        starterMergePaused = false
        do {
            if previousVersion != nil, previousVersion != starter.contentVersion, let sourceID = source?.id {
                try await store.deleteSource(id: sourceID)
                UserDefaults.standard.removeObject(forKey: key)
                await reload()
            }
            let tracks = try await Task.detached(priority: .utility) { try starter.tracks() }.value
            guard !tracks.isEmpty else { return }
            let versions = StarterMergeVersions(
                pipeline: DiscoveryPipelineVersion.pipeline, model: DiscoveryPipelineVersion.model,
                preprocessing: DiscoveryPipelineVersion.preprocessing,
                sampling: DiscoveryPipelineVersion.sampling,
                musicalAnalysis: DiscoveryPipelineVersion.musicalAnalysis)
            var progress = StarterMergeProgress(added: 0, total: tracks.count, since: Date(), paused: false)
            starterMerge = progress
            var changed = false
            for start in stride(from: 0, to: tracks.count, by: Self.starterMergeChunk) {
                if starterMergePaused {
                    progress.paused = true
                    starterMerge = progress
                    if changed { await reload() }
                    return
                }
                let chunk = Array(tracks[start..<min(start + Self.starterMergeChunk, tracks.count)])
                let result = try await store.mergeStarterLibrary(
                    chunk, sourceTitle: Self.moodIndexSourceTitle,
                    licenseText: "Creative Commons — attribution kept", versions: versions)
                changed = changed || result.tracksAdded > 0 || result.analysesAdded > 0 || result.artworkFilled > 0
                progress.added = min(tracks.count, start + chunk.count)
                starterMerge = progress
            }
            UserDefaults.standard.set(starter.contentVersion, forKey: key)
            AppLogger.app.info("Mood Starter merged: \(tracks.count, privacy: .public) tracks")
            starterMerge = nil
            if changed { await reload() }
        } catch {
            AppLogger.app.error("Merging the Mood Starter library failed: \(error.localizedDescription, privacy: .public)")
            starterMerge?.failure = error.localizedDescription
            starterMerge?.paused = true
        }
    }

    /// Pause (between chunks) or resume adding the Mood Starter tracks.
    func toggleStarterMergePause() {
        if starterMerge?.paused == true {
            Task { await seedBuiltInMoodIndexIfNeeded() }
        } else {
            starterMergePaused = true
        }
    }

    static let starterMergeChunk = 2_000

    private static let moodIndexSourceTitle = "Mood Starter"
}
