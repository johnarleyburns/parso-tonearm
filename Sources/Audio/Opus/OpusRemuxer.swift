import Foundation

/// Async, cancellable Ogg-Opus → CAF remux. Reads a completed `.opus` cache file,
/// demuxes it (OggPageReader) and writes a sibling `.caf` (CAFOpusWriter) that
/// AVFoundation can play natively (D1). On failure/cancel it leaves no partial
/// `.caf` and never surfaces a user-visible error — only a local counter (T2.3).
actor OpusRemuxer {
    static let shared = OpusRemuxer()

    /// Cache keys currently being remuxed, to avoid duplicate work.
    private var inProgress: Set<String> = []
    /// Keys whose remux failed this session; playback falls back per policy.
    private var unavailable: Set<String> = []
    /// Local-only counters (no telemetry). Exposed for tests/diagnostics.
    private(set) var successCount = 0
    private(set) var failureCount = 0

    enum RemuxError: Error, Equatable {
        case alreadyUnavailable
        case cancelled
        case emptyOutput
    }

    /// CAF sibling path for an Opus cache key: same directory, `.caf` extension.
    nonisolated static func cafURL(forOpusFile opusURL: URL) -> URL {
        opusURL.deletingPathExtension().appendingPathExtension("caf")
    }

    func isUnavailable(_ key: String) -> Bool { unavailable.contains(key) }

    func markUnavailable(_ key: String) { unavailable.insert(key) }

    /// Remuxes the `.opus` file at `sourceURL` to a sibling `.caf`. Returns the
    /// CAF URL on success. Deletes the raw `.opus` on success (the CAF becomes the
    /// cached artifact); deletes any partial `.caf` on failure/cancel.
    @discardableResult
    func remux(opusFileURL sourceURL: URL, cacheKey: String,
               deleteSourceOnSuccess: Bool = true) async throws -> URL {
        if unavailable.contains(cacheKey) { throw RemuxError.alreadyUnavailable }
        let cafURL = Self.cafURL(forOpusFile: sourceURL)

        // Already remuxed.
        if FileManager.default.fileExists(atPath: cafURL.path) { return cafURL }
        guard !inProgress.contains(cacheKey) else {
            // Another task owns it; wait for the file to appear or fail fast.
            return cafURL
        }
        inProgress.insert(cacheKey)
        defer { inProgress.remove(cacheKey) }

        do {
            try Task.checkCancellation()
            let oggData = try Data(contentsOf: sourceURL)
            try Task.checkCancellation()
            let stream = try OggPageReader.parse(oggData)
            let caf = try CAFOpusWriter.makeCAF(from: stream)
            guard !caf.isEmpty else { throw RemuxError.emptyOutput }
            try Task.checkCancellation()
            try caf.write(to: cafURL, options: .atomic)

            if deleteSourceOnSuccess {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            successCount += 1
            return cafURL
        } catch {
            // Leave no partial CAF behind; mark the key unavailable for fallback.
            try? FileManager.default.removeItem(at: cafURL)
            if error is CancellationError {
                throw RemuxError.cancelled
            }
            unavailable.insert(cacheKey)
            failureCount += 1
            throw error
        }
    }
}
