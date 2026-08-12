import AVFoundation
import Foundation
import Synchronization

public enum AudioGraphError: Error, Equatable {
    case failedToEnableManualRendering
    case failedToAllocateRenderBuffer
    case renderFailed(status: AVAudioEngineManualRenderingStatus)
}

/// The offline `AVAudioEngine` graph (plan §2.5, commit 4.1; §29 from 4.3).
///
/// The graph hosts two decks, each backed by a `DeckState` (the deck reader):
/// a pre-decoded PCM source is armed via `loadArm`, and the render block walks
/// the output buffer splitting it at sample-accurate loop and cue boundaries
/// (§30.2), exactly as the §30.2 pseudocode specifies. Control never touches
/// render state directly — only `RTCommand`s cross the boundary (§12.2). The
/// engine runs in `.offline` manual-rendering mode, so the harness is fully
/// deterministic on the `swift test` macOS host — no hardware (§47.2 "engine
/// integration, deterministic" tier).
///
/// The render block runs under the `RTGuard` shim and meters itself with
/// `RenderLoad`. The callback deliberately captures the ring/snapshot/load/
/// probe/graph-state objects rather than `self`, so the graph's lifetime is not
/// tied to the engine's, and the DEBUG probe (`guardWasActive`) proves the shim
/// wraps the callback.
///
/// After each callback the graph publishes the master sample and both decks'
/// playheads through relaxed atomics — the telemetry surface the control side
/// reads at display cadence (§30.1, §40.3). A playing deck with no valid source
/// (or one that has run past the end of its track) renders silence and bumps
/// the `starvedFrames` counter instead of garbage (§46.2).
public final class AudioGraph: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var sampleRate: Double
        public var channelCount: AVAudioChannelCount
        public var maximumFrameCount: AVAudioFrameCount
        public var ringCapacity: Int
        /// Master limiter ceiling; `nil` leaves the limiter out of the path.
        /// The offline deck-reader harness runs without one so its assertions
        /// stay frame-exact; mixer tests configure it explicitly (§35.5).
        public var limiterCeiling: Float?
        /// Master limiter lookahead in frames (0 = delay-free brickwall).
        public var limiterLookaheadFrames: Int

        public init(sampleRate: Double = 48_000,
                    channelCount: AVAudioChannelCount = 1,
                    maximumFrameCount: AVAudioFrameCount = 4096,
                    ringCapacity: Int = 8,
                    limiterCeiling: Float? = nil,
                    limiterLookaheadFrames: Int = 0) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrameCount = maximumFrameCount
            self.ringCapacity = ringCapacity
            self.limiterCeiling = limiterCeiling
            self.limiterLookaheadFrames = limiterLookaheadFrames
        }
    }

    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    /// The control channel: commands are enqueued here and drained by the
    /// render thread (§12.2).
    public let commandRing: CommandRing
    /// Published snapshots are read once per callback (§12.2).
    public let snapshot: EngineSnapshot
    /// Meters the render callback (§34.3).
    public let renderLoad: RenderLoad

    /// DEBUG: true after a render that ran inside `RTGuard.withRenderContext`
    /// (the shim actually wrapped the callback). Always false in RELEASE.
    public var guardWasActive: Bool {
        guardProbe.flag.load(ordering: .relaxed)
    }

    /// The master clock's absolute sample position (published after each
    /// callback — §30.1).
    public var masterSample: Int64 {
        graphState.masterSampleAtomic.load(ordering: .relaxed)
    }

    /// The most recently published playhead for a deck (0 = A, 1 = B).
    public func deckPlayhead(_ deck: UInt8) -> Int64 {
        switch deck {
        case 0: return graphState.playheadAtomicA.load(ordering: .relaxed)
        default: return graphState.playheadAtomicB.load(ordering: .relaxed)
        }
    }

    /// Frames a playing deck rendered as silence because it had no source or
    /// ran past the end of its track (§46.2).
    public var starvedFrames: UInt64 {
        graphState.starvedAtomic.load(ordering: .relaxed)
    }

    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let manualRenderingFormat: AVAudioFormat
    private let guardProbe: GuardActiveProbe
    private let graphState: RenderGraphState

    public init(configuration: Configuration = Configuration()) throws {
        let sampleRate = configuration.sampleRate
        channelCount = configuration.channelCount

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate,
                                         channels: configuration.channelCount) else {
            throw AudioGraphError.failedToEnableManualRendering
        }
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: configuration.maximumFrameCount)

        let ring = CommandRing(capacity: configuration.ringCapacity)
        let snap = EngineSnapshot()
        let load = RenderLoad()
        let probe = GuardActiveProbe()
        let graphState = RenderGraphState(sampleRate: sampleRate,
                                          channelCount: Int(channelCount),
                                          limiterCeiling: configuration.limiterCeiling,
                                          limiterLookaheadFrames: configuration.limiterLookaheadFrames)

        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
            RTGuard.withRenderContext {
                let start = load.startTicks()
                probe.flag.store(RTGuard.isInRenderContext, ordering: .relaxed)
                let masterSample = graphState.clock.masterSample
                let frames = Int(frameCount)
                ring.drain { graphState.apply($0, masterSample: masterSample) }
                _ = snap.read() // acquire the current snapshot once per callback
                graphState.renderDecks(into: UnsafeMutableAudioBufferListPointer(outputData),
                                       frames: frames)
                load.endTicks(start)
            }
            return 0
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        self.sampleRate = sampleRate
        self.engine = engine
        self.sourceNode = sourceNode
        self.commandRing = ring
        self.snapshot = snap
        self.renderLoad = load
        self.guardProbe = probe
        self.graphState = graphState
        self.manualRenderingFormat = format
    }

    deinit {
        engine.stop()
    }

    /// Start the manual-rendering engine. Required before any `render`.
    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    /// Render `frameCount` frames into a fresh buffer. The source node's render
    /// block runs synchronously inside this call (offline mode — no hardware).
    @discardableResult
    public func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: manualRenderingFormat,
                                            frameCapacity: frameCount) else {
            throw AudioGraphError.failedToAllocateRenderBuffer
        }
        let status = try engine.renderOffline(frameCount, to: buffer)
        guard status == .success else {
            throw AudioGraphError.renderFailed(status: status)
        }
        return buffer
    }
}

