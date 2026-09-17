import Foundation

/// Version constants for the unified indexing pipeline
/// (IMPLEMENT_CLAP_PLAN.md §6/§8). Bumping any of these makes prior rows for
/// that stage incompatible so they cannot be scanned/queried together with
/// new ones (plan §6: "Version the sampling change so old incompatible
/// vectors cannot be queried together").
///
/// These are real, load-bearing constants (referenced by the discovery
/// schema's job/embedding rows) rather than placeholders — the algorithms
/// that consume them (windowed reader, pooling, CLAP execution, BPM/key
/// analysis, retrieval) are C03–C06 work not yet ported into this target
/// this session; see docs/plans/clap/IMPLEMENTATION_STATUS.md.
public enum DiscoveryPipelineVersion {
    /// Overall job/pipeline shape. Bump when the job state machine or stage
    /// contract changes incompatibly.
    public static let pipeline = 1

    /// CLAP audio encoder weights/model identity.
    public static let model = 1

    /// Frontend/tensor preprocessing (resample, mel, normalization) applied
    /// before the encoder.
    public static let preprocessing = 1

    /// Window sampling policy: <=10s tracks get one zero-padded window;
    /// otherwise min(12, ceil(duration/10)) windows evenly distributed from
    /// 0 to duration-10 inclusive (plan §6).
    public static let sampling = 1

    /// BPM/key/energy musical analysis scope/algorithm version, checkpointed
    /// independently of the embedding stage (plan §6).
    public static let musicalAnalysis = 1
}

/// Fixed v1 sampling policy (plan §6): "at most 12 windows, evenly
/// distributed from 0 to duration-10 seconds inclusive. Count = min(12,
/// ceil(duration/10))." Kept as a pure function here (no I/O, no actor) so
/// it is trivially unit-testable ahead of the windowed reader that will call
/// it.
public enum DiscoverySamplingPolicy {
    /// - Parameter durationSeconds: total track duration, from actual
    ///   readable media when metadata is absent (plan §6).
    /// - Returns: ascending window start times in seconds. A single
    ///   zero-padded window (start 0) for tracks <= 10 seconds.
    public static func windowStarts(durationSeconds: Double) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [0] }
        guard durationSeconds > 10 else { return [0] }

        let maxWindows = 12
        let count = min(maxWindows, Int(ceil(durationSeconds / 10.0)))
        guard count > 1 else { return [0] }

        let lastStart = durationSeconds - 10
        var starts: [Double] = []
        starts.reserveCapacity(count)
        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            starts.append(fraction * lastStart)
        }
        return starts
    }
}

/// A single, honest, shared source for "how much data does sparsely
/// indexing one remote track cost" — used both by `IndexPolicy`-adjacent
/// documentation and by the Settings confirmation dialog that must state
/// this real cost before letting the user turn off Wi-Fi-only sampling
/// (docs/plans/remote-sparse-indexing.md).
public enum RemoteIndexingByteEstimate {
    /// Up to 12 × 10s embedding windows + one 60s musical-analysis window =
    /// up to 180s of decoded audio per track (`BoundedIndexWorker`,
    /// `DiscoverySamplingPolicy.windowStarts`), at a conservative 192kbps —
    /// real remote libraries vary, but this deliberately does not assume a
    /// smaller number (the plan's own byte-budget section: "Any byte-budget
    /// estimate for this feature must start from that number"). Padded up
    /// from the raw ~4.3 MB/track figure to account for per-window request
    /// overhead (see the plan's "pad generously" note).
    public static let perTrackBytes: Int64 = 5 * 1024 * 1024
}
