import XCTest

@testable import TonearmDJ

/// Commit S5 — `DemucsStemModel` wired to Core ML (plan `dj-stems-model.md` §6.5).
///
/// The real `.mlpackage` is not present in CI (it is a gitignored ~210 MB ODR
/// artifact), so these tests lock the model's contract **without** a model:
/// absence stays an honest nil (FR-SEM-6), a present-but-unloadable package is
/// a loud `.modelLoadFailed` (never a silent passthrough — ADR-10), and the
/// source-order mapping table is locked by name so the vocal fader can never
/// silently mute the drums.
final class DemucsStemModelTests: XCTestCase {

    /// Deterministic resource provider for macOS `swift test` (no ODR system).
    private final class FakeProvider: ModelResourceProviding, @unchecked Sendable {
        let tagFileNames: [ModelTag: String]
        private let lock = NSLock()
        private var _available: [ModelTag: Bool]
        private var _urls: [ModelTag: URL]

        init(available: [ModelTag: Bool], urls: [ModelTag: URL] = [:]) {
            self.tagFileNames = [.stems: "DemucsStems.mlpackage"]
            self._available = available
            self._urls = urls
        }

        func isAvailable(_ tag: ModelTag) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return _available[tag] ?? false
        }

        func url(for tag: ModelTag) async -> URL? { urlSync(tag) }

        private func urlSync(_ tag: ModelTag) -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard _available[tag] == true else { return nil }
            return _urls[tag]
        }

        func fetch(_ tag: ModelTag) -> AsyncStream<Double> {
            AsyncStream { continuation in continuation.finish() }
        }

        func release(_ tag: ModelTag) async {}
    }

    private func makeService(available: Bool, url: URL? = nil) -> ModelResourceService {
        let urls: [ModelTag: URL] = url.map { [.stems: $0] } ?? [:]
        return ModelResourceService(provider: FakeProvider(available: [.stems: available],
                                                           urls: urls))
    }

    // MARK: - Honest absence (the existing behaviour, re-asserted for S5)

    /// No model → `isAvailable() == false` and `separate` returns nil — the
    /// honest FR-SEM-6 absence, never an error and never a fabricated voice.
    func testAbsentModelReturnsNil() async throws {
        let model = DemucsStemModel(resource: makeService(available: false))
        let available = await model.isAvailable()
        XCTAssertFalse(available)
        let chunk = StemChunk(sampleRate: 44_100,
                              left: [Float](repeating: 0, count: 343_980),
                              right: [Float](repeating: 0, count: 343_980))
        let result = try await model.separate(chunk: chunk)
        XCTAssertNil(result, "absence is a value, never an error (FR-SEM-6)")
    }

    // MARK: - A present-but-unloadable package is loud

    /// A corrupt/unloadable package must throw `.modelLoadFailed` — never nil,
    /// which would silently degrade to the full mix and hide the broken
    /// download (ADR-10).
    func testCorruptPackageThrowsModelLoadFailed() async throws {
        // A real file that exists per ODR but is not a loadable model.
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemucsStems-corrupt-\(UUID().uuidString).bin")
        try Data("not a model".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        let model = DemucsStemModel(resource: makeService(available: true, url: bogus))
        let available = await model.isAvailable()
        XCTAssertTrue(available, "the file-path probe says present")
        let chunk = StemChunk(sampleRate: 44_100,
                              left: [Float](repeating: 0, count: 343_980),
                              right: [Float](repeating: 0, count: 343_980))
        do {
            _ = try await model.separate(chunk: chunk)
            XCTFail("an unloadable package must throw, never return nil")
        } catch StemModelError.modelLoadFailed {
            // expected — a broken download is loud
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - The source-order table

    /// The model's S axis is `['drums', 'bass', 'other', 'vocals']` — **not**
    /// `StemKind.allCases` order (`vocals, drums, bass, other`). Mapping the
    /// axes straight across would silently swap every stem: the vocal fader
    /// would mute the drums. The table is locked by name, and it must cover
    /// every stem exactly once.
    func testSourceOrderMapsByDemucsNames() {
        XCTAssertEqual(DemucsStemModel.sourceOrder, [.drums, .bass, .other, .vocals],
                       "the model's S axis is drums, bass, other, vocals (S1 §5.1)")
        XCTAssertNotEqual(DemucsStemModel.sourceOrder, StemKind.allCases,
                          "StemKind.allCases is vocals, drums, bass, other — "
                          + "a straight-across mapping would swap every stem")
        XCTAssertEqual(Set(DemucsStemModel.sourceOrder), Set(StemKind.allCases),
                       "every stem is covered exactly once")
        // The named mapping the separator's caller relies on: model source 3
        // is vocals, model source 0 is drums.
        XCTAssertEqual(DemucsStemModel.sourceOrder[3], .vocals)
        XCTAssertEqual(DemucsStemModel.sourceOrder[0], .drums)
        XCTAssertEqual(DemucsStemModel.sourceOrder[1], .bass)
        XCTAssertEqual(DemucsStemModel.sourceOrder[2], .other)
    }

    /// The wired model declares the real geometry (44 100 / 343 980) — S4's
    /// separator reads it off the seam.
    func testModelDeclaresNativeGeometry() {
        let model = DemucsStemModel(resource: makeService(available: false))
        XCTAssertEqual(model.nativeSampleRate, 44_100)
        XCTAssertEqual(model.segmentFrames, 343_980)
    }
}
