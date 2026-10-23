#if !os(watchOS)
import AVFoundation
import Foundation
import OSLog
import os

/// Why a Starter Blend stopped streaming. `retryable` says whether trying again can help.
struct StarterStreamFailure: Equatable, Sendable {
    let trackIndex: Int
    /// The track that was audible when streaming stopped.
    let playingIndex: Int
    let trackID: String
    let retryable: Bool
    let message: String
    /// Where the track that was playing had got to, so sequential playback can pick up there.
    let resumeSeconds: Double
}

/// What the stream renderer reports for one edge, as it happens.
enum StarterEdgeEvent: Equatable, Sendable {
    /// The supplied plan was resolved and handed to the renderer (`executed == planned`), or the
    /// edge could not honour it and will follow on without a blend (`executed == nil`).
    case scheduled(edge: Int, plan: BlendEdgePlan, executed: BlendEdgePlan.Style?)
    case overlapBegan(edge: Int, atFrame: Int64)
    case handedOff(edge: Int, atFrame: Int64)
}

@MainActor
protocol StarterStreamHost: AnyObject {
    func starterStreamBuffering(_ buffering: Bool)
    func starterStreamDidAdvance(to index: Int)
    func starterStreamPosition(seconds: Double)
    func starterStreamDidFinish()
    func starterStreamDidFail(_ failure: StarterStreamFailure)
    func starterStreamEdge(_ event: StarterEdgeEvent)
    /// Whether the edge leaving track `index` may blend (not under repeat-one or an end-of-track sleep timer).
    func starterStreamAllowsBlend(from index: Int) -> Bool
}

extension StarterStreamHost {
    func starterStreamAllowsBlend(from index: Int) -> Bool { true }
}

/// Shared by everything that must stop when a session ends: network reads in flight and decks.
final class StarterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []
    private var cancelled = false

    func register(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if !cancelled { handlers.append(handler) }
            return cancelled
        }
        if runNow { handler() }
    }

    func cancel() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            cancelled = true
            defer { handlers = [] }
            return handlers
        }
        pending.forEach { $0() }
    }
}

/// The audio device side. Nil in tests, which pull the mixer directly.
@MainActor
protocol StarterStreamOutput: AnyObject {
    var volume: Float { get set }
    func start() throws
    func pause()
    func stop()
}

/// A mixer plus the lock that serialises control calls with the render callback. The callback
/// only ever tries the lock: if a control call holds it, that one block is silence, never a wait.
final class StarterMixerCell: @unchecked Sendable {
    let mixer: BoundedDeckMixer
    private let lock = OSAllocatedUnfairLock()
    /// Preallocated planar scratch for the render callback (no allocation on the audio thread).
    private let block: UnsafeMutablePointer<Float>

    init(mixer: BoundedDeckMixer) {
        self.mixer = mixer
        block = .allocate(capacity: 2 * mixer.maxBlockFrames)
        block.initialize(repeating: 0, count: 2 * mixer.maxBlockFrames)
    }

    deinit { block.deallocate() }

    func perform<T>(_ body: (BoundedDeckMixer) -> T) -> T { lock.withLockUnchecked { body(mixer) } }

    /// Audio thread. False when the lock was busy (the destination was left untouched).
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let rendered: Void? = lock.withLockIfAvailableUnchecked {
            mixer.render(into: block, frames: frames)
            left.update(from: block, count: frames)
            right.update(from: block + frames, count: frames)
        }
        return rendered != nil
    }
}

/// One deck's decode thread. It owns the only writes into the deck's `BoundedDeckBuffer`, tagged
/// with the generation the controller attached the source under, so a retargeted deck is never
/// refilled from a stale source.
final class StarterDeckFeeder: @unchecked Sendable {
    private let buffer: BoundedDeckBuffer
    private let lock = NSLock()
    private var source: (any StarterDeckSource)?
    private var attachedGeneration = -1
    private var failure: ReleaseRangeError?
    private var stopped = false
    private var thread: Thread?

