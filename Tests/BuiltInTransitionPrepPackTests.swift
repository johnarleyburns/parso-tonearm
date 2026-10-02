import XCTest
@testable import TonearmCore

/// The shipped transition-prep pack must reproduce what the phone would have computed: exact key,
/// tempo, sections and loudness, beats to 0.1 ms, a faithful waveform.
final class BuiltInTransitionPrepPackTests: XCTestCase {
    private func payload(bins: Int = 2_000, duration: Double = 210) -> DJTrackPrepPayload {
        let beats = (0..<420).map { 0.317 + Double($0) * (60.0 / 121.37) }
        let waveform = (0..<bins).map { index -> DJTrackPrepPayload.WaveformBin in
            let level = Float(index) / Float(bins)
            return .init(min: -level, max: level * 0.9, rms: level * level * 0.5,
                         bandRMS: [level * 0.3, level * 0.2, level * 0.1])
        }
        return DJTrackPrepPayload(
            sampleRate: 44_100, channels: 2, sourceFrameCount: 9_261_000, duration: duration, bpm: 121.37,
            tempoConfidence: 0.83, beatPositions: beats, downbeatPositions: stride(from: 0, to: beats.count, by: 4).map { beats[$0] },
            isConstantTempo: true,
            key: .init(tonic: 9, mode: "minor", camelot: "8A", openKey: "1m", confidence: 0.71),
            sections: [.init(start: 0.317, kind: "intro", bar: 0), .init(start: 32.1, kind: "drop", bar: 16)],
            waveform: waveform, loudness: [-9.4, -0.8, -4.6, 6.1])
    }

    func testFullPackRoundTrips() throws {
        let original = payload()
        let decoded = try XCTUnwrap(BuiltInTransitionPrepPack.decode(
            BuiltInTransitionPrepPack.encode([("jamendo-1", original)], coarseWaveform: false))["jamendo-1"])
        XCTAssertEqual(decoded.algorithmID, original.algorithmID)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.bpm, original.bpm)
        XCTAssertEqual(decoded.key, original.key.with(confidence: Double(Float(original.key.confidence))))
        XCTAssertEqual(decoded.sourceFrameCount, original.sourceFrameCount)
        XCTAssertEqual(decoded.loudness, original.loudness)
        XCTAssertEqual(decoded.sections.map(\.kind), ["intro", "drop"])
        XCTAssertEqual(decoded.beatPositions.count, original.beatPositions.count)
        for (a, b) in zip(decoded.beatPositions, original.beatPositions) { XCTAssertEqual(a, b, accuracy: 0.000_051) }
        for (a, b) in zip(decoded.downbeatPositions, original.downbeatPositions) { XCTAssertEqual(a, b, accuracy: 0.000_051) }
        XCTAssertEqual(decoded.waveform.count, original.waveform.count)
        for (a, b) in zip(decoded.waveform, original.waveform) {
            XCTAssertEqual(a.max, b.max, accuracy: 0.0001)
            XCTAssertEqual(a.rms, b.rms, accuracy: 0.0005)
        }
    }

    func testIPhonePackKeepsOneWaveformBinPerSecondAndIsSmall() throws {
        let entries = (0..<50).map { ("track-\($0)", payload()) }
        let full = try BuiltInTransitionPrepPack.encode(entries, coarseWaveform: false)
        let coarse = try BuiltInTransitionPrepPack.encode(entries, coarseWaveform: true)
        let decoded = try BuiltInTransitionPrepPack.decode(coarse)
        XCTAssertEqual(decoded.count, 50)
        XCTAssertEqual(decoded["track-0"]?.waveform.count, 210)
        XCTAssertLessThan(coarse.count, full.count / 4)
        XCTAssertLessThan(coarse.count / 50, 4_000, "an iPhone pack entry should be a few KB")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try BuiltInTransitionPrepPack.decode(Data([1, 2, 3])))
    }
}

private extension DJTrackPrepPayload.Key {
    func with(confidence: Double) -> Self {
        var copy = self
        copy.confidence = confidence
        return copy
    }
}
