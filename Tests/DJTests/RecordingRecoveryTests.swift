import XCTest
import AVFoundation
@testable import TonearmDJ

/// Commit 5.11 — the §37.3 journal + crash/interruption recovery + finalize
/// (plan §5 5.11, FR-REC-1/3, NFR-REL-2, FR-ENG-8, §37.3–37.5, §34A.4).
///
/// Tiers:
/// - **journal state machine**: `begin` writes the in-progress `recording`
///   row; `finalize` promotes it to `complete` with the real duration/size;
///   `reconcile` salvages a stale row to `complete` (segments joined) or
///   `corrupt` (nothing recoverable) — a crash loses at most the in-flight
///   segment (NFR-REL-2).
/// - **the joined M4A**: finalize and reconcile produce one playable
///   `mix.m4a` and delete the intermediate segments.
/// - **the interruption path**: the encoder flushes the current segment and
///   waits, then a fresh segment on resume; the workspace consumes the §34A.4
///   responses and never auto-plays.
@MainActor
final class RecordingRecoveryTests: XCTestCase {

    // MARK: - Journal state machine

    func testBeginWritesTheInProgressJournalRow() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("abc-123", isDirectory: true)

        try await service.begin(outputDirectory: sessionDir)

        let stale = try await store.staleRecordingMixes()
        XCTAssertEqual(stale.count, 1, "begin must open the §37.3 journal row")
        let mix = try XCTUnwrap(stale.first)
        XCTAssertEqual(mix.state, .recording, "the row is in-progress")
        XCTAssertEqual(mix.format, RecordingEncoder.formatName, "FR-REC-7 honest format name")
        XCTAssertEqual(mix.bitrateKbps, RecordingEncoder.bitRateKbps)
        XCTAssertEqual(mix.durationSec, 0, accuracy: 1e-9)
        XCTAssertFalse(mix.title.isEmpty, "a default title exists until the finish screen")

