import Foundation
import AVFoundation
import os

/// Attaches the full Pro Audio chain to an `AVPlayerItem` via `MTAudioProcessingTap`
/// on the item's `audioMix`. The tap runs the 10-band EQ, the parametric cascade,
/// convolution, crossfeed and the ReplayGain multiplier on the realtime audio
/// thread. When every stage is transparent, samples pass through untouched.
///
/// Realtime safety: the audio thread does NO blocking lock, NO allocation and NO
/// Swift/ObjC runtime work in the hot path. New settings are compiled into a fully
/// pre-allocated `ProAudioKernel` on the MAIN thread and published under an
/// `os_unfair_lock`. The audio thread picks the pending kernel up with
/// `os_unfair_lock_trylock` (and keeps using the previous one if the trylock
/// fails), then processes without holding any lock.
public final class EQAudioTap {

    private final class Storage {
        /// Owned and mutated only on the audio thread (except `reset` in prepare).
        var live: ProAudioKernel
        /// Handed off from the main thread, picked up by the audio thread.
        private var pending: ProAudioKernel?
        private var lock = os_unfair_lock_s()

        init(kernel: ProAudioKernel) {
            self.live = kernel
        }

        /// MAIN thread: publish a freshly-compiled kernel (all allocation done).
        func publish(_ kernel: ProAudioKernel) {
            os_unfair_lock_lock(&lock)
            pending = kernel
            os_unfair_lock_unlock(&lock)
        }

        /// AUDIO thread: adopt a pending kernel if one is available and the lock is
        /// free. Never blocks; if the trylock fails we keep the current kernel.
        func adoptPendingIfAvailable() {
            guard os_unfair_lock_trylock(&lock) else { return }
            if let next = pending {
                live = next
                pending = nil
            }
            os_unfair_lock_unlock(&lock)
        }

        func reset() {
            live.reset()
        }
    }

    private let storage: Storage
    private var currentReplayGain: Double

    public init(kernel: ProAudioKernel) {
        self.storage = Storage(kernel: kernel)
        self.currentReplayGain = kernel.replayGain
    }

    public convenience init(engine: EQEngine,
                     settings: ProAudioSettings = .default,
                     replayGain: Double = 1,
                     sampleRate: Double = ProAudioSettings.convolutionSampleRate) {
        let kernel = ProAudioKernel(
            eqGains: engine.gains,
            eqBypassed: engine.bypassed,
            settings: settings,
            replayGain: replayGain,
            sampleRate: sampleRate)
        self.init(kernel: kernel)
    }

    /// Updates the processing state live (from the settings sliders). Compiles the
    /// new kernel here on the caller's (main) thread, then publishes it.
    public func update(gains: [Double],
                bypassed: Bool,
                settings: ProAudioSettings,
                replayGain: Double = 1,
                sampleRate: Double = ProAudioSettings.convolutionSampleRate) {
        currentReplayGain = replayGain
        let kernel = ProAudioKernel(
            eqGains: gains,
            eqBypassed: bypassed,
            settings: settings,
            replayGain: replayGain,
            sampleRate: sampleRate)
        storage.publish(kernel)
    }

    /// Builds an `AVAudioMix` carrying this tap for the given item's first audio
    /// track. Returns nil if the asset exposes no audio track yet.
    public func makeAudioMix(for item: AVPlayerItem) async -> AVAudioMix? {
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
                storage.reset()
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                                flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let raw = MTAudioProcessingTapGetStorage(tap)
                let storage = Unmanaged<Storage>.fromOpaque(raw).takeUnretainedValue()
                storage.adoptPendingIfAvailable()
                guard !storage.live.isTransparent else { return }

                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                // PostEffects taps deliver non-interleaved float: one buffer per
                // channel. Process frame-major so crossfeed sees L and R together.
                switch abl.count {
                case 1:
                    guard let data = abl[0].mData else { return }
                    let count = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for i in 0..<count {
                        let out = storage.live.processStereo(
                            left: Double(samples[i]), right: 0, stereo: false)
                        samples[i] = Float(out.left)
                    }
                case 2:
                    guard let leftData = abl[0].mData, let rightData = abl[1].mData else { return }
                    let leftCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                    let rightCount = Int(abl[1].mDataByteSize) / MemoryLayout<Float>.size
                    let count = min(leftCount, rightCount)
                    let left = leftData.bindMemory(to: Float.self, capacity: leftCount)
                    let right = rightData.bindMemory(to: Float.self, capacity: rightCount)
                    for i in 0..<count {
                        let out = storage.live.processStereo(
                            left: Double(left[i]), right: Double(right[i]), stereo: true)
                        left[i] = Float(out.left)
                        right[i] = Float(out.right)
                    }
                default:
                    // Unexpected channel layout: pass through untouched.
                    return
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
