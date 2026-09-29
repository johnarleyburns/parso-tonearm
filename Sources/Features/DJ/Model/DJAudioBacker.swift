import AVFoundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import TonearmCore
import TonearmDiscovery
@MainActor
final class DJAudioBacker {
    // Internal for DJAudioBacker+Source, which owns source resolution helpers.
    let engine = DJEngine(sampleRate: 48_000, maxFramesPerRender: 512,
                                  deckCount: 2, profile: .full)
    private let splitLeftRouter = DJMasterOutputRouter(mode: .splitLeft)
    private let splitRightRouter = DJMasterOutputRouter(mode: .splitRight)
    private var prepared: [DJDeckID: PreparedDJTrack] = [:]
    private var recorder: MixRecorder?
    private var bassBlend = 0.5
    private var lowEQ: [DJDeckID: Double] = [.a: 0.5, .b: 0.5]

    struct PreparedDJTrack: Sendable {
        let buffer: PCMBuffer
        let analysis: TrackAnalysis
        let usedCached: Bool
    }
    nonisolated static func prepare(url: URL, codec: String?,
                                    cachedAnalysis: TrackAnalysis? = nil,
                                    cachedFrameCount: Int64? = nil,
                                    onWaveform: @escaping @Sendable ([WaveformBin]) -> Void = { _ in }) throws -> PreparedDJTrack {
        let buffer = try AudioFileReader(url: url, container: container(codec: codec, url: url)).readAll()
        let cacheMatches = cachedAnalysis != nil
            && cachedFrameCount == Int64(buffer.frameCount)
            && abs(cachedAnalysis!.format.sampleRate - buffer.format.sampleRate) < 0.5
        if !cacheMatches {
            let preview = WaveformGenerator().generate(buffer, overviewBuckets: 512)
            onWaveform(Self.waveformBins(preview))
        }
        let analysis = cacheMatches ? cachedAnalysis! : TrackAnalyzer().analyze(buffer)
        return PreparedDJTrack(buffer: buffer, analysis: analysis, usedCached: cacheMatches)
    }

    nonisolated private static func waveformBins(_ waveform: Waveform) -> [WaveformBin] {
        waveform.overviewMinMax.indices.map { index in
            let bands = waveform.bandEnergy.indices.contains(index) ? waveform.bandEnergy[index] : .zero
            let rms = waveform.detailRMS.indices.contains(index) ? waveform.detailRMS[index] : 0
            return WaveformBin(min: waveform.overviewMinMax[index].x,
                               max: waveform.overviewMinMax[index].y,
                               rms: rms, bandRMS: [bands.x, bands.y, bands.z])
        }
    }

