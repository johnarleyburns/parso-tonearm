#if !os(watchOS)
import XCTest
import AVFoundation
@testable import TonearmCore

/// The mix decks driven offline through the real playback path (MixDeckPlayer
/// → MixEngine → AVAudioEngine in manual rendering mode).
@MainActor
final class MixDeckPlayerTests: XCTestCase {
    final class Host: MixDeckHost {
        var tracks: [(url: URL, bpm: Double)] = []
        var advanced: [(index: Int, seconds: Double)] = []
        var ended: [Int] = []
        var failures: [String] = []
        var plans: [TransitionPlan] = []
        /// Mix time (s) at which each planned blend becomes audible.
        var joins: [Double] = []
        var lastState: GridPrepState = .ready
        var states: [GridPrepState] = []
        var edge: MixDeckEdge = .blend
        weak var player: MixDeckPlayer?

        var mixDecksCurrentIndex = 0
        func mixDecksUpcomingIndex(after index: Int) -> Int? { index + 1 < tracks.count ? index + 1 : nil }

        func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)? {
            guard tracks.indices.contains(index) else { return nil }
            return (Int64(index + 1), .file(tracks[index].url, container: .auto, securityScoped: false), tracks[index].bpm)
        }

        func mixDecksDidAdvance(to index: Int, trackID: Int64, duration: Double) -> Int {
            mixDecksCurrentIndex = index
            advanced.append((index, Double(player?.masterFrame ?? 0) / MixDeckPlayer.sampleRate))
            return index
        }

