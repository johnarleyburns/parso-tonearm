import Foundation

/// The ODR tags that carry the CLAP encoders (§27.1a, FR-SEM-6).
public enum ModelTag: String, Sendable, CaseIterable {
    case clapText = "clap-text"
    case clapAudio = "clap-audio"
}

/// A snapshot of one tag's state for the UI (§41.3 / FR-SEM-6 honesty).
public struct ModelResourceState: Sendable, Equatable {
    public let tag: ModelTag
    public let isAvailable: Bool
    public let isFetching: Bool
    public let progress: Double?      // 0...1 while fetching

    public init(tag: ModelTag, isAvailable: Bool, isFetching: Bool, progress: Double?) {
        self.tag = tag
        self.isAvailable = isAvailable
        self.isFetching = isFetching
        self.progress = progress
    }
}

/// The delivery seam behind `ModelResourceService`. The production conformance
/// wraps `NSBundleResourceRequest` (iOS only); tests inject a deterministic fake,
/// since macOS `swift test` has no ODR system (plan decision 1, commit 2.1).
public protocol ModelResourceProviding: Sendable {
    /// Where each tag's model file lands once fetched (e.g. `CLAPTextEncoder.mlpackage`).
    var tagFileNames: [ModelTag: String] { get }
    /// Synchronous availability check (re-requested transparently after a purge).
    func isAvailable(_ tag: ModelTag) -> Bool
    /// On-disk URL of the model file, or nil when not available.
    func url(for tag: ModelTag) async -> URL?
    /// Begin fetching. Yields progress 0...1; the stream finishes on completion
    /// or failure. Absence is never an error (FR-SEM-6).
    func fetch(_ tag: ModelTag) -> AsyncStream<Double>
    /// Drop our retain so the system may reclaim the space (§27.1a).
    func release(_ tag: ModelTag) async
}

#if os(iOS)
/// Production ODR delivery via `NSBundleResourceRequest`. On any bundle without
/// the declared tags, resources never become available — the honest absence
/// state, never an error.
public struct BundleResourceProvider: ModelResourceProviding {
    public let tagFileNames: [ModelTag: String]
    private let state: State

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [ModelTag: NSBundleResourceRequest] = [:]
        var available: [ModelTag: Bool] = [:]
        func request(_ tag: ModelTag, tagFileNames: [ModelTag: String]) -> NSBundleResourceRequest {
            lock.lock(); defer { lock.unlock() }
            if let existing = requests[tag] { return existing }
            let request = NSBundleResourceRequest(tags: Set([tag.rawValue]))
            requests[tag] = request
            return request
        }
        func set(_ available: Bool, for tag: ModelTag) {
            lock.lock(); defer { lock.unlock() }
            self.available[tag] = available
        }
        func isAvailable(_ tag: ModelTag) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return available[tag] ?? false
        }
    }

    public init(tagFileNames: [ModelTag: String] = [
        .clapText: "CLAPTextEncoder.mlpackage",
        .clapAudio: "CLAPAudioEncoder.mlpackage",
    ]) {
        self.tagFileNames = tagFileNames
        self.state = State()
    }

    public func isAvailable(_ tag: ModelTag) -> Bool { state.isAvailable(tag) }

    public func url(for tag: ModelTag) async -> URL? {
        guard isAvailable(tag), let name = tagFileNames[tag] else { return nil }
        // ODR content is served into the main bundle on iOS; `bundleResourceURL`
        // is macOS-only, so resolve the on-disk location from the bundle.
        let path = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.main.url(forResource: path, withExtension: ext)
            ?? Bundle.main.resourceURL?.appendingPathComponent(name)
    }

    public func fetch(_ tag: ModelTag) -> AsyncStream<Double> {
        AsyncStream { continuation in
            let request = state.request(tag, tagFileNames: tagFileNames)
            continuation.yield(0.0)
            request.beginAccessingResources { error in
                if error == nil {
                    state.set(true, for: tag)
                    continuation.yield(1.0)
                } else {
                    state.set(false, for: tag)
                }
                continuation.finish()
            }
        }
    }

    public func release(_ tag: ModelTag) async {
        state.request(tag, tagFileNames: tagFileNames).endAccessingResources()
        state.set(false, for: tag)
    }
}
#else
/// No ODR system outside iOS (macOS `swift test` included) — resources are never
/// available, which is the honest FR-SEM-6 absence. Tests inject a fake provider.
public struct BundleResourceProvider: ModelResourceProviding {
    public let tagFileNames: [ModelTag: String]

