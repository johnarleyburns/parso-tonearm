import XCTest
import ParsoAudioCore
import ParsoDJEngine

@testable import TonearmDJ

/// Phase 6c — the `WorkspaceEngine` seam implemented over PAE's `ParsoDJEngine`.
/// These pin the adapter's control-mapping and value bridges; the golden-audio
/// re-baseline against the PAE renderer is 6d work (see
/// `parso-audio-engine/docs/phase6-parity.md`).
@MainActor
final class PAEWorkspaceEngineTests: XCTestCase {

    private func makeSource(frames: Int = 4_800, bpm: Double = 120,
                            channels: Int = 2, sampleRate: Double = 48_000)
        -> (DeckSource, UnsafeMutableRawPointer) {
        let count = frames * channels
        let pcm = UnsafeMutableRawPointer.allocate(byteCount: count * MemoryLayout<Float>.stride,
                                                   alignment: MemoryLayout<Float>.alignment)
        let floats = pcm.bindMemory(to: Float.self, capacity: count)
        for i in 0..<frames {
            let s = Float(sin(2 * .pi * 440 * Double(i) / sampleRate))
            for c in 0..<channels { floats[i * channels + c] = s }
        }
        let grid = DeckGrid(referenceSample: 0, bpm: bpm, beatsPerBar: 4, sampleRate: sampleRate)
        let source = DeckSource(pcm: UnsafeRawPointer(pcm), frameCount: Int64(frames),
                                channelCount: channels, sampleRate: sampleRate, grid: grid)
        return (source, pcm)
    }

    func testConformsAndAcceptsControlCallsWithoutGraph() throws {
        let engine: any WorkspaceEngine = PAEWorkspaceEngine()
        let (source, pcm) = makeSource()
        defer { pcm.deallocate() }

        engine.load(.a, source: source)
        engine.setCrossfader(0.25, curve: .constantPower)
        engine.setEQKnobs(.a, low: -1, mid: 0, high: 1)
        engine.setFilter(.a, knob: 0.5)
        engine.setChannelFader(.a, gain: 0.8)
        engine.setKeyLock(.a, locked: true)
        engine.setCueMode(.splitOutput)
        engine.setQuantize(true, resolution: .halfBeat)

        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.sampleRate, 48_000)
        XCTAssertGreaterThan(engine.bufferPeriodMillis, 0)
    }

    func testEQKnobCurveKillsAtMinusOneAndUnityAtZero() {
        XCTAssertEqual(PAEWorkspaceEngine.eqKnobToDB(0), 0, accuracy: 1e-9)
        XCTAssertEqual(PAEWorkspaceEngine.eqKnobToDB(1), 6, accuracy: 1e-9)
        XCTAssertEqual(PAEWorkspaceEngine.eqKnobToDB(-0.5), -30, accuracy: 1e-6)
        XCTAssertEqual(PAEWorkspaceEngine.eqKnobToDB(-1), -.infinity)
    }

    func testDeckSourceBridgeDeinterleavesAndBuildsGrid() {
        let (source, pcm) = makeSource(frames: 9_600, bpm: 128)
        defer { pcm.deallocate() }
        let buffer = PAEWorkspaceEngine.pcmBuffer(from: source)
        XCTAssertEqual(buffer.frameCount, 9_600)
        XCTAssertEqual(buffer.channelCount, 2)

        let analysis = PAEWorkspaceEngine.trackAnalysis(from: source)
        XCTAssertEqual(analysis.tempo.bpm, 128, accuracy: 1e-9)
        XCTAssertFalse(analysis.tempo.beatPositions.isEmpty)
        // 128 BPM ⇒ 0.46875 s/beat; first downbeat at 0, spacing = 4 beats.
        XCTAssertEqual(analysis.tempo.downbeatPositions.first ?? -1, 0, accuracy: 1e-6)
    }

    /// Tonearm's `SeparationVoice` and PAE's `ParsoDJEngine.StemKind` are bridged by
    /// `rawValue` string, not a switch (`armStemSet`/`setStemGain`/…) — a
    /// rename on either side would silently drop a voice. Pin the round-trip
    /// for all four cases (Phase 6d, `parso-audio-engine/docs/phase6-parity.md`,
    /// "6c — carried into 6d" item 5).
    func testStemKindRawValueRoundTripsWithPAE() {
        for kind in TonearmDJ.SeparationVoice.allCases {
            let mapped = ParsoDJEngine.StemKind(rawValue: kind.rawValue)
            XCTAssertNotNil(mapped, "Tonearm's \(kind) must map onto a PAE SeparationVoice by rawValue")
            XCTAssertEqual(mapped?.rawValue, kind.rawValue)
        }
        XCTAssertEqual(TonearmDJ.SeparationVoice.allCases.count, ParsoDJEngine.StemKind.allCases.count,
                       "both sides must enumerate exactly the same four voices")
    }

    func testTelemetrySnapshotIsFinite() {
        let engine = PAEWorkspaceEngine()
        let t = engine.sampleTelemetry()
        XCTAssertTrue(t.renderLoad.isFinite)
        XCTAssertTrue(t.deckA.bpmEffective.isFinite)
        XCTAssertFalse(t.deckA.playing)
    }
}