/// The render-thread-private graph state (§12.2 "its private RT state"). Only
/// the render block mutates it; the control side changes it solely via commands
/// applied through `apply`, and reads it back only through the published atomics.
final class RenderGraphState: @unchecked Sendable {
    /// The master clock in absolute samples on the device timeline (§30.1).
    var clock: DeckClock
    let masterSampleAtomic = Atomic<Int64>(0)
    let starvedAtomic = Atomic<UInt64>(0)
    let playheadAtomicA = Atomic<Int64>(0)
    let playheadAtomicB = Atomic<Int64>(0)
    let decks: [DeckState]
    let master: MasterStage

    init(sampleRate: Double, channelCount: Int,
         limiterCeiling: Float?, limiterLookaheadFrames: Int) {
        clock = DeckClock(sampleRate: sampleRate)
        decks = [DeckState(sampleRate: sampleRate, channelCount: channelCount),
                 DeckState(sampleRate: sampleRate, channelCount: channelCount)]
        master = MasterStage(channelCount: channelCount, sampleRate: sampleRate,
                             ceiling: limiterCeiling, lookaheadFrames: limiterLookaheadFrames)
    }

    /// Apply a drained command. The crossfader is global (master stage); every
    /// other command addresses a deck. A bad deck index is ignored at the
    /// boundary (§46.2).
    func apply(_ command: RTCommand, masterSample: Int64) {
        if command.tag == .setCrossfader {
            master.apply(command)
            return
        }
        let index = Int(command.deck)
        guard decks.indices.contains(index) else { return }
        decks[index].apply(command, masterSample: masterSample)
    }

