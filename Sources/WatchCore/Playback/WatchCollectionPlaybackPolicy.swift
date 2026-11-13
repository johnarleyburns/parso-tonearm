/// Pure policy for whether a collection detail screen's playback controls (Play, Shuffle) should
/// be enabled. Both must agree: a tap that reaches `play(...)` with nothing playable on either
/// target falls through to the T2 target-choice sheet with every option disabled — a dead end.
public enum WatchCollectionPlaybackPolicy {
    public static func canStartPlayback(canPlayOnPhone: Bool, canPlayOnWatch: Bool) -> Bool {
        canPlayOnPhone || canPlayOnWatch
    }
}
