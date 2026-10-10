#if !os(watchOS)
import Foundation
import OSLog
import AVFoundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoMixEngine

/// What the mix decks need from the queue owner (AudioPlayer).
@MainActor
protocol MixDeckHost: AnyObject, Sendable {
    /// The queue index of the track playing now (queue edits move it).
    var mixDecksCurrentIndex: Int { get }
    /// The queue index that follows `index`, nil at the end of the queue.
    func mixDecksUpcomingIndex(after index: Int) -> Int?
    /// The track at `index`, where to read it, and its approximate tempo if known.
    func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)?
    /// The incoming track is now the one playing (bass swap or cut reached).
    /// `index` is where it was when it was scheduled; returns where it is now.
    func mixDecksDidAdvance(to index: Int, trackID: Int64, duration: Double) -> Int
    /// The track playing ran out with nothing scheduled after it.
    func mixDecksDidReachEnd(trackID: Int64)
    /// The track at `index` could not be loaded; it is skipped.
    func mixDecksCouldNotPlay(index: Int, reason: String)
    func mixDecksPosition(seconds: Double)
    func mixDecksLoading(_ loading: Bool)
    /// The next blend and the honest state of its preparation.
    func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState)
}

/// Plays a mix queue on two decks of ParsoMixEngine with the approved "dj2"
/// blends (parso-tonearm/tools/blend-lab): each incoming track is analysed as it
/// will sound, placed by its groove and blended with a bass swap on a downbeat,
/// or cut on a phrase line when its groove can't be read.
///
/// The outgoing deck plays at the tempo it entered with; the incoming is
/// stretched once (keylocked) to it and stays there, so a mix keeps the first
/// track's tempo until a pair is too far apart (a cut resets it). Loudness is
/// matched the same way, each track to the one before as it is heard.
@MainActor
final class MixDeckPlayer {
    nonisolated static let sampleRate = 44_100.0
    /// A blend scheduled closer than this to now is played as a plain follow-on.
    static let scheduleLeadSeconds = 1.0
    /// Combined deck gain limits: loudness matching never boosts into clipping.
    static let gainRange: ClosedRange<Double> = 0.5...1.6

    private static let log = Logger(subsystem: "guru.parso.tonearm", category: "MixDecks")

    struct Deck {
        var index: Int
        let trackID: Int64
        let deck: MixDeck
        let audio: MixTrackAudio
        let tempo: Double
        let gain: Double
        /// Master frame at which played time 0 of the track is (played time =
        /// source time / tempo).
        var zeroFrame: Double
        /// The track as this deck plays it, for planning the next blend.
        var played: PlayedTrack?
        var duration: Double { Double(audio.audio.frameCount) / MixDeckPlayer.sampleRate }
        var endFrame: Double { zeroFrame + Double(audio.audio.frameCount) / tempo }
    }

    struct Upcoming {
        let index: Int
        let audio: MixTrackAudio
        let planning: BlendPlanning
        /// The outgoing track (and its tempo) the planning was made against.
        let outgoingTrackID: Int64
        let outgoingTempo: Double
    }

    struct Scheduled {
        var incoming: Deck
        /// When the incoming deck becomes audible, and when it becomes the current track.
        let joinFrame: Double
        let flipFrame: Double
        /// A planned blend, or a plain follow-on at the end of the outgoing track.
        let isBlend: Bool
    }

    /// What a planning in flight is for; a matching request leaves it running.
    private struct PlanningTarget: Equatable {
        let outgoingTrackID: Int64
        let outgoingTempo: Double
        let index: Int
        let trackID: Int64
    }

    private unowned let host: MixDeckHost
    private let output: MixDeckOutput
    private(set) var current: Deck?
    private(set) var upcoming: Upcoming?
    private(set) var scheduled: Scheduled?
    /// Disabled (smart transitions turned off): tracks follow each other without blends.
    var blendsEnabled = true {
        didSet { if blendsEnabled != oldValue { upcomingChanged() } }
    }
    var volume: Float {
        get { output.volume }
        set { output.volume = newValue }
    }

