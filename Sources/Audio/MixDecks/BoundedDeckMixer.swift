#if !os(watchOS)
import Foundation

/// Why the shared sample clock is frozen.
enum BoundedDeckPauseReason: String, Sendable, Equatable {
    case user, routeChange, interruption, backgrounded
}

enum BoundedDeckPhase: Equatable, Sendable {
    case idle
    /// The current deck has no audio buffered yet (start, seek, or a disk stall).
    case filling
    case playing
    /// The planned overlap time has come but the incoming deck is not buffered enough: the
    /// outgoing deck keeps playing alone and no fade has started.
    case waitingForIncoming
    case overlapping
    case paused(BoundedDeckPauseReason)
}

/// The actual state of the bounded path, published for the Smart Blend Now Playing / Queue UI.
struct BoundedDeckSnapshot: Equatable, Sendable {
    struct Deck: Equatable, Sendable {
        var bufferedSeconds: Double
        var positionSeconds: Double
        var generation: Int
        var underruns: Int
    }
    var phase: BoundedDeckPhase
    var clockFrame: Int64
    var current: Deck
    var incoming: Deck
    /// Fixed for the session: both decks' buffers, whatever the media length.
    var residentBytes: Int
    var stalledFrames: Int64
    var clippedSamples: Int
}

struct BoundedOverlapPlan: Equatable, Sendable {
    /// Shared-clock frame at which the incoming deck should become audible.
    var startClock: Int64
    var fadeFrames: Int
    var incomingStartFrame: Int64
    var incomingTotalFrames: Int64
    var incomingTempo: Double = 1
    var incomingGain: Float = 1
    /// Decoded audio the incoming deck must have buffered before the fade may begin.
    var minIncomingBufferedFrames: Int
}

/// Two bounded decks on one shared sample clock. The render path allocates nothing (scratch is
/// preallocated), does no I/O and takes no locks. The overlap is committed only once the incoming
/// deck holds `minIncomingBufferedFrames`, so a stalled disk delays the fade instead of starting it
/// over silence. Control calls and `render` must be serialized by the caller (offline: one thread;
/// live: a single audio-thread mailbox).
/// Deck storage is SPSC/atomic; renderer ownership is held by the output's
/// audio callback once live command dispatch is installed.
final class BoundedDeckMixer: @unchecked Sendable {
    enum Overlap: Equatable {
        case none
        case pending(BoundedOverlapPlan)
        case active(plan: BoundedOverlapPlan, fadeStart: Int64)
    }

    let sampleRate: Double
    let decks: [BoundedDeckBuffer]
    let maxBlockFrames: Int
    let prerollFrames: Int
    private let channelCount: Int
    private let scratch: UnsafeMutablePointer<Float>
    private var tempos = [1.0, 1.0]
    private var gains: [Float] = [1, 1]
    private(set) var clock: Int64 = 0
    private(set) var main = 0
    private(set) var overlap = Overlap.none
    private(set) var pauseReason: BoundedDeckPauseReason?
    private(set) var stalledFrames: Int64 = 0
    private(set) var clippedSamples = 0
    private var waiting = false

    var incomingIndex: Int { 1 - main }

    init(sampleRate: Double = 44_100, capacityFrames: Int, channelCount: Int = 2,
         maxBlockFrames: Int = 4_096, prerollFrames: Int = 0) {
        self.sampleRate = sampleRate
        self.maxBlockFrames = maxBlockFrames
        self.prerollFrames = prerollFrames
        self.channelCount = channelCount
        decks = [BoundedDeckBuffer(capacityFrames: capacityFrames, channelCount: channelCount),
                 BoundedDeckBuffer(capacityFrames: capacityFrames, channelCount: channelCount)]
        scratch = .allocate(capacity: 2 * channelCount * maxBlockFrames)
        scratch.initialize(repeating: 0, count: 2 * channelCount * maxBlockFrames)
    }

    deinit { scratch.deallocate() }

    // MARK: Control

    /// Starts the current track on the main deck.
    func begin(totalFrames: Int64, startFrame: Int64, tempo: Double = 1) {
        overlap = .none
        waiting = false
        tempos[main] = tempo
        gains[main] = 1
        decks[main].retarget(totalFrames: totalFrames, startFrame: startFrame)
    }

    /// Seeks the current track; any overlap is cancelled and the incoming deck's chunks invalidated.
    func seek(to frame: Int64) {
        cancelOverlap()
        decks[main].seek(to: frame)
    }

    func schedule(_ plan: BoundedOverlapPlan) {
        decks[incomingIndex].retarget(totalFrames: plan.incomingTotalFrames, startFrame: plan.incomingStartFrame)
        tempos[incomingIndex] = plan.incomingTempo
        gains[incomingIndex] = plan.incomingGain
        overlap = .pending(plan)
    }

