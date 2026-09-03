#if !os(watchOS)
import Foundation
@preconcurrency import AVFoundation
import ParsoAudioPlayback

/// Attaches the full Pro Audio chain to `AVPlayerItem`s via the shared
/// `EQTapInstaller` (one `MTAudioProcessingTap` per item, PostEffects). The tap
/// runs the 10-band EQ, the parametric cascade, convolution, crossfeed and the
/// ReplayGain multiplier on the realtime audio thread (in
/// `ProAudioRealtimeProcessor`). When every stage is transparent, samples pass
/// through untouched.
///
/// One processor instance per item (its own filter history), so a preloaded
/// next item and the currently-playing item never share DSP state across a
/// near-gapless swap. Live settings changes are compiled into a fresh
/// `ProAudioKernel` on the main thread and published lock-free to every live
/// processor.
public final class EQAudioTap: @unchecked Sendable {

    private let installer = EQTapInstaller(placement: .postEffects)
    private var processors: [ObjectIdentifier: ProAudioRealtimeProcessor] = [:]

    /// The most recently compiled kernel spec; new items start from this.
    private var currentKernel: ProAudioKernel

    public init(kernel: ProAudioKernel) {
        self.currentKernel = kernel
    }

    public convenience init(engine: EQEngine,
                            settings: ProAudioSettings = .default,
                            replayGain: Double = 1,
                            sampleRate: Double = ProAudioSettings.convolutionSampleRate) {
        self.init(kernel: ProAudioKernel(
            eqGains: engine.gains,
            eqBypassed: engine.bypassed,
            settings: settings,
            replayGain: replayGain,
            sampleRate: sampleRate))
    }

    /// Updates the processing state live (from the settings sliders). Compiles
    /// the new kernel here on the caller's (main) thread, then publishes it to
    /// every live per-item processor.
    public func update(gains: [Double],
                       bypassed: Bool,
                       settings: ProAudioSettings,
                       replayGain: Double = 1,
                       sampleRate: Double = ProAudioSettings.convolutionSampleRate) {
        let kernel = ProAudioKernel(
            eqGains: gains,
            eqBypassed: bypassed,
            settings: settings,
            replayGain: replayGain,
            sampleRate: sampleRate)
        currentKernel = kernel
        for processor in processors.values {
            processor.publish(kernel)
        }
    }

    /// Installs the Pro Audio tap on `item` (no-op if already installed), with
    /// its own processor seeded from `kernel` (ReplayGain is per-track). The
    /// tap's `audioMix` is set once the asset's audio track resolves. Passing
    /// `nil` uses the most recently compiled kernel.
    @discardableResult
    public func install(on item: AVPlayerItem, kernel: ProAudioKernel? = nil) -> Bool {
        let key = ObjectIdentifier(item)
        if processors[key] != nil { return false }
        if let kernel { currentKernel = kernel }
        let processor = ProAudioRealtimeProcessor(kernel: kernel ?? currentKernel)
        guard installer.install(on: item, processor: processor) else { return false }
        processors[key] = processor
        return true
    }

    /// Removes the tap from every item. Callers that also want the item to stop
    /// carrying a stale `audioMix` should clear `item.audioMix` themselves.
    public func removeAll() {
        installer.removeAll()
        processors.removeAll()
    }

    /// Evicts taps for items no longer in `items` (post gapless auto-advance).
    public func prune(keeping items: [AVPlayerItem]) {
        installer.prune(keeping: items)
        let live = Set(items.map(ObjectIdentifier.init))
        for key in processors.keys where !live.contains(key) {
            processors[key] = nil
        }
    }
}
#endif
