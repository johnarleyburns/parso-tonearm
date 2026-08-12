import AVFoundation
import Foundation
import Synchronization

public enum AudioGraphError: Error, Equatable {
    case failedToEnableManualRendering
    case failedToAllocateRenderBuffer
    case renderFailed(status: AVAudioEngineManualRenderingStatus)
}

/// The offline `AVAudioEngine` harness (plan §2.5, commit 4.1).
///
/// This is the graph boundary that later commits grow into the full two-deck
/// engine (§29): a `AVAudioSourceNode` whose render block drains the command
/// ring, reads the current snapshot once per callback, and writes audio into
/// the engine's output. The engine runs in `.offline` manual rendering mode, so
/// the harness is fully deterministic and runs on the `swift test` macOS host —
/// no hardware (§47.2 "engine integration, deterministic" tier).
///
/// The 4.1 source is a phase-accumulated sine: commands (`play`, `pause`,
/// `setPitch`, `loadArm`) are the only way to change what renders, exactly as
/// §12.2 demands — the control side never touches render state directly. The
/// render block runs under the `RTGuard` shim and meters itself with
/// `RenderLoad`, so any RT-unsafe call fails the offline-render tests.
///
/// The render block deliberately captures the ring/snapshot/load/probe/state
/// objects rather than `self`, so the graph's lifetime is not tied to the
/// engine's, and the DEBUG probe (`guardWasActive`) proves the shim wraps the
/// callback.
public final class AudioGraph: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var sampleRate: Double
        public var channelCount: AVAudioChannelCount
        public var maximumFrameCount: AVAudioFrameCount
        public var ringCapacity: Int
        public var initialFrequency: Float
        public var initialAmplitude: Float
        public var initialPlaying: Bool

        public init(sampleRate: Double = 48_000,
                    channelCount: AVAudioChannelCount = 1,
                    maximumFrameCount: AVAudioFrameCount = 4096,
                    ringCapacity: Int = 8,
                    initialFrequency: Float = 440,
                    initialAmplitude: Float = 0.25,
                    initialPlaying: Bool = true) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrameCount = maximumFrameCount
            self.ringCapacity = ringCapacity
            self.initialFrequency = initialFrequency
            self.initialAmplitude = initialAmplitude
            self.initialPlaying = initialPlaying
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

    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let manualRenderingFormat: AVAudioFormat
    private let guardProbe: GuardActiveProbe

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
        let state = RenderState(playing: configuration.initialPlaying,
                                frequency: configuration.initialFrequency,
                                amplitude: configuration.initialAmplitude)

        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
            RTGuard.withRenderContext {
                let start = load.startTicks()
                probe.flag.store(RTGuard.isInRenderContext, ordering: .relaxed)
                ring.drain { state.apply($0) }
                _ = snap.read() // acquire the current snapshot once per callback
                let frames = Int(frameCount)
                let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                if state.playing {
                    var currentPhase = state.phase
                    let phaseStep = 2 * Double.pi * Double(state.frequency) / sampleRate
                    for frame in 0..<frames {
                        let value = state.amplitude * Float(sin(currentPhase))
                        for m in buffers {
                            guard let data = m.mData else { continue }
                            data.assumingMemoryBound(to: Float.self)[frame] = value
                        }
                        currentPhase += phaseStep
                        if currentPhase >= 2 * Double.pi { currentPhase -= 2 * Double.pi }
                    }
                    state.phase = currentPhase
                } else {
                    for m in buffers {
                        guard let data = m.mData else { continue }
                        memset(data, 0, frames * MemoryLayout<Float>.size)
                    }
                }
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

/// The render-thread-private source state (§12.2 "its private RT state"). Only
/// the render block mutates it; the control side changes it solely via commands.
final class RenderState: @unchecked Sendable {
    var playing: Bool
    var frequency: Float
    let amplitude: Float
    var phase: Double
    var armedSource: UnsafeRawPointer?

    init(playing: Bool, frequency: Float, amplitude: Float) {
        self.playing = playing
        self.frequency = frequency
        self.amplitude = amplitude
        self.phase = 0
        self.armedSource = nil
    }

    func apply(_ command: RTCommand) {
        switch command.tag {
        case .play: playing = true
        case .pause: playing = false
        case .setPitch: frequency = command.f0
        case .loadArm: armedSource = command.ptr
        }
    }
}

/// Reference box so the render block and the graph share one atomic (a captured
/// struct `Atomic` copy would otherwise be ambiguous under copy/move semantics).
private final class GuardActiveProbe: @unchecked Sendable {
    let flag = Atomic<Bool>(false)
}
