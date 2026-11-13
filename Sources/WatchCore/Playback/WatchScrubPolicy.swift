import Foundation

/// Pure policy for the Watch Now Playing progress scrubber (local playback only).
public enum WatchScrubPolicy {
    /// Seeking stops just short of the end so an end-edge tap does not end the item.
    public static let endGuard: Double = 0.5

    /// The scrubber is interactive only for a local, non-busy, non-Always-On track with a known duration.
    public static func isInteractive(duration: Double, isLocal: Bool, isBusy: Bool, isLuminanceReduced: Bool) -> Bool {
        isLocal && !isBusy && !isLuminanceReduced && duration.isFinite && duration > 0
    }

    /// Clamps a seek target into 0...(duration - endGuard) (or 0...duration for very short items).
    public static func clamp(_ seconds: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, seconds.isFinite else { return 0 }
        let upper = duration > endGuard * 2 ? duration - endGuard : duration
        return min(max(0, seconds), upper)
    }

    /// Maps a horizontal location within a track of `width` to a clamped time.
    public static func time(forLocation x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return clamp(min(1, max(0, x / width)) * duration, duration: duration)
    }

    /// Target for a VoiceOver increment (+) / decrement (-) step: 5% of the duration, at least 5 s.
    public static func adjustedTime(from elapsed: Double, duration: Double, direction: Int) -> Double {
        let step = max(5, duration * 0.05)
        return clamp(elapsed + Double(direction) * step, duration: duration)
    }

    /// While a drag is in flight the scrub position wins; afterwards a stale player time (older than
    /// the committed target) must not pull the display backward.
    public static func displayed(scrub: Double?, committed: Double?, playerElapsed: Double) -> Double {
        scrub ?? committed ?? playerElapsed
    }
}
