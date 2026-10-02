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
    /// happens when the user presses play (CLAUDE.md "no silent/magic background work"). Each
    /// track's transition prep stays in the starter DB and is read on demand.
    ///
    /// One transaction; runs again only when the starter DB's content version changes, and then
    /// only adds what is missing (new tracks, analysis, artwork) — existing rows are never
    /// duplicated.
    func seedBuiltInMoodIndexIfNeeded() async {
        guard let starter = StarterLibrary.shared else { return }
        let key = "builtin.starterLibrary.mergedVersion"
        let alreadyMerged = UserDefaults.standard.string(forKey: key) == starter.contentVersion
        let sourcePresent = (try? await store.firstSource(title: Self.moodIndexSourceTitle, kind: .local)) != nil
        guard !(alreadyMerged && sourcePresent) else { return }
        do {
            let tracks = try await Task.detached(priority: .utility) { try starter.tracks() }.value
            guard !tracks.isEmpty else { return }
            let result = try await store.mergeStarterLibrary(
                tracks, sourceTitle: Self.moodIndexSourceTitle,
                licenseText: "Creative Commons — attribution kept",
                versions: StarterMergeVersions(
                    pipeline: DiscoveryPipelineVersion.pipeline, model: DiscoveryPipelineVersion.model,
                    preprocessing: DiscoveryPipelineVersion.preprocessing,
                    sampling: DiscoveryPipelineVersion.sampling,
                    musicalAnalysis: DiscoveryPipelineVersion.musicalAnalysis))
            UserDefaults.standard.set(starter.contentVersion, forKey: key)
            AppLogger.app.info("Mood Starter merged: \(result.tracksAdded, privacy: .public) tracks, \(result.analysesAdded, privacy: .public) analyses, \(result.artworkFilled, privacy: .public) artwork")
            if result.tracksAdded > 0 || result.analysesAdded > 0 || result.artworkFilled > 0 {
                await reload()
            }
        } catch {
            AppLogger.app.error("Merging the Mood Starter library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let moodIndexSourceTitle = "Mood Starter"
}
