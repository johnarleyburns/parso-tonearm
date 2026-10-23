#if !os(watchOS)
import Foundation
import AudioToolbox

/// Opens the bounded range-backed deck source for a catalog track from its durable `AudioLocator`:
/// a Starter row reads only its pinned Release asset (Jamendo is never consulted); a Jamendo row
/// resolves through `JamendoLocatorResolver` (refresh when absent/expired, once after an invalid
/// locator, bounded transient backoff). Everything here runs on the open queue, never the render
/// callback, and there is no whole-file or resident-decoder fallback.
struct CatalogSourceOpener: Sendable {
    typealias RangeOpen = @Sendable (_ url: URL, _ fileType: AudioFileTypeID, _ cancellation: StarterCancellation) throws
        -> any StarterDeckSource

    var pack: StarterBlendPack = .v1
    var lookup: @Sendable (_ catalogKey: String) async -> BlendCatalogTrack?
    var resolver: JamendoLocatorResolver
    var openRange: RangeOpen
    var persist: @Sendable (_ catalogKey: String, _ url: URL, _ expiry: Date?) async -> Void

    /// The shipping wiring: the library's catalog rows, the configured Jamendo client, byte-range readers.
    static func live() -> CatalogSourceOpener {
        CatalogSourceOpener(
            lookup: { try? await LibraryStore.shared.blendCatalogTrack(key: $0) },
            resolver: .configured(),
            openRange: { url, fileType, cancellation in
                let reader = ReleaseRangeReader(url: url)
                cancellation.register { reader.cancel() }
                return try ReleaseM4ADeckSource(reader: reader, fileType: fileType)
            },
            persist: { key, url, expiry in try? await LibraryStore.shared.updateCachedLocator(key: key, url: url, expiry: expiry) })
    }

    /// Blocking entry for `StarterStreamPlayer.SourceFactory` (called on its open queue).
    func openBlocking(trackID: String, cancellation: StarterCancellation) throws -> any StarterDeckSource {
        do {
            return try Self.runBlocking(cancellation) { try await self.open(trackID: trackID, cancellation: cancellation) }
        } catch let error as ReleaseRangeError {
            throw error
        } catch is CancellationError {
            throw ReleaseRangeError.cancelled
        } catch let error as JamendoResolveError {
            switch error {
            case .refreshFailed: throw ReleaseRangeError.permanent("the stream link could not be refreshed")
            case .permanent: throw ReleaseRangeError.permanent("this track is not available to stream")
            case .transientExhausted: throw ReleaseRangeError.transient("Jamendo could not be reached")
            }
        }
    }

    func open(trackID: String, cancellation: StarterCancellation) async throws -> any StarterDeckSource {
        let (key, locator) = try await locate(trackID)
        switch locator {
        case .starterRelease:
            guard let url = pack.assetURL(for: locator) else { throw ReleaseRangeError.permanent("not a Starter asset") }
            return try await offload { try openRange(url, kAudioFileM4AType, cancellation) }
        case .jamendo:
            let refreshed = RefreshedLocator()
            var tracking = resolver
            let refresh = resolver.refresh
            tracking.refresh = { id in
                let value = try await refresh(id)
                refreshed.set(value.url, value.expiry)
                return value
            }
            let source = try await tracking.open(locator) { url in
                do { return try await offload { try openRange(url, kAudioFileMP3Type, cancellation) } }
                catch { throw Self.classify(error) }
            }
            if let value = refreshed.value { Task { await persist(key, value.url, value.expiry) } }
            return source
        }
    }

    private func locate(_ trackID: String) async throws -> (key: String, locator: AudioLocator) {
        if pack.contains(trackID: trackID) {
            let key = BlendCatalogTrack.key(pack: pack, trackID: trackID)
            // A stored row must agree; with none, the pinned asset is the only possible source.
            if let row = await lookup(key) {
                guard let locator = row.audioLocator(in: pack) else { throw ReleaseRangeError.permanent("no usable source") }
                return (key, locator)
            }
            guard let locator = pack.locator(trackID: trackID) else { throw URLError(.unsupportedURL) }
            return (key, locator)
        }
        let key = BlendCatalogTrack.jamendoKey(trackID: trackID)
        guard let row = await lookup(key), let locator = row.audioLocator(in: pack),
              case .jamendo = locator else { throw ReleaseRangeError.permanent("no usable source") }
        return (key, locator)
    }

    /// Jamendo's failures as the resolver understands them: 401/403/404/410 means the locator is stale.
    static func classify(_ error: Error) -> Error {
        guard let range = error as? ReleaseRangeError else { return error }
        switch range {
        case .cancelled: return CancellationError()
        case .transient: return JamendoLocatorFailure.transient
        case .permanent(let detail):
            let stale = ["HTTP 401", "HTTP 403", "HTTP 404", "HTTP 410"].contains { detail.contains($0) }
            return stale ? JamendoLocatorFailure.expiredOrInvalid : JamendoLocatorFailure.permanent
        }
    }

    /// Blocking range I/O runs on a GCD queue, not the cooperative pool.
    private func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func runBlocking<T: Sendable>(_ cancellation: StarterCancellation,
                                                 _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
            done.signal()
        }
        cancellation.register { task.cancel() }
        done.wait()
        return try box.take().get()
    }
}

private final class RefreshedLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (url: URL, expiry: Date?)?
    func set(_ url: URL, _ expiry: Date?) { lock.withLock { stored = (url, expiry) } }
    var value: (url: URL, expiry: Date?)? { lock.withLock { stored } }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    func set(_ value: Result<T, any Error>) { lock.withLock { result = value } }
    func take() -> Result<T, any Error> { lock.withLock { result ?? .failure(CancellationError()) } }
}
#endif
