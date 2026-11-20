import Foundation
import Testing

@testable import TonearmCore

@Suite struct DuplicateDetectionTests {
    @Test func testIdenticalFilesAreGroupedBySizeAndSampleHash() {
        let payload = bytes(count: 300_000, salt: 7)
        let candidates = [
            DuplicateDetection.Candidate(id: "a.flac", bytes: payload),
            DuplicateDetection.Candidate(id: "b.flac", bytes: payload),
            DuplicateDetection.Candidate(id: "c.flac", bytes: bytes(count: 300_000, salt: 8)),
        ]

        let groups = DuplicateDetection.groups(from: candidates)

        #expect(groups.count == 1)
        #expect(groups[0].ids == ["a.flac", "b.flac"])
        #expect(groups[0].fingerprint.sizeBytes == 300_000)
        #expect(groups[0].fingerprint.sampleHash.count == 64)
    }

    @Test func testSameSizeDifferentContentDoesNotGroup() {
        let candidates = [
            DuplicateDetection.Candidate(id: "left", bytes: bytes(count: 400_000, salt: 1)),
            DuplicateDetection.Candidate(id: "right", bytes: bytes(count: 400_000, salt: 2)),
        ]

        #expect(DuplicateDetection.groups(from: candidates) == [])
    }

    @Test func testFilesSmallerThanTwoWindowsAreCoveredByOverlappingSample() {
        let base = bytes(count: 180_000, salt: 3)
        var changed = base
        changed[100_000] ^= 0xff

        #expect(DuplicateDetection.sample(bytes: base).count == 256 * 1_024)

        let groups = DuplicateDetection.groups(from: [
            DuplicateDetection.Candidate(id: "original", bytes: base),
            DuplicateDetection.Candidate(id: "copy", bytes: base),
            DuplicateDetection.Candidate(id: "mutated", bytes: changed),
        ])

        #expect(groups.map(\.ids) == [["original", "copy"]])
    }

    @Test func testVerySmallAndEmptyFilesUseDeterministicFingerprints() {
        let smallA = DuplicateDetection.Candidate(id: "small-a", bytes: [1, 2, 3])
        let smallB = DuplicateDetection.Candidate(id: "small-b", bytes: [1, 2, 3])
        let smallC = DuplicateDetection.Candidate(id: "small-c", bytes: [1, 2, 4])
        let emptyA = DuplicateDetection.Candidate(id: "empty-a", bytes: [])
        let emptyB = DuplicateDetection.Candidate(id: "empty-b", bytes: [])

        let groups = DuplicateDetection.groups(from: [smallA, smallB, smallC, emptyA, emptyB])

        #expect(groups.map(\.ids) == [
            ["small-a", "small-b"],
            ["empty-a", "empty-b"],
        ])
        #expect(emptyA.fingerprint.sizeBytes == 0)
        #expect(emptyA.fingerprint.sampleHash == emptyB.fingerprint.sampleHash)
        #expect(smallA.fingerprint.sampleHash != smallC.fingerprint.sampleHash)
    }

    @Test func testCallerCanProvidePrecomputedWindowHashesWithoutFileIO() {
        let first = Data(bytes(count: DuplicateDetection.sampleByteCount, salt: 11))
        let last = Data(bytes(count: DuplicateDetection.sampleByteCount, salt: 12))
        let fingerprint = DuplicateDetection.fingerprint(
            sizeBytes: 900_000,
            firstBytes: first,
            lastBytes: last
        )

        let groups = DuplicateDetection.groups(from: [
            DuplicateDetection.Candidate(id: "remote-a", sizeBytes: fingerprint.sizeBytes, sampleHash: fingerprint.sampleHash),
            DuplicateDetection.Candidate(id: "remote-b", sizeBytes: fingerprint.sizeBytes, sampleHash: fingerprint.sampleHash),
            DuplicateDetection.Candidate(id: "near-match", sizeBytes: fingerprint.sizeBytes + 1, sampleHash: fingerprint.sampleHash),
        ])

        #expect(groups.map(\.ids) == [["remote-a", "remote-b"]])
    }

    @Test func testFiveThousandFileLibraryGroupsStably() {
        var candidates: [DuplicateDetection.Candidate] = []
        candidates.reserveCapacity(5_000)

        for index in 0..<4_995 {
            candidates.append(DuplicateDetection.Candidate(
                id: "unique-\(index)",
                bytes: bytes(count: 64 + index, salt: UInt8(index % 251))
            ))
        }

        let duplicateA = bytes(count: 280_000, salt: 42)
        let duplicateB = bytes(count: 20_000, salt: 84)
        candidates.insert(DuplicateDetection.Candidate(id: "album-a-track-1", bytes: duplicateA), at: 1_000)
        candidates.insert(DuplicateDetection.Candidate(id: "album-a-track-2", bytes: duplicateA), at: 1_001)
        candidates.insert(DuplicateDetection.Candidate(id: "album-a-track-3", bytes: duplicateA), at: 1_002)
        candidates.insert(DuplicateDetection.Candidate(id: "album-b-track-1", bytes: duplicateB), at: 4_000)
        candidates.insert(DuplicateDetection.Candidate(id: "album-b-track-2", bytes: duplicateB), at: 4_001)

        let startedAt = Date()
        let groups = DuplicateDetection.groups(from: candidates)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(candidates.count == 5_000)
        #expect(groups.map(\.ids) == [
            ["album-a-track-1", "album-a-track-2", "album-a-track-3"],
            ["album-b-track-1", "album-b-track-2"],
        ])
        #expect(elapsed < 0.5)
    }

    private func bytes(count: Int, salt: UInt8) -> Data {
        Data((0..<count).map { index in
            UInt8((index * 31 + Int(salt)) & 0xff)
        })
    }
}