    private nonisolated static func container(codec: String?, url: URL) -> AudioContainer {
        let value = DJLoadSourcePolicy.containerHint(codec: codec, sourceURL: url) ?? ""
        if value.contains("flac") { return .flac }
        if value.contains("opus") { return .opus }
        if value.contains("ogg") { return .oggVorbis }
        if value.contains("mp3") || value.contains("mpeg") || value.contains("mp32") { return .mp3 }
        if value.contains("aac") { return .aac }
        if value.contains("m4b") { return .m4b }
        if value.contains("m4a") || value.contains("alac") || value.contains("mp4") { return .m4a }
        if value.contains("aiff") || value == "aif" { return .aiff }
        if value.contains("caf") { return .caf }
        if value.contains("wav") { return .wav }

        // AudioCache stores complete remote blobs without an extension. A
        // signature probe is the final fallback for imported rows whose
        // metadata was incomplete at ingestion time.
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 12 {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return .flac }
            if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return .oggVorbis }
            if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && bytes[8..<12].elementsEqual([0x57, 0x41, 0x56, 0x45]) { return .wav }
            if bytes.starts(with: [0x63, 0x61, 0x66, 0x66]) { return .caf }
            if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) { return .aiff }
            if bytes[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70]) { return .m4a }
            if bytes.starts(with: [0x49, 0x44, 0x33]) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return .mp3 }
        }
        return .auto
    }

    func load(_ track: PreparedDJTrack, analysis: TrackAnalysis? = nil, deck: DJDeckID) throws {
        if !engine.isRunning { try start() }
        let index = deck == .a ? 0 : 1
        let selectedAnalysis = analysis ?? track.analysis
        engine.decks[index].load(selectedAnalysis, buffer: track.buffer)
        engine.decks[index].tempoRange = .wide
        prepared[deck] = PreparedDJTrack(buffer: track.buffer, analysis: selectedAnalysis,
                                         usedCached: track.usedCached)
        restoreHotCues(deck)
    }

    func waveform(for deck: DJDeckID) -> [WaveformBin] {
        guard let waveform = prepared[deck]?.analysis.waveform else { return [] }
        return waveform.overviewMinMax.indices.map { index in
            let bands = waveform.bandEnergy.indices.contains(index) ? waveform.bandEnergy[index] : .zero
            let rms = waveform.detailRMS.indices.contains(index) ? waveform.detailRMS[index] : 0
            return WaveformBin(min: waveform.overviewMinMax[index].x,
                               max: waveform.overviewMinMax[index].y,
                               rms: rms,
                               bandRMS: [bands.x, bands.y, bands.z])
        }
    }

    func play(deck: DJDeckID, position: Double, rate: Double) {
        if !engine.isRunning { try? start() }
        let player = engine.decks[index(for: deck)]
        setRate(deck: deck, rate: rate)
        if abs(player.playhead - position) > 0.02 { seek(deck: deck, position: position) }
        player.play()
    }

    func pause(deck: DJDeckID) { engine.decks[index(for: deck)].pause() }

    func pollEvents() { engine.pollEvents() }

    func setBeatGrid(deck: DJDeckID, bpm: Double, firstBeat: Double) {
        guard let track = prepared[deck], bpm.isFinite, bpm > 0, firstBeat.isFinite else { return }
        engine.decks[index(for: deck)].setBeatGrid(bpm: bpm, firstBeat: firstBeat)
        prepared[deck] = PreparedDJTrack(buffer: track.buffer,
                                         analysis: gridAdjustedAnalysis(track.analysis,
                                                                        bpm: bpm,
                                                                        firstBeat: firstBeat),
                                         usedCached: track.usedCached)
    }

    private func gridAdjustedAnalysis(_ analysis: TrackAnalysis, bpm: Double, firstBeat: Double) -> TrackAnalysis {
        var adjusted = analysis
        let first = max(0, min(adjusted.duration, firstBeat))
        let beat = 60 / bpm
        adjusted.tempo.bpm = bpm
        adjusted.tempo.beatPositions = stride(from: first, through: adjusted.duration, by: beat).map { $0 }
        adjusted.tempo.downbeatPositions = stride(from: first, through: adjusted.duration, by: beat * 4).map { $0 }
        return adjusted
    }

    func setMasterLevel(_ value: Double) {
        engine.mixer.master.level = max(0, min(1, value))
    }

    func seek(deck: DJDeckID, position: Double) {
        guard let track = prepared[deck] else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        engine.decks[index(for: deck)].seek(toSample: frame, quantized: false)
    }

    func position(for deck: DJDeckID) -> Double {
        engine.decks[index(for: deck)].playhead
    }

    func isPlaying(for deck: DJDeckID) -> Bool {
        engine.decks[index(for: deck)].isPlaying
    }

    func isLoopActive(for deck: DJDeckID) -> Bool {
        engine.decks[index(for: deck)].isLoopActive
    }

    func setRate(deck: DJDeckID, rate: Double) {
        let player = engine.decks[index(for: deck)]
        player.tempoRange = .wide
        player.tempoPercent = (max(0.25, min(4, rate)) - 1) * 100
    }

    func sync(deck: DJDeckID) { engine.decks[index(for: deck)].sync() }
    func setAsMaster(deck: DJDeckID) { engine.decks[index(for: deck)].setAsMaster() }
    func keySync(deck: DJDeckID, to reference: DJDeckID) {
        _ = engine.decks[index(for: deck)].keySync(to: engine.decks[index(for: reference)])
    }
    func setKeyLock(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].keyLock = enabled }
    func setPitchShift(deck: DJDeckID, semitones: Int) {
        engine.decks[index(for: deck)].pitchSemitones = Double(max(-12, min(12, semitones)))
    }
    func setVinyl(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].vinylMode = enabled }
    func setSlip(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].slip = enabled }
    func setReverse(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].reverse = enabled }
    func setQuantize(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].quantize = enabled }
    func loopRoll(deck: DJDeckID, beats: Double) { engine.decks[index(for: deck)].loopRoll(beats: beats) }
    func setReverb(deck: DJDeckID, enabled: Bool) {
        engine.mixer.beatFX.kind = .reverb
        engine.mixer.beatFX.assign = deck == .a ? .chA : .chB
        engine.mixer.beatFX.isOn = enabled
    }
    func brake(deck: DJDeckID) {
        engine.mixer.beatFX.kind = .vinylBrake
        engine.mixer.beatFX.assign = deck == .a ? .chA : .chB
        engine.mixer.beatFX.isOn = true
    }
    func setBeatFX(kind: Int, beat: Int, depth: Double, assignment: String, enabled: Bool) {
        let unit = engine.mixer.beatFX
        let kinds = BeatFXUnit.Kind.allCases
        if kinds.indices.contains(kind) { unit.kind = kinds[kind] }
        unit.beats = [0.25, 0.5, 0.75, 1, 2, 4, 8, 16][max(0, min(7, beat))]
        unit.depth = max(0, min(1, depth))
        unit.assign = assignment == "B" ? .chB : assignment == "M" ? .master : .chA
        unit.isOn = enabled
    }

    func setChannelLevel(deck: DJDeckID, value: Double) {
        channel(deck).fader = max(0, min(1, value))
    }

    func setTrim(deck: DJDeckID, value: Double) {
        channel(deck).trim = max(0, min(1, value))
    }

    func setEQ(deck: DJDeckID, high: Double, mid: Double, low: Double) {
        let target = channel(deck)
        lowEQ[deck] = low
        target.eqHigh = DJKnobMapping.isolatorDB(high) ?? -.infinity
        target.eqMid = DJKnobMapping.isolatorDB(mid) ?? -.infinity
        applyCombinedLowEQ(deck)
    }

    func setColorFX(deck: DJDeckID, value: Double) {
        let target = channel(deck)
        target.colorFX = .filter
        target.colorAmount = (max(0, min(1, value)) - 0.5) * 2
    }

    func setHeadphoneLevel(_ value: Double) { engine.monitoring.headphoneLevel = max(0, min(1, value)) }
    func setCueMasterMix(_ value: Double) { engine.monitoring.cueMasterMix = max(0, min(1, value)) }
    func setIsolator(low: Double, mid: Double, high: Double) {
        engine.mixer.master.isolatorLow = DJKnobMapping.isolatorDB(low) ?? -.infinity
        engine.mixer.master.isolatorMid = DJKnobMapping.isolatorDB(mid) ?? -.infinity
        engine.mixer.master.isolatorHigh = DJKnobMapping.isolatorDB(high) ?? -.infinity
    }

    func setRecording(_ enabled: Bool) {
        if enabled {
            guard recorder == nil,
                  let documents = try? FileManager.default.url(for: .documentDirectory,
                                                               in: .userDomainMask, appropriateFor: nil, create: true) else { return }
            let url = documents.appendingPathComponent("Mix-\(Int(Date().timeIntervalSince1970)).m4a")
            recorder = try? MixRecorder(url: url)
            if let recorder { engine.startRecording(recorder) }
        } else {
            try? engine.stopRecording()
            recorder = nil
        }
    }

    func peakMeter(for deck: DJDeckID) -> Float { channel(deck).peakMeter }
    func peakHold(for deck: DJDeckID) -> Float { channel(deck).peakHold }
    func restoreHotCues(_ cues: [Int: Double], deck: DJDeckID) {
        guard let track = prepared[deck] else { return }
        let player = engine.decks[index(for: deck)]
        for bank in 0..<2 {
            player.hotCueBank = bank
            for slot in 0..<4 { player.deleteHotCue(slot) }
        }
        for (slot, position) in cues {
            guard let mapped = DJHotCueMapping.slot(slot) else { continue }
            player.hotCueBank = mapped.bank
            let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                         position * track.buffer.format.sampleRate)).rounded())
            player.triggerHotCue(mapped.index, atSample: frame)
        }
        player.hotCueBank = 0
    }

    func setHotCue(_ slot: Int, deck: DJDeckID, position: Double) {
        guard let track = prepared[deck], let mapped = DJHotCueMapping.slot(slot) else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.triggerHotCue(mapped.index, atSample: frame)
        player.hotCueBank = 0
    }

    func setCue(deck: DJDeckID, position: Double) {
        guard let track = prepared[deck] else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        engine.decks[index(for: deck)].setCue(atSample: frame)
    }

    func jumpToCue(deck: DJDeckID) { engine.decks[index(for: deck)].jumpToCue() }
    func cuePlayPress(deck: DJDeckID) { engine.decks[index(for: deck)].cuePlayPress() }
    func cuePlayRelease(deck: DJDeckID) { engine.decks[index(for: deck)].cuePlayRelease() }

    func setLoop(deck: DJDeckID, start: Double, end: Double, active: Bool) {
        guard let track = prepared[deck] else { return }
        let rate = track.buffer.format.sampleRate
        let maxFrame = Double(track.buffer.frameCount)
        let startFrame = Int64(max(0, min(maxFrame, start * rate)).rounded())
        let endFrame = Int64(max(0, min(maxFrame, end * rate)).rounded())
        let player = engine.decks[index(for: deck)]
        player.setLoop(startSample: startFrame, endSample: endFrame)
        player.setActiveLoop(active)
    }

    func loopIn(deck: DJDeckID) { engine.decks[index(for: deck)].loopIn() }
    func setLoopActive(deck: DJDeckID, active: Bool) { engine.decks[index(for: deck)].setActiveLoop(active) }
    func exitLoopAtEnd(deck: DJDeckID) { engine.decks[index(for: deck)].exitLoopAtEnd() }
    func cancelLoopExit(deck: DJDeckID) { engine.decks[index(for: deck)].cancelLoopExit() }
    func reloopExit(deck: DJDeckID) { engine.decks[index(for: deck)].reloopExit() }

    func armEchoOut(deck: DJDeckID) { engine.decks[index(for: deck)].armEchoOut() }
    func disarmEchoOut(deck: DJDeckID) { engine.decks[index(for: deck)].disarmEchoOut() }
    func setEcho(deck: DJDeckID, enabled: Bool, beats: Double) {
        engine.decks[index(for: deck)].setEcho(enabled: enabled, beats: beats)
    }
    func stop(deck: DJDeckID, echoOut: Bool) {
        if echoOut { engine.decks[index(for: deck)].echoOutStop() }
        else { engine.decks[index(for: deck)].pause() }
    }

    func jumpHotCue(_ slot: Int, deck: DJDeckID) {
        guard let mapped = DJHotCueMapping.slot(slot) else { return }
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.jumpHotCue(mapped.index)
        player.hotCueBank = 0
    }

    func deleteHotCue(_ slot: Int, deck: DJDeckID) {
        guard let mapped = DJHotCueMapping.slot(slot) else { return }
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.deleteHotCue(mapped.index)
        player.hotCueBank = 0
    }

    func beginScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchBegan()
    }

    func scratch(deck: DJDeckID, seconds: Double) {
        engine.decks[index(for: deck)].fastSearch(seconds: seconds)
    }

    func frameSearch(deck: DJDeckID, seconds: Double) {
        engine.decks[index(for: deck)].fastSearch(seconds: seconds)
    }

    func endScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchEnded()
    }

    func setBassBlend(_ value: Double) {
        bassBlend = max(0, min(1, value))
        applyCombinedLowEQ(.a)
        applyCombinedLowEQ(.b)
    }

    private func applyCombinedLowEQ(_ deck: DJDeckID) {
        guard let value = DJBassEQMapping.combined(lowKnob: lowEQ[deck] ?? 0.5,
                                                   bassBlend: bassBlend, deckA: deck == .a) else {
            channel(deck).eqLow = -.infinity
            return
        }
        channel(deck).eqLow = value
    }

    func setCrossfader(_ value: Double) {
        engine.mixer.crossfader = (max(0, min(1, value)) * 2) - 1
    }

    func setOutputMode(_ mode: DJOutputMode, cueA: Bool, cueB: Bool) {
        switch mode {
        case .stereo: engine.mixer.setInsert(nil, at: .master)
        case .splitLeft: engine.mixer.setInsert(splitLeftRouter, at: .master)
        case .splitRight: engine.mixer.setInsert(splitRightRouter, at: .master)
        }
        setCueRouting(outputMode: mode, cueA: cueA, cueB: cueB)
    }

    func setCue(deck: DJDeckID, enabled: Bool, outputMode: DJOutputMode,
                cueA: Bool, cueB: Bool) {
        if deck == .a { engine.mixer.channelA.cuePFL = enabled }
        else { engine.mixer.channelB.cuePFL = enabled }
        setCueRouting(outputMode: outputMode, cueA: cueA, cueB: cueB)
    }

    private func setCueRouting(outputMode: DJOutputMode, cueA: Bool, cueB: Bool) {
        engine.mixer.channelA.cuePFL = cueA
        engine.mixer.channelB.cuePFL = cueB
        engine.monitoring.masterCue = cueA || cueB
        engine.monitoring.cueMasterMix = 0
        engine.monitoring.cueMode = (cueA || cueB)
            ? (outputMode == .stereo ? .cueInPlace : .splitOutput)
            : .off
    }

    func stop() {
        for deck in DJDeckID.allCases { engine.decks[index(for: deck)].pause() }
        if engine.isRunning { engine.stop() }
    }

    private func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        try engine.start()
    }

}
