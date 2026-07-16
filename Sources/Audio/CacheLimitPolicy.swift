import Foundation

public struct CacheLimitPolicy {
    public static let minimumBytes: Int64 = 100 * 1024 * 1024

    public struct Result: Equatable {
        var requestedBytes: Int64
        var allowedBytes: Int64
        var reason: String?
    }

    public static func validate(requestedBytes: Int64, freeDiskBytes: Int64) -> Result {
        guard requestedBytes > 0 else {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: minAllowedBytes(freeDiskBytes: freeDiskBytes),
                reason: "Cache must be at least 100 MB."
            )
        }

        let ceiling = max(0, freeDiskBytes / 5 * 4)
        guard ceiling > 0 else {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: 0,
                reason: "No free disk space is available for cache."
            )
        }

        if requestedBytes < minimumBytes {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: min(minimumBytes, ceiling),
                reason: "Cache must be at least 100 MB."
            )
        }

        if requestedBytes > ceiling {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: ceiling,
                reason: "Cache is limited to 80% of free disk space."
            )
        }

        return Result(requestedBytes: requestedBytes, allowedBytes: requestedBytes, reason: nil)
    }

    private static func minAllowedBytes(freeDiskBytes: Int64) -> Int64 {
        let ceiling = max(0, freeDiskBytes / 5 * 4)
        guard ceiling > 0 else { return 0 }
        return min(minimumBytes, ceiling)
    }
}
