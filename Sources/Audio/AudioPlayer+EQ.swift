#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - EQ (T4.1)

    /// Applies the current EQ state to an item via the shared `EQTapInstaller`
    /// (`EQAudioTap`) when any stage is non-transparent. Detaching happens
    /// naturally in the same teardown path as `shutdownLoaders()` (the item's
    /// audioMix is dropped when the item is replaced). The one persistent
    /// `eqTap` installs on both the current and the preloaded next item so EQ
    /// survives near-gapless swaps.
    func applyEQ(to item: AVPlayerItem, row: TrackRow) {
        let settings = EQSettingsPersistence.load()
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let proAudio = ProAudioSettingsPersistence.load()
        let replayGain = replayGainValue(for: row.track)
        // The tap must attach whenever ANY stage is non-transparent: the 10-band
        // EQ, ReplayGain, OR the pro-audio chain. Without the pro-audio clause a
        // flat EQ + unity ReplayGain would strand the parametric/crossfeed/
        // convolution stages (the historical bug).
        guard settings.enabled || replayGain != 1 || !proAudio.isTransparent else {
            item.audioMix = nil
            return
        }
        let gains = settings.enabled ? store.effectiveBands(for: settings).map(Double.init)
            : Array(repeating: 0, count: EQEngine.bandCount)
        let kernel = ProAudioKernel(
            eqGains: gains,
            eqBypassed: !settings.enabled,
            settings: proAudio,
            replayGain: replayGain,
            sampleRate: ProAudioSettings.convolutionSampleRate)
        let tap = eqTap ?? EQAudioTap(kernel: kernel)
        eqTap = tap
        // Each item gets its own processor seeded with that track's ReplayGain.
        tap.install(on: item, kernel: kernel)
    }

    /// Live-updates EQ gains on the currently playing item without interrupting
    /// playback (engage/disengage is glitch-free). Call from the EQ settings UI.
    public func updateEQ(gains: [Double], enabled: Bool) {
        let settings = EQSettings(bands: gains.map(Float.init), enabled: enabled, activePresetID: nil)
        updateEQ(settings: settings)
    }

    public func updateEQ(settings: EQSettings) {
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let normalized = store.normalized(settings)
        EQSettingsPersistence.save(normalized)
        pushLiveAudioProcessing(eqEnabled: normalized.enabled,
                                gains: store.effectiveBands(for: normalized).map(Double.init))
    }

    /// Pushes the current Pro Audio settings into the live tap (from the Pro Tools
    /// audio sliders). Mirrors `updateEQ(settings:)`.
    public func updateProAudio(_ settings: ProAudioSettings) {
        ProAudioSettingsPersistence.save(settings)
        let eqSettings = EQSettingsPersistence.load()
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let gains = eqSettings.enabled ? store.effectiveBands(for: eqSettings).map(Double.init)
            : Array(repeating: 0, count: EQEngine.bandCount)
        pushLiveAudioProcessing(eqEnabled: eqSettings.enabled, gains: gains)
    }

    /// Shared live-update path: pushes EQ + Pro Audio + ReplayGain into the running
    /// tap without interrupting playback, attaching or clearing the mix as the
    /// combined transparency changes.
    func pushLiveAudioProcessing(eqEnabled: Bool, gains: [Double]) {
        let proAudio = ProAudioSettingsPersistence.load()
        let replayGain = currentTrack.map { replayGainValue(for: $0.track) } ?? 1
        let needsTap = eqEnabled || replayGain != 1 || !proAudio.isTransparent
        if let tap = eqTap, needsTap {
            tap.update(gains: gains, bypassed: !eqEnabled, settings: proAudio, replayGain: replayGain)
        } else if !needsTap {
            eqTap?.removeAll()
            player.currentItem?.audioMix = nil
            preloadedNextItem?.audioMix = nil
            eqTap = nil
        } else if let item = player.currentItem, let row = currentTrack {
            // Toggled on from a clean chain: (re)attach the mix on the live item.
            applyEQ(to: item, row: row)
        }
    }

    func replayGainValue(for track: Track) -> Double {
        ReplayGain.appliedGain(
            mode: replayGainMode,
            tags: track.replayGainTags,
            preampDB: replayGainPreampDB,
            preventClipping: replayGainPreventClipping)
    }

    /// The hardware output sample rate the audio session is currently running at.
    public var hardwareSampleRate: Double {
        bridge.sampleRate
    }

    /// The nominal sample rate of the currently loaded source audio track, or 0
    /// when unknown (e.g. nothing playing yet).
    public var currentSourceSampleRate: Double {
        loadedSourceSampleRate
    }

    /// Honest bit-perfect plan for the current state: derived from the REAL
    /// hardware/source rates and the live ReplayGain, never from view `@State`.
    public func bitPerfectPlan(for settings: ProAudioSettings) -> BitPerfectOutputPlan {
        let replayGain = currentTrack.map { replayGainValue(for: $0.track) } ?? 1
        return settings.bitPerfectPlan(
            hardwareSampleRate: hardwareSampleRate,
            sourceSampleRate: currentSourceSampleRate,
            replayGainActive: replayGain != 1)
    }
}
#endif
