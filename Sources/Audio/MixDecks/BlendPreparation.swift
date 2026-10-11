#if !os(watchOS)
import Foundation
import ParsoAudioAnalysis
import ParsoMixEngine

/// Plans the blends of a queue ahead of playback, with the same loader,
/// planner and cache the mix decks use (`BlendEdgePlanner`, `BlendPlanCache`),
/// so the Mix preview and Up Next show the blends the decks will play.
///
/// The queue is planned as a chain, as the decks play it: the first track at
/// its own tempo, each next one stretched to the one before. Only the outgoing
/// and incoming tracks of the edge being planned are in memory.
@MainActor
public enum BlendPreparation {
    /// Why a track can't be prepared right now (network, Wi-Fi only, memory), or
    /// nil to go ahead. A blocked track also stops the chain after it.
    public typealias Gate = @MainActor (TrackRow) -> GridPrepState?
    /// Whether the edge between two tracks is a blend (false: gapless or a plain fade,
    /// after which the next track plays at its own tempo).
    public typealias Blends = @MainActor (TrackRow, TrackRow) -> Bool

    private struct Outgoing {
        let row: TrackRow
        let id: Int64
        var audio: MixTrackAudio?
        let tempo: Double
        let playedAnalysis: BlendTrackAnalysis?
    }

    /// Prepares the blends between consecutive `rows`. `progress` gets each
    /// track's state: the blend *into* it (the first track is ready at once).
    public static func prepare(rows: [TrackRow], gate: Gate, blends: Blends,
                               progress: @escaping @MainActor (Int64, GridPrepState) -> Void) async {
        var outgoing: Outgoing?
        for row in rows {
            guard !Task.isCancelled, let id = row.track.id else { return }
            if let blocked = gate(row) {
                progress(id, blocked)
                return
            }
            // The first track, or one after a plain fade / gapless edge: nothing to plan,
            // but it is downloaded too, so the whole queue plays from disk.
            guard let previous = outgoing, blends(previous.row, row) else {
                do {
                    try await download(row) { progress(id, $0) }
                } catch is CancellationError {
                    progress(id, .cancelled)
                    return
                } catch {
                    progress(id, .failed(error.localizedDescription))
                    return
                }
                progress(id, .ready)
                outgoing = Outgoing(row: row, id: id, audio: nil, tempo: 1, playedAnalysis: nil)
                continue
            }
            if let cached = BlendPlanCache.shared.entry(from: previous.id, to: id, outgoingTempo: previous.tempo) {
                progress(id, .ready)
                outgoing = Outgoing(row: row, id: id, audio: nil, tempo: cached.tempo,
                                    playedAnalysis: cached.incomingPlayed)
                continue
            }
            do {
                progress(id, .queued)
                let outgoingAudio: MixTrackAudio
                if let audio = previous.audio {
                    outgoingAudio = audio
                } else {
                    outgoingAudio = try await load(previous.row, id: previous.id) { _ in }
                }
                let incoming = try await load(row, id: id) { progress(id, $0) }
                progress(id, .analyzing(0.5))
                let (tempo, played) = (previous.tempo, previous.playedAnalysis)
                let planning = try await Task.detached(priority: .utility) { () throws -> BlendPlanning in
                    guard let outgoingPlayed = BlendEdgePlanner.played(outgoingAudio, tempo: tempo, analysis: played),
                          let planning = BlendEdgePlanner.plan(outgoing: outgoingPlayed, incoming: incoming) else {
                        throw MixTrackLoaderError.empty
                    }
                    return planning
                }.value
                let entry = BlendPlanCache.Entry(plans: planning.plans, incomingPlayed: planning.incoming.analysis,
                                                 outgoingTempo: tempo)
                BlendPlanCache.shared.store(entry, from: previous.id, to: id)
                progress(id, .ready)
                outgoing = Outgoing(row: row, id: id, audio: incoming, tempo: entry.tempo,
                                    playedAnalysis: entry.incomingPlayed)
            } catch is CancellationError {
                progress(id, .cancelled)
                return
            } catch {
                progress(id, .failed(error.localizedDescription))
                return
            }
        }
    }

    /// Downloads a remote track into the stream cache unless it is there already
    /// (local files, and streams that can't be cached, need nothing).
    static func download(_ row: TrackRow,
                         progress: @escaping @MainActor (GridPrepState) -> Void) async throws {
        guard let asset = row.asset,
              case .remote(let url, let headers, let container, let key?) = AudioPlayer.shared.mixTrackSource(for: asset)
        else { return }
        try await Task.detached(priority: .utility) {
            let file = try await MixTrackLoader.download(url, headers: headers, container: container) { stage in
                if case .downloading(let fraction) = stage {
                    Task { @MainActor in progress(.downloading(fraction)) }
                }
            }
            if await MixTrackLoader.adoptIntoCache(file, key: key) == nil {
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }

    /// Decodes and analyses one track for planning, as the decks do.
    static func load(_ row: TrackRow, id: Int64,
                     progress: @escaping @MainActor (GridPrepState) -> Void) async throws -> MixTrackAudio {
        guard let asset = row.asset, let source = AudioPlayer.shared.mixTrackSource(for: asset) else {
            throw MixTrackLoaderError.decode("no playable audio")
        }
        let hint = (try? await LibraryStore.shared.blendTempoHint(trackId: id)) ?? nil
        let sampleRate = MixDeckPlayer.sampleRate
        return try await Task.detached(priority: .utility) {
            try await MixTrackLoader.load(trackID: id, source: source, approximateBPM: hint,
                                          sampleRate: sampleRate) { stage in
                Task { @MainActor in
                    switch stage {
                    case .downloading(let fraction): progress(.downloading(fraction))
                    case .analyzing: progress(.analyzing(0.1))
                    }
                }
            }
        }.value
    }
}
#endif
