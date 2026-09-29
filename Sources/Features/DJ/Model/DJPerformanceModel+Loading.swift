import Foundation
import Combine
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDiscovery

@MainActor
extension DJPerformanceModel {
    func refreshPrepIfLoaded(trackID: Int64) {
        guard let id = DJDeckID.allCases.first(where: { deck($0).row?.id == trackID }) else { return }
        let state = deck(id)
        Task { [store] in
            guard let prep = try? await store.djTrackPrep(trackId: trackID) else { return }
            state.hotCues = prep.markings.hotCues
            state.hotCueColors = prep.markings.hotCueColors
            state.hotLoops = prep.markings.hotLoops
            state.cuePoint = prep.cuePointSeconds
            state.loopIn = prep.loopInSeconds
            state.loopOut = prep.loopOutSeconds
            state.keyShiftSemitones = prep.keyShiftSemitones
            state.bpmOverride = prep.bpmOverride
            state.firstBeatOverride = prep.firstBeatOverride
            if let data = prep.analysisPayload,
               let payload = try? DJTrackPrepPayload.decoded(data) {
                state.duration = payload.duration
                state.bpm = prep.bpmOverride ?? payload.bpm
                state.key = payload.key.camelot
                state.beatPositions = payload.beatPositions
                state.downbeatPositions = payload.downbeatPositions
                state.waveform = payload.waveform.map { WaveformBin(min: $0.min, max: $0.max, rms: $0.rms, bandRMS: $0.bandRMS) }
            }
            guard state.row?.id == trackID else { return }
            audio.restoreHotCues(state.hotCues, deck: id)
            if let cue = state.cuePoint { audio.setCue(deck: id, position: cue) }
            if let start = state.loopIn, let end = state.loopOut {
                audio.setLoop(deck: id, start: start, end: end, active: state.loopActive)
            }
            audio.setPitchShift(deck: id, semitones: state.keyShiftSemitones)
        }
    }

    func deck(_ id: DJDeckID) -> DJDeckState { id == .a ? deckA : deckB }

