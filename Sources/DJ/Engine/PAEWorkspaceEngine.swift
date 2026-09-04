import AVFoundation
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine

// `TrackAnalysis` / `Waveform` / `KeyResult` etc. collide with TonearmDJ's own
// analysis-artifact types once both modules are in scope — pin the ones the PAE
// `Deck.load` seam wants.
typealias PAEPCMBuffer = ParsoAudioCore.PCMBuffer
typealias PAEAudioFormat = ParsoAudioCore.AudioFormat
typealias PAETrackAnalysis = ParsoAudioAnalysis.TrackAnalysis
typealias PAETempoResult = ParsoAudioAnalysis.TempoResult
typealias PAEKeyResult = ParsoAudioAnalysis.KeyResult
typealias PAEWaveform = ParsoAudioAnalysis.Waveform
typealias PAELoudnessResult = ParsoAudioCore.LoudnessResult

/// Phase 6c/6d — the `WorkspaceEngine` seam implemented over PAE's
/// `ParsoDJEngine`, replacing Tonearm's GPLv3 `PerformanceEngine`
/// (`parso-audio-engine/docs/phase6-parity.md`, "6c backlog" / "6d backlog").
///
/// This is the adapter half of the DJ-engine convergence: the control/telemetry
/// vocabulary the session view model talks to is unchanged, but every call maps
/// onto `ParsoDJEngine.DJEngine`'s `@MainActor` control objects, and the DSP
/// runs in `CParsoEngine`. As of Phase 6d this is the **only** engine — the
/// GPLv3 `PerformanceEngine` and its `-D PAE_DJ_ENGINE` coexistence flag are
/// gone (§6d).
///
/// Author decision (2026-09-03): **PAE's mixer curves are the reference.** The
/// knob→dB EQ curve here is fresh (not `ThreeBandEQ.knobToGain`), and the
/// crossfader / filter / limiter math is PAE's — the golden-audio tests are
/// re-baselined against this renderer in 6d with a written rationale, not the
/// other way round.
@MainActor
public final class PAEWorkspaceEngine: WorkspaceEngine {

    private let engine: DJEngine
    private let telemetryStream = EngineTelemetryStream()

    /// Backing PCM for each deck's full-mix source and its four stem voices —
    /// PAE's `Deck.load` / `armStems` retain the `PAEPCMBuffer`s, but the adapter
    /// keeps its own strong refs so a reload cannot free memory the render
    /// thread might still touch mid-callback (the `SourceBoxRegistry` analogue).
    private var deckBuffers: [Deck: PAEPCMBuffer] = [:]
    private var stemBuffers: [Deck: [PAEPCMBuffer]] = [:]

    /// A rotating 8-slot hot-cue map: `triggerHotCue(_:atSample:)` is
    /// sample-addressed on the seam but PAE's hot cues are index-keyed.
    private var hotCueSlots: [Deck: [Int64]] = [:]
    private var hotCueNext: [Deck: Int] = [:]

    /// Per-deck echo parameters — the seam sets them one at a time, PAE takes
    /// them together in `Deck.setEcho`.
    private struct Echo { var enabled = false; var beats = 1.0; var depth: Float = 0.5; var feedback: Float = 0.4 }
    private var echo: [Deck: Echo] = [.a: Echo(), .b: Echo()]

    // Recording (§37.2 / §34A.4).
    private var recorder: MixRecorder?
    private var recordingDir: URL?
    private var recordingSegments: [URL] = []
    private var recordingSegmentIndex = 0
    private var recordingStartSample: Int64 = 0
    private let recordingRoot: URL
    public private(set) var isRecording = false

    public init(sampleRate: Double = 48_000,
                maxFramesPerRender: Int = 128,
                recordingDirectory: URL = DJDatabase.mixesDirectory) {
        engine = DJEngine(sampleRate: sampleRate, maxFramesPerRender: maxFramesPerRender)
        recordingRoot = recordingDirectory
    }

    // MARK: - Lifecycle & graph

    public func start() throws { try engine.start() }
    public func stop() { engine.stop() }
    public var isGraphRunning: Bool { engine.isRunning }
    public func configurationChanges() -> AsyncStream<Void> { engine.configurationChanges() }
    public func recoverGraph() throws { try engine.recoverGraph() }

    // MARK: - Clock & readouts

    public var masterSample: Int64 { engine.telemetry().masterSample }
    public var sampleRate: Double { engine.sampleRate }
    public var bufferPeriodMillis: Double { engine.bufferPeriodMillis }

    public var limiterCeiling: Float? {
        guard engine.mixer.master.limiterEnabled else { return nil }
        return Float(pow(10.0, engine.mixer.master.limiterCeilingDB / 20.0))
    }

