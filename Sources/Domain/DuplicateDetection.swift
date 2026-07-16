import CryptoKit
import Foundation

public enum DuplicateDetection {
    public static let sampleByteCount = 128 * 1_024

    public struct Fingerprint: Hashable, Equatable {
        var sizeBytes: Int64
        var sampleHash: String
    }

    public struct Candidate: Identifiable, Equatable {
        public var id: String
        var fingerprint: Fingerprint

        var sizeBytes: Int64 { fingerprint.sizeBytes }
        var sampleHash: String { fingerprint.sampleHash }

        init(id: String, sizeBytes: Int64, sampleHash: String) {
            self.id = id
            self.fingerprint = Fingerprint(sizeBytes: sizeBytes, sampleHash: sampleHash)
        }

        init(id: String, bytes: Data) {
            self.id = id
            self.fingerprint = DuplicateDetection.fingerprint(bytes: bytes)
        }

        init(id: String, bytes: [UInt8]) {
            self.init(id: id, bytes: Data(bytes))
        }
    }

    public struct Group: Equatable {
        var fingerprint: Fingerprint
        var candidates: [Candidate]

        var ids: [String] {
            candidates.map(\.id)
        }
    }

    public static func groups(from candidates: [Candidate]) -> [Group] {
        struct Bucket {
            var firstIndex: Int
            var candidates: [Candidate]
        }

        var buckets: [Fingerprint: Bucket] = [:]
        for (index, candidate) in candidates.enumerated() {
            if var bucket = buckets[candidate.fingerprint] {
                bucket.candidates.append(candidate)
                buckets[candidate.fingerprint] = bucket
            } else {
                buckets[candidate.fingerprint] = Bucket(firstIndex: index, candidates: [candidate])
            }
        }

        var groups: [(fingerprint: Fingerprint, bucket: Bucket)] = []
        for (fingerprint, bucket) in buckets where bucket.candidates.count > 1 {
            groups.append((fingerprint, bucket))
        }
        groups.sort { lhs, rhs in
            lhs.bucket.firstIndex < rhs.bucket.firstIndex
        }
        return groups.map { item in
            Group(fingerprint: item.fingerprint, candidates: item.bucket.candidates)
        }
    }

    public static func fingerprint(bytes: Data) -> Fingerprint {
        Fingerprint(
            sizeBytes: Int64(bytes.count),
            sampleHash: hashSample(bytes: bytes)
        )
    }

    public static func fingerprint(sizeBytes: Int64, firstBytes: Data, lastBytes: Data) -> Fingerprint {
        Fingerprint(
            sizeBytes: sizeBytes,
            sampleHash: hashSample(firstBytes: firstBytes, lastBytes: lastBytes)
        )
    }

    public static func sample(bytes: Data) -> Data {
        let firstBytes = bytes.prefix(sampleByteCount)
        let lastBytes = bytes.suffix(sampleByteCount)
        var sample = Data()
        sample.reserveCapacity(firstBytes.count + lastBytes.count)
        sample.append(firstBytes)
        sample.append(lastBytes)
        return sample
    }

    private static func hashSample(bytes: Data) -> String {
        let firstBytes = bytes.prefix(sampleByteCount)
        let lastBytes = bytes.suffix(sampleByteCount)
        return hashSample(firstBytes: firstBytes, lastBytes: lastBytes)
    }

    private static func hashSample<First: DataProtocol, Last: DataProtocol>(
        firstBytes: First,
        lastBytes: Last
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: firstBytes)
        hasher.update(data: lastBytes)
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
