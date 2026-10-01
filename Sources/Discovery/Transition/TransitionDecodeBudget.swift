import Foundation

/// Transition prep decodes a whole track to float PCM before analysing it. libFLAC first decodes
/// to 32-bit integers and that copy lives alongside the float buffer, so a 10-minute 96 kHz stereo
/// FLAC peaks near 1 GB. Two of those at once ended the iPhone app (an allocation abort in
/// `PCMBuffer.init`). This decides, before decoding, whether a track fits in memory now.
public enum TransitionDecodeBudget {
    /// Peak bytes to decode and analyse one track: interleaved Int32 + float PCM, plus 50% for the
    /// analyser's working buffers.
    public static func estimatedPeakBytes(durationSec: Double?, sampleRate: Int?, fileBytes: Int64?,
                                          channels: Int = 2) -> Int64? {
        if let durationSec, durationSec > 0, durationSec.isFinite {
            let rate = Double(sampleRate.flatMap { $0 > 0 ? $0 : nil } ?? 44_100)
            let pcmBytes = durationSec * rate * Double(max(1, channels)) * 4
            return Int64((pcmBytes * 2.5).rounded(.up))
        }
        // No duration: compressed audio rarely exceeds 1:4 against 16-bit PCM, and float PCM is
        // twice that, so 8× the file (×2.5 for the peak) is a safe upper bound.
        if let fileBytes, fileBytes > 0 { return fileBytes * 8 * 5 / 2 }
        return nil
    }

    /// A decode may use at most half of what the OS says this process can still allocate.
    public static func fits(estimatedPeakBytes: Int64?, availableBytes: Int64?) -> Bool {
        guard let estimatedPeakBytes, let availableBytes else { return true }
        return estimatedPeakBytes <= availableBytes / 2
    }
}

/// Runs full-track decodes one at a time across the whole app. Cancelling a prep task can't stop
/// a decode that has started (it's synchronous C), so without this a re-prepared queue stacked
/// decodes on top of each other. A queued decode that was cancelled before its turn never starts.
public actor TransitionDecodeGate {
    public static let shared = TransitionDecodeGate()
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let previous = tail
        let work = Task.detached(priority: .utility) { () throws -> T in
            await previous?.value
            try Task.checkCancellation()
            return try operation()
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