    init(buffer: BoundedDeckBuffer, name: String) {
        self.buffer = buffer
        let thread = Thread { [weak self] in self?.run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func attach(_ source: (any StarterDeckSource)?, generation: Int) {
        let old: (any StarterDeckSource)? = lock.withLock {
            let previous = self.source
            self.source = source
            attachedGeneration = generation
            failure = nil
            return previous
        }
        // Re-attaching the same source (a seek) must not cancel it.
        if let old, old !== source { old.cancel() }
    }

    func takeFailure() -> ReleaseRangeError? { lock.withLock { let f = failure; failure = nil; return f } }

    func stop() {
        let old: (any StarterDeckSource)? = lock.withLock {
            stopped = true
            let previous = source
            source = nil
            return previous
        }
        old?.cancel()
    }

    private func run() {
        while true {
            let (source, generation, isStopped) = lock.withLock { (self.source, attachedGeneration, stopped) }
            if isStopped { return }
            guard let source else { Thread.sleep(forTimeInterval: 0.02); continue }
            let request = buffer.nextRequest()
            guard request.generation == generation, request.wanted > 0 else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            do {
                let channels = try source.read(startFrame: request.startFrame, count: min(request.wanted, 8_192))
                guard channels.first?.isEmpty == false else { Thread.sleep(forTimeInterval: 0.02); continue }
                _ = buffer.write(DeckChunk(generation: request.generation, startFrame: request.startFrame,
                                           channels: channels))
            } catch {
                let reason = (error as? ReleaseRangeError) ?? .transient(error.localizedDescription)
                lock.withLock {
                    // A source swapped meanwhile is not at fault for the old one's failure.
                    if attachedGeneration == generation, reason != .cancelled { failure = reason }
                    if attachedGeneration == generation { self.source = nil }
                }
            }
        }
    }
}

/// The Starter Blend renderer: two bounded decks streaming decoded frames from range-backed
/// sources, mixed on one sample clock by `BoundedDeckMixer`, executing the *supplied* edge plan at
/// every adjacent pair (bass swap, double drop or phrase cut). It never holds a whole track: each
/// deck is a fixed ring, and there is no resident-PCM or whole-file fallback.
@MainActor
final class StarterStreamPlayer {
    typealias SourceFactory = @Sendable (_ trackID: String, _ cancellation: StarterCancellation) throws
        -> any StarterDeckSource

    struct Config {
        var trackIDs: [String]
        /// `plans[i]` joins track `i` to track `i + 1`.
        var plans: [BlendEdgePlan]
        var deckSeconds = 8.0
        var startBufferSeconds = 1.0
        var incomingBufferSeconds = 0.75
        /// An edge whose overlap would start sooner than this after scheduling plays as a follow-on.
        var minLeadSeconds = 0.5
        static let cutFadeSeconds = 0.010
    }

    private static let log = Logger(subsystem: "guru.parso.tonearm", category: "StarterStream")
    /// Combined gain limits (the resident decks use the same range): loudness matching never boosts into clipping.
    static let gainRange: ClosedRange<Double> = 0.5...1.6

    private var config: Config
    private unowned let host: StarterStreamHost
    private let makeSource: SourceFactory
    private let output: StarterStreamOutput?
    private let openQueue = DispatchQueue(label: "guru.parso.tonearm.starter-open", qos: .userInitiated,
                                          attributes: .concurrent)
    private(set) var cell: StarterMixerCell?
    private var feeders: [StarterDeckFeeder] = []
    private var rate = 0.0
    private(set) var currentIndex = 0
    var capacityFrames: Int { Int(max(8_192, rate * config.deckSeconds)) }
    private var currentGain = 1.0
    private var scheduledGain = 1.0
    /// Bumped by every start/jump/stop; work from an older epoch is dropped.
    private var epoch = 0
    private var cancellation = StarterCancellation()
    private var mainSource: (any StarterDeckSource)?
    private var openTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var scheduledEdge: Int?
    private(set) var isBuffering = true
    private var isPaused = false
    private var reportedFinish = false
    private var lastHandoffs = 0
    private var overlapReported = false

    var isStreaming: Bool { cell != nil }
    var sampleRate: Double { rate }
    var volume: Float {
        get { output?.volume ?? 1 }
        set { output?.volume = newValue }
    }

    init(config: Config, host: StarterStreamHost, output: StarterStreamOutput?, makeSource: @escaping SourceFactory) {
        self.config = config
        self.host = host
        self.output = output
        self.makeSource = makeSource
    }

    // MARK: Control

    /// Starts track `index` at `seconds`. Output begins only after `startBufferSeconds` is decoded.
    func start(at index: Int, seconds: Double = 0) {
        teardown(keepOutput: true)
        guard config.trackIDs.indices.contains(index) else { return }
        epoch += 1
        let myEpoch = epoch
        currentIndex = index
        currentGain = 1
        isBuffering = true
        isPaused = false
        reportedFinish = false
        scheduledEdge = nil
        overlapReported = false
        host.starterStreamBuffering(true)
        let token = StarterCancellation()
        cancellation = token
        let trackID = config.trackIDs[index]
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.open(trackID, token)
                guard self.epoch == myEpoch else { source.cancel(); return }
                self.beginMain(source: source, index: index, seconds: seconds)
            } catch {
                guard self.epoch == myEpoch else { return }
                self.fail(index: index, trackID: trackID, error: error, resume: seconds)
            }
        }
    }