        let asset = try await store.mixAsset(mixID: try XCTUnwrap(mix.id))
        XCTAssertEqual(asset?.localRelPath, "abc-123/mix.m4a",
                       "the asset path is the eventual joined file, relative to the mixes root")
    }

    func testFinalizeJoinsSegmentsIntoACompleteM4A() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("rec-1", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)

        let output = try await makeRecording(segmentFrames: 12_000, outputDirectory: sessionDir)
        XCTAssertGreaterThanOrEqual(output.segmentURLs.count, 3,
                                    "~1 s at a 0.25 s budget → several flushed segments")
        let finished = try await service.finalize(output: output, journal: nil,
                                                  timeline: MixTimeline())

        let mix = try XCTUnwrap(finished)
        XCTAssertEqual(mix.state, .complete, "finalize promotes the journal row and returns the row")
        XCTAssertEqual(mix.durationSec, 1.0, accuracy: 0.15)
        XCTAssertGreaterThan(mix.sizeBytes ?? 0, 0)

        let finalURL = sessionDir.appendingPathComponent("mix.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path),
                      "the joined M4A exists — the §37.5 final artifact")
        let file = try AVAudioFile(forReading: finalURL)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.0, accuracy: 0.15)
        XCTAssertGreaterThan(try readAllFrames(file).count, 40_000,
                             "the joined M4A decodes real audio")

        let segmentsLeft = try FileManager.default.contentsOfDirectory(atPath: sessionDir.path)
            .filter { $0.hasPrefix("segment-") }
        XCTAssertTrue(segmentsLeft.isEmpty, "the intermediate segments are deleted after the join")

        let remainingStale = try await store.staleRecordingMixes()
        XCTAssertEqual(remainingStale.count, 0, "no journal row stays in-progress")
    }

    func testFinalizeExportsJournalJSONOnlyUnderUIRegression() async throws {
        let (store, root) = try makeStoreAndRoot()
        let sessionDir = root.appendingPathComponent("rec-2", isDirectory: true)

        // Without the harness flag: no JSON.
        let plain = RecordingService(store: store, mixesRoot: root)
        try await plain.begin(outputDirectory: sessionDir)
        let output = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir)
        _ = try await plain.finalize(output: output, journal: config, timeline: MixTimeline())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("mix-journal.json").path),
            "mix-journal.json is a -uiRegression hook, never written otherwise")

        // Under the flag: the self-describing engine configuration (hook 5.11).
        let uiRegression = RecordingService(store: store, mixesRoot: root,
                                            exportJournalMetadata: true)
        let sessionDir2 = root.appendingPathComponent("rec-3", isDirectory: true)
        try await uiRegression.begin(outputDirectory: sessionDir2)
        let output2 = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir2)
        _ = try await uiRegression.finalize(output: output2, journal: config,
                                            timeline: MixTimeline())

        let jsonURL = sessionDir2.appendingPathComponent("mix-journal.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let decoded = try JSONDecoder().decode(JournalPayload.self,
                                               from: Data(contentsOf: jsonURL))
        XCTAssertEqual(decoded.engine.sampleRate, 48_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(decoded.engine.limiterCeiling), 0.95, accuracy: 1e-6)
        XCTAssertEqual(decoded.engine.masterBPM, 122.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.engine.echoBeatsA, 1.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.engine.echoBeatsB, 0.5, accuracy: 1e-6)
        XCTAssertTrue(decoded.events.isEmpty)

        // The recording block: what the app believes it wrote, so the analyzer
        // can hold the file against it (§53.10's length check and its dropout
        // budget). The joined M4A is a whole second of 48 kHz audio here.
        let recording = decoded.recording
        XCTAssertEqual(Double(recording.frames) / 48_000, 1.0, accuracy: 0.15)
        XCTAssertEqual(recording.durationSeconds, Double(recording.frames) / 48_000,
                       accuracy: 1e-9, "the duration is the frames, not a second opinion")
        XCTAssertEqual(recording.droppedFrames, 1_920,
                       "the tap's dropped-frame count travels into the journal")
        XCTAssertEqual(recording.format, RecordingEncoder.formatName,
                       "the journal names the format the encoder actually produced (FR-REC-7)")
    }

    func testFinalizeWithoutAnActiveRecordingThrows() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let output = RecordingEncoder.RecordingOutput(
            outputDirectory: root, segmentURLs: [],
            totalFrames: 0, sampleRate: 48_000, channelCount: 1,
            format: RecordingEncoder.formatName)
        do {
            _ = try await service.finalize(output: output, journal: nil, timeline: MixTimeline())
            XCTFail("finalize without a begin must be the honest noActiveRecording error")
        } catch RecordingService.ServiceError.noActiveRecording {
            // expected
        }
    }

    // MARK: - §37.4 timeline persistence (plan 5.12)

    func testFinalizeWritesTheTimelineRowsWithSnapshots() async throws {
        let (store, root) = try makeStoreAndRoot()
        let trackA = try insertTrack(title: "Neon Circuit", artist: "Kora Mechanism",
                                     bpm: 124, camelot: "8A", store: store)
        let trackB = try insertTrack(title: "Warehouse Line", artist: "Nils Anberg",
                                     bpm: 128, camelot: "9A", store: store)

        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("tl-1", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)
        let output = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir)

        var timeline = MixTimeline()
        timeline.record(trackID: trackA, deck: "A", startOffsetSec: 0)
        timeline.record(trackID: trackB, deck: "B", startOffsetSec: 5)
        let finished = try await service.finalize(output: output, journal: nil, timeline: timeline)

        let mix = try XCTUnwrap(finished)
        XCTAssertEqual(mix.trackCount, 2, "the timeline's length is the mix's track count")

        let mixID = try XCTUnwrap(mix.id)
        let events = try await store.mixTrackEvents(mixID: mixID)
        XCTAssertEqual(events.map(\.title), ["Neon Circuit", "Warehouse Line"],
                       "snapshots are resolved from the DJ library at finalize (§37.4)")
        XCTAssertEqual(events.map(\.artist), ["Kora Mechanism", "Nils Anberg"])
        XCTAssertEqual(events.map(\.deck), ["A", "B"])
        XCTAssertEqual(events.map(\.startOffsetSec), [0, 5])
        XCTAssertEqual(events.map(\.bpmAtPlay), [124, 128])
        XCTAssertEqual(events.map(\.camelotAtPlay), ["8A", "9A"])
        XCTAssertEqual(events.map(\.position), [1, 2])
    }

    func testFinalizeReplacesPriorTimelineRows() async throws {
        let (store, root) = try makeStoreAndRoot()
        let track = try insertTrack(title: "Only One", artist: nil, bpm: nil, camelot: nil, store: store)
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("tl-2", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)
        let output = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir)

        var first = MixTimeline()
        first.record(trackID: track, deck: "A", startOffsetSec: 0)
        let finalized = try await service.finalize(output: output, journal: nil, timeline: first)
        let mix = try XCTUnwrap(finalized)
        let mixID = try XCTUnwrap(mix.id)

        // A re-finalize replaces the rows rather than appending (the DELETE-
        // then-INSERT convention) — the timeline and header can never disagree
        // (NFR-REL-1).
        let replaced = [
            DJMixTrackEvent(mixID: mixID, trackID: track, title: "Only One", artist: nil,
                            deck: "B", startOffsetSec: 3, bpmAtPlay: nil,
                            camelotAtPlay: nil, position: 1),
        ]
        _ = try await store.finalizeRecordingMix(mixID: mixID, durationSec: 1,
                                                 sizeBytes: 1, events: replaced)

        let events = try await store.mixTrackEvents(mixID: mixID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deck, "B")
        let offset = try XCTUnwrap(events.first?.startOffsetSec)
        XCTAssertEqual(offset, 3, accuracy: 1e-9)
    }

    // MARK: - Reconcile (crash recovery)

    func testReconcileSalvagesCrashedRecordingFromFlushedSegments() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("crashed", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)

        // Simulate a crash mid-recording: write 1 s through the encoder with a
        // 0.5 s budget, flushing once (closing a complete playable segment),
        // then abandon WITHOUT finalize. A real crash leaves the in-flight
        // segment's file incomplete — drop it, the "at most the final segment"
        // loss (NFR-REL-2). (A graceful encoder deinit would close the file,
        // which is exactly what a crash does NOT do.)
        try await writeFlushedRecording(segmentFrames: 24_000, outputDirectory: sessionDir)
        let segments = try FileManager.default.contentsOfDirectory(atPath: sessionDir.path)
            .filter { $0.hasPrefix("segment-") }
            .sorted()
        XCTAssertGreaterThanOrEqual(segments.count, 2, "the write flushed and then opened an in-flight segment")
        try FileManager.default.removeItem(at: sessionDir.appendingPathComponent(segments.last!))

        let stale = try await store.staleRecordingMixes()
        XCTAssertEqual(stale.count, 1,
                       "the abandoned recording's journal row is still in-progress")
        let recovered = try await service.reconcile()
        XCTAssertEqual(recovered.count, 1)
        guard case .salvaged(let mix) = recovered[0] else {
            return XCTFail("flushed segments must be salvaged, not marked corrupt")
        }
        XCTAssertEqual(mix.state, .complete)
        // ~0.5 s survives (the flushed segment); the in-flight 0.5 s is the
        // "at most the final segment" NFR-REL-2 loss.
        XCTAssertEqual(mix.durationSec, 0.5, accuracy: 0.1)

        let finalURL = sessionDir.appendingPathComponent("mix.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let file = try AVAudioFile(forReading: finalURL)
        XCTAssertGreaterThan(try readAllFrames(file).count, 15_000,
                             "the recovered mix decodes the flushed audio")
        let remaining = try await store.staleRecordingMixes()
        XCTAssertEqual(remaining.count, 0)
    }

    func testReconcileSalvagesAJoinedM4AWhenOnlyItSurvives() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("postjoin", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)

        // Finalize crashed after the join but before the rows committed: the
        // mix.m4a exists, the segments are already deleted, the row is still
        // `recording`. Reconcile must salvage the finished M4A directly.
        let output = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir)
        _ = try M4AJoiner.join(segmentURLs: output.segmentURLs,
                               to: sessionDir.appendingPathComponent("mix.m4a"),
                               sampleRate: 48_000, channelCount: 1)

        let recovered = try await service.reconcile()
        XCTAssertEqual(recovered.count, 1)
        guard case .salvaged(let mix) = recovered[0] else {
            return XCTFail("an existing joined M4A must be salvaged")
        }
        XCTAssertEqual(mix.durationSec, 1.0, accuracy: 0.15)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("mix.m4a").path))
    }

    func testReconcileMarksCorruptWhenNothingRecoverable() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("gone", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)
        // Nothing was ever written to the session directory.

        let recovered = try await service.reconcile()
        XCTAssertEqual(recovered.count, 1)
        guard case .corrupt = recovered[0] else {
            return XCTFail("a recording with no recoverable file must be honest corrupt")
        }
        let remaining = try await store.staleRecordingMixes()
        XCTAssertEqual(remaining.count, 0)
    }

    func testReconcileIsANoOpWhenNoStaleRows() async throws {
        let (store, root) = try makeStoreAndRoot()
        let service = RecordingService(store: store, mixesRoot: root)
        let sessionDir = root.appendingPathComponent("done", isDirectory: true)
        try await service.begin(outputDirectory: sessionDir)
        let output = try await makeRecording(segmentFrames: 24_000, outputDirectory: sessionDir)
        _ = try await service.finalize(output: output, journal: nil, timeline: MixTimeline())

        let recovered = try await service.reconcile()
        XCTAssertTrue(recovered.isEmpty, "a finished mix is not stale")
    }

    // MARK: - Interruption path (§34A.4)

    func testEncoderInterruptionFlushesThenResumesIntoANewSegment() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tap = RecordTap(sampleRate: 48_000, channelCount: 1, capacityFrames: 96_000)
        let encoder = try RecordingEncoder(tap: tap, configuration: .init(
            sampleRate: 48_000, channelCount: 1,
            segmentFrames: 48_000, // no mid-stream flush — segments split at interruption
            outputDirectory: tmp))
        try await encoder.start()

        // First half (0.25 s) → segment 0.
        try writeTone(into: tap, frames: 12_000)
        _ = try await encoder.drain(maxFrames: 8192)

        // `.began` — the current segment is flushed to a complete playable file
        // and the encoder waits (NFR-REL-2's critical line).
        try await encoder.interruptSegment()
        let drainedWhileInterrupted = try await encoder.drain(maxFrames: 8192)
        XCTAssertEqual(drainedWhileInterrupted, 0,
                       "drain waits while interrupted — nothing is written to a half-open file")

        // Second half (0.25 s) after `.ended` — goes to a NEW segment.
        try writeTone(into: tap, frames: 12_000)
        try await encoder.resumeSegment()
        _ = try await encoder.drain(maxFrames: 8192)

        let output = try await encoder.finalize()
        XCTAssertEqual(output.segmentURLs.count, 2,
                       "interrupt → flush + resume must split the recording at the interruption")
        for url in output.segmentURLs {
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(try readAllFrames(file).count, 1000,
                                 "every segment on either side of the interruption is playable")
        }
        XCTAssertEqual(output.totalFrames, 24_000, "the interruption loses no written audio")
    }

    // MARK: - Helpers

    private let config = RecordingJournalConfiguration(sampleRate: 48_000,
                                                       limiterCeiling: 0.95,
                                                       masterBPM: 122.0,
                                                       echoBeatsA: 1.0,
                                                       echoBeatsB: 0.5,
                                                       droppedFrames: 1_920)

    private func makeStoreAndRoot() throws -> (DJLibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try DJLibraryStore(path: tmp.appendingPathComponent("dj.sqlite"))
        return (store, tmp.appendingPathComponent("Mixes", isDirectory: true))
    }

    /// Insert a DJ-library track (plus a primary artist when given) directly
    /// through the pool — the snapshot the §37.4 timeline resolves at finalize.
    private func insertTrack(title: String, artist: String?,
                             bpm: Double?, camelot: String?,
                             store: DJLibraryStore) throws -> Int64 {
        let pool = store.pool
        var track = DJTrack(syncID: UUID().uuidString,
                            title: title,
                            contentHash: UUID().uuidString,
                            sortKey: title,
                            bpm: bpm,
                            camelot: camelot,
                            addedAt: Date(),
                            updatedAt: Date())
        try pool.write { db in
            try track.insert(db)
            if let artist, let trackID = track.id {
                var row = DJArtist(syncID: UUID().uuidString, name: artist,
                                   sortName: artist.lowercased(), createdAt: Date())
                try row.insert(db)
                try db.execute(sql: """
                    INSERT INTO track_artist (trackID, artistID, role, position)
                    VALUES (?, ?, 'primary', 0)
                    """, arguments: [trackID, row.id ?? 0])
            }
        }
        return track.id!
    }

    /// A ~1 s recording through the real encoder: 1 s of 440 Hz tone into the
    /// tap, drained (which flushes segments on `segmentFrames`), finalized. The
    /// returned output is what `finalize` consumes.
    private func makeRecording(segmentFrames: Int,
                               outputDirectory: URL) async throws -> RecordingEncoder.RecordingOutput {
        let tap = RecordTap(sampleRate: 48_000, channelCount: 1, capacityFrames: 96_000)
        let encoder = try RecordingEncoder(tap: tap, configuration: .init(
            sampleRate: 48_000, channelCount: 1,
            segmentFrames: segmentFrames,
            outputDirectory: outputDirectory))
        try await encoder.start()
        try writeTone(into: tap, frames: 48_000)
        while tap.availableFrames > 0 {
            _ = try await encoder.drain(maxFrames: 8192)
        }
        return try await encoder.finalize()
    }

    /// Write 1 s into the encoder, flushing at `segmentFrames`, and abandon
    /// WITHOUT finalize — the encoder's current segment stays open (a crash's
    /// in-flight segment); the flushed one is a complete playable M4A.
    private func writeFlushedRecording(segmentFrames: Int,
                                       outputDirectory: URL) async throws {
        let tap = RecordTap(sampleRate: 48_000, channelCount: 1, capacityFrames: 96_000)
        let encoder = try RecordingEncoder(tap: tap, configuration: .init(
            sampleRate: 48_000, channelCount: 1,
            segmentFrames: segmentFrames,
            outputDirectory: outputDirectory))
        try await encoder.start()
        try writeTone(into: tap, frames: 48_000)
        while tap.availableFrames > 0 {
            _ = try await encoder.drain(maxFrames: 8192)
        }
        // Deliberately no finalize() — the crash.
    }

    private func writeTone(into tap: RecordTap, frames: Int) throws {
        tap.setRecording(true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(4096))!
        let data = buffer.floatChannelData![0]
        var written = 0
        while written < frames {
            let count = min(4096, frames - written)
            for i in 0..<count {
                data[i] = 0.25 * Float(sin(2 * Double.pi * 440.0 * Double(written + i) / 48_000.0))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            tap.write(into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                      frames: count)
            written += count
        }
    }

    private func readAllFrames(_ file: AVAudioFile) throws -> [Float] {
        var out: [Float] = []
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 16_384
        var remaining = file.length
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), remaining))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            if let data = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                           count: Int(buffer.frameLength)))
            }
            remaining -= Int64(buffer.frameLength)
        }
        return out
    }

    /// The `mix-journal.json` payload shape the harness exports (hook 5.11).
    private struct JournalPayload: Codable {
        struct Engine: Codable {
            let sampleRate: Double
            let limiterCeiling: Double?
            let masterBPM: Double
            let echoBeatsA: Double
            let echoBeatsB: Double
        }
        struct Recording: Codable {
            let frames: Int64
            let durationSeconds: Double
            let droppedFrames: Int64
            let format: String
        }
        let engine: Engine
        let recording: Recording
        let events: [RecordingJournalEvent]
    }
}