    /// Render both decks into the output. The baseline is zeroed first, so a
    /// paused or unloaded deck contributes silence rather than garbage (§46.2);
    /// loaded, playing decks accumulate onto it through their EQ/filter/fader
    /// chains. The crossfader gains are applied per deck, then the master
    /// limiter shapes the summed bus (§35.5).
    func renderDecks(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let frameStart = clock.masterSample
        for m in list {
            guard let data = m.mData else { continue }
            memset(data, 0, frames * MemoryLayout<Float>.size)
        }
        let (gainA, gainB) = master.gains()
        decks[0].setCrossfaderGain(gainA)
        decks[1].setCrossfaderGain(gainB)
        for deck in decks {
            renderDeck(deck, into: list, frames: frames, frameStart: frameStart)
        }
        master.limit(into: list, frames: frames)
        clock.advance(by: Int64(frames))
        masterSampleAtomic.store(clock.masterSample, ordering: .relaxed)
        for (index, deck) in decks.enumerated() {
            let playhead = Int64(deck.playhead)
            switch index {
            case 0: playheadAtomicA.store(playhead, ordering: .relaxed)
            default: playheadAtomicB.store(playhead, ordering: .relaxed)
            }
        }
    }

    /// Render one deck's output for the callback, splitting the buffer at the
    /// exact frame for scheduled cue jumps and loop boundaries (§30.2).
    private func renderDeck(_ deck: DeckState, into list: UnsafeMutableAudioBufferListPointer,
                            frames: Int, frameStart: Int64) {
        guard deck.playing else { return } // paused: silence, playhead frozen
        guard let source = deck.source() else {
            deck.starved = true
            starvedAtomic.add(UInt64(frames), ordering: .relaxed)
            return
        }

        var f = 0
        while f < frames {
            // Next sample-accurate boundary within this callback (§30.2).
            var boundary = frames

            // A scheduled cue/seek jump fires at its absolute master sample.
            if let jump = deck.pendingJump {
                let fireOffset = Int(jump.atSample - frameStart)
                if fireOffset <= f {
                    // Already at/past the fire frame — apply now and split here.
                    deck.playhead = Double(jump.targetSample)
                    deck.pendingJump = nil
                    continue
                }
                boundary = min(boundary, fireOffset)
            }

            // The loop's half-open [start, end) end boundary (§33.2).
            if deck.loopActive && deck.playhead < Double(deck.loopEnd) {
                let framesToEnd = (Double(deck.loopEnd) - deck.playhead) / deck.rate
                boundary = min(boundary, f + max(1, Int(framesToEnd.rounded(.up))))
            }

            let count = boundary - f
            readChunk(deck, source, into: list, at: f, count: count)
            f = boundary
            deck.playhead += Double(count) * deck.rate

            if deck.loopActive && CueLoop.reachedEnd(deck.playhead, loopEnd: deck.loopEnd) {
                deck.playhead = CueLoop.wrap(deck.playhead, loopStart: deck.loopStart,
                                             loopEnd: deck.loopEnd)
            }
        }

        if Int64(deck.playhead) >= source.frameCount {
            deck.starved = true
            starvedAtomic.add(UInt64(frames), ordering: .relaxed)
        }
    }

    /// Copy `source[playhead ..< playhead+count)` into the output at `frame`,
    /// clamped at the end of the track — frames past EOF render silence, never
    /// an out-of-bounds read (§46.2). Each sample runs through the deck's
    /// EQ/filter/fader/crossfader chain (§35.1). Accumulates (`+=`) so both
    /// decks sum.
    private func readChunk(_ deck: DeckState, _ source: DeckSource,
                           into list: UnsafeMutableAudioBufferListPointer,
                           at frame: Int, count: Int) {
        guard count > 0 else { return }
        let start = deck.playhead
        let rate = deck.rate
        let base = source.pcm.assumingMemoryBound(to: Float.self)
        let srcChannels = source.channelCount
        for c in 0..<Int(list.count) {
            guard let mData = list[c].mData else { continue }
            let out = mData.assumingMemoryBound(to: Float.self)
            let srcChannel = srcChannels == 1 ? 0 : min(c, srcChannels - 1)
            for i in 0..<count {
                let track = Int64(start + Double(i) * rate)
                if track >= 0 && track < source.frameCount {
                    let raw = base[Int(track) * srcChannels + srcChannel]
                    out[frame + i] += deck.mixers[c].process(raw)
                }
            }
        }
    }
}

