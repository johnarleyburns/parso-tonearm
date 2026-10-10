#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoMixEngine

/// The audio output of the mix decks: one AVAudioEngine whose only source is
/// a ParsoMixEngine. A new engine is swapped in for every restart (seek, skip),
/// which is the one way to drop both decks at once while nothing renders.
@MainActor
final class MixDeckOutput {
    nonisolated static let maxFramesPerRender = 4_096

    let sampleRate: Double
    private(set) var mix: MixEngine
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var node: AVAudioSourceNode
    private var configurationObserver: NSObjectProtocol?
    /// Whether the output should be running; a configuration change (route,
    /// sample rate) stops the engine and it is restarted only if so.
    private(set) var isRunning = false

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// `offline`: no audio device; `renderOffline` pulls the mix (tests and
    /// listening renders of the real playback path).
    init(sampleRate: Double, offline: Bool = false) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MixEngineError.invalidArgument
        }
        self.sampleRate = sampleRate
        self.format = format
        mix = try MixEngine(sampleRate: sampleRate, maxFramesPerRender: Self.maxFramesPerRender)
        node = Self.makeNode(handle: mix.handle, format: format)
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: AVAudioFrameCount(Self.maxFramesPerRender))
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.engine.isRunning else { return }
                try? self.engine.start()
            }
        }
    }

    isolated deinit {
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func start() throws {
        isRunning = true
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// The master clock stops with the engine, so every scheduled deck start
    /// and blend waits too.
    func pause() {
        isRunning = false
        engine.pause()
    }

    /// Both decks gone: a fresh MixEngine behind a fresh source node. The old
    /// one is released only after the engine has stopped calling into it.
    func reset() throws {
        let wasRunning = isRunning
        engine.stop()
        engine.detach(node)
        mix = try MixEngine(sampleRate: sampleRate, maxFramesPerRender: Self.maxFramesPerRender)
        node = Self.makeNode(handle: mix.handle, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        isRunning = false
        if wasRunning { try start() }
    }

    func stop() {
        isRunning = false
        engine.stop()
    }

    /// Offline mode only: the next `frames` (≤ maxFramesPerRender) of the mix.
    func renderOffline(frames: Int) -> AVAudioPCMBuffer? {
        guard engine.isInManualRenderingMode, engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? engine.renderOffline(AVAudioFrameCount(frames), to: buffer)) == .success else { return nil }
        return buffer
    }

    /// Built outside the main actor: a closure formed in a @MainActor context
    /// carries an isolation check that traps on the audio IO thread. It
    /// captures only the Sendable render handle.
    nonisolated private static func makeNode(handle: MixRenderHandle, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let total = Int(frameCount)
            var done = 0
            while done < total {
                let n = min(maxFramesPerRender, total - done)
                handle.render(left: left + done, right: right + done, frames: n)
                done += n
            }
            return noErr
        }
    }
}
#endif
