#if !os(watchOS)
import AVFoundation
import Foundation

/// AVAudioEngine endpoint for the bounded two-deck mixer. Its source node
/// reaches only preallocated mixer storage; fetching, decoding and planning
/// happen outside the callback.
@MainActor
final class BoundedDeckOutput {
    nonisolated static let maxFramesPerRender = 4_096

    let mixer: BoundedDeckMixer
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var node: AVAudioSourceNode
    private let bridge: PlanarRenderBridge
    private let commands = BoundedDeckCommandMailbox()
    private(set) var isRunning = false

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init(sampleRate: Double = 44_100, capacityFrames: Int, offline: Bool = false) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MixTrackLoaderError.decode("invalid deck output format")
        }
        self.format = format
        mixer = BoundedDeckMixer(sampleRate: sampleRate, capacityFrames: capacityFrames,
                                 maxBlockFrames: Self.maxFramesPerRender)
        bridge = PlanarRenderBridge(capacityFrames: Self.maxFramesPerRender)
        node = Self.makeNode(mixer: mixer, bridge: bridge, commands: commands, format: format)
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: AVAudioFrameCount(Self.maxFramesPerRender))
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    isolated deinit { engine.stop() }

    func start() throws {
        isRunning = true
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func pause() { isRunning = false; engine.pause() }
    func stop() { isRunning = false; engine.stop() }

    func begin(totalFrames: Int64, startFrame: Int64, tempo: Double = 1) { commands.begin(total: totalFrames, start: startFrame, tempo: tempo) }
    func seek(to frame: Int64) { commands.seek(frame) }
    func schedule(_ plan: BoundedOverlapPlan) { commands.schedule(plan) }
    func cancelOverlap() { commands.cancel() }

    func renderOffline(frames: Int) -> AVAudioPCMBuffer? {
        guard engine.isInManualRenderingMode, engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? engine.renderOffline(AVAudioFrameCount(frames), to: buffer)) == .success else { return nil }
        return buffer
    }

    nonisolated private static func makeNode(mixer: BoundedDeckMixer, bridge: PlanarRenderBridge,
                                             commands: BoundedDeckCommandMailbox,
                                             format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let total = Int(frameCount)
            var done = 0
            while done < total {
                commands.consume(into: mixer)
                let n = min(maxFramesPerRender, total - done)
                mixer.render(into: bridge.samples, frames: n)
                for i in 0..<n { left[done + i] = bridge.samples[i]; right[done + i] = bridge.samples[n + i] }
                done += n
            }
            return noErr
        }
    }
}

/// Preallocated callback bridge between the mixer’s planar output and the
/// AudioUnit buffer list. It is touched only on the render thread.
private final class PlanarRenderBridge: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    init(capacityFrames: Int) {
        samples = .allocate(capacity: 2 * capacityFrames)
        samples.initialize(repeating: 0, count: 2 * capacityFrames)
    }
    deinit { samples.deallocate() }
}
#endif
