import XCTest

@testable import TonearmDJ

final class ModelResourceServiceTests: XCTestCase {

    /// Deterministic provider for macOS `swift test` (no ODR system). Availability
    /// is fully scripted: fetch reports progress and succeeds unless configured
    /// to stay absent — which is the FR-SEM-6 absence shape.
    private final class FakeModelResourceProvider: ModelResourceProviding, @unchecked Sendable {
        let tagFileNames: [ModelTag: String]
        private let lock = NSLock()
        private var _available: [ModelTag: Bool]
        private var _urls: [ModelTag: URL]
        private var _progress: [ModelTag: [Double]]
        private var _fetchSucceeds: [ModelTag: Bool]
        private var _releaseCount: [ModelTag: Int]

        init(tagFileNames: [ModelTag: String] = [
            .clapText: "CLAPTextEncoder.mlpackage",
            .clapAudio: "CLAPAudioEncoder.mlpackage",
        ],
             available: [ModelTag: Bool],
             urls: [ModelTag: URL] = [:],
             progress: [ModelTag: [Double]] = [:],
             fetchSucceeds: [ModelTag: Bool] = [:]) {
            self.tagFileNames = tagFileNames
            self._available = available
            self._urls = urls
            self._progress = progress
            self._fetchSucceeds = fetchSucceeds
            self._releaseCount = [:]
        }

        func setAvailable(_ tag: ModelTag, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            _available[tag] = value
        }

        func setURL(_ tag: ModelTag, _ url: URL?) {
            lock.lock(); defer { lock.unlock() }
            _urls[tag] = url
        }

        func releaseCount(_ tag: ModelTag) -> Int {
            lock.lock(); defer { lock.unlock() }
            return _releaseCount[tag] ?? 0
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
            AsyncStream { continuation in
                let config = fetchConfig(tag)
                for p in config.progress { continuation.yield(p) }
                if config.succeeds { self.setAvailable(tag, true) }
                continuation.finish()
            }
        }

        private func fetchConfig(_ tag: ModelTag) -> (progress: [Double], succeeds: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (_progress[tag] ?? [], _fetchSucceeds[tag] ?? true)
        }

        func release(_ tag: ModelTag) async { releaseSync(tag) }

        private func releaseSync(_ tag: ModelTag) {
            lock.lock(); defer { lock.unlock() }
            _releaseCount[tag, default: 0] += 1
            _available[tag] = false
        }
    }

    /// Runs `body` while collecting every state the service emits.
    private func collect(_ service: ModelResourceService,
                         while body: () async -> Void) async -> [ModelResourceState] {
        let stream = service.states
        let collector = Task { () -> [ModelResourceState] in
            var states: [ModelResourceState] = []
            for await state in stream { states.append(state) }
            return states
        }
        await body()
        collector.cancel()
        return await collector.value
    }

    func testAbsentTagIsHonestNeverAnError() async throws {
        let provider = FakeModelResourceProvider(
            available: [.clapText: false, .clapAudio: true],
            urls: [.clapAudio: URL(fileURLWithPath: "/tmp/CLAPAudioEncoder.mlpackage")],
            progress: [.clapText: [0.25, 0.75]],
            fetchSucceeds: [.clapText: false])
        let service = ModelResourceService(provider: provider)

        let states = await collect(service) {
            let ok = await service.retain(.clapText)
            XCTAssertFalse(ok, "absent tag -> retain reports unavailable (never throws)")
            let url = await service.url(for: .clapText)
            XCTAssertNil(url)
        }
        let absent = await service.isAvailable(.clapText)
        XCTAssertFalse(absent)
        let sawProgress = states.contains { $0.tag == .clapText && $0.progress == 0.75 }
        XCTAssertTrue(sawProgress, "absence still surfaces download progress honestly")
        let finalStates = states.filter { $0.tag == .clapText && !$0.isFetching }
        XCTAssertTrue(finalStates.allSatisfy { !$0.isAvailable })
    }

    func testLeaseReleaseAndURL() async throws {
        let modelURL = URL(fileURLWithPath: "/tmp/CLAPAudioEncoder.mlpackage")
        let provider = FakeModelResourceProvider(
            available: [.clapText: false, .clapAudio: true],
            urls: [.clapAudio: modelURL])
        let service = ModelResourceService(provider: provider)

        let ok = await service.retain(.clapAudio)
        XCTAssertTrue(ok)
        let url = await service.url(for: .clapAudio)
        XCTAssertEqual(url, modelURL)

        await service.release(.clapAudio)
        XCTAssertEqual(provider.releaseCount(.clapAudio), 1)
        let released = await service.isAvailable(.clapAudio)
        XCTAssertFalse(released)
    }

    func testFetchProgressIsStreamed() async throws {
        let provider = FakeModelResourceProvider(
            available: [:],
            urls: [.clapText: URL(fileURLWithPath: "/tmp/CLAPTextEncoder.mlpackage")],
            progress: [.clapText: [0.0, 0.5, 1.0]])
        let service = ModelResourceService(provider: provider)

        let states = await collect(service) {
            let ok = await service.retain(.clapText)
            XCTAssertTrue(ok)
        }
        let clap = states.filter { $0.tag == .clapText }
        XCTAssertTrue(clap.contains { $0.isFetching && $0.progress == 0.0 })
        XCTAssertTrue(clap.contains { $0.isFetching && $0.progress == 0.5 })
        XCTAssertTrue(clap.contains { $0.isFetching && $0.progress == 1.0 })
        XCTAssertTrue(clap.contains { !$0.isFetching && $0.isAvailable })
    }

    func testPurgeIsReRequestedTransparently() async throws {
        let modelURL = URL(fileURLWithPath: "/tmp/CLAPAudioEncoder.mlpackage")
        let provider = FakeModelResourceProvider(
            available: [.clapAudio: true],
            urls: [.clapAudio: modelURL])
        let service = ModelResourceService(provider: provider)

        let purgedURL = await service.url(for: .clapAudio)
        XCTAssertEqual(purgedURL, modelURL)

        // System evicts the tag while we hold a lease.
        provider.setAvailable(.clapAudio, false)

        let states = await collect(service) {
            let url = await service.url(for: .clapAudio)
            XCTAssertEqual(url, modelURL, "purge re-requested transparently, never a dialog")
        }
        XCTAssertTrue(states.contains { $0.tag == .clapAudio && $0.isFetching })
        XCTAssertTrue(states.contains { $0.tag == .clapAudio && $0.isAvailable })
    }
}