    /// Decodes in flight or done, by track id (a skip to the upcoming track reuses its decode).
    private var loads: [Int64: Task<MixTrackAudio, any Error>] = [:]
    private var startTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var planning: PlanningTarget?
    private var ticker: Task<Void, Never>?
    /// Bumped by every restart; work started under an older epoch is dropped.
    private var epoch = 0
    private var reportedEnd = false
    /// Audition: once the next blend is planned, jump to shortly before it.
    private var auditionPending = false
    static let auditionLeadSeconds = 10.0

    init(host: MixDeckHost, offline: Bool = false) throws {
        self.host = host
        output = try MixDeckOutput(sampleRate: Self.sampleRate, offline: offline)
    }

    isolated deinit {
        startTask?.cancel()
        cancelPlanning()
        ticker?.cancel()
        loads.values.forEach { $0.cancel() }
    }

    var isRunning: Bool { output.isRunning }

    /// Loading the current track or planning the next blend.
    var isPreparing: Bool { planning != nil || (current == nil && startTask != nil) }

    /// Master clock, in frames since the decks were created or last reset.
    var masterFrame: Int64 { output.mix.masterFrame }

    /// Offline decks only: renders the next `frames` frames and advances the clock.
    func renderOffline(frames: Int) -> AVAudioPCMBuffer? {
        let buffer = output.renderOffline(frames: frames)
        tick()
        return buffer
    }

    /// The current track played out with nothing after it.
    var hasReachedEnd: Bool { reportedEnd }

    /// Plays the planned blend into the next track from shortly before it starts.
    func auditionNextBlend() {
        auditionPending = true
        trySchedule()
    }

    /// Source seconds of the track playing now.
    var currentSeconds: Double? {
        guard let current, let position = output.mix.position(of: current.deck) else { return nil }
        return position / Self.sampleRate
    }

    // MARK: - Transport

    /// Plays the queue track at `index` from `seconds`. Seeking within the
    /// current track keeps its tempo and its planned blend.
    func start(index: Int, at seconds: Double, autoplay: Bool) {
        epoch += 1
        let myEpoch = epoch
        startTask?.cancel()
        reportedEnd = false
        let previous = current
        let keepsTrack = previous != nil && previous?.trackID == host.mixDecksTrack(at: index)?.trackID
        if !keepsTrack {
            cancelPlanning()
            upcoming = nil
        }
        scheduled = nil
        current = nil
        do { try output.reset() } catch {
            host.mixDecksCouldNotPlay(index: index, reason: "Audio output failed: \(error.localizedDescription)")
            return
        }
        if autoplay { try? output.start() } else { output.pause() }
        startTicker()

        if keepsTrack, let previous {
            begin(index: index, audio: previous.audio, tempo: previous.tempo, gain: previous.gain,
                  played: previous.played, at: seconds)
            return
        }
        guard let track = host.mixDecksTrack(at: index) else {
            host.mixDecksCouldNotPlay(index: index, reason: "The track has no playable audio")
            return
        }
        host.mixDecksLoading(true)
        let load = audioTask(for: track)
        dropLoads(keeping: [track.trackID])
        startTask = Task { [weak self] in
            do {
                let audio = try await load.value
                guard let self, self.epoch == myEpoch else { return }
                self.startTask = nil
                self.host.mixDecksLoading(false)
                self.begin(index: index, audio: audio, tempo: 1, gain: 1, played: nil, at: seconds)
            } catch {
                guard let self, self.epoch == myEpoch, !(error is CancellationError) else { return }
                self.startTask = nil
                self.loads[track.trackID] = nil
                self.host.mixDecksLoading(false)
                self.host.mixDecksCouldNotPlay(index: index, reason: error.localizedDescription)
            }
        }
    }

    func pause() { output.pause() }

