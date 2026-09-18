import AVFoundation
import Foundation
import GRDB
import ParsoAudioAnalysis
import ParsoAudioCore
import ParsoDJEngine
import TonearmCore

/// One of the plan's four required candidate states
/// (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §8) for a
/// chosen outgoing/incoming pair, BEFORE `TransitionPlanner` has run —
/// what the picker screen shows while getting to a candidate list.
public enum TransitionLabPairState: Equatable, Sendable {
    /// Either track has no local asset — full-song analysis and preview both
    /// require the complete file decoded; there is no sparse/remote path
    /// (see `TransitionLabAssetResolver`'s doc).
    case downloadRequired(outgoing: Bool, incoming: Bool)
    /// Full-song analysis is running for at least one of the two tracks.
    case analyzing(TransitionLabAnalysisProgress)
    /// Both tracks are analyzed; `TransitionPlanner` produced candidates (or
    /// legitimately none — see `AudioTransitionProposal` array being empty
    /// meaning "no viable transition", not an error).
    case ready([AudioTransitionProposal])
    case failed(String)
}

public struct TransitionLabAnalysisProgress: Equatable, Sendable {
    public var outgoingFraction: Double?
    public var incomingFraction: Double?
}

/// Orchestrates Transition Lab's PAE 1.2 integration: resolve two tracks to
/// local audio, run (or reuse cached) full-song analysis, call
/// `TransitionPlanner`, and render an offline preview of a chosen proposal.
///
/// Portable/testable (no UIKit, no `AppState`) — the App-layer view
/// (`Sources/Features/DJ/TransitionLabView.swift`) owns track *selection*
/// (which two `TrackRow`s) and calls into this model once both are chosen.
@MainActor
public final class TransitionLabModel: ObservableObject {
    @Published public private(set) var state: TransitionLabPairState = .downloadRequired(
        outgoing: false, incoming: false)
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var previewError: String?

    private let repository: TransitionAnalysisRepository
    private var analysisTask: Task<Void, Never>?
    private var previewPlayer: AVAudioPlayerNode?
    private var previewEngine: AVAudioEngine?

    /// Cached per current pair, so `preview(_:)` doesn't need to re-decode a
    /// track's full PCM just because the user tapped a different candidate
    /// for the same pair.
    private var outgoingAnalysis: FullAnalysisResult?
    private var incomingAnalysis: FullAnalysisResult?
    private var outgoingURL: URL?
    private var incomingURL: URL?

    public init(writer: any DatabaseWriter) {
        self.repository = TransitionAnalysisRepository(writer: writer)
    }

    // MARK: - Set Practice (playlist edge persistence)

    /// The saved prepared/needs-work status for this exact adjacent pair
    /// within `playlistId`, if the user has ever previewed a candidate (or
    /// exhausted the candidates) for it before.
    public func edgeStatus(playlistId: Int64, outgoing: TrackRow, incoming: TrackRow)
        -> TransitionPlaylistEdgeRow?
    {
        guard let outID = outgoing.track.id, let inID = incoming.track.id else { return nil }
        return try? repository.edge(
            playlistId: playlistId, outgoingTrackId: outID, incomingTrackId: inID)
    }

    /// Records the user's choice (or non-choice) of proposal for this edge —
    /// call after a preview, or when the candidate list came back empty, so
    /// Set Practice can show prepared/needs-work without re-running
    /// `TransitionPlanner` every time the screen reopens.
    public func saveEdge(
        playlistId: Int64, outgoing: TrackRow, incoming: TrackRow,
        proposal: AudioTransitionProposal?
    ) {
        guard let outID = outgoing.track.id, let inID = incoming.track.id else { return }
        try? repository.saveEdge(
            playlistId: playlistId, outgoingTrackId: outID, incomingTrackId: inID,
            outgoingRevision: 1, incomingRevision: 1, proposal: proposal)
    }

    /// Starts (or restarts) planning for a new outgoing/incoming pair.
    /// Cancels any in-flight analysis for a previous pair.
    public func plan(
        outgoing: TrackRow, incoming: TrackRow,
        intent: TransitionPlanningIntent = .default, semanticSimilarity: Double? = nil
    ) {
        analysisTask?.cancel()
        outgoingAnalysis = nil
        incomingAnalysis = nil
        outgoingURL = nil
        incomingURL = nil

        guard let outgoingAsset = outgoing.asset,
            let outURL = TransitionLabAssetResolver.localURL(for: outgoingAsset)
        else {
            state = .downloadRequired(
                outgoing: true, incoming: incoming.asset.flatMap {
                    TransitionLabAssetResolver.localURL(for: $0)
                } == nil)
            return
        }
        guard let incomingAsset = incoming.asset,
            let inURL = TransitionLabAssetResolver.localURL(for: incomingAsset)
        else {
            state = .downloadRequired(outgoing: false, incoming: true)
            return
        }
        outgoingURL = outURL
        incomingURL = inURL

        state = .analyzing(TransitionLabAnalysisProgress(outgoingFraction: 0, incomingFraction: 0))
        analysisTask = Task { [weak self] in
            await self?.runPlanning(
                outgoingTrack: outgoing.track, outgoingAsset: outgoingAsset, outURL: outURL,
                incomingTrack: incoming.track, incomingAsset: incomingAsset, inURL: inURL,
                intent: intent, semanticSimilarity: semanticSimilarity)
        }
    }