    public init(tagFileNames: [ModelTag: String] = [
        .clapText: "CLAPTextEncoder.mlpackage",
        .clapAudio: "CLAPAudioEncoder.mlpackage",
    ]) {
        self.tagFileNames = tagFileNames
    }

    public func isAvailable(_ tag: ModelTag) -> Bool { false }
    public func url(for tag: ModelTag) async -> URL? { nil }
    public func fetch(_ tag: ModelTag) -> AsyncStream<Double> {
        AsyncStream { continuation in continuation.finish() }
    }
    public func release(_ tag: ModelTag) async {}
}
#endif

/// Owns model leases and surfaces honest availability (§27.1a, FR-SEM-6). A tag
/// is retained while any pipeline holds a lease; when the last lease drops the
/// provider releases it so the system may reclaim the space. A purge is detected
/// at request time and re-requested transparently — never an error, never a dialog.
public actor ModelResourceService {
    public let provider: any ModelResourceProviding

    private var leases: [ModelTag: Int] = [:]
    private let continuation: AsyncStream<ModelResourceState>.Continuation

    public init(provider: any ModelResourceProviding) {
        self.provider = provider
        let pair = AsyncStream<ModelResourceState>.makeStream()
        self.states = pair.stream
        self.continuation = pair.continuation
    }

    /// The state/progress stream (single producer; consumed by the UI's §41.3
    /// indicator or by tests). Each element is emitted by the service actor.
    public nonisolated let states: AsyncStream<ModelResourceState>

    /// Honest availability: consult the provider (a system purge is reflected at
    /// the next read, and `url`/`retain` re-request transparently).
    public func isAvailable(_ tag: ModelTag) -> Bool {
        provider.isAvailable(tag)
    }

    /// The model file URL once the tag is available. If the system purged the
    /// tag since the last check, re-request transparently. Returns nil when
    /// absent — never an error (FR-SEM-6).
    public func url(for tag: ModelTag) async -> URL? {
        if !provider.isAvailable(tag) { await fetchIfNeeded(tag) }
        guard provider.isAvailable(tag) else { return nil }
        return await provider.url(for: tag)
    }

    /// Retain a lease and make sure the tag is present. Returns whether it is
    /// available now — absence is a value, never a thrown error (FR-SEM-6).
    @discardableResult
    public func retain(_ tag: ModelTag) async -> Bool {
        leases[tag, default: 0] += 1
        if provider.isAvailable(tag) { return true }
        await fetchIfNeeded(tag)
        return provider.isAvailable(tag)
    }

    /// Drop one lease; at zero, release the tag so the system may reclaim it.
    public func release(_ tag: ModelTag) async {
        let remaining = (leases[tag] ?? 1) - 1
        if remaining <= 0 {
            leases[tag] = nil
            await provider.release(tag)
            emit(ModelResourceState(tag: tag, isAvailable: false,
                                    isFetching: false, progress: nil))
        } else {
            leases[tag] = remaining
        }
    }

    private func fetchIfNeeded(_ tag: ModelTag) async {
        guard !provider.isAvailable(tag) else { return }
        emit(ModelResourceState(tag: tag, isAvailable: false, isFetching: true, progress: nil))
        var lastProgress = 0.0
        for await progress in provider.fetch(tag) {
            lastProgress = progress
            emit(ModelResourceState(tag: tag, isAvailable: false,
                                    isFetching: true, progress: progress))
        }
        let available = provider.isAvailable(tag) || lastProgress >= 1.0
        emit(ModelResourceState(tag: tag, isAvailable: available,
                                isFetching: false, progress: available ? 1.0 : nil))
    }

    private func emit(_ state: ModelResourceState) {
        continuation.yield(state)
    }
}
