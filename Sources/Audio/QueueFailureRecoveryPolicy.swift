/// Pure policy for what to do when the current queue entry fails to load during an
/// autoplaying advance. Bounded: never revisits the failing sequence's starting entry
/// and never recurses on Repeat One.
public enum QueueFailureRecoveryPolicy {
    public enum Decision: Equatable {
        case advance(to: Int)
        case stop
    }

    /// - Parameters:
    ///   - failedAttempts: failures already seen in this advance sequence, including the current one.
    public static func decide(index: Int, count: Int, repeatMode: RepeatMode,
                              autoplay: Bool, failedAttempts: Int) -> Decision {
        guard autoplay, count > 1, repeatMode != .one,
              failedAttempts < count else { return .stop }
        if index < count - 1 { return .advance(to: index + 1) }
        return repeatMode == .all ? .advance(to: 0) : .stop
    }
}
