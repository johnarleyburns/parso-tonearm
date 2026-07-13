import Foundation
import AVFoundation

/// Attaches the 10-band EQ to an `AVPlayerItem` via `MTAudioProcessingTap` on the
/// item's `audioMix` (valid for the progressive/file assets this app plays). The
/// tap runs the biquad cascade and ReplayGain multiplier on the realtime audio
/// thread. When both stages are transparent, samples pass through untouched.
final class EQAudioTap {

    /// Shared engine mutated from the main thread (UI) and read on the audio
    /// thread. Access is guarded by a lock.
    private final class Storage {
        var engine: EQEngine
        var replayGain: Double
        private let lock = NSLock()
        init(engine: EQEngine, replayGain: Double) {
            self.engine = engine
            self.replayGain = replayGain
        }
        func withLock<T>(_ body: (inout EQEngine) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&engine)
        }
        func withState<T>(_ body: (inout EQEngine, Double) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&engine, replayGain)
        }
        func update(gains: [Double], bypassed: Bool, replayGain: Double) {
            lock.lock(); defer { lock.unlock() }
            engine.setGains(gains)
            engine.bypassed = bypassed
            self.replayGain = replayGain
        }
    }

    private let storage: Storage

    init(engine: EQEngine, replayGain: Double = 1) {
        self.storage = Storage(engine: engine, replayGain: replayGain)
    }

    /// Updates the processing state live (e.g. from the settings sliders).
    func update(gains: [Double], bypassed: Bool, replayGain: Double = 1) {
        storage.update(gains: gains, bypassed: bypassed, replayGain: replayGain)
    }

    /// Builds an `AVAudioMix` carrying this EQ tap for the given item's first
    /// audio track. Returns nil if the asset exposes no audio track yet.
    func makeAudioMix(for item: AVPlayerItem) async -> AVAudioMix? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let storage = self.storage
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(storage).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let raw = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<Storage>.fromOpaque(raw).release()
            },
            prepare: { tap, _, _ in
                let raw = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<Storage>.fromOpaque(raw).takeUnretainedValue()
                storage.withLock { $0.reset() }
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                                flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let raw = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<Storage>.fromOpaque(raw).takeUnretainedValue()
                storage.withState { eq, replayGain in
                    guard !eq.isTransparent || replayGain != 1 else { return }
                    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                    for (channel, buffer) in abl.enumerated() {
                        guard let data = buffer.mData else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.bindMemory(to: Float.self, capacity: count)
                        for i in 0..<count {
                            var sample = Double(samples[i])
                            if !eq.isTransparent {
                                sample = eq.process(sample, channel: channel)
                            }
                            if replayGain != 1 {
                                sample *= replayGain
                            }
                            samples[i] = Float(sample)
                        }
                    }
                }
            })

        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr, let tap else { return nil }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
