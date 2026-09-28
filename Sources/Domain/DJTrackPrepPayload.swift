import Foundation

#if canImport(Compression)
import Compression
#endif

/// Versioned, binary-property-list representation of the DJ analysis needed
/// to paint a deck before a second decode finishes. It intentionally mirrors
/// PAE's public `TrackAnalysis` without making the database target depend on
/// the analysis engine.
public struct DJTrackPrepPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let currentAlgorithmID = "pae-track-analysis-1.2"

    public struct Key: Codable, Equatable, Sendable {
        public var tonic: Int
        public var mode: String
        public var camelot: String
        public var openKey: String
        public var confidence: Double
    }

    public struct Section: Codable, Equatable, Sendable {
        public var start: Double
        public var kind: String
        public var bar: Int
    }

    public struct WaveformBin: Codable, Equatable, Sendable {
        public var min: Float
        public var max: Float
        public var rms: Float
        public var bandRMS: [Float]
    }

    public var version: Int
    public var algorithmID: String
    public var sampleRate: Double
    public var channels: Int
    public var sourceFrameCount: Int64
    public var duration: Double
    public var bpm: Double
    public var tempoConfidence: Double
    public var beatPositions: [Double]
    public var downbeatPositions: [Double]
    public var isConstantTempo: Bool
    public var key: Key
    public var sections: [Section]
    public var waveform: [WaveformBin]
    public var loudness: [Double]

    public init(version: Int = currentVersion,
                algorithmID: String = currentAlgorithmID,
                sampleRate: Double, channels: Int, sourceFrameCount: Int64,
                duration: Double, bpm: Double, tempoConfidence: Double,
                beatPositions: [Double], downbeatPositions: [Double],
                isConstantTempo: Bool, key: Key, sections: [Section],
                waveform: [WaveformBin], loudness: [Double]) {
        self.version = version
        self.algorithmID = algorithmID
        self.sampleRate = sampleRate
        self.channels = channels
        self.sourceFrameCount = sourceFrameCount
        self.duration = duration
        self.bpm = bpm
        self.tempoConfidence = tempoConfidence
        self.beatPositions = beatPositions
        self.downbeatPositions = downbeatPositions
        self.isConstantTempo = isConstantTempo
        self.key = key
        self.sections = sections
        self.waveform = waveform
        self.loudness = loudness
    }

    public var isCurrent: Bool {
        version == Self.currentVersion && algorithmID == Self.currentAlgorithmID
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let raw = try encoder.encode(self)
        #if canImport(Compression)
        return try (raw as NSData).compressed(using: .lzfse) as Data
        #else
        return raw
        #endif
    }

    public static func decoded(_ data: Data) throws -> DJTrackPrepPayload {
        #if canImport(Compression)
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        #else
        let raw = data
        #endif
        let value = try PropertyListDecoder().decode(Self.self, from: raw)
        guard value.isCurrent else { throw DJTrackPrepPayloadError.stale }
        guard value.sampleRate > 0, value.sourceFrameCount >= 0,
              value.duration >= 0, value.bpm > 0,
              value.beatPositions.allSatisfy(\.isFinite),
              value.downbeatPositions.allSatisfy(\.isFinite) else {
            throw DJTrackPrepPayloadError.invalid
        }
        return value
    }
}

public enum DJTrackPrepPayloadError: Error, Equatable, Sendable {
    case stale
    case invalid
}
