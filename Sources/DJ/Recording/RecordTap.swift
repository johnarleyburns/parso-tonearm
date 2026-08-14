import AVFoundation
import Foundation
import Synchronization

/// The §37.2 recording tap: an RT-safe, post-limiter master-bus copy into a
/// pre-allocated lock-free ring (plan 5.10, FR-ENG-7).
///
/// The render thread (inside the render callback, under `RTGuard`) calls
/// `write(into:frames:)` and nothing else — no encoding, no file I/O, no
/// allocation, no locks. The `RecordingEncoder` actor drains the ring off-RT
/// through `drain(maxFrames:into:)`. The ring is SPSC (one producer, one
/// consumer) and wait-free; `write` **never blocks audio**: when the ring is
/// full it drops the incoming block and counts it, exactly the "the ring
/// absorbs a dropped drain" property the plan's tests assert — a slow encoder
/// costs the tail of the recording, never the live performance.
///
/// The tap is **idle unless recording**: `setRecording(_:)` gates the copy, so
/// a graph built with `recordTapEnabled` still leaves the master signal
/// untouched when nothing is being recorded. And `AudioGraph.Configuration`
/// defaults `recordTapEnabled` to `false`, so the frame-exact reader harness
/// never constructs a tap at all and stays bit-exact.
///
/// Samples are stored interleaved (`Float` per frame per channel) — the encoder
/// de-interleaves into the `AVAudioPCMBuffer` the file writer needs.
public final class RecordTap: @unchecked Sendable {

    public let sampleRate: Double
    public let channelCount: Int
    /// Ring capacity in frames, rounded up to a power of two (the mask).
    public let capacityFrames: Int

    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    /// Consumer-owned (the encoder); only the encoder writes it.
    private let head = Atomic<Int>(0)
    /// Producer-owned (the render thread); only the render thread writes it.
    private let tail = Atomic<Int>(0)
    /// Whether the tap is capturing (§37.2 "idle unless recording").
    private let recordingFlag = Atomic<Bool>(false)
    /// Frames dropped because the ring was full — never blocks, never stalls.
    private let droppedFlag = Atomic<UInt64>(0)

    public init(sampleRate: Double, channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0, "a record tap needs at least one channel")
        precondition(capacityFrames > 0, "a record tap needs capacity")
        var capacity = capacityFrames
        if capacity & (capacity - 1) != 0 {
            var rounded = 1
            while rounded < capacity { rounded <<= 1 }
            capacity = rounded
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capacityFrames = capacity
        self.mask = capacity - 1
        buffer = .allocate(capacity: capacity * channelCount)
        buffer.initialize(repeating: 0, count: capacity * channelCount)
    }

    deinit {
        buffer.deinitialize(count: capacityFrames * channelCount)
        buffer.deallocate()
    }

    // MARK: - Control side

    /// Start (or stop) capturing. Idle taps are zero-cost: `write` returns
    /// without touching the signal, so an enabled-but-not-recording graph is
    /// still bit-exact (§37.2, the reader harness).
    public func setRecording(_ on: Bool) {
        recordingFlag.store(on, ordering: .releasing)
    }

    public var isRecording: Bool {
        recordingFlag.load(ordering: .acquiring)
    }

    /// Frames available to drain.
    public var availableFrames: Int {
        tail.load(ordering: .acquiring) - head.load(ordering: .acquiring)
    }

    /// Frames the render thread dropped because the ring was full.
    public var droppedFrames: UInt64 {
        droppedFlag.load(ordering: .relaxed)
    }

    // MARK: - Render side (under RTGuard; must never block or allocate)

    /// Copy `frames` frames of the master output into the ring, interleaved.
    /// If the whole block does not fit, drop it and count it — the render
    /// thread never waits for the encoder (§37.2 "never blocks audio").
    public func write(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard recordingFlag.load(ordering: .relaxed), frames > 0 else { return }
        let producer = tail.load(ordering: .relaxed)
        let consumer = head.load(ordering: .acquiring)
        guard producer - consumer + frames <= capacityFrames else {
            droppedFlag.add(UInt64(frames), ordering: .relaxed)
            return
        }
        let channels = channelCount
        let mask = mask
        let buffer = buffer
        for c in 0..<Int(list.count) {
            guard let mData = list[c].mData else { continue }
            let src = mData.assumingMemoryBound(to: Float.self)
            let ch = min(c, channels - 1)
            var pos = producer & mask
            for i in 0..<frames {
                buffer[pos * channels + ch] = src[i]
                pos = (pos + 1) & mask
            }
        }
        tail.store(producer + frames, ordering: .releasing)
    }

    // MARK: - Encoder side (off-RT)

    /// Read up to `maxFrames` interleaved frames out of the ring into `dest`.
    /// Returns the number of frames read.
    public func read(maxFrames: Int, into dest: UnsafeMutablePointer<Float>) -> Int {
        guard maxFrames > 0 else { return 0 }
        let producer = tail.load(ordering: .acquiring)
        let consumer = head.load(ordering: .relaxed)
        let frames = min(maxFrames, producer - consumer)
        guard frames > 0 else { return 0 }
        let channels = channelCount
        let mask = mask
        let buffer = buffer
        var pos = consumer & mask
        for i in 0..<frames {
            for c in 0..<channels {
                dest[i * channels + c] = buffer[pos * channels + c]
            }
            pos = (pos + 1) & mask
        }
        head.store(consumer + frames, ordering: .releasing)
        return frames
    }
}
