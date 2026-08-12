import Foundation

/// One deck's telemetry row (§40.3, App. I.4). Sampled at display cadence by
/// the control side — the render thread publishes the raw atomics, never a
/// Swift object, and the UI degrades to a stale-but-safe readout if a frame is
/// missed (§40.3).
public struct EngineTelemetry: Sendable, Equatable {

    /// One deck's sampled state.
    public struct Deck: Sendable, Equatable {
        /// The deck's playhead in its track's sample space (§30.1).
        public var playheadSample: Int64
        /// The deck's current effective BPM (grid BPM × rate).
        public var bpmEffective: Double
        /// The deck's beat phase (0 ≤ p < 1) at its playhead.
        public var phase: Double
        /// Post-chain peak level, 0…1.
        public var level: Float
        /// Whether the deck is currently rendering.
        public var playing: Bool
        /// Whether beat sync is engaged (SYNC holds, §32.1).
        public var synced: Bool

        public init(playheadSample: Int64 = 0, bpmEffective: Double = 0, phase: Double = 0,
                    level: Float = 0, playing: Bool = false, synced: Bool = false) {
            self.playheadSample = playheadSample
            self.bpmEffective = bpmEffective
            self.phase = phase
            self.level = level
            self.playing = playing
            self.synced = synced
        }
    }

    /// The master clock's absolute sample position.
    public var masterSample: Int64
    /// The master deck's effective BPM (0 before a deck is loaded).
    public var masterBPM: Double
    /// The master deck's downbeat phase (0 ≤ p < 1).
    public var downbeatPhase: Double
    public var deckA: Deck
    public var deckB: Deck
    /// Post-limiter master-bus peak level, 0…1.
    public var masterLevel: Float
    /// Render load as time-over-buffer-period, 0…1 (mockup `ipad/07`'s CPU%).
    public var renderLoad: Double

    public init(masterSample: Int64 = 0, masterBPM: Double = 0, downbeatPhase: Double = 0,
                deckA: Deck = Deck(), deckB: Deck = Deck(), masterLevel: Float = 0,
                renderLoad: Double = 0) {
        self.masterSample = masterSample
        self.masterBPM = masterBPM
        self.downbeatPhase = downbeatPhase
        self.deckA = deckA
        self.deckB = deckB
        self.masterLevel = masterLevel
        self.renderLoad = renderLoad
    }
}

/// The atomics → `AsyncStream` bridge (App. I.4, §40.3). The display-rate pump
/// calls `push` with each sampled value; the session view model awaits
/// `stream`. Buffering is newest-1: a missed frame drops the stale readout,
/// never the audio (§40.3).
@MainActor
public final class EngineTelemetryStream: Sendable {
    private var built: AsyncStream<EngineTelemetry>?
    private var continuation: AsyncStream<EngineTelemetry>.Continuation?

    public init() {}

    /// The single consumer stream. The first access builds it; later access
    /// returns the same stream so the pump and the consumer share one
    /// continuation.
    public var stream: AsyncStream<EngineTelemetry> {
        if let built { return built }
        let (stream, continuation) = AsyncStream<EngineTelemetry>.makeStream(
            of: EngineTelemetry.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        built = stream
        return stream
    }

    /// Control side, display cadence: publish the latest sampled value.
    public func push(_ value: EngineTelemetry) {
        continuation?.yield(value)
    }
}
