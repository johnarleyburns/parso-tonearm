import XCTest
import AVFoundation
@testable import TonearmDJ

/// Commit 5.12 — the pure §37.4 pieces: the `MixTimeline` accumulation and its
/// pause/blip suppression, the `CueSheetBuilder` (FR-REC-4/7) and the
/// review-listen waveform accumulator (FR-REC-6).
final class MixTimelineTests: XCTestCase {

    // MARK: - MixTimeline (§37.4)

    func testRecordAppendsInOrder() {
        var timeline = MixTimeline()
        timeline.record(trackID: 1, deck: "A", startOffsetSec: 0)
        timeline.record(trackID: 2, deck: "B", startOffsetSec: 5)
        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.entries.map(\.trackID), [1, 2])
        XCTAssertEqual(timeline.entries.map(\.deck), ["A", "B"])
    }

    func testSameTrackResumeWithinTheWindowIsSuppressed() {
        var timeline = MixTimeline()
        timeline.record(trackID: 7, deck: "A", startOffsetSec: 0)
        // A pause → resume blip 2 s later is not a new play.
        timeline.record(trackID: 7, deck: "A", startOffsetSec: 2)
        XCTAssertEqual(timeline.count, 1, "a same-deck same-track blip is suppressed")
        XCTAssertEqual(timeline.entries.first?.startOffsetSec, 0)
    }

    func testGenuineReplayAfterTheWindowIsLogged() {
        var timeline = MixTimeline()
        timeline.record(trackID: 7, deck: "A", startOffsetSec: 0)
        timeline.record(trackID: 7, deck: "A", startOffsetSec: 30)
        XCTAssertEqual(timeline.count, 2,
                       "a genuine replay after the suppression window is a real 'played' (§37.4)")
    }

    func testSameTrackOnTheOtherDeckIsNotSuppressed() {
        var timeline = MixTimeline()
        timeline.record(trackID: 7, deck: "A", startOffsetSec: 0)
        timeline.record(trackID: 7, deck: "B", startOffsetSec: 1)
        XCTAssertEqual(timeline.count, 2, "the suppression is per deck")
    }

    // MARK: - CueSheetBuilder (FR-REC-4, FR-REC-7)

    func testCueSheetCarriesTitleTracklistAndAttribution() {
        let events = [
            DJMixTrackEvent(mixID: 1, trackID: 5, title: "Neon Circuit",
                            artist: "Kora Mechanism", deck: "A",
                            startOffsetSec: 0, bpmAtPlay: 124, camelotAtPlay: "8A", position: 1),
            DJMixTrackEvent(mixID: 1, trackID: 9, title: "Warehouse Line",
                            artist: "Nils Anberg", deck: "B",
                            startOffsetSec: 300, bpmAtPlay: 128, camelotAtPlay: "9A", position: 2),
        ]
        let text = CueSheetBuilder.text(title: "Friday set",
                                        recordedAtText: "14 Aug 2026, 20:00",
                                        duration: 360,
                                        formatLabel: "M4A · AAC 256 kbps",
                                        events: events,
                                        attribution: ["Kora Mechanism — Neon Circuit",
                                                      "Nils Anberg — Warehouse Line"])
        XCTAssertTrue(text.contains("Friday set"))
        XCTAssertTrue(text.contains("M4A · AAC 256 kbps"),
                      "the cue-sheet names the real format — never MP3 (FR-REC-7)")
        XCTAssertTrue(text.contains("0:00"))
        XCTAssertTrue(text.contains("5:00"))
        XCTAssertTrue(text.contains("Neon Circuit"))
        XCTAssertTrue(text.contains("Attribution:"))
        XCTAssertTrue(text.contains(CueSheetBuilder.attributionLine),
                      "the licence line (§18A.5) survives into the exported cue-sheet")
    }

    func testCueSheetTimestampFormats() {
        XCTAssertEqual(CueSheetBuilder.timestamp(0), "0:00")
        XCTAssertEqual(CueSheetBuilder.timestamp(59), "0:59")
        XCTAssertEqual(CueSheetBuilder.timestamp(600), "10:00")
        XCTAssertEqual(CueSheetBuilder.timestamp(3661), "1:01:01")
    }

    // MARK: - Review-listen waveform accumulator (FR-REC-6)

    func testWaveformAccumulatorAssignsBinsAndKeepsPeaks() {
        // 8 frames into 4 bins → 2 frames per bin.
        var accumulator = MixWaveformAccumulator(bins: 4, totalFrames: 8)
        let samples: [Float] = [0.1, 0.9, 0.2, 0.3, 0.7, 0.1, 0.5, 0.4]
        for sample in samples {
            accumulator.consume(frameValue: sample)
        }
        XCTAssertEqual(accumulator.result.count, 4)
        XCTAssertEqual(accumulator.result[0], 0.9, accuracy: 1e-6)
        XCTAssertEqual(accumulator.result[1], 0.3, accuracy: 1e-6)
        XCTAssertEqual(accumulator.result[2], 0.7, accuracy: 1e-6)
        XCTAssertEqual(accumulator.result[3], 0.5, accuracy: 1e-6)
    }

    func testWaveformAccumulatorHandlesNonIntegralBins() {
        // 10 frames into 3 bins — the boundary math must not lose or gain a bin.
        var accumulator = MixWaveformAccumulator(bins: 3, totalFrames: 10)
        for i in 0..<10 {
            accumulator.consume(frameValue: Float(i % 3) / 3 + 0.1)
        }
        XCTAssertEqual(accumulator.result.count, 3, "every bin is filled")
        XCTAssertTrue(accumulator.result.allSatisfy { $0 > 0 })
    }

    func testWaveformModelLevelReadsTheBinAtTheFraction() {
        let model = MixWaveformModel(peaks: [0.1, 0.5, 1.0, 0.25], duration: 4,
                                     sampleRate: 48_000, channelCount: 2)
        XCTAssertEqual(model.level(atFraction: 0), 0.1, accuracy: 1e-6)
        XCTAssertEqual(model.level(atFraction: 0.5), 1.0, accuracy: 1e-6)
        XCTAssertEqual(model.level(atFraction: 1.0), 0.25, accuracy: 1e-6)
        XCTAssertEqual(MixWaveformModel(peaks: [], duration: 0, sampleRate: 0, channelCount: 0)
            .level(atFraction: 0.5), 0, "an empty model reads 0, never crashes")
    }

    func testWaveformBuilderDecodesAMixAudioFile() throws {
        // A real audio file → the review-listen overview: peaks count equals
        // the requested bins, and the decoded duration matches the file. PCM
        // in a WAV keeps the write deterministic; the AAC/M4A read path is the
        // same `AVAudioFile` decoder the encoder round-trip tests already
        // prove playable.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
        let url = tmp.appendingPathComponent("mix.wav")
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<48_000 {
                let magnitude = Float(i % 2 == 0 ? 0.8 : 0.1)
                data[i] = magnitude
            }
        }
        try file.write(from: buffer)
        file.close()

        let model = try MixWaveformBuilder.build(from: url, bins: 24)
        XCTAssertEqual(model.binCount, 24)
        XCTAssertEqual(model.duration, 1.0, accuracy: 0.1)
        XCTAssertEqual(model.sampleRate, 48_000, accuracy: 1)
        XCTAssertEqual(model.channelCount, 2)
        XCTAssertTrue(model.peaks.allSatisfy { $0 >= 0 && $0 <= 1.01 },
                      "peaks are normalized magnitudes")
        XCTAssertGreaterThan(model.peaks.reduce(0, +), 1,
                             "the alternating 0.8/0.1 magnitudes survive the mono mix + peak bins")
    }
}