/// The render-thread-private deck state (§12.2). Only the render block mutates
/// it; the control side changes it solely via `apply`.
final class DeckState: @unchecked Sendable {

    struct PendingJump {
        /// Absolute master-timeline sample at which the jump fires (§30.2).
        var atSample: Int64
        /// Track sample the playhead moves to when it fires.
        var targetSample: Int64
    }

    /// Ownership-transfer marker for the armed `DeckSource` (control side keeps
    /// the boxed allocation alive; §12.2).
    var sourcePointer: UnsafeRawPointer?
    var playing = false
    var playhead: Double = 0
    var rate: Double = 1
    var loopStart: Int64 = 0
    var loopEnd: Int64 = 0
    var loopActive = false
    var quantizeOn = false
    var quantizeResolution: QuantizeResolution = .beat
    var cue = TempCueState()
    var pendingJump: PendingJump?
    var starved = false
    /// The per-channel EQ/filter/fader/crossfader chain (§35.1). Only the
    /// render thread mutates it.
    var mixers: [DeckMixer]
    private let sampleRate: Double

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        mixers = (0..<channelCount).map { _ in DeckMixer(sampleRate: sampleRate) }
    }

    /// Read the armed source without retaining anything (§12.3).
    func source() -> DeckSource? {
        guard let pointer = sourcePointer else { return nil }
        return pointer.load(as: DeckSource.self)
    }

    /// The deck's beat grid; falls back to a nominal grid before any source is
    /// loaded so quantize math stays well-defined.
    private func grid() -> DeckGrid {
        source()?.grid ?? DeckGrid(sampleRate: sampleRate)
    }

    func apply(_ command: RTCommand, masterSample: Int64) {
        switch command.tag {
        case .play:
            playing = true
        case .pause:
            playing = false
        case .setRate:
            rate = Double(command.f0)
        case .loadArm:
            sourcePointer = command.ptr
        case .seek:
            let target = command.f0 >= 0.5
                ? Scheduler.quantizedBoundary(after: command.i0,
                                              resolution: quantizeResolution, grid: grid())
                : command.i0
            pendingJump = PendingJump(atSample: masterSample, targetSample: target)
        case .setCue:
            cue.setPoint(command.i0)
        case .cuePress:
            if cue.press(at: Int64(playhead)) {
                playhead = Double(cue.pointSample)
                playing = true
            }
        case .cueRelease:
            if let restore = cue.release() {
                playhead = Double(restore)
                playing = false
            }
        case .triggerHotCue:
            let at = Scheduler.triggerFrame(playhead: Int64(playhead), masterSample: masterSample,
                                            targetSample: command.i0, quantized: quantizeOn,
                                            resolution: quantizeResolution, grid: grid(), rate: rate)
            pendingJump = PendingJump(atSample: at, targetSample: command.i0)
        case .setLoop:
            loopStart = command.i0
            loopEnd = command.i1
            loopActive = true
        case .exitLoop:
            loopActive = false
        case .setQuantize:
            quantizeOn = command.f0 >= 0.5
            if let resolution = QuantizeResolution(rawValue: UInt8(command.f1)) {
                quantizeResolution = resolution
            }
        case .setEQ:
            for c in mixers.indices {
                mixers[c].eqEngaged = true
                mixers[c].eq.setGains(low: command.f0, mid: command.f1, high: command.f2)
            }
        case .setFilter:
            for c in mixers.indices { mixers[c].filter.setKnob(command.f0) }
        case .setFader:
            for c in mixers.indices { mixers[c].fader.target = command.f0 }
        case .setCrossfader:
            break // global — handled by the master stage
        }
    }

    /// Set the per-channel crossfader gain target (applied each callback from
    /// the master stage's current position).
    func setCrossfaderGain(_ gain: Float) {
        for c in mixers.indices { mixers[c].crossfaderGain.target = gain }
    }
}

/// Reference box so the render block and the graph share one atomic (a captured
/// struct `Atomic` copy would otherwise be ambiguous under copy/move semantics).
private final class GuardActiveProbe: @unchecked Sendable {
    let flag = Atomic<Bool>(false)
}