    func pause() {
        isPaused = true
        cell?.perform { $0.pause(.user) }
        output?.pause()
    }

    func resume() {
        guard cell != nil else { return }
        isPaused = false
        cell?.perform { $0.resume() }
        if !isBuffering { try? output?.start() }
    }

    /// Seeks within the current track; the pending overlap is dropped and re-planned from here.
    func seek(to seconds: Double) {
        guard let cell, let source = mainSource else { return }
        let frame = Int64(min(max(0, seconds), Double(source.totalFrames) / rate - 0.1) * rate)
        let (main, generation): (Int, Int) = cell.perform { mixer in
            mixer.seek(to: frame)
            return (mixer.main, mixer.decks[mixer.main].generation)
        }
        feeders[main].attach(source, generation: generation)
        feeders[1 - main].attach(nil, generation: -1)
        nextSource?.cancel()
        nextSource = nil
        scheduledEdge = nil
        overlapReported = false
        openTask?.cancel()
        scheduleUpcomingIfNeeded()
    }

    func stop() {
        epoch += 1
        teardown(keepOutput: false)
    }

    /// Repeat or the sleep timer changed: an overlap that has not begun is dropped when it is no longer
    /// allowed, and one that is now allowed is scheduled.
    func edgePolicyChanged() {
        guard let cell else { return }
        if scheduledEdge != nil, !host.starterStreamAllowsBlend(from: currentIndex) {
            let cancelled: Int? = cell.perform { mixer in
                guard case .pending = mixer.overlap else { return nil }
                mixer.cancelOverlap()
                return 1 - mixer.main
            }
            guard let incoming = cancelled else { return }
            feeders[incoming].attach(nil, generation: -1)
            nextSource?.cancel()
            nextSource = nil
            scheduledEdge = nil
            openTask?.cancel()
        } else {
            scheduleUpcomingIfNeeded()
        }
    }

    /// Appends tracks (and the plans joining them) to a session in progress, e.g. Keep Playing.
    func extend(trackIDs: [String], plans: [BlendEdgePlan]) {
        config.trackIDs += trackIDs
        config.plans += plans
        reportedFinish = false
        scheduleUpcomingIfNeeded()
    }

    /// Seconds into the current track.
    var positionSeconds: Double {
        guard let cell, rate > 0 else { return 0 }
        return Double(cell.perform { $0.decks[$0.main].currentFrame }) / rate
    }

    // MARK: Opening

