import XCTest
@testable import TonearmDJ

/// Commit 5.12 — the Recorded Mixes screen's model (§41.12, mockup `ipad/10`):
/// the finished-mix library, the on-device storage roll-up, and deletion.
/// FR-REC-5 — this screen is free; a finished mix is an ordinary playable item.
@MainActor
final class MixesModelTests: XCTestCase {

    private final class FakeMixRepository: MixServicing, @unchecked Sendable {
        var mixes: [DJMix] = []
        var storage: Int64 = 0
        private(set) var deleted: [Int64] = []

        func completedMixes() async throws -> [DJMix] { mixes }
        func mixTrackEvents(mixID: Int64) async throws -> [DJMixTrackEvent] { [] }
        func mixAssetURL(mixID: Int64) async throws -> URL? { nil }
        func updateMix(mixID: Int64, title: String, notes: String?) async throws {}
        func deleteMix(mixID: Int64) async throws {
            deleted.append(mixID)
            mixes.removeAll { $0.id == mixID }
        }
        func mixStorageBytes() async throws -> Int64 { storage }
    }

    private func makeMix(id: Int64, title: String, duration: Double,
                         sizeBytes: Int64, state: MixLocalState = .complete) -> DJMix {
        var mix = DJMix(syncID: "mix-\(id)", title: title, durationSec: duration,
                        trackCount: 1, format: RecordingEncoder.formatName,
                        sizeBytes: sizeBytes, recordedAt: Date(),
                        localState: state.rawValue)
        mix.id = id
        return mix
    }

    func testBeginListsMixesAndStorage() async throws {
        let repository = FakeMixRepository()
        repository.mixes = [
            makeMix(id: 2, title: "Friday set", duration: 360, sizeBytes: 138_000_000),
            makeMix(id: 1, title: "Kitchen practice", duration: 120, sizeBytes: 92_000_000),
        ]
        repository.storage = 230_000_000
        let model = MixesModel(repository: repository)
        await model.begin()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.rows.map(\.mix.id), [2, 1])
        XCTAssertEqual(model.mixStorageText(), "230 MB")
    }

    func testDeleteRemovesTheMixAndRefreshes() async throws {
        let repository = FakeMixRepository()
        repository.mixes = [makeMix(id: 1, title: "To delete", duration: 10, sizeBytes: 1)]
        let model = MixesModel(repository: repository)
        await model.begin()

        await model.delete(try XCTUnwrap(model.rows.first))

        XCTAssertEqual(repository.deleted, [1])
        XCTAssertTrue(model.isEmpty, "the list refreshes after a delete")
    }

    func testEmptyStateIsHonest() async throws {
        let repository = FakeMixRepository()
        let model = MixesModel(repository: repository)
        XCTAssertTrue(model.isEmpty, "no mixes yet — the honest empty state")
        XCTAssertEqual(model.summaryText, "0 mixes · 0 bytes")
    }

    func testFailedReadIsAnEmptyListNotACrash() async throws {
        let repository = ThrowingMixRepository()
        let model = MixesModel(repository: repository)
        await model.begin()
        XCTAssertTrue(model.isLoaded)
        XCTAssertTrue(model.isEmpty, "a failed read is an honest empty list (§46.2), never a crash")
    }

    /// A repository whose reads throw — the model's failure honesty.
    private struct ThrowingMixRepository: MixServicing {
        func completedMixes() async throws -> [DJMix] { throw MixError.broken }
        func mixTrackEvents(mixID: Int64) async throws -> [DJMixTrackEvent] { throw MixError.broken }
        func mixAssetURL(mixID: Int64) async throws -> URL? { throw MixError.broken }
        func updateMix(mixID: Int64, title: String, notes: String?) async throws { throw MixError.broken }
        func deleteMix(mixID: Int64) async throws { throw MixError.broken }
        func mixStorageBytes() async throws -> Int64 { throw MixError.broken }
    }

    private enum MixError: Error { case broken }
}
