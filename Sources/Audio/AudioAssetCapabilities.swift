import Foundation

/// Typed availability of a source for live mixing. Distinct outcomes: a supported file is never
/// marked unsupported just because a probe has not finished or the file is momentarily unreadable.
public enum AudioAssetAvailability: Equatable, Sendable {
    case available
    case preparing
    case unavailableSource
    case temporarilyUnreadable
    case unsupportedFormat
    case unknown
}

/// Where the technical facts came from.
public enum AudioAssetProvenance: String, Equatable, Sendable { case headerProbe, none }

/// The one authoritative description of an audio source for every live-mix entry point.
/// Technical fields come only from the probe; there are no stereo or DB-derived defaults.
public struct AudioAssetCapabilities: Equatable, Sendable {
    /// Opaque identity (never a title, path or URL).
    public let sourceID: String
    public let durationSeconds: Double?
    public let sampleRate: Int?
    public let channelCount: Int?
    public let container: String?
    /// Whether an active decoder/reader has been proven to support bounded random access.
    /// A FLAC SEEKTABLE does not decide this; production has no bounded decoder in use yet.
    public let boundedRandomAccessActive: Bool
    /// Measured bounded working set, only meaningful when `boundedRandomAccessActive`.
    public let measuredBoundedWorkingSetBytes: Int64?
    public let provenance: AudioAssetProvenance
    public let checkedAt: Date
    public let availability: AudioAssetAvailability

    public static func unresolved(_ id: String, _ availability: AudioAssetAvailability,
                                  at date: Date = Date()) -> AudioAssetCapabilities {
        AudioAssetCapabilities(sourceID: id, durationSeconds: nil, sampleRate: nil, channelCount: nil,
                               container: nil, boundedRandomAccessActive: false,
                               measuredBoundedWorkingSetBytes: nil, provenance: .none,
                               checkedAt: date, availability: availability)
    }

    /// Nil channel count stays nil, which makes the admission metadata invalid.
    public var admissionMetadata: TransitionTrackMetadata {
        TransitionTrackMetadata(durationSec: durationSeconds, sampleRate: sampleRate, channels: channelCount)
    }
}

/// Production owner of capability lookups. Every live-mix path asks this; it routes local files
/// through the resolver/lease (via the metadata provider) and cached/app-owned files by URL.
public final class AudioAssetCapabilityService: @unchecked Sendable {
    public static let shared = AudioAssetCapabilityService()

    public static let refreshSeconds: TimeInterval = 60
    private let provider: LocalAudioMetadataProvider
    private let lock = NSLock()
    private var known: [String: AudioAssetCapabilities] = [:]
    private var inFlight: Set<String> = []
    /// Called (on an arbitrary thread) when a probe finished with a new answer.
    public var onChange: (@Sendable () -> Void)?
    /// Number of provider lookups started; instrumentation for integration tests.
    public private(set) var lookupCount = 0

    public init(provider: LocalAudioMetadataProvider = LocalAudioMetadataProvider()) {
        self.provider = provider
    }

    public enum Target: Sendable {
        case local(Asset)
        case file(URL, key: String)
        /// Streamed and not cached: nothing local to probe.
        case remoteUncached(key: String)
    }

    /// Synchronous current answer. Starts (or refreshes) the probe in the background.
    public func capabilities(for target: Target) -> AudioAssetCapabilities {
        let id = Self.id(for: target)
        if case .remoteUncached = target { return .unresolved(id, .preparing) }
        let (current, start): (AudioAssetCapabilities?, Bool) = lock.withLock {
            let current = known[id]
            let stale = current.map { Date().timeIntervalSince($0.checkedAt) > Self.refreshSeconds } ?? true
            let start = stale && !inFlight.contains(id)
            if start { inFlight.insert(id); lookupCount += 1 }
            return (current, start)
        }
        if start {
            let provider = self.provider
            Task.detached(priority: .utility) { [weak self] in
                let outcome: LocalAudioMetadataOutcome
                switch target {
                case .local(let asset): outcome = await provider.metadata(for: asset)
                case .file(let url, let key): outcome = await provider.metadata(forFile: url, key: key)
                case .remoteUncached: return
                }
                self?.finish(id: id, outcome: outcome, container: Self.container(for: target))
            }
        }
        return current ?? .unresolved(id, .preparing)
    }

    private func finish(id: String, outcome: LocalAudioMetadataOutcome, container: String?) {
        let caps: AudioAssetCapabilities
        switch outcome {
        case .available(let m):
            caps = AudioAssetCapabilities(sourceID: id, durationSeconds: m.durationSeconds, sampleRate: m.sampleRate,
                                          channelCount: m.channelCount, container: container,
                                          boundedRandomAccessActive: false, measuredBoundedWorkingSetBytes: nil,
                                          provenance: .headerProbe, checkedAt: Date(), availability: .available)
        case .checkingDetails: caps = .unresolved(id, .preparing)
        case .temporarilyInaccessible: caps = .unresolved(id, .temporarilyUnreadable)
        case .unsupported: caps = .unresolved(id, .unsupportedFormat)
        case .resourceDenied: caps = .unresolved(id, .temporarilyUnreadable)
        }
        let changed: Bool = lock.withLock {
            inFlight.remove(id)
            let previous = known[id]
            // A transient "still checking" answer never overwrites a real one.
            if caps.availability == .preparing, previous != nil { return false }
            known[id] = caps
            return previous?.availability != caps.availability || previous?.durationSeconds != caps.durationSeconds
        }
        if changed { onChange?() }
    }

    static func id(for target: Target) -> String {
        switch target {
        case .local(let asset): asset.id.map { "asset-\($0)" } ?? "track-\(asset.trackId)"
        case .file(_, let key), .remoteUncached(let key): key
        }
    }

    static func container(for target: Target) -> String? {
        switch target {
        case .local(let asset): asset.relPath.map { ($0 as NSString).pathExtension.lowercased() }
        case .file(let url, _): url.pathExtension.lowercased()
        case .remoteUncached: nil
        }
    }

    /// Admission for the production player. Pure given capabilities and the system state.
    public static func decide(outgoing: AudioAssetCapabilities?, incoming: AudioAssetCapabilities,
                              system: TransitionSystemState = .current()) -> TransitionAdmissionDecision {
        switch incoming.availability {
        case .available: break
        case .preparing, .unknown: return .defer(reason: .preparingDetails)
        case .unavailableSource: return .gaplessFallback(reason: .unavailableSource)
        case .temporarilyUnreadable: return .defer(reason: .temporarilyUnreadable)
        case .unsupportedFormat: return .gaplessFallback(reason: .unsupportedFormat)
        }
        if let outgoing, outgoing.availability != .available { return .defer(reason: .preparingDetails) }
        return TransitionAdmissionController.decide(outgoing: outgoing?.admissionMetadata,
                                                    incoming: incoming.admissionMetadata, system: system)
    }

    /// Bytes to reserve. Conservative full-PCM estimate until a bounded decoder is actually active;
    /// only then the measured bounded working set. Nil when nothing can bound it.
    public static func reservationBytes(outgoing: AudioAssetCapabilities?, incoming: AudioAssetCapabilities) -> Int64? {
        if incoming.boundedRandomAccessActive, let bounded = incoming.measuredBoundedWorkingSetBytes, bounded > 0 {
            return bounded
        }
        return TransitionAdmissionController.estimatedPeakBytes(outgoing: outgoing?.admissionMetadata,
                                                                incoming: incoming.admissionMetadata)
    }
}
