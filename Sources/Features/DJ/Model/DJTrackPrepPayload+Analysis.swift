import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import TonearmCore

extension DJTrackPrepPayload {
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
                    ? analysis.waveform.bandEnergy[index]
                    : .zero
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
            sections: sections.map { ParsoAudioAnalysis.Section(start: $0.start, kind: kind($0.kind), bar: $0.bar) },
            waveform: Waveform(overviewMinMax: bins, detailRMS: rms,
                               bandEnergy: bands),
            loudness: LoudnessResult(integratedLUFS: loud[0], truePeakDBTP: loud[1],
                                     gainToTargetDB: loud[2], loudnessRangeLU: loud[3]))
    }
}
