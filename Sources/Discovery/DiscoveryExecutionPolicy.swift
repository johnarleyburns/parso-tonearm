import Foundation

/// Decides which Core ML compute engine (GPU/ANE-preferred vs CPU-only)
/// automatic indexing should use *right now*. Separate from `IndexPolicy`,
/// which decides whether indexing may run at all — this only decides HOW,
/// once `IndexPolicy.decide()` has already said yes.
///
/// Real incident this replaces (`DiscoveryRuntimeController.swift`'s old
/// `executionContext: { .background }` comment, kept there for history):
/// naively using GPU/ANE whenever the scene was foregrounded made
/// `ProcessInfo.thermalState` blip from `.nominal` to `.fair` well before
/// the device felt warm, and the old policy's 60-continuous-second `.fair`
/// recovery rule meant every blip reset the countdown — indexing spent
/// nearly all its time in a self-triggered debounce loop instead of
/// actually running.
///
/// The fix is not "never use GPU": GPU/ANE plausibly finishes a track
/// several times faster than CPU, which very likely means LESS total heat
/// generated per track overall, not more — a shorter, hotter burst can
/// still beat a longer, cooler one on total thermal load. The actual bug
/// was reacting to a single instantaneous thermal-state blip as if it were
/// sustained heat, and then fully halting indexing (even the safe CPU-only
/// path) while waiting it out. This policy instead:
///  - reacts to a *sustained* `.fair` reading, not a single sample,
///  - only ever falls back to CPU, never stops indexing outright — the
///    corresponding relaxation in `IndexPolicy.decide()` no longer blocks
///    on `.fair` at all, only on `.serious`/`.critical`,
///  - trips a circuit breaker back to CPU-only for a while after repeated
///    downgrades, since a context switch is a real model reload
///    (`ModelManager`), not free, and a device that keeps tripping `.fair`
///    shortly after each GPU attempt is telling you something real,
///  - and treats active playback as a hard, non-negotiable exception —
///    not a thermal concern at all, but the pre-existing, separately
///    documented risk of a GPU/ANE inference burst contending with the
///    real-time audio render thread (see `IndexPolicy.swift`'s
///    `.foreground` case comment). This policy does not touch that
///    tradeoff; it is intentionally not "always" GPU.
public enum DiscoveryExecutionPolicy {
    /// A single momentary `.fair` reading is common and often not real heat
    /// buildup (see the incident above) — only fall back to CPU once
    /// `.fair` (or worse) has been continuously observed for this long.
    public static let fairSustainedThresholdSeconds: TimeInterval = 20

    /// If thermal sustain has forced a downgrade from GPU to CPU this many
    /// times within `oscillationWindowSeconds`, stop retrying GPU for the
    /// rest of that window. A device genuinely running warm shouldn't have
    /// its model reloaded back and forth repeatedly.
    public static let oscillationLimit = 3
    public static let oscillationWindowSeconds: TimeInterval = 600

    public enum Engine: Equatable, Sendable {
        case gpuPreferred
        case cpuOnly(reason: CPUOnlyReason)
    }

    public enum CPUOnlyReason: Equatable, Sendable {
        case playbackActive
        case thermalSeriousOrCritical
        case thermalSustainedFair
        case recentOscillation
    }

    /// Everything the policy needs, gathered by the caller each tick —
    /// pure function of this snapshot, no live system access here (same
    /// testability discipline as `IndexPolicy`/`DiscoverySchedulingSnapshot`).
    public struct Snapshot: Equatable, Sendable {
        public var thermalState: DiscoveryThermalState
        /// Seconds `.fair` (or worse) has been continuously observed,
        /// tracked by the caller across ticks (mirrors
        /// `DiscoverySchedulingSnapshot.continuousNominalSeconds`'s own
        /// pattern, just for the opposite direction).
        public var continuousFairOrWorseSeconds: TimeInterval
        public var isPlaybackActive: Bool
        /// Number of thermal-triggered GPU→CPU downgrades the caller has
        /// recorded within the trailing `oscillationWindowSeconds`.
        public var recentThermalDowngradeCount: Int

        public init(
            thermalState: DiscoveryThermalState,
            continuousFairOrWorseSeconds: TimeInterval,
            isPlaybackActive: Bool,
            recentThermalDowngradeCount: Int
        ) {
            self.thermalState = thermalState
            self.continuousFairOrWorseSeconds = continuousFairOrWorseSeconds
            self.isPlaybackActive = isPlaybackActive
            self.recentThermalDowngradeCount = recentThermalDowngradeCount
        }
    }

    public static func decide(_ s: Snapshot) -> Engine {
        // Real-time audio render thread protection — a documented, separate
        // concern from thermal signal noise. Not overridable by "prefer
        // GPU": this is about audio-glitch risk, not heat.
        if s.isPlaybackActive { return .cpuOnly(reason: .playbackActive) }

        if s.thermalState == .serious || s.thermalState == .critical {
            return .cpuOnly(reason: .thermalSeriousOrCritical)
        }

        if s.recentThermalDowngradeCount >= oscillationLimit {
            return .cpuOnly(reason: .recentOscillation)
        }

        if s.thermalState == .fair && s.continuousFairOrWorseSeconds >= fairSustainedThresholdSeconds {
            return .cpuOnly(reason: .thermalSustainedFair)
        }

        return .gpuPreferred
    }
}
