import Foundation
import ParsoAudioAnalysis
import ParsoAudioCore
import TonearmCore

/// The full-track analysis used by Mix transitions.
///
/// Keeping decode, cache validation, and payload conversion in Discovery makes
/// the transition engine usable by the library indexer and by the UI without
/// depending on the removed DJ surface.
public enum TrackGridAnalyzer {
    public struct Prepared: Sendable {
        public let buffer: PCMBuffer
        public let analysis: TrackAnalysis
        public let usedCached: Bool

        public init(buffer: PCMBuffer, analysis: TrackAnalysis, usedCached: Bool) {
            self.buffer = buffer
            self.analysis = analysis
            self.usedCached = usedCached
        }
    }

    public static func analyze(
        url: URL,
        codec: String?,
        cached: DJTrackPrepPayload? = nil,
        cachedFrameCount: Int64? = nil
    ) throws -> (payload: DJTrackPrepPayload, frameCount: Int64, usedCached: Bool) {
        let prepared = try prepare(url: url, codec: codec,
                                   cached: cached, cachedFrameCount: cachedFrameCount)
        return (DJTrackPrepPayload(analysis: prepared.analysis,
                                   sourceFrameCount: Int64(prepared.buffer.frameCount)),
                Int64(prepared.buffer.frameCount), prepared.usedCached)
    }

    /// Decode once for callers that also need the PCM buffer for playback.
    public static func prepare(
        url: URL,
        codec: String?,
        cached: DJTrackPrepPayload? = nil,
        cachedFrameCount: Int64? = nil
    ) throws -> Prepared {
        let buffer = try AudioFileReader(url: url, container: container(codec: codec, url: url)).readAll()
        let cacheMatches = cached != nil
            && cachedFrameCount == Int64(buffer.frameCount)
            && abs(cached!.sampleRate - buffer.format.sampleRate) < 0.5

        let analysis = cacheMatches ? cached!.trackAnalysis() : TrackAnalyzer().analyze(buffer)
        return Prepared(buffer: buffer, analysis: analysis, usedCached: cacheMatches)
    }

    private static func container(codec: String?, url: URL) -> AudioContainer {
        let hint = codec?.lowercased() ?? url.pathExtension.lowercased()
        if hint.contains("flac") { return .flac }
        if hint.contains("opus") { return .opus }
        if hint.contains("ogg") { return .oggVorbis }
        if hint.contains("mp3") || hint.contains("mpeg") || hint.contains("mp32") { return .mp3 }
        if hint.contains("aac") { return .aac }
        if hint.contains("m4b") { return .m4b }
        if hint.contains("m4a") || hint.contains("alac") || hint.contains("mp4") { return .m4a }
        if hint.contains("aiff") || hint == "aif" { return .aiff }
        if hint.contains("caf") { return .caf }
        if hint.contains("wav") { return .wav }

        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 12 {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return .flac }
            if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return .oggVorbis }
            if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) &&
                bytes[8..<12].elementsEqual([0x57, 0x41, 0x56, 0x45]) { return .wav }
            if bytes.starts(with: [0x63, 0x61, 0x66, 0x66]) { return .caf }
            if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) { return .aiff }
            if bytes[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70]) { return .m4a }
            if bytes.starts(with: [0x49, 0x44, 0x33]) ||
                (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return .mp3 }
        }
        return .auto
    }
}

public extension DJTrackPrepPayload {
    init(analysis: TrackAnalysis, sourceFrameCount: Int64) {
        self.init(
            sampleRate: analysis.format.sampleRate,
            channels: analysis.format.channelCount,
            sourceFrameCount: sourceFrameCount,
            duration: analysis.duration,
            bpm: analysis.tempo.bpm,
            tempoConfidence: analysis.tempo.confidence,
            beatPositions: analysis.tempo.beatPositions,
            downbeatPositions: analysis.tempo.downbeatPositions,
            isConstantTempo: analysis.tempo.isConstantTempo,
            key: .init(tonic: analysis.key.tonic,
                       mode: analysis.key.mode == .minor ? "minor" : "major",
                       camelot: analysis.key.camelot,
                       openKey: analysis.key.openKey,
                       confidence: analysis.key.confidence),
            sections: analysis.sections.map {
                .init(start: $0.start, kind: String(describing: $0.kind), bar: $0.bar)
            },
            waveform: analysis.waveform.overviewMinMax.indices.map { index in
                let pair = analysis.waveform.overviewMinMax[index]
                let bands = analysis.waveform.bandEnergy.indices.contains(index)
                    ? analysis.waveform.bandEnergy[index] : .zero
                let rms = analysis.waveform.detailRMS.indices.contains(index)
                    ? analysis.waveform.detailRMS[index] : 0
                return .init(min: pair.x, max: pair.y, rms: rms,
                             bandRMS: [bands.x, bands.y, bands.z])
            },
            loudness: [analysis.loudness.integratedLUFS,
                       analysis.loudness.truePeakDBTP,
                       analysis.loudness.gainToTargetDB,
                       analysis.loudness.loudnessRangeLU])
    }

    func trackAnalysis() -> TrackAnalysis {
        let kind: (String) -> ParsoAudioAnalysis.Section.Kind = { raw in
            switch raw {
            case "intro": return .intro
            case "buildup": return .buildup
            case "drop": return .drop
            case "verse": return .verse
            case "chorus": return .chorus
            case "breakdown": return .breakdown
            case "outro": return .outro
            default: return .unknown
            }
        }
        let bins = waveform.map { SIMD2<Float>($0.min, $0.max) }
        let rms = waveform.map(\.rms)
        let bands = waveform.map { value in
            let padded = value.bandRMS + [0, 0, 0]
            return SIMD3<Float>(padded[0], padded[1], padded[2])
        }
        let loud = loudness + [0, 0, 0, 0]
        return TrackAnalysis(
            format: AudioFormat(sampleRate: sampleRate, channelCount: channels),
            duration: duration,
            tempo: TempoResult(bpm: bpm, confidence: tempoConfidence,
                               beatPositions: beatPositions,
                               downbeatPositions: downbeatPositions,
                               isConstantTempo: isConstantTempo),
            key: KeyResult(tonic: key.tonic,
                           mode: key.mode == "minor" ? .minor : .major,
                           camelot: key.camelot, openKey: key.openKey,
                           confidence: key.confidence),
            sections: sections.map {
                ParsoAudioAnalysis.Section(start: $0.start, kind: kind($0.kind), bar: $0.bar)
            },
            waveform: Waveform(overviewMinMax: bins, detailRMS: rms,
                               bandEnergy: bands),
            loudness: LoudnessResult(integratedLUFS: loud[0], truePeakDBTP: loud[1],
                                     gainToTargetDB: loud[2], loudnessRangeLU: loud[3]))
    }
}
