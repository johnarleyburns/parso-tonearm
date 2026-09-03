#if !os(watchOS)
import Foundation
@preconcurrency import AVFoundation
import ParsoAudioPlayback
import os

/// Drives the full Pro Audio chain (10-band EQ + parametric cascade +
/// convolution + crossfeed + ReplayGain) on the realtime audio thread, behind
/// the shared `EQTapInstaller` tap.
///
/// Realtime safety: the audio thread does NO blocking lock, NO allocation and
/// NO Swift/ObjC runtime work in the hot path. New settings are compiled into a
/// fully pre-allocated `ProAudioKernel` on the MAIN thread and published under
/// an `os_unfair_lock`; the audio thread adopts the pending kernel with
/// `os_unfair_lock_trylock` (keeping the previous one if the trylock fails),
/// then processes without holding any lock.
public final class ProAudioRealtimeProcessor: RealtimeAudioProcessor, @unchecked Sendable {

    /// Owned and mutated only on the audio thread (except `reset` in prepare).
    private var live: ProAudioKernel
    /// Handed off from the main thread, picked up by the audio thread.
    private var pending: ProAudioKernel?
    private var lock = os_unfair_lock_s()

    public init(kernel: ProAudioKernel) {
        self.live = kernel
    }

    /// MAIN thread: publish a freshly-compiled kernel (all allocation done).
    public func publish(_ kernel: ProAudioKernel) {
        os_unfair_lock_lock(&lock)
        pending = kernel
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - RealtimeAudioProcessor

    public func prepareRealtime() {
        live.reset()
    }

    public func processRealtime(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingIfAvailable()
        guard !live.isTransparent else { return }

        // PostEffects taps deliver non-interleaved float: one buffer per channel.
        // Process frame-major so crossfeed sees L and R together.
        switch bufferList.count {
        case 1:
            guard let data = bufferList[0].mData else { return }
            let count = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count {
                let out = live.processStereo(left: Double(samples[i]), right: 0, stereo: false)
                samples[i] = Float(out.left)
            }
        case 2:
            guard let leftData = bufferList[0].mData, let rightData = bufferList[1].mData else { return }
            let leftCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            let rightCount = Int(bufferList[1].mDataByteSize) / MemoryLayout<Float>.size
            let count = min(leftCount, rightCount)
            let left = leftData.bindMemory(to: Float.self, capacity: leftCount)
            let right = rightData.bindMemory(to: Float.self, capacity: rightCount)
            for i in 0..<count {
                let out = live.processStereo(left: Double(left[i]), right: Double(right[i]), stereo: true)
                left[i] = Float(out.left)
                right[i] = Float(out.right)
            }
        default:
            return   // Unexpected channel layout: pass through untouched.
        }
    }

    private func adoptPendingIfAvailable() {
        guard os_unfair_lock_trylock(&lock) else { return }
        if let next = pending {
            live = next
            pending = nil
        }
        os_unfair_lock_unlock(&lock)
    }
}
#endif
