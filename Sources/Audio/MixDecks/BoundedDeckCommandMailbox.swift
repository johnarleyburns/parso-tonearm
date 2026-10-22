#if !os(watchOS)
import Synchronization

/// Fixed-capacity SPSC control queue. Commands are never coalesced: `begin`
/// followed by `schedule` must reach the renderer in that order. It allocates
/// once at setup and the callback only reads preallocated slots.
final class BoundedDeckCommandMailbox: @unchecked Sendable {
    private enum Kind: Int { case begin, seek, schedule, pause, resume, cancel }
    private struct Command {
        var kind: Kind = .cancel
        var a: Int64 = 0, b: Int64 = 0, c: Int64 = 0, d: Int64 = 0, e: UInt64 = 0, f: Int = 0
        var gain: Float = 1
    }
    private static let capacity = 32
    private let slots = UnsafeMutablePointer<Command>.allocate(capacity: capacity)
    private let head = Atomic<Int>(0), tail = Atomic<Int>(0)

    init() { slots.initialize(repeating: Command(), count: Self.capacity) }
    deinit { slots.deinitialize(count: Self.capacity); slots.deallocate() }

    func begin(total: Int64, start: Int64, tempo: Double) { enqueue(.init(kind: .begin, a: total, b: start, e: tempo.bitPattern)) }
    func seek(_ frame: Int64) { enqueue(.init(kind: .seek, a: frame)) }
    func cancel() { enqueue(.init(kind: .cancel)) }
    func pause() { enqueue(.init(kind: .pause)) }
    func resume() { enqueue(.init(kind: .resume)) }
    func schedule(_ plan: BoundedOverlapPlan) {
        enqueue(.init(kind: .schedule, a: plan.startClock, b: Int64(plan.fadeFrames), c: plan.incomingStartFrame,
                      d: plan.incomingTotalFrames, e: plan.incomingTempo.bitPattern,
                      f: plan.minIncomingBufferedFrames, gain: plan.incomingGain))
    }

    func consume(into mixer: BoundedDeckMixer) {
        var read = tail.load(ordering: .relaxed)
        let written = head.load(ordering: .acquiring)
        while read < written {
            let command = slots[read % Self.capacity]
            switch command.kind {
            case .begin: mixer.begin(totalFrames: command.a, startFrame: command.b, tempo: Double(bitPattern: command.e))
            case .seek: mixer.seek(to: command.a)
            case .schedule: mixer.schedule(.init(startClock: command.a, fadeFrames: Int(command.b), incomingStartFrame: command.c,
                                                  incomingTotalFrames: command.d, incomingTempo: Double(bitPattern: command.e),
                                                  incomingGain: command.gain, minIncomingBufferedFrames: command.f))
            case .pause: mixer.pause(.user)
            case .resume: mixer.resume()
            case .cancel: mixer.cancelOverlap()
            }
            read += 1
        }
        tail.store(read, ordering: .releasing)
    }

    private func enqueue(_ command: Command) {
        let write = head.load(ordering: .relaxed)
        let read = tail.load(ordering: .acquiring)
        precondition(write - read < Self.capacity, "bounded deck control queue overflow")
        slots[write % Self.capacity] = command
        head.store(write + 1, ordering: .releasing)
    }
}
#endif