    public func deckRate(_ deck: Deck) -> Double {
        self.deck(deck).effectiveRate
    }

    // MARK: - Transport & loading

    private func deck(_ d: Deck) -> ParsoDJEngine.Deck {
        d == .a ? engine.deckA : engine.deckB
    }
    private func channel(_ d: Deck) -> Channel {
        d == .a ? engine.mixer.channelA : engine.mixer.channelB
    }

    public func load(_ deck: Deck, source: DeckSource) {
        let buffer = Self.pcmBuffer(from: source)
        let analysis = Self.trackAnalysis(from: source)
        deckBuffers[deck] = buffer
        hotCueSlots[deck] = Array(repeating: 0, count: 8)
        hotCueNext[deck] = 0
        self.deck(deck).load(analysis, buffer: buffer)
    }

    public func play(_ deck: Deck) { self.deck(deck).play() }
    public func pause(_ deck: Deck) { self.deck(deck).pause() }
    public func cue(_ deck: Deck) { self.deck(deck).cuePlayPress() }
    public func releaseCue(_ deck: Deck) { self.deck(deck).cuePlayRelease() }

    public func seek(_ deck: Deck, toSample: Int64, quantized: Bool) {
        self.deck(deck).seek(toSample: toSample, quantized: quantized)
    }

    public func setCue(_ deck: Deck, atSample: Int64) {
        self.deck(deck).setCue(atSample: atSample)
    }

    public func triggerHotCue(_ deck: Deck, atSample: Int64) {
        var slots = hotCueSlots[deck] ?? Array(repeating: 0, count: 8)
        var next = hotCueNext[deck] ?? 0
        // Reuse a slot already pointing here, else take the next in rotation.
        let slot = slots.firstIndex(of: atSample) ?? next
        slots[slot] = atSample
        next = (slot == next) ? (next + 1) % 8 : next
        hotCueSlots[deck] = slots
        hotCueNext[deck] = next
        self.deck(deck).triggerHotCue(slot, atSample: atSample)
    }

    public func setLoopRange(_ deck: Deck, start: Int64, end: Int64) {
        self.deck(deck).setLoop(startSample: start, endSample: end)
    }

    public func setLoop(_ deck: Deck, beats: Double) {
        self.deck(deck).autoBeatLoop(beats: beats)
    }

    public func exitLoop(_ deck: Deck) {
        self.deck(deck).setActiveLoop(false)
    }

    public func setQuantize(_ on: Bool, resolution: QuantizeResolution) {
        let mapped: ParsoDJEngine.QuantizeResolution
        switch resolution {
        case .halfBeat: mapped = .halfBeat
        case .beat: mapped = .beat
        case .bar: mapped = .bar
        case .fourBars: mapped = .fourBars
        }
        for d in [Deck.a, .b] {
            let dk = self.deck(d)
            dk.quantize = on
            dk.quantizeResolution = mapped
        }
    }

    // MARK: - Tempo / pitch / key

    public func setRate(_ deck: Deck, rate: Float) {
        let dk = self.deck(deck)
        dk.tempoRange = .wide
        dk.tempoPercent = (Double(rate) - 1) * 100
    }

    public func setKeyLock(_ deck: Deck, locked: Bool) {
        self.deck(deck).keyLock = locked
    }

    public func setKeyShift(_ deck: Deck, semitones: Float) {
        self.deck(deck).pitchSemitones = Double(semitones)
    }

    // MARK: - Sync (§32)

    public func sync(_ deck: Deck, to master: Deck, barSync: Bool) {
        guard deck != master else { return }
        self.deck(master).setAsMaster()
        self.deck(deck).sync(barSync: barSync)
    }

    public func unsync(_ deck: Deck) { self.deck(deck).unsync() }
    public func isSynced(_ deck: Deck) -> Bool { self.deck(deck).isSynced }

    // MARK: - Mixer (§35) — PAE curves are the reference

    /// Fresh EQ knob→dB curve (author decision: do not reuse `ThreeBandEQ`).
    /// 0 → unity, +1 → +6 dB, −1 → full kill (−∞), a smooth dB taper between.
    static func eqKnobToDB(_ knob: Float) -> Double {
        let x = Double(max(-1, min(1, knob)))
        if x >= 0 { return x * 6.0 }
        if x <= -1 + 1e-6 { return -.infinity }
        return 30.0 * x / (1.0 + x)   // x=−0.5 → −30 dB, x→−1 → −∞
    }

    public func setEQKnobs(_ deck: Deck, low: Float, mid: Float, high: Float) {
        let ch = channel(deck)
        ch.eqLow = Self.eqKnobToDB(low)
        ch.eqMid = Self.eqKnobToDB(mid)
        ch.eqHigh = Self.eqKnobToDB(high)
    }