    private func runPlanning(
        outgoingTrack: Track, outgoingAsset: Asset, outURL: URL,
        incomingTrack: Track, incomingAsset: Asset, inURL: URL,
        intent: TransitionPlanningIntent, semanticSimilarity: Double?
    ) async {
        do {
            async let outResult = analysis(
                for: outgoingTrack, asset: outgoingAsset, url: outURL, isOutgoing: true)
            async let inResult = analysis(
                for: incomingTrack, asset: incomingAsset, url: inURL, isOutgoing: false)
            let (out, incoming) = try await (outResult, inResult)
            guard !Task.isCancelled else { return }
            outgoingAnalysis = out
            incomingAnalysis = incoming
            let proposals = TransitionPlanner.proposals(
                from: out, to: incoming, intent: intent, semanticSimilarity: semanticSimilarity)
            state = .ready(proposals)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Cached analysis if present and matching the asset's current revision,
    /// else runs `FullAnalysis.analyze(url:)` (staged/cancellable) and
    /// persists the result.
    private func analysis(
        for track: Track, asset: Asset, url: URL, isOutgoing: Bool
    ) async throws -> FullAnalysisResult {
        if let cached = try? repository.cachedAnalysis(trackId: track.id ?? -1),
            let result = try? cached.fullAnalysisResult()
        {
            return result
        }
        for try await event in FullAnalysis.analyze(url: url) {
            if Task.isCancelled { throw CancellationError() }
            switch event {
            case .progress(let progress):
                updateProgress(progress.fraction, isOutgoing: isOutgoing)
            case .complete(let result):
                if let trackID = track.id, let assetID = asset.id,
                    let header = try? AVAudioFile(forReading: url)
                {
                    // Header-only probe (no sample decode) for the two raw
                    // fields `.portable(sourceSampleRate:sourceFrameCount:)`
                    // needs but `FullAnalysisResult` itself doesn't carry —
                    // cheap, matches `WindowedAudioReader.duration(url:)`'s
                    // existing pattern elsewhere in this codebase.
                    let portable = result.portable(
                        sourceSampleRate: header.processingFormat.sampleRate,
                        sourceFrameCount: header.length)
                    try? repository.saveAnalysis(
                        trackId: trackID, assetId: assetID, assetRevision: 1, analysis: portable)
                }
                return result
            default:
                continue
            }
        }
        throw TransitionLabError.analysisProducedNoResult
    }

    private func updateProgress(_ fraction: Double, isOutgoing: Bool) {
        guard case .analyzing(var progress) = state else { return }
        if isOutgoing { progress.outgoingFraction = fraction } else { progress.incomingFraction = fraction }
        state = .analyzing(progress)
    }

    /// Renders and plays an offline preview of `proposal` — decodes both
    /// tracks' full PCM (expensive; only done when the user actually asks to
    /// hear something, never during planning) and plays the rendered clip
    /// through a throwaway `AVAudioEngine`/`AVAudioPlayerNode` this model
    /// owns for the duration of playback.
    public func preview(_ proposal: AudioTransitionProposal) {
        guard let outURL = outgoingURL, let inURL = incomingURL,
            let outAnalysis = outgoingAnalysis, let inAnalysis = incomingAnalysis
        else { return }
        stopPreview()
        isPreviewing = true
        previewError = nil
        Task { [weak self] in
            await self?.renderAndPlay(
                outURL: outURL, inURL: inURL, outAnalysis: outAnalysis, inAnalysis: inAnalysis,
                proposal: proposal)
        }
    }

    private func renderAndPlay(
        outURL: URL, inURL: URL, outAnalysis: FullAnalysisResult, inAnalysis: FullAnalysisResult,
        proposal: AudioTransitionProposal
    ) async {
        do {
            let outPCM = try AudioFileReader(url: outURL).readAll()
            let inPCM = try AudioFileReader(url: inURL).readAll()
            guard !Task.isCancelled else { return }
            let preview = try TransitionPreviewRenderer.render(
                from: TransitionPreviewSource(pcm: outPCM, analysis: outAnalysis),
                to: TransitionPreviewSource(pcm: inPCM, analysis: inAnalysis),
                proposal: proposal)
            play(preview.pcm)
        } catch {
            isPreviewing = false
            previewError = error.localizedDescription
        }
    }

    private func play(_ pcm: ParsoAudioCore.PCMBuffer) {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: pcm.format.sampleRate,
                channels: AVAudioChannelCount(pcm.channelCount)),
            let avBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frameCount)),
            let channelData = avBuffer.floatChannelData
        else {
            isPreviewing = false
            previewError = "Could not prepare the preview for playback."
            return
        }
        avBuffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        for c in 0..<pcm.channelCount {
            let channel = pcm.channel(c)
            for (i, sample) in channel.enumerated() { channelData[c][i] = sample }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        previewEngine = engine
        previewPlayer = player
        do {
            try engine.start()
        } catch {
            isPreviewing = false
            previewError = "Could not start audio playback: \(error.localizedDescription)"
            return
        }
        player.scheduleBuffer(avBuffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in self?.isPreviewing = false }
        }
        player.play()
    }

    public func stopPreview() {
        previewPlayer?.stop()
        previewEngine?.stop()
        previewPlayer = nil
        previewEngine = nil
        isPreviewing = false
    }

    deinit {
        analysisTask?.cancel()
    }
}

enum TransitionLabError: Error, LocalizedError {
    case analysisProducedNoResult
    var errorDescription: String? {
        "Analysis did not produce a result."
    }
}
