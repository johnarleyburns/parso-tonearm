import AVFoundation
import XCTest
@testable import TonearmDJ

/// §44.2a / FR-HW-3 — cue monitoring: the pure output matrices, and the
/// engine's pre-fader tap rendered offline.
///
/// The claim that matters is **pre-fader**: a cue that dies with the channel
/// fader is not a cue at all, because auditing the track whose fader is down is
/// the entire activity. That is asserted here against rendered audio, not
/// against a flag.
@MainActor
final class CueBusTests: XCTestCase {

    private let sampleRate = 48_000.0

    // MARK: - The pure matrices

    func testSplitOutputPutsMasterLeftAndCueRightInMono() {
        // Master hard-panned left, cue hard-panned right — the case that
        // proves both legs are summed rather than simply passed through.
        var master: [Float] = [1.0, 0.0, 1.0, 0.0]      // 2 frames, L=1 R=0
        let cue: [Float] = [0.0, 0.6, 0.0, 0.6]         // 2 frames, L=0 R=0.6

        CueMix.applySplitOutput(master: &master, cue: cue, frames: 2, channels: 2)

        // Master mono = (1 + 0) * 0.5; cue mono = (0 + 0.6) * 0.5.
        XCTAssertEqual(master[0], 0.5, accuracy: 1e-6, "master summed to mono on the left")
        XCTAssertEqual(master[1], 0.3, accuracy: 1e-6, "cue summed to mono on the right")
        XCTAssertEqual(master[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(master[3], 0.3, accuracy: 1e-6)
    }

    /// The −6 dB is not decoration: summing a correlated stereo pair to mono
    /// doubles it, so without the attenuation switching cue on would clip a mix
    /// that was fine a moment earlier.
    func testMonoSummingCannotClipAMixThatWasFine() {
        var master: [Float] = [0.9, 0.9]   // 1 frame, both channels near full
        let cue: [Float] = [0.9, 0.9]
        CueMix.applySplitOutput(master: &master, cue: cue, frames: 1, channels: 2)
        XCTAssertEqual(master[0], 0.9, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(abs(master[0]), 1.0)
        XCTAssertLessThanOrEqual(abs(master[1]), 1.0)
    }

    func testMultichannelKeepsBothLegsInStereo() {
        var master: [Float] = [0.5, -0.5, 0, 0]   // 1 frame, 4 channels
        let cue: [Float] = [0.25, -0.25, 0, 0]
        CueMix.applyMultichannel(master: &master, cue: cue, frames: 1, channels: 4)
        XCTAssertEqual(master[0], 0.5, accuracy: 1e-6, "master keeps 1/2 untouched")
        XCTAssertEqual(master[1], -0.5, accuracy: 1e-6)
        XCTAssertEqual(master[2], 0.25, accuracy: 1e-6, "cue lands on 3/4, still stereo")
        XCTAssertEqual(master[3], -0.25, accuracy: 1e-6)
    }

    func testCueInPlaceReplacesTheMaster() {
        var master: [Float] = [0.8, 0.8]
        let cue: [Float] = [0.2, 0.2]
        CueMix.applyCueInPlace(master: &master, cue: cue, frames: 1, channels: 2)
        XCTAssertEqual(master[0], 0.2, accuracy: 1e-6,
                       "the room hears what you are auditing — that is what 'in place' means")
    }

    // MARK: - Availability is refused, not substituted

    func testAModeThatCannotWorkIsUnavailableRatherThanApproximated() {
        XCTAssertFalse(CueMode.multichannel.isAvailable(outputChannels: 2),
                       "a 2-channel route cannot carry a separate cue leg")
        XCTAssertTrue(CueMode.multichannel.isAvailable(outputChannels: 4))
        XCTAssertTrue(CueMode.splitOutput.isAvailable(outputChannels: 2))
        XCTAssertTrue(CueMode.cueInPlace.isAvailable(outputChannels: 1),
                      "cue in place needs nothing — it is the mode of last resort")
    }

    func testEveryModeWithACostStatesIt() {
        // §44.2a: "the cost is honest and must be stated in the UI". A mode
        // whose note is missing would ship a trade the user never agreed to.
        XCTAssertNil(CueMode.off.costNote)
        for mode: CueMode in [.splitOutput, .cueInPlace, .multichannel] {
            XCTAssertNotNil(mode.costNote, "\(mode) trades something and must say what")
        }
        XCTAssertTrue(CueMode.splitOutput.costNote!.lowercased().contains("mono"),
                      "split output makes the master mono and must say so in as many words")
    }

    // MARK: - The engine: pre-fader, rendered

    /// **The claim.** Deck A's fader is at zero — silent in the master — and it
    /// is still fully present in the cue leg. A post-fader tap would give
    /// silence in both.
    func testCueIsPreFaderSoAKilledChannelIsStillAudible() throws {
        let engine = try makeStereoEngine()
        try engine.start()
        defer { engine.stop() }

        let a = TestSource(frames: 200_000, channels: 2) { _ in 0.5 }
        engine.load(.a, source: a.source)
        engine.play(.a)
        engine.setCueMode(.splitOutput)
        engine.setHeadphoneCue(.a, enabled: true)
        engine.setChannelFader(.a, gain: 0)      // the fader is all the way down
        _ = try engine.graph.render(4096)        // settle the smoothed gain

        let frames = try engine.graph.render(4096)
        let (left, right) = deinterleaved(frames)

        XCTAssertLessThan(rms(left), 0.01,
                          "the master leg is silent — the channel fader is down")
        XCTAssertGreaterThan(rms(right), 0.2,
                             "the cue leg still carries the deck: the tap is pre-fader, "
                             + "which is the whole point of a pre-listen")
    }

    /// The EQ and filter are *before* the tap, like every club mixer's PFL: a
    /// DJ setting up the incoming track's low kill wants to hear the low kill.
    func testCueHearsTheEQ() throws {
        let engine = try makeStereoEngine()
        try engine.start()
        defer { engine.stop() }

        let a = TestSource(frames: 200_000, channels: 2) { n in
            0.5 * Float(sin(2 * Double.pi * 55 * Double(n) / 48_000))
        }
        engine.load(.a, source: a.source)
        engine.play(.a)
        engine.setCueMode(.splitOutput)
        engine.setHeadphoneCue(.a, enabled: true)
        engine.setChannelFader(.a, gain: 0)
        // 4096 is the graph's maximumFrameCount — settle in two pulls, not one
        // oversized one.
        for _ in 0..<2 { _ = try engine.graph.render(4096) }
        let before = rms(deinterleaved(try engine.graph.render(4096)).right)

        engine.setEQKnobs(.a, low: -1, mid: 0, high: 0)   // kill the low band
        for _ in 0..<2 { _ = try engine.graph.render(4096) }
        let after = rms(deinterleaved(try engine.graph.render(4096)).right)

        XCTAssertLessThan(after, before * 0.2,
                          "killing LOW removes the 55 Hz tone from the cue leg too")
    }

    /// A cue mode selected but no deck cued must leave the output **bit-exact**.
    /// Otherwise choosing "split output" in settings would silently make every
    /// mix mono — a setting that degrades audio while doing nothing is the
    /// worst kind.
    func testAnEngagedModeWithNothingCuedIsBitExact() throws {
        let reference = try renderTwoDecks { _ in }
        let withMode = try renderTwoDecks { engine in
            engine.setCueMode(.splitOutput)
        }
        XCTAssertEqual(reference, withMode,
                       "no deck cued means the render path is untouched")
    }

    /// And with cue off entirely, engaging a deck's cue changes nothing either.
    func testCueOffIgnoresACuedDeck() throws {
        let reference = try renderTwoDecks { _ in }
        let cuedButOff = try renderTwoDecks { engine in
            engine.setHeadphoneCue(.a, enabled: true)   // mode stays .off
        }
        XCTAssertEqual(reference, cuedButOff)
    }

    // MARK: - Helpers

    private func makeStereoEngine() throws -> PerformanceEngine {
        try PerformanceEngine(configuration: .init(sampleRate: sampleRate, channelCount: 2,
                                                   ringCapacity: 32))
    }

    private func renderTwoDecks(_ configure: (PerformanceEngine) -> Void) throws -> [Float] {
        let engine = try makeStereoEngine()
        try engine.start()
        defer { engine.stop() }
        let a = TestSource(frames: 100_000, channels: 2) { n in
            0.4 * Float(sin(2 * Double.pi * 220 * Double(n) / 48_000))
        }
        let b = TestSource(frames: 100_000, channels: 2) { n in
            0.4 * Float(sin(2 * Double.pi * 330 * Double(n) / 48_000))
        }
        engine.load(.a, source: a.source)
        engine.load(.b, source: b.source)
        engine.play(.a)
        engine.play(.b)
        configure(engine)
        _ = try engine.graph.render(2048)
        return try engine.graph.render(4096).map { $0 }
    }

    private func deinterleaved(_ buffer: AVAudioPCMBuffer) -> (left: [Float], right: [Float]) {
        guard let data = buffer.floatChannelData else { return ([], []) }
        let n = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: data[0], count: n)),
                Array(UnsafeBufferPointer(start: data[1], count: n)))
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

private extension AVAudioPCMBuffer {
    func map(_ transform: (Float) -> Float) -> [Float] {
        guard let data = floatChannelData else { return [] }
        var out: [Float] = []
        for channel in 0..<Int(format.channelCount) {
            out += (0..<Int(frameLength)).map { transform(data[channel][$0]) }
        }
        return out
    }
}

/// A heap-backed PCM source for the offline harness.
///
/// Indexed by **frame**, not by interleaved sample: a stereo source generated
/// per sample plays every tone an octave out, which is the kind of quiet error
/// that makes a frequency assertion mean nothing.
private final class TestSource {
    let buffer: UnsafeMutablePointer<Float>
    let source: DeckSource

    init(frames: Int, channels: Int = 1, sampleRate: Double = 48_000,
         grid: DeckGrid = DeckGrid(bpm: 120, sampleRate: 48_000),
         _ generator: (Int) -> Float) {
        buffer = .allocate(capacity: frames * channels)
        for frame in 0..<frames {
            let value = generator(frame)
            for c in 0..<channels { buffer[frame * channels + c] = value }
        }
        source = DeckSource(pcm: UnsafeRawPointer(buffer), frameCount: Int64(frames),
                            channelCount: channels, sampleRate: sampleRate, grid: grid)
    }

    deinit { buffer.deallocate() }
}
