import Foundation

/// The immutable, versioned origin of Starter Blend audio. Never a runtime Jamendo stream: every
/// asset is a CC0 AAC-LC M4A on a pinned GitHub Release.
public struct StarterBlendPack: Codable, Sendable, Equatable, Hashable {
    /// Stable identity of the pack as saved with a blend (`starter-blends-aac-v1`).
    public let releaseTag: String
    public let version: Int
    public let audioFormat: String

    public static let v1 = StarterBlendPack(releaseTag: "starter-blends-aac-v1", version: 1,
                                            audioFormat: "aac-lc-128k-m4a")

    /// Whether `trackID` is one of the mirrored Starter Pack assets. Only these exist on the release.
    public func contains(trackID: String) -> Bool {
        StarterBlendCatalog.starterTrackIDs.contains(trackID)
    }

    /// The release asset for a mirrored Starter track: `…/releases/download/<tag>/<trackID>.m4a`.
    /// Nil for any other catalog ID: a Starter Release URL is never built for a general catalog track.
    public func assetURL(trackID: String) -> URL? {
        guard contains(trackID: trackID) else { return nil }
        return URL(string: "https://github.com/johnarleyburns/parso-tonearm/releases/download/\(releaseTag)/\(trackID).m4a")!
    }

    /// The explicit source for a Starter track (nil when it is not a mirrored asset).
    public func locator(trackID: String) -> AudioLocator? {
        contains(trackID: trackID) ? .starterRelease(packTag: releaseTag, assetName: "\(trackID).m4a") : nil
    }

    /// Whether `url` is an asset of this pack (what the Starter path is allowed to read).
    public func owns(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix("https://github.com/johnarleyburns/parso-tonearm/releases/download/\(releaseTag)/")
    }
}

/// Facts the blender needs about a track, from the release's analysis. Time is source seconds;
/// beat `k` of the grid is at `beatPhase + k * beatPeriod`.
public struct StarterTrackFacts: Codable, Sendable, Equatable {
    public let id: String
    public let durationSeconds: Double
    public let bpm: Double
    public let beatPeriod: Double
    public let beatPhase: Double
    public let rmsDB: Double

    public func beatTime(_ beat: Int) -> Double { beatPhase + Double(beat) * beatPeriod }
}

@available(*, deprecated, renamed: "BlendEdgePlan")
public typealias StarterEdgePlan = BlendEdgePlan

/// A concrete, immutable plan for any directed blend edge (fixed, saved or catalog-derived), copied verbatim from the source-controlled
/// supplied edge plans (`StarterBlendRuntimeData`); the release carries only AAC bytes. No runtime planner exists: playback executes these values.
public struct BlendEdgePlan: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, Equatable {
        case bassSwap = "bass-swap"
        case doubleDrop = "double-drop"
        case phraseCut = "phrase-cut"
    }

    public let blendID: String
    /// 1-based edge number within the blend (edge 1 joins track 1 → 2).
    public let edge: Int
    public let outgoingTrackID: String
    public let incomingTrackID: String
    public let style: Style
    /// Incoming playback rate relative to its native tempo (matches its BPM to the outgoing's).
    public let tempo: Double
    public let overlapBeats: Int
    public var incomingGain: Double? = nil
    public var outgoingSwapBeat: Int? = nil
    public var incomingSwapBeat: Int? = nil
    /// Outgoing source seconds at which the incoming deck becomes audible.
    public var blendStartSeconds: Double? = nil
    public var swapSeconds: Double? = nil
    public var blendEndSeconds: Double? = nil
    /// Outgoing-timeline second at which the incoming track's own time 0 plays: the incoming
    /// source position at outgoing time `T` is `(T - incomingOffsetSeconds) * tempo`.
    public var incomingOffsetSeconds: Double? = nil
    /// Phrase cut: outgoing source second of the cut and incoming source second it lands on.
    public var outgoingStartSeconds: Double? = nil
    public var incomingStartSeconds: Double? = nil

    /// What the renderer needs, all in source seconds of each track.
    public struct Schedule: Equatable, Sendable {
        public let style: Style
        /// Outgoing source second where the incoming becomes audible.
        public let outgoingStart: Double
        /// Overlap length in outgoing seconds (0 for a cut).
        public let overlapSeconds: Double
        /// Seconds into the overlap where the bass swaps (nil: no swap).
        public let swapOffsetSeconds: Double?
        /// Incoming source second playing when the overlap starts.
        public let incomingStart: Double
        public let incomingTempo: Double
        public let incomingGain: Double
    }

    /// Resolves the plan from its own stored values. Nil when the plan lacks the values its
    /// style needs (a malformed plan is never silently replaced by a guess).
    public func schedule() -> Schedule? {
        switch style {
        case .phraseCut:
            guard let cut = outgoingStartSeconds, let start = incomingStartSeconds else { return nil }
            return Schedule(style: style, outgoingStart: cut, overlapSeconds: 0,
                            swapOffsetSeconds: nil, incomingStart: start,
                            incomingTempo: tempo, incomingGain: incomingGain ?? 1)
        case .bassSwap, .doubleDrop:
            guard let start = blendStartSeconds, let end = blendEndSeconds, let swap = swapSeconds,
                  let offset = incomingOffsetSeconds, end > start else { return nil }
            return Schedule(style: style, outgoingStart: start, overlapSeconds: end - start,
                            swapOffsetSeconds: min(max(swap - start, 0), end - start),
                            incomingStart: max(0, (start - offset) * tempo), incomingTempo: tempo,
                            incomingGain: incomingGain ?? 1)
        }
    }
}