        func mixDecksDidReachEnd(trackID: Int64) { ended.append(Int(trackID) - 1) }
        func mixDecksCouldNotPlay(index: Int, reason: String) { failures.append(reason) }
        func mixDecksPosition(seconds: Double) {}
        func mixDecksLoading(_ loading: Bool) {}
        func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge { edge }
        func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState) {
            lastState = state
            states.append(state)
            if let plan, plans.last != plan {
                plans.append(plan)
                joins.append((player?.scheduled?.joinFrame ?? 0) / MixDeckPlayer.sampleRate)
            }
        }
    }

    /// Renders until the last track ends (or `limit` seconds), waiting for loading
    /// and planning in between: offline, the clock stops while they run.
    private func render(_ player: MixDeckPlayer, host: Host, limit: Double,
                        into file: AVAudioFile? = nil) async throws {
        let sr = MixDeckPlayer.sampleRate
        while host.ended.isEmpty, host.failures.isEmpty, Double(player.masterFrame) < limit * sr {
            while player.isPreparing { try await Task.sleep(nanoseconds: 20_000_000) }
            guard let buffer = player.renderOffline(frames: 4_096) else { return XCTFail("render failed") }
            try file?.write(from: buffer)
        }
    }

    private func clickTrack(bpm: Double, seconds: Double) throws -> URL {
        let sr = MixDeckPlayer.sampleRate
        let frames = Int(seconds * sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let spacing = 60 / bpm * sr
        for c in 0..<2 {
            let ch = buffer.floatChannelData![c]
            for i in 0..<frames {
                let beatPhase = Double(i).truncatingRemainder(dividingBy: spacing)
                let kick = beatPhase < 2_000 ? Float(sin(2 * .pi * 55 * beatPhase / sr) * exp(-beatPhase / 600)) : 0
                ch[i] = 0.5 * kick + 0.05 * Float(sin(2 * .pi * 440 * Double(i) / sr))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixdeck-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testContainerHints() {
        XCTAssertEqual(MixTrackLoader.container(forMIME: "audio/mpeg"), .mp3)
        XCTAssertEqual(MixTrackLoader.container(forMIME: nil), .auto)
        XCTAssertEqual(MixTrackLoader.container(forExtension: "FLAC"), .flac)
        XCTAssertEqual(MixTrackLoader.fileExtension(for: .mp3), "mp3")
    }

    private func playTwoTracks(edge: MixDeckEdge, ids: (a: URL, b: URL)) async throws -> (Host, MixDeckPlayer) {
        let host = Host()
        host.edge = edge
        host.tracks = [(ids.a, 124), (ids.b, 122)]
        let player = try MixDeckPlayer(host: host, offline: true)
        host.player = player
        player.start(index: 0, at: 0, autoplay: true)
        try await render(player, host: host, limit: 120)
        return (host, player)
    }

    func testQueuePlaysThroughBothTracksOnTheDecks() async throws {
        let a = try clickTrack(bpm: 124, seconds: 12)
        let b = try clickTrack(bpm: 122, seconds: 10)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let (host, player) = try await playTwoTracks(edge: .blend, ids: (a, b))
        XCTAssertEqual(host.failures, [])
        XCTAssertEqual(host.advanced.map(\.index), [1])
        XCTAssertEqual(host.ended, [1])
        XCTAssertEqual(player.current?.index, 1)
        XCTAssertNotNil(host.plans.first)

        // The plan is in the shared cache: a second run (the preview prepared it, or this
        // queue again) plays it without planning again.
        XCTAssertNotNil(BlendPlanCache.shared.entry(from: 1, to: 2, outgoingTempo: 1))
        let (again, _) = try await playTwoTracks(edge: .blend, ids: (a, b))
        XCTAssertEqual(again.advanced.map(\.index), [1])
        XCTAssertFalse(again.states.contains(.analyzing(0.5)), "a cached plan is not planned again")
        XCTAssertEqual(again.plans.first?.style, host.plans.first?.style)
    }

    func testPlainFadeAndGaplessEdgesFollowTheOutgoingEnd() async throws {
        let a = try clickTrack(bpm: 124, seconds: 12)
        let b = try clickTrack(bpm: 122, seconds: 10)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        for edge in [MixDeckEdge.fade, .gapless] {
            let (host, _) = try await playTwoTracks(edge: edge, ids: (a, b))
            XCTAssertEqual(host.failures, [], "\(edge)")
            XCTAssertEqual(host.ended, [1], "\(edge)")
            let expected: TransitionStyle = edge == .fade ? .plainCrossfade : .gapless
            XCTAssertEqual(host.plans.last?.style, expected)
            // The next track takes over where the first one ends (12 s + the 1,024-frame lead).
            let handover = try XCTUnwrap(host.advanced.first?.seconds)
            XCTAssertEqual(handover, 12 + 1_024 / MixDeckPlayer.sampleRate, accuracy: 0.1, "\(edge)")
        }
    }

    /// A listening render of a whole mix through the playback path. Set
    /// TONEARM_MIX_RENDER to a JSON file: {"output": "mix.wav", "tracks":
    /// [{"file": "a.mp3", "bpm": 130.0}, ...]}. Skipped otherwise.
    func testListeningRender() async throws {
        guard let specPath = ProcessInfo.processInfo.environment["TONEARM_MIX_RENDER"] else {
            throw XCTSkip("TONEARM_MIX_RENDER not set")
        }
        struct Spec: Decodable {
            struct Track: Decodable { let file: String; let bpm: Double }
            let output: String
            let tracks: [Track]
        }
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
        let host = Host()
        host.tracks = spec.tracks.map { (URL(fileURLWithPath: $0.file), $0.bpm) }
        let player = try MixDeckPlayer(host: host, offline: true)
        host.player = player
        let format = AVAudioFormat(standardFormatWithSampleRate: MixDeckPlayer.sampleRate, channels: 2)!
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: spec.output), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        player.start(index: 0, at: 0, autoplay: true)
        try await render(player, host: host, limit: 3 * 3_600, into: file)
        let mmss = { (t: Double) in String(format: "%d:%04.1f", Int(t / 60), t.truncatingRemainder(dividingBy: 60)) }
        for (n, plan) in host.plans.enumerated() {
            print("blend \(n + 1) at \(mmss(host.joins[n])): \(plan.style) tempo x\(String(format: "%.4f", plan.blendRate)) gain \(String(format: "%+.1f", plan.gainMatchDB ?? 0)) dB")
        }
        for event in host.advanced { print("track \(event.index + 1) takes over at \(mmss(event.seconds)) of the mix") }
        XCTAssertEqual(host.failures, [])
        XCTAssertEqual(host.ended, [spec.tracks.count - 1])
    }
}
#endif