    public func setFilter(_ deck: Deck, knob: Float) {
        let ch = channel(deck)
        ch.colorFX = .filter
        ch.colorAmount = Double(max(-1, min(1, knob)))
    }

    public func setChannelFader(_ deck: Deck, gain: Float) {
        channel(deck).fader = Double(max(0, min(1, gain)))
    }

    public func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
        engine.mixer.crossfader = Double(max(-1, min(1, position)))
        switch curve {
        case .constantPower: engine.mixer.crossfaderCurve = .smooth
        case .linear: engine.mixer.crossfaderCurve = .linear
        case .sharp: engine.mixer.crossfaderCurve = .sharp
        }
    }

    // MARK: - Beat FX — per-deck §35A echo

    private func pushEcho(_ deck: Deck) {
        let e = echo[deck] ?? Echo()
        self.deck(deck).setEcho(enabled: e.enabled, beats: e.beats,
                                depth: Double(e.depth), feedback: Double(e.feedback))
    }
    public func setEchoEnabled(_ deck: Deck, enabled: Bool) {
        echo[deck, default: Echo()].enabled = enabled; pushEcho(deck)
    }
    public func setEchoBeats(_ deck: Deck, beats: Double) {
        echo[deck, default: Echo()].beats = beats; pushEcho(deck)
    }
    public func setEchoDepth(_ deck: Deck, depth: Float) {
        echo[deck, default: Echo()].depth = depth; pushEcho(deck)
    }
    public func setEchoFeedback(_ deck: Deck, feedback: Float) {
        echo[deck, default: Echo()].feedback = feedback; pushEcho(deck)
    }

    // MARK: - Stems — per-deck 4-voice (§35.1)

    public func armStemSet(_ deck: Deck, stemSet: StemSet?) {
        guard let stemSet else {
            self.deck(deck).disarmStems()
            stemBuffers[deck] = nil
            return
        }
        var voices: [ParsoDJEngine.StemKind: PAEPCMBuffer] = [:]
        var retained: [PAEPCMBuffer] = []
        for kind in SeparationVoice.allCases {
            let buffer = Self.pcmBuffer(from: stemSet.source(kind))
            retained.append(buffer)
            if let paeKind = ParsoDJEngine.StemKind(rawValue: kind.rawValue) {
                voices[paeKind] = buffer
            }
        }
        stemBuffers[deck] = retained
        self.deck(deck).armStems(voices)
    }

    public func setStemGain(_ deck: Deck, stem: SeparationVoice, gain: Float) {
        guard let k = ParsoDJEngine.StemKind(rawValue: stem.rawValue) else { return }
        self.deck(deck).setStemGain(k, Double(gain))
    }
    public func setStemMute(_ deck: Deck, stem: SeparationVoice, muted: Bool) {
        guard let k = ParsoDJEngine.StemKind(rawValue: stem.rawValue) else { return }
        self.deck(deck).setStemMute(k, muted)
    }
    public func setStemSolo(_ deck: Deck, stem: SeparationVoice, soloed: Bool) {
        guard let k = ParsoDJEngine.StemKind(rawValue: stem.rawValue) else { return }
        self.deck(deck).setStemSolo(k, soloed)
    }

    // MARK: - Cue monitoring (§44.2a)

    public func setHeadphoneCue(_ deck: Deck, enabled: Bool) {
        channel(deck).cuePFL = enabled
    }

    public func setCueMode(_ mode: CueMode) {
        engine.monitoring.cueMode = ParsoDJEngine.CueMode(rawValue: mode.rawValue) ?? .off
    }

    // MARK: - Recording (§37.2 / §34A.4)

    public func startRecording() async throws -> URL {
        if isRecording, let dir = recordingDir { return dir }
        let dir = recordingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let segment = dir.appendingPathComponent("segment-0.m4a")
        let rec = try MixRecorder(codec: .aac(bitrate: 256_000), url: segment)
        engine.startRecording(rec)
        recorder = rec
        recordingDir = dir
        recordingSegments = [segment]
        recordingSegmentIndex = 0
        recordingStartSample = engine.telemetry().masterSample
        isRecording = true
        return dir
    }

    public func stopRecording() async throws -> RecordingEncoder.RecordingOutput? {
        guard isRecording, let dir = recordingDir else { return nil }
        try engine.stopRecording()
        let frames = max(0, engine.telemetry().masterSample - recordingStartSample)
        let output = RecordingEncoder.RecordingOutput(
            outputDirectory: dir,
            segmentURLs: recordingSegments,
            totalFrames: Int(frames),
            sampleRate: engine.sampleRate,
            channelCount: 2,
            format: "m4a")
        recorder = nil
        recordingDir = nil
        recordingSegments = []
        isRecording = false
        return output
    }

    public func interruptRecordingForInterruption() async throws {
        guard isRecording, let dir = recordingDir else { return }
        recordingSegmentIndex += 1
        let flushed = dir.appendingPathComponent("segment-\(recordingSegmentIndex).m4a")
        _ = try engine.interruptRecording(to: flushed)
        recordingSegments.append(flushed)
    }

    public func resumeRecordingFromInterruption() async throws {
        // PAE's `MixRecorder` continues into fresh chunks after a flush — the
        // new segment is opened lazily on the next drain, so there is nothing
        // to do here beyond the bookkeeping `interruptRecording` already did.
    }

    public var droppedRecordFrames: UInt64 {
        UInt64(max(0, engine.droppedRecordFrames))
    }

    // MARK: - Telemetry (§40.3)

    public var telemetry: AsyncStream<EngineTelemetry> { telemetryStream.stream }

    public func sampleTelemetry() -> EngineTelemetry {
        let stats = engine.telemetry()
        func deckRow(_ d: Deck, _ dk: ParsoDJEngine.Deck,
                     bpm: Double, phase: Double, synced: Bool, level: Float) -> EngineTelemetry.Deck {
            EngineTelemetry.Deck(
                playheadSample: Int64((dk.playhead * engine.sampleRate).rounded()),
                bpmEffective: bpm,
                phase: phase,
                level: level,
                playing: dk.isPlaying,
                synced: synced)
        }
        return EngineTelemetry(
            masterSample: stats.masterSample,
            masterBPM: stats.masterBPM,
            downbeatPhase: stats.downbeatPhase,
            deckA: deckRow(.a, engine.deckA, bpm: stats.deckEffectiveBPM.0,
                           phase: stats.deckBeatPhase.0, synced: stats.deckSynced.0,
                           level: engine.mixer.channelA.peakMeter),
            deckB: deckRow(.b, engine.deckB, bpm: stats.deckEffectiveBPM.1,
                           phase: stats.deckBeatPhase.1, synced: stats.deckSynced.1,
                           level: engine.mixer.channelB.peakMeter),
            masterLevel: engine.mixer.master.peakMeter,
            renderLoad: stats.renderLoad)
    }

    public func pushTelemetry() { telemetryStream.push(sampleTelemetry()) }

    // MARK: - DeckSource → PAE bridge

    static func pcmBuffer(from source: DeckSource) -> PAEPCMBuffer {
        let channels = max(1, source.channelCount)
        let frames = Int(max(0, source.frameCount))
        let buffer = PAEPCMBuffer(
            format: PAEAudioFormat(sampleRate: source.sampleRate, channelCount: channels),
            capacity: frames)
        guard frames > 0 else { return buffer }
        source.pcm.withMemoryRebound(to: Float.self, capacity: frames * channels) { interleaved in
            for c in 0..<channels {
                let dst = buffer.channel(c)
                for i in 0..<frames { dst[i] = interleaved[i * channels + c] }
            }
        }
        return buffer
    }

    static func trackAnalysis(from source: DeckSource) -> PAETrackAnalysis {
        let grid = source.grid
        let duration = source.sampleRate > 0 ? Double(source.frameCount) / source.sampleRate : 0
        let beatSeconds = 60.0 / max(grid.bpm, 1)
        let reference = grid.sampleRate > 0 ? grid.referenceSample / grid.sampleRate : 0
        var beats: [TimeInterval] = []
        if beatSeconds.isFinite, beatSeconds > 0, duration > 0 {
            var t = reference.truncatingRemainder(dividingBy: beatSeconds)
            if t < 0 { t += beatSeconds }
            while t <= duration { beats.append(t); t += beatSeconds }
        }
        let beatsPerBar = max(grid.beatsPerBar, 1)
        let downbeats = beats.enumerated().filter { $0.offset % beatsPerBar == 0 }.map { $0.element }
        let tempo = PAETempoResult(bpm: grid.bpm > 0 ? grid.bpm : 120,
                                   confidence: 1,
                                   beatPositions: beats,
                                   downbeatPositions: downbeats,
                                   isConstantTempo: true)
        return PAETrackAnalysis(
            format: PAEAudioFormat(sampleRate: source.sampleRate, channelCount: max(1, source.channelCount)),
            duration: duration,
            tempo: tempo,
            key: PAEKeyResult(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 0),
            sections: [],
            waveform: PAEWaveform(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: PAELoudnessResult(integratedLUFS: 0, truePeakDBTP: 0, gainToTargetDB: 0))
    }
}