    func resume() {
        do { try output.start() } catch {
            Self.log.error("mix decks: output did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func seek(to seconds: Double) {
        guard current != nil else { return }
        start(index: host.mixDecksCurrentIndex, at: seconds, autoplay: output.isRunning)
    }

    func stop() {
        epoch += 1
        startTask?.cancel()
        cancelPlanning()
        ticker?.cancel()
        ticker = nil
        loads.values.forEach { $0.cancel() }
        loads.removeAll()
        output.stop()
        current = nil
        upcoming = nil
        scheduled = nil
    }

    /// The queue after the current track changed (edit, Keep Playing append),
    /// or blends were turned on or off. A blend already audible is kept; one
    /// not yet started is replaced.
    func upcomingChanged() {
        guard current != nil else { return }
        current?.index = host.mixDecksCurrentIndex
        let next = host.mixDecksUpcomingIndex(after: host.mixDecksCurrentIndex)
        let nextID = next.flatMap { host.mixDecksTrack(at: $0)?.trackID }
        if let scheduled {
            let unchanged = scheduled.incoming.index == next && scheduled.incoming.trackID == nextID
            if unchanged && scheduled.isBlend == blendsEnabled { return }
            guard Double(output.mix.masterFrame) < scheduled.joinFrame else { return }
            output.mix.clearRecipe()
            output.mix.stop(scheduled.incoming.deck)
            self.scheduled = nil
        }
        if let upcoming, upcoming.index != next || upcoming.audio.trackID != nextID {
            self.upcoming = nil
        }
        prepareUpcoming()
    }

    // MARK: - Decks

    private func begin(index: Int, audio: MixTrackAudio, tempo: Double, gain: Double, played: PlayedTrack?, at seconds: Double) {
        let mix = output.mix
        let lead = 1_024.0
        let startFrame = Double(mix.masterFrame) + lead
        let sourcePosition = max(0, min(seconds, Double(audio.audio.frameCount) / Self.sampleRate - 0.1)) * Self.sampleRate
        do {
            try mix.prepare(.a, buffer: audio.audio, sourcePosition: sourcePosition, tempo: tempo, gain: Float(gain))
            try mix.start(.a, atFrame: Int64(startFrame))
        } catch {
            host.mixDecksCouldNotPlay(index: index, reason: "The deck did not start: \(error)")
            return
        }
        current = Deck(index: index, trackID: audio.trackID, deck: .a, audio: audio, tempo: tempo, gain: gain,
                       zeroFrame: startFrame - sourcePosition / tempo, played: played)
        host.mixDecksPosition(seconds: sourcePosition / Self.sampleRate)
        if upcoming != nil { trySchedule() } else { prepareUpcoming() }
    }

    /// Loads and plans the blend into the next queue track.
    private func prepareUpcoming() {
        guard let current else { return }
        guard let nextIndex = host.mixDecksUpcomingIndex(after: host.mixDecksCurrentIndex),
              let track = host.mixDecksTrack(at: nextIndex) else {
            cancelPlanning()
            dropLoads(keeping: [current.trackID])
            host.mixDecksPublish(plan: nil, state: .ready)
            return
        }
        if let upcoming, upcoming.index == nextIndex, upcoming.audio.trackID == track.trackID,
           upcoming.outgoingTrackID == current.trackID, upcoming.outgoingTempo == current.tempo {
            trySchedule()
            return
        }
        let target = PlanningTarget(outgoingTrackID: current.trackID, outgoingTempo: current.tempo,
                                    index: nextIndex, trackID: track.trackID)
        if planning == target { return }
        cancelPlanning()
        upcoming = nil
        planning = target
        dropLoads(keeping: [current.trackID, track.trackID])
        let load = audioTask(for: track)
        host.mixDecksPublish(plan: nil, state: .queued)
        let outgoing = current
        planTask = Task { [weak self] in
            do {
                let audio = try await load.value
                guard let self, self.planning == target, !Task.isCancelled else { return }
                self.host.mixDecksPublish(plan: nil, state: .analyzing(0.5))
                let outgoingPlayed = outgoing.played, outgoingAudio = outgoing.audio
                let planning = try await Task.detached(priority: .utility) {
                    let played = outgoingPlayed
                        ?? PlayedTrack(source: outgoingAudio.audio, analysis: outgoingAudio.analysis)
                    guard let planning = BlendPlanner.planBlend(outgoing: played, incoming: audio.analysis,
                                                                incomingAudio: audio.audio) else {
                        throw MixTrackLoaderError.empty
                    }
                    return planning
                }.value
                guard self.planning == target, !Task.isCancelled else { return }
                self.planning = nil
                if let plan = planning.plans.first {
                    Self.log.notice("mix decks: \(plan.style.rawValue, privacy: .public) (\(plan.placement.rawValue, privacy: .public)): \(plan.reason, privacy: .public)")
                }
                self.upcoming = Upcoming(index: nextIndex, audio: audio, planning: planning,
                                         outgoingTrackID: outgoing.trackID, outgoingTempo: outgoing.tempo)
                self.trySchedule()
            } catch {
                guard let self, self.planning == target, !(error is CancellationError) else { return }
                self.planning = nil
                self.loads[track.trackID] = nil
                Self.log.error("mix decks: preparing the next track failed: \(error.localizedDescription, privacy: .public)")
                self.host.mixDecksPublish(plan: nil, state: .failed(error.localizedDescription))
            }
        }
    }

    private func cancelPlanning() {
        planTask?.cancel()
        planTask = nil
        planning = nil
    }

    /// Puts the planned blend on the free deck once that deck is released.
    private func trySchedule() {
        guard let current, let upcoming, scheduled == nil else { return }
        let mix = output.mix
        let other = current.deck.other
        switch mix.state(of: other) {
        case .finished: mix.reset(other)
        case .armed, .playing: return       // the previous outgoing is still fading out
        case .idle: break
        }
        let sr = Self.sampleRate
        let now = Double(mix.masterFrame)
        let nowPlayed = (now - current.zeroFrame) / sr
        guard var plan = upcoming.planning.plans.first else { return }
        if auditionPending {
            auditionPending = false
            let target = max(0, plan.blendStart - Self.auditionLeadSeconds) * current.tempo
            start(index: host.mixDecksCurrentIndex, at: target, autoplay: true)
            return
        }
        plan.incomingGain = min(max(current.gain * plan.incomingGain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        let join = plan.style == .phraseCut ? plan.blendStart - 0.003 : plan.blendStart
        do {
            if blendsEnabled, join > nowPlayed + Self.scheduleLeadSeconds {
                try mix.schedule(plan, outgoing: current.deck, outgoingStartFrame: Int64(current.zeroFrame.rounded()),
                                 incoming: upcoming.audio.audio)
                let outgoingZero = Double(Int64(current.zeroFrame.rounded()))
                let incoming = Deck(index: upcoming.index, trackID: upcoming.audio.trackID, deck: other,
                                    audio: upcoming.audio, tempo: plan.tempo, gain: plan.incomingGain,
                                    zeroFrame: outgoingZero + plan.incomingOffset * sr,
                                    played: upcoming.planning.incoming)
                let flip = plan.style == .phraseCut ? plan.blendStart : plan.swapTime
                scheduled = Scheduled(incoming: incoming, joinFrame: outgoingZero + join * sr,
                                      flipFrame: outgoingZero + flip * sr, isBlend: true)
                host.mixDecksPublish(plan: transitionPlan(plan, from: current, to: upcoming), state: .ready)
            } else {
                // Too late for the planned blend (a seek past it, a slow download): the next
                // track follows the end of this one at its own tempo.
                let startFrame = max(current.endFrame, now + 1_024)
                try mix.prepare(other, buffer: upcoming.audio.audio, sourcePosition: 0, tempo: 1,
                                gain: Float(plan.incomingGain))
                try mix.start(other, atFrame: Int64(startFrame))
                let incoming = Deck(index: upcoming.index, trackID: upcoming.audio.trackID, deck: other,
                                    audio: upcoming.audio, tempo: 1, gain: plan.incomingGain,
                                    zeroFrame: startFrame, played: nil)
                scheduled = Scheduled(incoming: incoming, joinFrame: startFrame, flipFrame: startFrame, isBlend: false)
                host.mixDecksPublish(plan: TransitionPlan(fromTrackID: current.trackID, toTrackID: upcoming.audio.trackID,
                                                          style: .gapless, exitTime: current.duration),
                                     state: .ready)
            }
        } catch {
            Self.log.error("mix decks: scheduling failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Clock

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    func tick() {
        guard let current else { return }
        let mix = output.mix
        let now = Double(mix.masterFrame)
        if let scheduled, now >= scheduled.flipFrame {
            var incoming = scheduled.incoming
            self.scheduled = nil
            upcoming = nil
            reportedEnd = false
            incoming.index = host.mixDecksDidAdvance(to: incoming.index, trackID: incoming.trackID,
                                                     duration: incoming.duration)
            self.current = incoming
            prepareUpcoming()
            return
        }
        if let seconds = currentSeconds { host.mixDecksPosition(seconds: seconds) }
        let other = current.deck.other
        if scheduled == nil, mix.state(of: other) == .finished {
            mix.reset(other)
            trySchedule()
        } else if scheduled == nil, upcoming != nil {
            trySchedule()
        }
        if mix.state(of: current.deck) == .finished, scheduled == nil, !reportedEnd {
            reportedEnd = true
            host.mixDecksDidReachEnd(trackID: current.trackID)
        }
    }

    // MARK: - Helpers

    private func audioTask(for track: (trackID: Int64, source: MixTrackSource, bpm: Double?)) -> Task<MixTrackAudio, any Error> {
        if let existing = loads[track.trackID] { return existing }
        let trackID = track.trackID, source = track.source, bpm = track.bpm
        let sampleRate = Self.sampleRate
        let host = self.host
        let task = Task.detached(priority: .userInitiated) { () throws -> MixTrackAudio in
            let storedBPM: Double?
            if bpm == nil {
                storedBPM = (try? await LibraryStore.shared.transitionPrepPayload(trackId: trackID))?.bpm
            } else {
                storedBPM = bpm
            }
            return try await MixTrackLoader.load(trackID: trackID, source: source, approximateBPM: storedBPM,
                                                 sampleRate: sampleRate) { stage in
                Task { @MainActor [weak host] in
                    switch stage {
                    case .downloading(let fraction): host?.mixDecksPublish(plan: nil, state: .downloading(fraction))
                    case .analyzing: host?.mixDecksPublish(plan: nil, state: .analyzing(0))
                    }
                }
            }
        }
        loads[trackID] = task
        return task
    }

    private func dropLoads(keeping ids: Set<Int64>) {
        for (id, task) in loads where !ids.contains(id) {
            task.cancel()
            loads[id] = nil
        }
    }

    private func transitionPlan(_ plan: BlendPlan, from current: Deck, to upcoming: Upcoming) -> TransitionPlan {
        TransitionPlan(fromTrackID: current.trackID, toTrackID: upcoming.audio.trackID,
                       style: plan.style == .phraseCut ? .phraseFade : .beatmatchedBlend,
                       exitTime: plan.blendStart * current.tempo,
                       entryTime: max(0, (plan.blendStart - plan.incomingOffset) * plan.tempo),
                       overlapBeats: plan.overlapBeats,
                       overlapSeconds: Double(plan.overlapBeats) * plan.period,
                       blendRate: plan.tempo,
                       gainMatchDB: 20 * log10(max(plan.incomingGain, 1e-6)),
                       bpmDeltaPct: (plan.tempo - 1) * 100,
                       confidence: plan.placement == .none ? 0.5 : 1,
                       reasons: [.tempoMatched(pct: (plan.tempo - 1) * 100)])
    }
}
#endif
