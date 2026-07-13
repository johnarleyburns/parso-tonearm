import Foundation
import AVFoundation

/// Attaches the 10-band EQ to an `AVPlayerItem` via `MTAudioProcessingTap` on the
/// item's `audioMix` (valid for the progressive/file assets this app plays). The
/// tap runs the biquad cascade on the realtime audio thread. When the EQ is
/// transparent (flat/bypassed) the tap passes samples through untouched so bypass
/// is bit-transparent.
final class EQAudioTap {

    /// Shared engine mutated from the main thread (UI) and read on the audio
    /// thread. Access is guarded by a lock.
    private final class Storage {
        var engine: EQEngine
        private let lock = NSLock()
        init(engine: EQEngine) { self.engine = engine }
        func withLock<T>(_ body: (inout EQEngine) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&engine)
        }
    }

    private let storage: Storage

    init(engine: EQEngine) {
        self.storage = Storage(engine: engine)
    }

    /// Updates the EQ gains live (e.g. from the settings sliders).
    func update(gains: [Double], bypassed: Bool) {
        storage.withLock { eq in
            eq.setGains(gains)
            eq.bypassed = bypassed
        }
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
                storage.withLock { eq in
                    guard !eq.isTransparent else { return }  // bit-transparent bypass
                    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                    for (channel, buffer) in abl.enumerated() {
                        guard let data = buffer.mData else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.bindMemory(to: Float.self, capacity: count)
                        for i in 0..<count {
                            samples[i] = Float(eq.process(Double(samples[i]), channel: channel))
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