    /// Drops a pending or active overlap. The incoming deck is retargeted to nothing so a decode
    /// still running for it can no longer write.
    func cancelOverlap() {
        guard overlap != .none else { return }
        overlap = .none
        waiting = false
        decks[incomingIndex].retarget(totalFrames: 0, startFrame: 0)
    }

    func pause(_ reason: BoundedDeckPauseReason) { pauseReason = reason }
    func resume() { pauseReason = nil }

    // MARK: Render

    /// Mixes `frames` planar frames (channel stride `frames`) into `out`. Real-time safe.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        precondition(frames <= maxBlockFrames)
        for channel in 0..<channelCount { (out + channel * frames).update(repeating: 0, count: frames) }
        guard pauseReason == nil else { return }       // both decks and the timeline stay frozen
        var done = 0
        while done < frames {
            var n = frames - done
            if case .pending(let plan) = overlap {
                if clock >= plan.startClock {
                    if decks[incomingIndex].bufferedFrames >= max(plan.minIncomingBufferedFrames, prerollFrames + 1) {
                        overlap = .active(plan: plan, fadeStart: clock)
                        waiting = false
                    } else {
                        waiting = true
                        stalledFrames += Int64(n)
                    }
                } else if plan.startClock - clock < Int64(n) {
                    n = Int(plan.startClock - clock)
                }
            }
            renderSegment(out: out + done, outStride: frames, frames: n)
            done += n
            clock += Int64(n)
        }
    }

    private func renderSegment(out: UnsafeMutablePointer<Float>, outStride: Int, frames n: Int) {
        let stride = maxBlockFrames
        let a = scratch
        let b = scratch + channelCount * stride
        _ = decks[main].render(into: a, stride: stride, frames: n, tempo: tempos[main], prerollFrames: prerollFrames)
        var fade: (plan: BoundedOverlapPlan, start: Int64)?
        if case .active(let plan, let start) = overlap {
            fade = (plan, start)
            _ = decks[incomingIndex].render(into: b, stride: stride, frames: n, tempo: tempos[incomingIndex],
                                            prerollFrames: prerollFrames)
        }
        for i in 0..<n {
            var outGain: Float = gains[main], inGain: Float = 0
            if let fade {
                let t = Double(clock + Int64(i) - fade.start) / Double(max(1, fade.plan.fadeFrames))
                let x = min(max(t, 0), 1) * .pi / 2
                outGain *= Float(cos(x))
                inGain = Float(sin(x)) * gains[incomingIndex]
            }
            for channel in 0..<channelCount {
                var sample = a[channel * stride + i] * outGain
                if fade != nil { sample += b[channel * stride + i] * inGain }
                if sample > 1 || sample < -1 { clippedSamples += 1; sample = min(max(sample, -1), 1) }
                out[channel * outStride + i] = sample
            }
        }
        if let fade, clock + Int64(n) >= fade.start + Int64(fade.plan.fadeFrames) {
            main = incomingIndex                       // the incoming deck is now the current track
            gains[main] = fade.plan.incomingGain
            overlap = .none
        }
    }

    /// Offline convenience for tests: renders and returns planar channels. Allocates.
    func renderOffline(frames: Int) -> [[Float]] {
        var result = [[Float]](repeating: [], count: channelCount)
        var block = [Float](repeating: 0, count: channelCount * maxBlockFrames)
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, maxBlockFrames)
            block.withUnsafeMutableBufferPointer { render(into: $0.baseAddress!, frames: n) }
            for channel in 0..<channelCount { result[channel] += block[(channel * n)..<(channel * n + n)] }
            remaining -= n
        }
        return result
    }

    // MARK: State

    func snapshot() -> BoundedDeckSnapshot {
        func deck(_ i: Int) -> BoundedDeckSnapshot.Deck {
            .init(bufferedSeconds: Double(decks[i].bufferedFrames) / sampleRate,
                  positionSeconds: Double(decks[i].positionFrame) / sampleRate,
                  generation: decks[i].generation, underruns: decks[i].underrunCount)
        }
        let phase: BoundedDeckPhase
        if let pauseReason { phase = .paused(pauseReason) }
        else if case .active = overlap { phase = .overlapping }
        else if waiting { phase = .waitingForIncoming }
        else if decks[main].totalFrames == 0 { phase = .idle }
        else if decks[main].bufferedFrames == 0 { phase = .filling }
        else { phase = .playing }
        return BoundedDeckSnapshot(phase: phase, clockFrame: clock, current: deck(main), incoming: deck(incomingIndex),
                                   residentBytes: decks.reduce(0) { $0 + $1.residentBytes },
                                   stalledFrames: stalledFrames, clippedSamples: clippedSamples)
    }
}
#endif
