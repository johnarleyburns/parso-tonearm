import Foundation

/// Persisted set of contiguous byte ranges present in a sparse cache file.
struct ByteRangeMap: Codable, Equatable {
    private(set) var ranges: [Range<Int64>] = []

    init() {}

    init(data: Data) {
        if let decoded = try? JSONDecoder().decode(ByteRangeMap.self, from: data) {
            self = decoded
        }
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    mutating func insert(_ range: Range<Int64>) {
        guard range.lowerBound < range.upperBound else { return }
        var merged: [Range<Int64>] = []
        var newRange = range
        for r in ranges {
            if r.upperBound < newRange.lowerBound || r.lowerBound > newRange.upperBound {
                merged.append(r)
            } else {
                newRange = min(r.lowerBound, newRange.lowerBound)..<max(r.upperBound, newRange.upperBound)
            }
        }
        merged.append(newRange)
        ranges = merged.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Number of contiguous cached bytes starting at `offset`.
    func contiguousBytes(from offset: Int64) -> Int64 {
        for r in ranges where r.contains(offset) {
            return r.upperBound - offset
        }
        return 0
    }

    func totalBytes() -> Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    func covers(total: Int64) -> Bool {
        guard total > 0 else { return false }
        return contiguousBytes(from: 0) >= total
    }
}
