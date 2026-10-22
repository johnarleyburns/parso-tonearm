import Foundation

/// Immutable musical facts admitted to the blend catalog.  Playback never
/// promotes an unknown track: only a record tied to the exact asset revision
/// may participate in a planned edge.
public struct BlendCatalogTrack: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case unindexed, analyzing, blendEligible }
    public struct Analysis: Codable, Sendable, Equatable {
        public var version: Int
        public var assetRevision: String
        public var bpm: Double
        public var camelotKey: String
        public var subgenre: String
        public var loudnessDB: Double
        public var beatPhaseSeconds: Double
        public var phraseStarts: [Double]
        public var entryWindows: [Double]
        public var exitWindows: [Double]
        public init(version: Int, assetRevision: String, bpm: Double, camelotKey: String,
                    subgenre: String, loudnessDB: Double, beatPhaseSeconds: Double,
                    phraseStarts: [Double], entryWindows: [Double], exitWindows: [Double]) {
            self.version = version; self.assetRevision = assetRevision; self.bpm = bpm
            self.camelotKey = camelotKey; self.subgenre = subgenre; self.loudnessDB = loudnessDB
            self.beatPhaseSeconds = beatPhaseSeconds; self.phraseStarts = phraseStarts
            self.entryWindows = entryWindows; self.exitWindows = exitWindows
        }
        public var isComplete: Bool { version > 0 && !assetRevision.isEmpty && bpm > 0 && !camelotKey.isEmpty
            && !subgenre.isEmpty && !phraseStarts.isEmpty && !entryWindows.isEmpty && !exitWindows.isEmpty }
    }
    public var id: String
    public var source: BlendDocument.SourceIdentity
    public var state: State
    public var analysis: Analysis?
    public init(id: String, source: BlendDocument.SourceIdentity, state: State, analysis: Analysis? = nil) {
        self.id = id; self.source = source; self.state = state; self.analysis = analysis
    }
    public var isBlendEligible: Bool { state == .blendEligible && analysis?.isComplete == true }
}

/// A recipe makes a blend unique.  It references catalog analyses rather than
/// embedding PCM or an expiring URL; MixDeck only has to fetch/decode the
/// scheduled byte ranges and render this edge.
public struct CatalogEdgePlan: Codable, Sendable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, fromCatalogTrackID, toCatalogTrackID, analysisVersion, style, outgoingPhraseSeconds
        case incomingPhraseSeconds, overlapBeats, blendStartSeconds, swapSeconds, blendEndSeconds
        case incomingOffsetSeconds, tempo, incomingGain
    }
    public var id: UUID
    public var fromCatalogTrackID: String
    public var toCatalogTrackID: String
    public var analysisVersion: Int
    public var style: String
    public var outgoingPhraseSeconds: Double
    public var incomingPhraseSeconds: Double
    public var overlapBeats: Int
    /// Times are in their respective source tracks. These are the complete
    /// render recipe, so playback never re-analyses or whole-decodes a track.
    public var blendStartSeconds: Double
    public var swapSeconds: Double
    public var blendEndSeconds: Double
    public var incomingOffsetSeconds: Double
    public var tempo: Double
    public var incomingGain: Double
    public init(id: UUID = UUID(), fromCatalogTrackID: String, toCatalogTrackID: String,
                analysisVersion: Int, style: String, outgoingPhraseSeconds: Double,
                incomingPhraseSeconds: Double, overlapBeats: Int,
                blendStartSeconds: Double = 0, swapSeconds: Double = 0,
                blendEndSeconds: Double = 0, incomingOffsetSeconds: Double = 0,
                tempo: Double = 1, incomingGain: Double = 1) {
        self.id = id; self.fromCatalogTrackID = fromCatalogTrackID; self.toCatalogTrackID = toCatalogTrackID
        self.analysisVersion = analysisVersion; self.style = style; self.outgoingPhraseSeconds = outgoingPhraseSeconds
        self.incomingPhraseSeconds = incomingPhraseSeconds; self.overlapBeats = overlapBeats
        self.blendStartSeconds = blendStartSeconds; self.swapSeconds = swapSeconds
        self.blendEndSeconds = blendEndSeconds; self.incomingOffsetSeconds = incomingOffsetSeconds
        self.tempo = tempo; self.incomingGain = incomingGain
    }

    /// Recipes saved during the schema introduction carried only phrase anchors.
    /// They remain readable but are intentionally not renderable until re-planned.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fromCatalogTrackID = try values.decode(String.self, forKey: .fromCatalogTrackID)
        toCatalogTrackID = try values.decode(String.self, forKey: .toCatalogTrackID)
        analysisVersion = try values.decode(Int.self, forKey: .analysisVersion)
        style = try values.decode(String.self, forKey: .style)
        outgoingPhraseSeconds = try values.decode(Double.self, forKey: .outgoingPhraseSeconds)
        incomingPhraseSeconds = try values.decode(Double.self, forKey: .incomingPhraseSeconds)
        overlapBeats = try values.decode(Int.self, forKey: .overlapBeats)
        blendStartSeconds = try values.decodeIfPresent(Double.self, forKey: .blendStartSeconds) ?? -1
        swapSeconds = try values.decodeIfPresent(Double.self, forKey: .swapSeconds) ?? -1
        blendEndSeconds = try values.decodeIfPresent(Double.self, forKey: .blendEndSeconds) ?? -1
        incomingOffsetSeconds = try values.decodeIfPresent(Double.self, forKey: .incomingOffsetSeconds) ?? -1
        tempo = try values.decodeIfPresent(Double.self, forKey: .tempo) ?? 0
        incomingGain = try values.decodeIfPresent(Double.self, forKey: .incomingGain) ?? 0
    }

    public var isRenderable: Bool {
        analysisVersion > 0 && overlapBeats > 0 && blendStartSeconds >= 0 && swapSeconds >= blendStartSeconds
            && blendEndSeconds >= swapSeconds && incomingOffsetSeconds >= 0 && tempo.isFinite && tempo > 0
            && incomingGain.isFinite && incomingGain > 0
    }
}
