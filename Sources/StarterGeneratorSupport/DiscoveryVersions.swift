import Foundation

/// Version constants for the unified indexing pipeline.
/// Bumping any of these makes prior rows for that stage incompatible so they
/// cannot be scanned/queried together with new ones (plan §6: "Version the
/// sampling change so old incompatible vectors cannot be queried together").
public enum DiscoveryPipelineVersion {
    /// Overall job/pipeline shape. Bump when the job state machine or stage
    /// contract changes incompatibly.
    public static let pipeline = 1

    /// BPM/key/energy musical analysis scope/algorithm version.
    /// Bumped when BPM/key became mandatory indexed output and old analysis
    /// rows began being migrated by startup reconciliation.
    public static let musicalAnalysis = 2
}

/// A single, honest, shared source for "how much data does sparsely
/// indexing one remote track cost" — used both by `IndexPolicy`-adjacent
/// documentation and by the Settings confirmation dialog that must state
/// this real cost before letting the user turn off Wi-Fi-only sampling
/// (docs/plans/remote-sparse-indexing.md).
public enum RemoteIndexingByteEstimate {
    /// One 60s musical-analysis window at a conservative 192kbps is ~1.44 MB
    /// of decoded audio; padded to 2 MB for per-request overhead. Real remote
    /// libraries vary, but this deliberately does not assume a smaller
    /// number.
    public static let perTrackBytes: Int64 = 2 * 1024 * 1024
}