    func load(
        _ row: TrackRow,
        into id: DJDeckID,
        resolve: @escaping (TrackRow) async throws -> URL,
        requestIndex: @escaping (Int64) async -> Void
    ) {
        cancelGlide(id)
        loadGeneration[id, default: 0] += 1
        let generation = loadGeneration[id] ?? 0
        let deck = deck(id)
        loadingDecks.insert(id)
        loadPhases[id] = .loading
        deck.isPlaying = false
        deck.position = 0
        deck.row = row
        deck.duration = row.track.durationSec ?? 0
        deck.bpm = nil
        deck.key = nil
        deck.waveform = []
        deck.beatPositions = []
        deck.downbeatPositions = []
        deck.hotCues = [:]
        deck.hotCueColors = [:]
        deck.hotLoops = [:]
        deck.cuePoint = nil
        deck.loopIn = nil
        deck.loopOut = nil
        deck.loopActive = false
        deck.loopExitPending = false
        deck.loopSetIndex = 2
        deck.loopSetApplied = false
        deck.padMode = .hotCue
        deck.echoPad = nil
        deck.tempoPercent = 0
        deck.syncEnabled = false
        deck.masterTempo = true
        deck.keySync = false
        deck.keyShiftSemitones = 0
        deck.bpmOverride = nil
        deck.firstBeatOverride = nil
        deck.analyzedBPM = nil
        deck.analyzedFirstBeat = nil
        deck.previousPadMode = .hotCue
        deck.echoOutArmed = false
        deck.vinyl = true
        deck.slip = false
        deck.reverse = false
        deck.quantize = true
        deck.tempo = 120
        loadError = nil
        loadErrors[id] = nil

        Task { [weak self, store] in
            var stage: DJLoadFailureStage = .loadRecord
            var diagnosticURL: URL?
            var diagnosticCodec: String?
            do {
                let prep = try await store.djTrackPrep(trackId: row.id)
                var cachedAnalysis: TrackAnalysis?
                if let prep {
                    deck.hotCues = prep.markings.hotCues
                    deck.hotCueColors = prep.markings.hotCueColors
                    deck.hotLoops = prep.markings.hotLoops
                    deck.cuePoint = prep.cuePointSeconds
                    deck.loopIn = prep.loopInSeconds
                    deck.loopOut = prep.loopOutSeconds
                    deck.keyShiftSemitones = prep.keyShiftSemitones
                    deck.bpmOverride = prep.bpmOverride
                    deck.firstBeatOverride = prep.firstBeatOverride
                    if let payloadData = prep.analysisPayload,
                       let payload = try? DJTrackPrepPayload.decoded(payloadData) {
                        cachedAnalysis = payload.trackAnalysis()
                        deck.duration = payload.duration
                        deck.bpm = prep.bpmOverride ?? payload.bpm
                        deck.key = payload.key.camelot
                        deck.beatPositions = payload.beatPositions
                        deck.downbeatPositions = payload.downbeatPositions
                        deck.waveform = payload.waveform.map {
                            WaveformBin(min: $0.min, max: $0.max, rms: $0.rms, bandRMS: $0.bandRMS)
                        }
                        self?.loadPhases[id] = .decoding
                    }
                }
                // Resolution may download a remote asset into the local cache.
                // It is part of loading, so a track that was not pre-indexed or
                // pre-downloaded remains a valid DJ selection.
                stage = .resolveSource
                let url = try await resolve(row)
                guard let self else { return }
                guard self.loadGeneration[id] == generation else { return }
                if cachedAnalysis == nil { self.loadPhases[id] = .analyzing }
                diagnosticURL = url
                let sourceURL = url
                let sourceCodec = row.track.codec ?? row.asset?.remoteURL ?? row.asset?.altRemoteURL
                diagnosticCodec = sourceCodec
                let sourceBookmark = row.asset?.bookmark
                let cachedTrackAnalysis = cachedAnalysis
                let cachedSourceFrameCount = prep?.sourceFrameCount
                stage = .decodeAndAnalyze
                let waveformUpdate: @Sendable ([WaveformBin]) -> Void = { [weak self] bins in
                    Task { @MainActor in
                        guard let self,
                              self.loadGeneration[id] == generation,
                              self.deck(id).row?.id == row.id else { return }
                        self.deck(id).waveform = bins
                    }
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    if let bookmark = sourceBookmark,
                       let bookmarkURL = BookmarkVault.resolve(bookmark)?.url,
                       DJLoadSourcePolicy.shouldUseBookmark(bookmarkURL: bookmarkURL,
                                                            sourceURL: sourceURL) {
                        do {
                            if let prepared = try BookmarkVault.withAccess(bookmark, { bookmarkURL in
                                try DJAudioBacker.prepare(url: bookmarkURL, codec: sourceCodec,
                                                          cachedAnalysis: cachedTrackAnalysis,
                                                          cachedFrameCount: cachedSourceFrameCount,
                                                          onWaveform: waveformUpdate)
                            }) {
                                return prepared
                            }
                        } catch {
                            // The resolver already verified sourceURL. If the
                            // bookmark scope cannot be reopened, prepare that
                            // verified URL directly instead of failing a valid load.
                        }
                    }
                    return try DJAudioBacker.prepare(url: sourceURL, codec: sourceCodec,
                                                     cachedAnalysis: cachedTrackAnalysis,
                                                     cachedFrameCount: cachedSourceFrameCount,
                                                     onWaveform: waveformUpdate)
                }.value
                guard self.loadGeneration[id] == generation,
                      self.deck(id).row?.id == row.id else { return }
                if cachedAnalysis != nil && !prepared.usedCached {
                    self.loadPhases[id] = .analyzing
                }
                let analyzedBPM = prepared.analysis.tempo.bpm
                let analyzedFirstBeat = prepared.analysis.tempo.beatPositions.first ?? 0
                var analysis = prepared.analysis
                if let bpmOverride = prep?.bpmOverride, bpmOverride > 0 {
                    analysis.tempo.bpm = bpmOverride
                    let first = max(0, prep?.firstBeatOverride ?? 0)
                    let beat = 60 / bpmOverride
                    analysis.tempo.beatPositions = stride(from: first, through: analysis.duration, by: beat).map { $0 }
                    analysis.tempo.downbeatPositions = stride(from: first, through: analysis.duration, by: beat * 4).map { $0 }
                }
                stage = .loadEngine
                try self.audio.load(prepared, analysis: analysis, deck: id)
                self.audio.setChannelLevel(deck: id, value: deck.channelLevel)
                self.audio.setCrossfader(self.crossfader)
                self.audio.setMasterLevel(self.masterLevel)
                self.audio.setReverse(deck: id, enabled: deck.reverse)
                self.audio.restoreHotCues(deck.hotCues, deck: id)
                self.audio.setPitchShift(deck: id, semitones: deck.keyShiftSemitones)
                self.audio.setKeyLock(deck: id, enabled: deck.masterTempo)
                if let cue = deck.cuePoint { self.audio.setCue(deck: id, position: cue) }
                if let start = deck.loopIn, let end = deck.loopOut { self.audio.setLoop(deck: id, start: start, end: end, active: false) }
                self.loadingDecks.remove(id)
                self.loadPhases[id] = nil
                deck.duration = analysis.duration
                deck.analyzedBPM = analyzedBPM
                deck.analyzedFirstBeat = analyzedFirstBeat
                deck.waveform = self.audio.waveform(for: id)
                deck.beatPositions = analysis.tempo.beatPositions
                deck.downbeatPositions = analysis.tempo.downbeatPositions
                let indexed = try? await store.discoveryTrackAnalysis(trackId: row.id)
                deck.bpm = indexed?.bpm ?? prep?.bpmOverride ?? analysis.tempo.bpm
                deck.key = indexed?.key ?? analysis.key.camelot
                if let bpm = deck.bpm { deck.tempo = bpm }
                let gain = analysis.loudness.gainToTargetDB
                if autoGain, gain.isFinite {
                    deck.trim = max(0, min(1, 0.5 + gain / 12))
                    self.audio.setTrim(deck: id, value: deck.trim)
                }
                if !prepared.usedCached, row.id >= 0 {
                    let payload = DJTrackPrepPayload(analysis: analysis, sourceFrameCount: Int64(prepared.buffer.frameCount))
                    stage = .persistAnalysis
                    if let data = try? payload.encoded() {
                        try? await store.saveDJAnalysis(data,
                                                        meta: (DJTrackPrepPayload.currentAlgorithmID,
                                                               DJTrackPrepPayload.currentVersion,
                                                               prepared.buffer.format.sampleRate,
                                                               Int64(prepared.buffer.frameCount),
                                                               analysis.tempo.bpm,
                                                               analysis.key.camelot),
                                                        trackId: row.id)
                        await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: row.id)
                    }
                }
                if indexed == nil, row.id >= 0 {
                    // Queue the durable library index as soon as the track has
                    // been made playable. The DJ's local analysis above keeps
                    // the deck useful immediately while the shared indexer
                    // finishes in the background.
                    await requestIndex(row.id)
                }
            } catch {
                guard let self, self.loadGeneration[id] == generation else { return }
                self.loadingDecks.remove(id)
                self.loadPhases[id] = nil
                deck.duration = 0
                deck.waveform = []
                let message = DJLoadFailurePresentation.message(
                    stage: stage, error: error, trackTitle: row.track.title,
                    sourceURL: diagnosticURL, codec: diagnosticCodec)
                self.loadErrors[id] = message
                self.loadError = message
            }
        }
    }

}
