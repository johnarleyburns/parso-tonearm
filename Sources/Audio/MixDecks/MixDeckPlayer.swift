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
    /// The outgoing track's deck has played out after a handoff: nothing of it is audible any more.
    func mixDecksOutgoingDidFinish()
    /// How the track at `from` hands over to the one at `to`.
    func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge
    /// Whether the track at `index` may be whole-decoded now, alone or as the incoming side of a
    /// blend out of `outgoing`. Nothing is decoded before this allows it.
    func mixDecksAdmission(index: Int, outgoing: Int?) -> TransitionAdmissionDecision
    /// The track at `index` was denied; it plays normally (never skipped).
    func mixDecksDenied(index: Int, decision: TransitionAdmissionDecision)
    /// The current queue generation; changes whenever the queue's occurrences change.
    var mixDecksQueueGeneration: Int { get }
    /// The stable occurrence identity of the queue slot at `index`.
    func mixDecksOccurrence(at index: Int) -> QueueOccurrenceID?
    /// What the renderer actually scheduled/played for an occurrence edge.
    func mixDecksExecution(_ event: MixDeckExecutionEvent)
}

extension MixDeckHost {
    func mixDecksAdmission(index: Int, outgoing: Int?) -> TransitionAdmissionDecision { .allowSmartBlend }
    func mixDecksDenied(index: Int, decision: TransitionAdmissionDecision) {}
}

extension MixDeckHost {
    func mixDecksOutgoingDidFinish() {}
    var mixDecksQueueGeneration: Int { 0 }
    func mixDecksOccurrence(at index: Int) -> QueueOccurrenceID? { nil }
    func mixDecksExecution(_ event: MixDeckExecutionEvent) {}
}

/// What the renderer actually did for one occurrence edge, reported as it happens.
enum MixDeckExecutionEvent: Sendable {
    case scheduled(key: TransitionEdgeKey, generation: Int, requested: TransitionDisplayStyle,
                   planned: TransitionDisplayStyle, executed: TransitionDisplayStyle,
                   reason: TransitionExecutionReason?, overlapStartFrame: Int64?, overlapEndFrame: Int64?,
                   handoffFrame: Int64, sampleRate: Double)
    case overlapBegan(key: TransitionEdgeKey, generation: Int, atFrame: Int64)
    case handedOff(key: TransitionEdgeKey, generation: Int, atFrame: Int64)
    case outgoingFinished(key: TransitionEdgeKey, generation: Int, atFrame: Int64)
    /// The decks restarted or stopped: everything not yet handed off is void.
    case reset(TransitionExecutionReason)
}