    private func open(_ trackID: String, _ token: StarterCancellation) async throws -> any StarterDeckSource {
        let factory = makeSource
        return try await withCheckedThrowingContinuation { continuation in
            openQueue.async {
                do { continuation.resume(returning: try factory(trackID, token)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func beginMain(source: any StarterDeckSource, index: Int, seconds: Double) {
        rate = source.sampleRate
        let capacity = max(8_192, Int(rate * config.deckSeconds))
        let mixer = BoundedDeckMixer(sampleRate: rate, capacityFrames: capacity,
                                     maxBlockFrames: StarterStreamLimits.maxFramesPerRender, prerollFrames: 0)
        let cell = StarterMixerCell(mixer: mixer)
        self.cell = cell
        output?.stop()
        let startFrame = Int64(min(max(0, seconds), max(0, Double(source.totalFrames) / rate - 1)) * rate)
        cell.perform { $0.begin(totalFrames: source.totalFrames, startFrame: startFrame) }
        cell.perform { $0.pause(.user) }          // frozen until enough is buffered
        feeders = (0..<2).map { StarterDeckFeeder(buffer: mixer.decks[$0], name: "starter-deck-\($0)") }
        feeders[0].attach(source, generation: mixer.decks[0].generation)
        mainSource = source
        lastHandoffs = 0
        startTicker()
    }

    private func teardown(keepOutput: Bool) {
        openTask?.cancel(); openTask = nil
        ticker?.cancel(); ticker = nil
        cancellation.cancel()
        cancellation = StarterCancellation()
        feeders.forEach { $0.stop() }
        feeders = []
        mainSource?.cancel()
        mainSource = nil
        cell = nil
        if !keepOutput { output?.stop() }
        scheduledEdge = nil
    }

    // MARK: Tick

    private func startTicker() {
        ticker?.cancel()
        let myEpoch = epoch
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.epoch == myEpoch else { return }
                self.tick()
            }
        }
    }

    /// One control pass; the timer calls it every 100 ms and tests call it directly.
    func tick() {
        guard let cell, !feeders.isEmpty else { return }
        if isBuffering {
            let main = cell.perform { $0.main }
            let buffered = cell.perform { $0.decks[main].bufferedFrames }
            let total = cell.perform { $0.decks[main].totalFrames - $0.decks[main].currentFrame }
            if buffered >= Int(rate * config.startBufferSeconds) || Int64(buffered) >= total {
                isBuffering = false
                if !isPaused {
                    cell.perform { $0.resume() }
                    do { try output?.start() } catch {
                        fail(index: currentIndex, trackID: config.trackIDs[currentIndex],
                             error: ReleaseRangeError.permanent("audio output unavailable"), resume: positionSeconds)
                        return
                    }
                }
                host.starterStreamBuffering(false)
                scheduleUpcomingIfNeeded()
            }
        }
        for slot in feeders.indices {
            if let error = feeders[slot].takeFailure() {
                let isMain = slot == cell.perform({ $0.main })
                let index = isMain ? currentIndex : currentIndex + 1
                fail(index: min(index, config.trackIDs.count - 1), trackID: config.trackIDs[min(index, config.trackIDs.count - 1)],
                     error: error, resume: positionSeconds)
                return
            }
        }
        let state = cell.perform { mixer -> (handoffs: Int, overlapActive: Bool, finished: Bool, clock: Int64) in
            var active = false
            if case .active = mixer.overlap { active = true }
            let deck = mixer.decks[mixer.main]
            let noOverlap = mixer.overlap == .none
            return (mixer.handoffs, active, noOverlap && deck.totalFrames > 0 && deck.currentFrame >= deck.totalFrames, mixer.clock)
        }
        if state.overlapActive, !overlapReported, let edge = scheduledEdge {
            overlapReported = true
            host.starterStreamEdge(.overlapBegan(edge: edge + 1, atFrame: state.clock))
        }
        if state.handoffs > lastHandoffs {
            lastHandoffs = state.handoffs
            completeHandoff(clock: state.clock)
        } else if state.finished, !reportedFinish, currentIndex == config.trackIDs.count - 1 || scheduledEdge == nil {
            reportedFinish = true
            output?.pause()
            host.starterStreamDidFinish()
        }
        host.starterStreamPosition(seconds: positionSeconds)
    }

    private func completeHandoff(clock: Int64) {
        guard let edge = scheduledEdge, let cell else { return }
        let finished = edge
        // A cut's overlap is a few milliseconds: the tick may never have seen it active.
        if !overlapReported { host.starterStreamEdge(.overlapBegan(edge: finished + 1, atFrame: clock)) }
        currentIndex = finished + 1
        currentGain = scheduledGain
        scheduledEdge = nil
        overlapReported = false
        mainSource = nextSource
        nextSource = nil
        // The deck that just finished is idle: stop feeding it.
        feeders[1 - cell.perform { $0.main }].attach(nil, generation: -1)
        host.starterStreamEdge(.handedOff(edge: finished + 1, atFrame: clock))
        host.starterStreamDidAdvance(to: currentIndex)
        scheduleUpcomingIfNeeded()
    }

    // MARK: Edges

    private var nextSource: (any StarterDeckSource)?

    /// Opens the following track and hands the renderer the supplied plan for the edge into it.
    private func scheduleUpcomingIfNeeded() {
        guard cell != nil, mainSource != nil, scheduledEdge == nil, currentIndex + 1 < config.trackIDs.count,
              host.starterStreamAllowsBlend(from: currentIndex) else { return }
        let edge = currentIndex
        let outgoingID = config.trackIDs[edge], incomingID = config.trackIDs[edge + 1]
        scheduledEdge = edge
        let myEpoch = epoch
        let token = cancellation
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.open(incomingID, token)
                guard self.epoch == myEpoch, self.scheduledEdge == edge, self.cell != nil else { source.cancel(); return }
                self.commitEdge(edge, outgoingID: outgoingID, incomingID: incomingID, source: source)
            } catch {
                guard self.epoch == myEpoch else { return }
                self.fail(index: edge + 1, trackID: incomingID, error: error, resume: self.positionSeconds)
            }
        }
    }

    private func commitEdge(_ edge: Int, outgoingID: String, incomingID: String, source: any StarterDeckSource) {
        guard let cell, let mainSource, let plan = config.plans.first(where: { $0.outgoingTrackID == outgoingID
            && $0.incomingTrackID == incomingID }) ?? (config.plans.indices.contains(edge) ? config.plans[edge] : nil) else {
            source.cancel()
            fail(index: edge + 1, trackID: incomingID, error: ReleaseRangeError.permanent("no edge plan"),
                 resume: positionSeconds)
            return
        }
        guard abs(source.sampleRate - rate) < 0.5 else {
            source.cancel()
            fail(index: edge + 1, trackID: incomingID,
                 error: ReleaseRangeError.permanent("unsupported sample rate"), resume: positionSeconds)
            return
        }
        let outgoingTotal = mainSource.totalFrames
        let position = cell.perform { $0.decks[$0.main].currentFrame }
        let schedule = plan.schedule()
        var bounded: BoundedOverlapPlan
        var executed: BlendEdgePlan.Style?
        if let schedule {
            let trigger = Int64(schedule.outgoingStart * rate)
            let cut = schedule.style == .phraseCut
            let fade = cut ? Int(Config.cutFadeSeconds * rate) : max(1, Int(schedule.overlapSeconds * rate))
            let honourable = trigger - position > Int64(config.minLeadSeconds * rate) && trigger < outgoingTotal
                && schedule.incomingStart * rate < Double(source.totalFrames)
            if honourable {
                let gain = min(max(currentGain * schedule.incomingGain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
                scheduledGain = gain
                let style: BoundedOverlapStyle = {
                    switch schedule.style {
                    case .bassSwap: return .bassSwap
                    case .doubleDrop: return .doubleDrop
                    case .phraseCut: return .crossfade
                    }
                }()
                bounded = BoundedOverlapPlan(
                    startClock: 0, outgoingTriggerFrame: trigger, style: style,
                    swapOffsetFrames: Int((schedule.swapOffsetSeconds ?? 0) * rate), fadeFrames: fade,
                    incomingStartFrame: Int64(schedule.incomingStart * rate), incomingTotalFrames: source.totalFrames,
                    incomingTempo: schedule.incomingTempo, incomingGain: Float(gain),
                    minIncomingBufferedFrames: Int(rate * config.incomingBufferSeconds))
                executed = schedule.style
            } else {
                bounded = followOn(outgoingTotal: outgoingTotal, incomingTotal: source.totalFrames)
            }
        } else {
            bounded = followOn(outgoingTotal: outgoingTotal, incomingTotal: source.totalFrames)
        }
        if executed == nil { scheduledGain = currentGain }
        bounded.minIncomingBufferedFrames = min(bounded.minIncomingBufferedFrames, Int(source.totalFrames))
        let generation: Int = cell.perform { mixer in
            mixer.schedule(bounded)
            return mixer.decks[mixer.incomingIndex].generation
        }
        nextSource = source
        feeders[1 - cell.perform { $0.main }].attach(source, generation: generation)
        host.starterStreamEdge(.scheduled(edge: edge + 1, plan: plan, executed: executed))
    }

    /// The edge's plan could not be honoured (the listener seeked past it, or it is malformed): the
    /// next track starts as this one ends, with no blend, and the host is told so.
    private func followOn(outgoingTotal: Int64, incomingTotal: Int64) -> BoundedOverlapPlan {
        let fade = Int(Config.cutFadeSeconds * rate)
        return BoundedOverlapPlan(startClock: 0, outgoingTriggerFrame: max(0, outgoingTotal - Int64(fade)),
                                  style: .crossfade, fadeFrames: fade, incomingStartFrame: 0,
                                  incomingTotalFrames: incomingTotal, incomingTempo: 1, incomingGain: Float(currentGain),
                                  minIncomingBufferedFrames: Int(rate * config.incomingBufferSeconds))
    }

    private func fail(index: Int, trackID: String, error: any Error, resume: Double) {
        let range = (error as? ReleaseRangeError) ?? .transient(error.localizedDescription)
        if range == .cancelled { return }
        let number = index + 1
        let failure = StarterStreamFailure(trackIndex: index, playingIndex: currentIndex, trackID: trackID, retryable: range.isRetryable,
                                           message: "Track \(number): \(range.errorDescription ?? "unavailable")",
                                           resumeSeconds: resume)
        Self.log.error("starter stream failed at track \(number, privacy: .public): \(String(describing: range), privacy: .public)")
        epoch += 1
        teardown(keepOutput: false)
        host.starterStreamDidFail(failure)
    }

    // MARK: Offline pull (tests)

    /// Renders the next `frames` stereo frames exactly as the audio callback would, returning planar channels.
    func renderOffline(frames: Int) -> [[Float]]? {
        guard let cell else { return nil }
        return cell.perform { $0.renderOffline(frames: frames) }
    }

    /// Decoded frames ready on the deck (test and diagnostics hook).
    func bufferedFrames(deck: Int) -> Int { cell?.perform { $0.decks[deck].bufferedFrames } ?? 0 }
    var residentBytes: Int { cell?.perform { $0.snapshot().residentBytes } ?? 0 }
    func snapshot() -> BoundedDeckSnapshot? { cell?.perform { $0.snapshot() } }
}

enum StarterStreamLimits {
    static let maxFramesPerRender = 4_096
}

/// The live output: one `AVAudioEngine` whose only source node pulls the Starter mixer.
@MainActor
final class StarterLiveOutput: StarterStreamOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var attachedCell: StarterMixerCell?
    private let cellProvider: @MainActor () -> StarterMixerCell?
    private let sampleRate: @MainActor () -> Double

    init(cell: @escaping @MainActor () -> StarterMixerCell?, sampleRate: @escaping @MainActor () -> Double) {
        cellProvider = cell
        self.sampleRate = sampleRate
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func start() throws {
        guard let cell = cellProvider() else { return }
        if attachedCell !== cell {
            stop()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate(), channels: 2) else {
                throw ReleaseRangeError.permanent("audio format")
            }
            let source = Self.makeNode(cell: cell, format: format)
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            node = source
            attachedCell = cell
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    func pause() { engine.pause() }

    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
        attachedCell = nil
    }

    /// Built outside the main actor so the render closure carries no isolation check on the IO thread.
    nonisolated private static func makeNode(cell: StarterMixerCell, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let total = Int(frameCount)
            var done = 0
            while done < total {
                let n = min(StarterStreamLimits.maxFramesPerRender, total - done)
                if !cell.render(left: left + done, right: right + done, frames: n) {
                    (left + done).update(repeating: 0, count: n)
                    (right + done).update(repeating: 0, count: n)
                }
                done += n
            }
            return noErr
        }
    }
}
#endif
