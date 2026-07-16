import Foundation
import XCTest

@testable import TonearmCore

final class DuplicateDetectionTests: XCTestCase {
    func testIdenticalFilesAreGroupedBySizeAndSampleHash() {
        let payload = bytes(count: 300_000, salt: 7)
        let candidates = [
            DuplicateDetection.Candidate(id: "a.flac", bytes: payload),
            DuplicateDetection.Candidate(id: "b.flac", bytes: payload),
            DuplicateDetection.Candidate(id: "c.flac", bytes: bytes(count: 300_000, salt: 8)),
        ]

        let groups = DuplicateDetection.groups(from: candidates)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].ids, ["a.flac", "b.flac"])
        XCTAssertEqual(groups[0].fingerprint.sizeBytes, 300_000)
        XCTAssertEqual(groups[0].fingerprint.sampleHash.count, 64)
    }

    func testSameSizeDifferentContentDoesNotGroup() {
        let candidates = [
            DuplicateDetection.Candidate(id: "left", bytes: bytes(count: 400_000, salt: 1)),
            DuplicateDetection.Candidate(id: "right", bytes: bytes(count: 400_000, salt: 2)),
        ]

        XCTAssertEqual(DuplicateDetection.groups(from: candidates), [])
    }

    func testFilesSmallerThanTwoWindowsAreCoveredByOverlappingSample() {
        let base = bytes(count: 180_000, salt: 3)
        var changed = base
        changed[100_000] ^= 0xff

        XCTAssertEqual(DuplicateDetection.sample(bytes: base).count, 256 * 1_024)

        let groups = DuplicateDetection.groups(from: [
            DuplicateDetection.Candidate(id: "original", bytes: base),
            DuplicateDetection.Candidate(id: "copy", bytes: base),
            DuplicateDetection.Candidate(id: "mutated", bytes: changed),
        ])

        XCTAssertEqual(groups.map(\.ids), [["original", "copy"]])
    }

    func testVerySmallAndEmptyFilesUseDeterministicFingerprints() {
        let smallA = DuplicateDetection.Candidate(id: "small-a", bytes: [1, 2, 3])
        let smallB = DuplicateDetection.Candidate(id: "small-b", bytes: [1, 2, 3])
        let smallC = DuplicateDetection.Candidate(id: "small-c", bytes: [1, 2, 4])
        let emptyA = DuplicateDetection.Candidate(id: "empty-a", bytes: [])
        let emptyB = DuplicateDetection.Candidate(id: "empty-b", bytes: [])

        let groups = DuplicateDetection.groups(from: [smallA, smallB, smallC, emptyA, emptyB])

        XCTAssertEqual(groups.map(\.ids), [
            ["small-a", "small-b"],
            ["empty-a", "empty-b"],
        ])
        XCTAssertEqual(emptyA.fingerprint.sizeBytes, 0)
        XCTAssertEqual(emptyA.fingerprint.sampleHash, emptyB.fingerprint.sampleHash)
        XCTAssertNotEqual(smallA.fingerprint.sampleHash, smallC.fingerprint.sampleHash)
    }

    func testCallerCanProvidePrecomputedWindowHashesWithoutFileIO() {
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

        XCTAssertEqual(groups.map(\.ids), [["remote-a", "remote-b"]])
    }

    func testFiveThousandFileLibraryGroupsStably() {
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

        XCTAssertEqual(candidates.count, 5_000)
        XCTAssertEqual(groups.map(\.ids), [
            ["album-a-track-1", "album-a-track-2", "album-a-track-3"],
            ["album-b-track-1", "album-b-track-2"],
        ])
        XCTAssertLessThan(elapsed, 0.5)
    }

    private func bytes(count: Int, salt: UInt8) -> Data {
        Data((0..<count).map { index in
            UInt8((index * 31 + Int(salt)) & 0xff)
        })
    }
}