/// How one track hands over to the next on the mix decks.
enum MixDeckEdge: Equatable, Sendable {
    /// The planned DJ blend (bass swap / double drop, or a phrase cut).
    case blend
    /// A plain fade the listener chose for this edge: the outgoing fades out over
    /// its last seconds and the next track starts as it ends.
    case fade
    /// Gapless (consecutive tracks of an album): the next track starts exactly as
    /// this one ends.
    case gapless
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
    /// A plain fade's length (the edge the listener chose "plain fade" for).
    static let plainFadeSeconds = 8.0
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
        /// The track as this deck plays it, for planning the next blend (built on
        /// demand: the source itself at tempo 1, else a keylocked render).
        var played: PlayedTrack?
        /// Its analysis in that time base, when known from a plan.
        var playedAnalysis: BlendTrackAnalysis?
        var duration: Double { Double(audio.audio.frameCount) / MixDeckPlayer.sampleRate }
        var endFrame: Double { zeroFrame + Double(audio.audio.frameCount) / tempo }
    }

    struct Upcoming {
        let index: Int
        let audio: MixTrackAudio
        /// Best first; all share one tempo.
        let plans: [BlendPlan]
        /// The incoming as its deck will play it, when the planning produced it here.
        let incomingPlayed: PlayedTrack?
        let incomingPlayedAnalysis: BlendTrackAnalysis
        /// The outgoing track (and its tempo) the planning was made against.
        let outgoingTrackID: Int64
        let outgoingTempo: Double
    }

    struct Scheduled {
        var incoming: Deck
        /// When the incoming deck becomes audible, and when it becomes the current track.
        let joinFrame: Double
        let flipFrame: Double
        /// The handover it was scheduled for (a late blend falls back to a follow-on
        /// but is still the `.blend` edge).
        let edge: MixDeckEdge
        /// Occurrence identity captured when scheduled, so later queue edits cannot retarget it.
        var key: TransitionEdgeKey? = nil
        var generation = 0
        var overlapReported = false
    }

    /// What a planning in flight is for; a matching request leaves it running.
    private struct PlanningTarget: Equatable {
        let outgoingTrackID: Int64
        let outgoingTempo: Double
        let index: Int
        let trackID: Int64
    }

    private unowned let host: MixDeckHost
    /// Durable risk sentinel around decode/plan/schedule work; nil in tests and offline renders.
    var safety: TransitionSafetyMonitor?
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
        let center = NotificationCenter.default
        pressureObservers = [
            center.addObserver(forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
                               object: nil, queue: .main) { [weak self] _ in
                TransitionPressure.shared.noteMemoryWarning()
                Task { @MainActor in self?.shedFuturePreparation() }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                let state = ProcessInfo.processInfo.thermalState
                guard state == .serious || state == .critical else { return }
                Task { @MainActor in self?.shedFuturePreparation() }
            }
        ]
    }

    private var pressureObservers: [any NSObjectProtocol] = []

    /// Memory or thermal pressure: stop preparing what is not audible yet and free it. The
    /// current track (and an already executing transition) keeps playing.
    func shedFuturePreparation() {
        guard scheduled == nil else { return }
        cancelPlanning()
        upcoming = nil
        dropLoads(keeping: current.map { [$0.trackID] } ?? [])
        if current != nil { host.mixDecksPublish(plan: nil, state: .cancelled) }
    }

    deinit {
        MainActor.assumeIsolated {
            pressureObservers.forEach { NotificationCenter.default.removeObserver($0) }
            startTask?.cancel()
            cancelPlanning()
            ticker?.cancel()
            loads.values.forEach { $0.cancel() }
        }
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
        // A restart (skip, seek, back) discards any overlap: the old outgoing tail is gone with the reset.
        host.mixDecksExecution(.reset(.restarted))
        tailDeck = nil
        tailKey = nil
        scheduled = nil
        current = nil
        if let safety, !safety.enter(.startingCurrent) {
            host.mixDecksCouldNotPlay(index: index, reason: "Smart Blend safety journal unavailable")
            return
        }
        do { try output.reset() } catch {
            safety?.resolve(.safeFallback)
            host.mixDecksCouldNotPlay(index: index, reason: "Audio output failed: \(error.localizedDescription)")
            return
        }
        if autoplay { try? output.start() } else { output.pause() }
        startTicker()

        if keepsTrack, let previous {
            begin(index: index, audio: previous.audio, tempo: previous.tempo, gain: previous.gain,
                  played: previous.played, playedAnalysis: previous.playedAnalysis, at: seconds)
            return
        }
        guard let track = host.mixDecksTrack(at: index) else {
            host.mixDecksCouldNotPlay(index: index, reason: "The track has no playable audio")
            return
        }
        let admission = host.mixDecksAdmission(index: index, outgoing: nil)
        guard admission == .allowSmartBlend else {
            cancelPlanning()
            dropLoads(keeping: [])
            output.stop()
            host.mixDecksDenied(index: index, decision: admission)
            return
        }
        if let safety, !safety.enter(.decodingCurrent) {
            host.mixDecksCouldNotPlay(index: index, reason: "Smart Blend safety journal unavailable")
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
                self.begin(index: index, audio: audio, tempo: 1, gain: 1, played: nil, playedAnalysis: nil, at: seconds)
            } catch {
                guard let self, self.epoch == myEpoch, !(error is CancellationError) else { return }
                self.startTask = nil
                self.loads[track.trackID] = nil
                self.host.mixDecksLoading(false)
                self.safety?.resolve(.safeFallback)
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
        host.mixDecksExecution(.reset(.stopped))
        tailKey = nil
        safety?.resolve(.cancelled)
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
        tailDeck = nil
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
            let edge = blendsEnabled && next != nil
                ? host.mixDecksEdge(from: host.mixDecksCurrentIndex, to: next!) : .gapless
            if unchanged && scheduled.edge == edge { return }
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

    private func begin(index: Int, audio: MixTrackAudio, tempo: Double, gain: Double, played: PlayedTrack?,
                       playedAnalysis: BlendTrackAnalysis?, at seconds: Double) {
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
                       zeroFrame: startFrame - sourcePosition / tempo, played: played,
                       playedAnalysis: playedAnalysis)
        host.mixDecksPosition(seconds: sourcePosition / Self.sampleRate)
        if upcoming != nil { trySchedule() } else { prepareUpcoming() }
    }

    /// Loads the next queue track and plans the blend into it (or takes the plan
    /// the transition preparation already made: same planner, shared cache).
    private func prepareUpcoming() {
        guard let current else { return }
        guard let nextIndex = host.mixDecksUpcomingIndex(after: host.mixDecksCurrentIndex),
              let track = host.mixDecksTrack(at: nextIndex) else {
            cancelPlanning()
            dropLoads(keeping: [current.trackID])
            safety?.resolve(.completed)
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
        let admission = host.mixDecksAdmission(index: nextIndex, outgoing: host.mixDecksCurrentIndex)
        guard admission == .allowSmartBlend else {
            cancelPlanning()
            upcoming = nil
            dropLoads(keeping: [current.trackID])
            host.mixDecksDenied(index: nextIndex, decision: admission)
            return
        }
        cancelPlanning()
        upcoming = nil
        if let safety, !safety.enter(.planningIncoming) {
            host.mixDecksDenied(index: nextIndex, decision: .gaplessFallback(reason: .preparationFailed))
            return
        }
        planning = target
        dropLoads(keeping: [current.trackID, track.trackID])
        let load = audioTask(for: track)
        host.mixDecksPublish(plan: nil, state: .queued)
        let outgoing = current
        planTask = Task { [weak self] in
            do {
                let audio = try await load.value
                guard let self, self.planning == target, !Task.isCancelled else { return }
                let cached = BlendPlanCache.shared.entry(from: outgoing.trackID, to: audio.trackID,
                                                         outgoingTempo: outgoing.tempo)
                let plans: [BlendPlan], incomingPlayed: PlayedTrack?, incomingAnalysis: BlendTrackAnalysis
                if let cached {
                    (plans, incomingPlayed, incomingAnalysis) = (cached.plans, nil, cached.incomingPlayed)
                } else {
                    self.host.mixDecksPublish(plan: nil, state: .analyzing(0.5))
                    let deck = outgoing
                    let safety = self.safety
                    safety?.workerStarted()
                    let planning = try await Task.detached(priority: .utility) { () throws -> BlendPlanning in
                        defer { Task { @MainActor in safety?.workerExited() } }
                        guard let played = deck.played
                                ?? BlendEdgePlanner.played(deck.audio, tempo: deck.tempo, analysis: deck.playedAnalysis),
                              let planning = BlendEdgePlanner.plan(outgoing: played, incoming: audio) else {
                            throw MixTrackLoaderError.empty
                        }
                        return planning
                    }.value
                    guard self.planning == target, !Task.isCancelled else { return }
                    (plans, incomingPlayed, incomingAnalysis) = (planning.plans, planning.incoming, planning.incoming.analysis)
                    BlendPlanCache.shared.store(.init(plans: plans, incomingPlayed: incomingAnalysis,
                                                      outgoingTempo: outgoing.tempo),
                                                from: outgoing.trackID, to: audio.trackID)
                }
                self.planning = nil
                if let plan = plans.first {
                    Self.log.notice("mix decks: \(plan.style.rawValue, privacy: .public) (\(plan.placement.rawValue, privacy: .public)): \(plan.reason, privacy: .public)")
                }
                self.upcoming = Upcoming(index: nextIndex, audio: audio, plans: plans,
                                         incomingPlayed: incomingPlayed, incomingPlayedAnalysis: incomingAnalysis,
                                         outgoingTrackID: outgoing.trackID, outgoingTempo: outgoing.tempo)
                self.trySchedule()
            } catch {
                guard let self, self.planning == target, !(error is CancellationError) else { return }
                self.planning = nil
                self.loads[track.trackID] = nil
                self.safety?.resolve(.safeFallback)
                Self.log.error("mix decks: preparing the next track failed: \(error.localizedDescription, privacy: .public)")
                self.host.mixDecksDenied(index: nextIndex, decision: .gaplessFallback(reason: .preparationFailed))
            }
        }
    }

    private func cancelPlanning() {
        planTask?.cancel()
        planTask = nil
        planning = nil
    }

    /// Puts the next track on the free deck once that deck is released: the
    /// planned blend, a plain fade, or a gapless follow-on.
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
        guard var plan = upcoming.plans.first else { return }
        if auditionPending {
            auditionPending = false
            let target = max(0, plan.blendStart - Self.auditionLeadSeconds) * current.tempo
            start(index: host.mixDecksCurrentIndex, at: target, autoplay: true)
            return
        }
        plan.incomingGain = min(max(current.gain * plan.incomingGain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        let edge = blendsEnabled ? host.mixDecksEdge(from: host.mixDecksCurrentIndex, to: upcoming.index) : .gapless
        let join = plan.style == .phraseCut ? plan.blendStart - 0.003 : plan.blendStart
        let plannedDisplay: TransitionDisplayStyle = plan.style == .phraseCut ? .phraseBlend : .beatMatched
        do {
            if edge == .blend, join > nowPlayed + Self.scheduleLeadSeconds {
                try mix.schedule(plan, outgoing: current.deck, outgoingStartFrame: Int64(current.zeroFrame.rounded()),
                                 incoming: upcoming.audio.audio)
                let outgoingZero = Double(Int64(current.zeroFrame.rounded()))
                let incoming = Deck(index: upcoming.index, trackID: upcoming.audio.trackID, deck: other,
                                    audio: upcoming.audio, tempo: plan.tempo, gain: plan.incomingGain,
                                    zeroFrame: outgoingZero + plan.incomingOffset * sr,
                                    played: upcoming.incomingPlayed, playedAnalysis: upcoming.incomingPlayedAnalysis)
                let flip = plan.style == .phraseCut ? plan.blendStart : plan.swapTime
                scheduled = Scheduled(incoming: incoming, joinFrame: outgoingZero + join * sr,
                                      flipFrame: outgoingZero + flip * sr, edge: edge)
                reportScheduled(planned: plannedDisplay, executed: plannedDisplay, reason: nil,
                                requested: plannedDisplay, incomingIndex: upcoming.index)
                _ = safety?.enter(.scheduled)   // already journaled active; a failed phase update leaves the earlier phase on disk
                host.mixDecksPublish(plan: BlendPlanCache.transitionPlan(plan, from: current.trackID,
                                                                         to: upcoming.audio.trackID,
                                                                         outgoingTempo: current.tempo),
                                     state: .ready)
                return
            }
            // A plain fade, a gapless edge, or too late for the planned blend (a seek past it,
            // a slow download): the next track starts as this one ends, at its own tempo.
            let end = current.endFrame
            let startFrame = max(end, now + 1_024)
            var style = TransitionStyle.gapless
            if edge == .fade, end - now > Self.plainFadeSeconds * sr * 0.5 {
                style = .plainCrossfade
                mix.scheduleCut(from: current.deck, to: other, cutFrame: end,
                                fadeFrames: min(Self.plainFadeSeconds * sr, end - now))
            }
            try mix.prepare(other, buffer: upcoming.audio.audio, sourcePosition: 0, tempo: 1,
                            gain: Float(plan.incomingGain))
            try mix.start(other, atFrame: Int64(startFrame))
            let incoming = Deck(index: upcoming.index, trackID: upcoming.audio.trackID, deck: other,
                                audio: upcoming.audio, tempo: 1, gain: plan.incomingGain,
                                zeroFrame: startFrame, played: nil, playedAnalysis: nil)
            scheduled = Scheduled(incoming: incoming, joinFrame: startFrame, flipFrame: startFrame, edge: edge)
            let requested: TransitionDisplayStyle = switch edge {
            case .blend: plannedDisplay
            case .fade: .plainCrossfade
            case .gapless: .gapless
            }
            let reason: TransitionExecutionReason = switch edge {
            case .blend: .lateForPlannedBlend
            case .fade: .plainFadeEdge
            case .gapless: .gaplessEdge
            }
            reportScheduled(planned: plannedDisplay, executed: TransitionDisplayStyle(style),
                            reason: edge == .fade && style == .plainCrossfade ? nil : reason,
                            requested: requested, incomingIndex: upcoming.index)
            host.mixDecksPublish(plan: TransitionPlan(fromTrackID: current.trackID, toTrackID: upcoming.audio.trackID,
                                                      style: style, exitTime: current.duration,
                                                      overlapSeconds: style == .plainCrossfade ? Self.plainFadeSeconds : 0),
                                 state: .ready)
        } catch {
            Self.log.error("mix decks: scheduling failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reports to the host exactly what was just scheduled on the renderer.
    private func reportScheduled(planned: TransitionDisplayStyle, executed: TransitionDisplayStyle,
                                 reason: TransitionExecutionReason?, requested: TransitionDisplayStyle,
                                 incomingIndex: Int) {
        guard let current, scheduled != nil,
              let key = occurrenceKey(outgoing: host.mixDecksCurrentIndex, incoming: incomingIndex) else { return }
        let generation = host.mixDecksQueueGeneration
        scheduled?.key = key
        scheduled?.generation = generation
        let join = Int64(scheduled?.joinFrame ?? 0), flip = Int64(scheduled?.flipFrame ?? 0)
        host.mixDecksExecution(.scheduled(key: key, generation: generation, requested: requested,
                                          planned: planned, executed: executed,
                                          reason: reason, overlapStartFrame: executed.overlaps ? join : nil,
                                          overlapEndFrame: executed.overlaps ? flip : nil,
                                          handoffFrame: flip, sampleRate: Self.sampleRate))
        _ = current
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

    /// The deck that handed over at the last flip, until it has fully played out.
    private var tailDeck: MixDeck?
    private var tailKey: (key: TransitionEdgeKey, generation: Int)?

    private func occurrenceKey(outgoing: Int, incoming: Int) -> TransitionEdgeKey? {
        guard let from = host.mixDecksOccurrence(at: outgoing), let to = host.mixDecksOccurrence(at: incoming) else { return nil }
        return TransitionEdgeKey(from: from, to: to)
    }

    func tick() {
        guard let current else { return }
        let mix = output.mix
        let now = Double(mix.masterFrame)
        if let scheduled, now >= scheduled.flipFrame {
            var incoming = scheduled.incoming
            if let key = scheduled.key {
                host.mixDecksExecution(.handedOff(key: key, generation: scheduled.generation, atFrame: Int64(now)))
                tailKey = (key, scheduled.generation)
            }
            tailDeck = current.deck
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
        if let scheduled, scheduled.edge == .blend, !scheduled.overlapReported, now >= scheduled.joinFrame,
           let key = scheduled.key {
            self.scheduled?.overlapReported = true
            host.mixDecksExecution(.overlapBegan(key: key, generation: scheduled.generation, atFrame: Int64(now)))
        }
        if let tail = tailDeck, mix.state(of: tail) == .finished {
            tailDeck = nil
            if let tailKey {
                host.mixDecksExecution(.outgoingFinished(key: tailKey.key, generation: tailKey.generation, atFrame: Int64(now)))
            }
            tailKey = nil
            host.mixDecksOutgoingDidFinish()
        }
        if let safety {
            if let scheduled, scheduled.edge == .blend, now >= scheduled.joinFrame {
                _ = safety.enter(.overlap)
            } else if scheduled?.edge == .blend {
                safety.heartbeat()
            } else if isPreparing {
                safety.heartbeat()
            } else if safety.isActive {
                // Stable and non-risky: nothing left decoding, planning or blending.
                safety.resolve(.completed)
            }
        }
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
        let safety = self.safety
        safety?.workerStarted()
        let task = Task.detached(priority: .userInitiated) { () throws -> MixTrackAudio in
            // The sentinel stays until this worker really exits, even if it was cancelled meanwhile.
            defer { Task { @MainActor in safety?.workerExited() } }
            let storedBPM: Double?
            if bpm == nil {
                storedBPM = (try? await LibraryStore.shared.blendTempoHint(trackId: trackID)) ?? nil
            } else {
                storedBPM = bpm
            }
            // One whole-track decode in the app at a time; a cancelled one never starts.
            return try await TransitionDecodeGate.shared.runAsync {
                try await MixTrackLoader.load(trackID: trackID, source: source, approximateBPM: storedBPM,
                                              sampleRate: sampleRate) { stage in
                Task { @MainActor [weak host] in
                    switch stage {
                    case .downloading(let fraction): host?.mixDecksPublish(plan: nil, state: .downloading(fraction))
                    case .analyzing: host?.mixDecksPublish(plan: nil, state: .analyzing(0))
                    }
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
}
#endif
