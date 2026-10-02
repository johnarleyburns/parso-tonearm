#if !os(watchOS)
import Foundation
import ParsoAudioAnalysis
import TonearmCore
import TonearmDiscovery

// Dev-only offline tool: adds tempo, key and energy to the bundled mood-starter index
// (Resources/Audio/builtin-mood-index.json) so Build a Mix can place the built-in tracks on a
// fresh install. BuiltInEmbedder only produced the sound embedding; the app seeded those tracks
// with musical analysis marked unsupported, so Generate had nothing with BPM + key to order.
//
// Mirrors BoundedIndexWorker's musical-analysis stage exactly: a window of
// `musicalAnalysisMaxSeconds` centred on the track, read by `WindowedAudioReader` at its target
// rate, run through `FullAnalysis`, key stored as the Camelot code.
//
// Usage: swift run BuiltInAnalyzer <builtin-mood-index.json> [parallelism]
// Each track's audio is downloaded to a temp file, analysed, then deleted. Progress is written
// back to the index every 25 tracks, and tracks that already carry analysis are skipped, so an
// interrupted run resumes where it stopped.

@main
struct BuiltInAnalyzer {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "pack" {
            pack(directory: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                 full: args.contains("--full"))
            return
        }
        guard args.count >= 2 else {
            FileHandle.standardError.write("usage: BuiltInAnalyzer <builtin-mood-index.json> [parallelism]\n".data(using: .utf8)!)
            exit(1)
        }
        let indexURL = URL(fileURLWithPath: args[1])
        let parallelism = args.count >= 3 ? max(1, Int(args[2]) ?? 4) : 4
        guard let data = try? Data(contentsOf: indexURL),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            FileHandle.standardError.write("cannot read \(indexURL.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let pending = entries.indices.filter { index in
            prepMode
                ? entries[index]["transitionPrep"] == nil && entries[index]["transitionPrepUnavailable"] == nil
                : entries[index]["bpm"] == nil && entries[index]["analysisUnavailable"] == nil
        }
        say("\(entries.count) tracks, \(pending.count) to analyse, \(parallelism) at a time")

        var done = 0
        var next = 0
        await withTaskGroup(of: (Int, Analysis?).self) { group in
            func enqueue() {
                guard next < pending.count else { return }
                let index = pending[next]
                next += 1
                let entry = Entry(id: entries[index]["id"] as? String ?? "?",
                                  streamURL: entries[index]["streamURL"] as? String,
                                  duration: (entries[index]["durationSec"] as? NSNumber)?.doubleValue)
                group.addTask { (index, prepMode ? await prepare(entry) : await analyse(entry)) }
            }
            for _ in 0..<parallelism { enqueue() }
            while let (index, analysis) = await group.next() {
                done += 1
                if prepMode {
                    if let prep = analysis?.prep {
                        entries[index]["transitionPrep"] = true
                        entries[index]["transitionPrepFrameCount"] = prep.frameCount
                    } else {
                        entries[index]["transitionPrepUnavailable"] = true
                    }
                } else if let analysis {
                    entries[index]["bpm"] = analysis.bpm
                    entries[index]["key"] = analysis.key
                    entries[index]["energy"] = analysis.energy
                    entries[index]["analysisScopeSeconds"] = analysis.scopeSeconds
                } else {
                    entries[index]["analysisUnavailable"] = true
                }
                let id = entries[index]["id"] as? String ?? "?"
                if prepMode {
                    say("[\(done)/\(pending.count)] \(id) \(analysis?.prep.map { "prep \($0.payloadBase64.count) b64 bytes" } ?? "unavailable")")
                } else {
                say("[\(done)/\(pending.count)] \(id) \(analysis.map { "bpm \($0.bpm.map { String(format: "%.1f", $0) } ?? "—") key \($0.key ?? "—")" } ?? "unavailable")")
                }
                if done % 25 == 0 { write(entries, to: indexURL) }
                enqueue()
            }
        }
        write(entries, to: indexURL)
        let analysed = entries.filter { $0["bpm"] != nil && $0["key"] != nil }.count
        say("done: \(analysed)/\(entries.count) tracks have BPM and key")
    }

    struct Entry: Sendable { let id: String; let streamURL: String?; let duration: Double? }
    struct Analysis: Sendable {
        let bpm: Double?; let key: String?; let energy: Double?; let scopeSeconds: Double
        var prep: Prep? = nil
    }
    struct Prep: Sendable { let payloadBase64: String; let frameCount: Int64 }

    /// `BUILTIN_ANALYZER_PREP=1`: also ship each track's transition-prep payload (beat grid,
    /// phrases, cue points) — exactly what TransitionPrepService computes on the phone with
    /// `TrackGridAnalyzer.analyze` after downloading and decoding the whole track. With it, Build
    /// a Mix's transitions are ready on install instead of "Preparing…" track by track.
    static let prepMode = ProcessInfo.processInfo.environment["BUILTIN_ANALYZER_PREP"] == "1"
    static let prepDirectory = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["BUILTIN_ANALYZER_PREP_DIR"] ?? "/tmp/builtin-prep")

    static func prepare(_ entry: Entry) async -> Analysis? {
        guard let streamURL = entry.streamURL.flatMap(URL.init(string:)) else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-prep-\(entry.id)-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temp) }
        var downloaded = false
        for attempt in 0..<3 where !downloaded {
            downloaded = await curl(streamURL, to: temp)
            if !downloaded && attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
        }
        guard downloaded else { say("  \(entry.id): download failed"); return nil }
        return await Task.detached(priority: .utility) { () -> Analysis? in
            guard let result = try? TrackGridAnalyzer.analyze(url: temp, codec: "mp3") else { return nil }
            // Full payload, one file per track; `pack` makes the iPhone (coarse waveform) and Mac
            // (full waveform) resources from these.
            guard let data = try? result.payload.encoded() else { return nil }
            let file = prepDirectory.appendingPathComponent("\(entry.id).plz")
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            return Analysis(bpm: nil, key: nil, energy: nil, scopeSeconds: 0,
                            prep: Prep(payloadBase64: "\(data.count) bytes", frameCount: result.frameCount))
        }.value
    }

    static func analyse(_ entry: Entry) async -> Analysis? {
        guard let streamURL = entry.streamURL.flatMap(URL.init(string:)) else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-analyzer-\(entry.id)-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temp) }
        // curl, not URLSession: from this command-line tool URLSession downloads from Jamendo's
        // storage crawled (12 tracks in 7.5 minutes at ~1% CPU) while curl fetched each in ~3 s.
        var downloaded = false
        for attempt in 0..<3 where !downloaded {
            downloaded = await curl(streamURL, to: temp)
            if !downloaded && attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
        }
        guard downloaded else { say("  \(entry.id): download failed"); return nil }
        return await Task.detached(priority: .utility) { () -> Analysis? in
            let reader = WindowedAudioReader()
            let duration = entry.duration ?? 0
            guard duration > 0 else { return nil }
            // BoundedIndexWorker's musical-analysis window.
            let scope = min(BoundedIndexWorker.musicalAnalysisMaxSeconds, duration)
            let start = max(0, duration / 2 - scope / 2)
            guard let pcm = try? reader.readWindow(url: temp, startSeconds: start, windowSeconds: scope),
                  !pcm.isEmpty else { return nil }
            let musical = musicalStages(AnalysisAudio(sampleRate: reader.targetSampleRate, channels: [pcm]))
            if verify {
                let full = FullAnalysis.run(AnalysisAudio(sampleRate: reader.targetSampleRate, channels: [pcm]))
                let fullEnergy = full.energy.map { Double($0.scalar) }
                if full.bpm != musical.bpm || full.key?.camelot.code != musical.key || fullEnergy != musical.energy {
                    say("  MISMATCH \(entry.id): full \(String(describing: full.bpm)) \(full.key?.camelot.code ?? "-") \(String(describing: fullEnergy)) vs \(String(describing: musical.bpm)) \(musical.key ?? "-") \(String(describing: musical.energy))")
                }
            }
            return Analysis(bpm: musical.bpm, key: musical.key, energy: musical.energy, scopeSeconds: scope)
        }.value
    }

    /// Set `BUILTIN_ANALYZER_VERIFY=1` to also run the whole `FullAnalysis` and report any track
    /// where the two disagree.
    static let verify = ProcessInfo.processInfo.environment["BUILTIN_ANALYZER_VERIFY"] == "1"

    /// `FullAnalysis.runInternal`'s tempo → beat grid → key → energy stages, line for line, without
    /// the loudness (true-peak oversampling), phrase and waveform stages Build a Mix doesn't use —
    /// those were ~80% of the time, putting the 4,017-track run at five hours.
    static func musicalStages(_ pcm: AnalysisAudio) -> (bpm: Double?, key: String?, energy: Double?) {
        let stft = STFTConfig()
        let kernel = STFTKernel(config: stft)
        let spectra = kernel.spectra(pcm.mono)
        let hopSeconds = Double(stft.hopSize) / stft.sampleRate
        var frames: [SpectralFrame] = []
        if !spectra.isEmpty {
            frames.reserveCapacity(spectra.count)
            let monoBase = pcm.mono.baseAddress
            let monoCount = pcm.mono.count
            for (i, spec) in spectra.enumerated() {
                let prev = i > 0 ? spectra[i - 1].power : spec.power
                let offset = stft.hopSize * i
                let sliceCount = min(stft.fftSize, max(0, monoCount - offset))
                let slice = UnsafeBufferPointer(
                    start: sliceCount > 0 ? monoBase?.advanced(by: offset) : nil, count: sliceCount)
                frames.append(SpectralFeatures.frame(spec, prevPower: prev, frameSamples: slice))
            }
        }
        let envelope = OnsetDetector.envelope(spectra: spectra)
        let onsets = hopSeconds > 0 ? OnsetDetector.peaks(envelope, frameRateHz: 1 / hopSeconds) : []
        let tempo = hopSeconds > 0 ? TempoAnalyzer.estimate(novelty: envelope, hopSeconds: hopSeconds).first : nil
        var bpm: Double?
        var beatGrid: BeatGrid?
        if let tempo {
            bpm = tempo.bpm
            beatGrid = BeatTracker.grid(novelty: envelope, hopSeconds: hopSeconds, sampleRate: stft.sampleRate,
                                        onsets: onsets, bpm: tempo.bpm)
        }
        var key: KeyEstimate?
        if !spectra.isEmpty {
            key = KeyDetector.estimate(spectra.map { KeyDetector.fusedChroma($0) })
        }
        var energy: Double?
        if let beatGrid, !frames.isEmpty {
            let curve = EnergyAnalyzer.curve(frames: frames, beatSamples: beatGrid.beatSamples,
                                             frameRateHz: 1 / hopSeconds, sampleRate: stft.sampleRate)
            energy = Double(EnergyAnalyzer.scalar(curve))
        }
        return (bpm, key?.camelot.code, energy)
    }

    /// Progress for the person running the tool (stdout, unbuffered).
    static func say(_ line: String) {
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    }

    /// Downsamples to one bin per second: min of mins, max of maxes, RMS of RMS per band.
    static func coarseWaveform(_ bins: [DJTrackPrepPayload.WaveformBin], duration: Double) -> [DJTrackPrepPayload.WaveformBin] {
        let target = max(1, Int(duration.rounded(.up)))
        guard bins.count > target else { return bins }
        return (0..<target).map { index in
            let lower = index * bins.count / target
            let upper = max(lower + 1, (index + 1) * bins.count / target)
            let slice = bins[lower..<min(upper, bins.count)]
            func rms(_ values: [Float]) -> Float {
                (values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count))).squareRoot()
            }
            let bandCount = slice.map(\.bandRMS.count).max() ?? 0
            return .init(min: slice.map(\.min).min() ?? 0, max: slice.map(\.max).max() ?? 0,
                         rms: rms(slice.map(\.rms)),
                         bandRMS: (0..<bandCount).map { band in rms(slice.map { $0.bandRMS.indices.contains(band) ? $0.bandRMS[band] : 0 }) })
        }
    }

    /// `BuiltInAnalyzer pack <payload-dir> <out.bin> [--full]`: the per-track payloads from a
    /// BUILTIN_ANALYZER_PREP run → the shipped pack (compact waveform for iPhone, full for Mac).
    static func pack(directory: URL, output: URL, full: Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [(id: String, payload: DJTrackPrepPayload)] = []
        for file in files.filter({ $0.pathExtension == "plz" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file), let payload = try? DJTrackPrepPayload.decoded(data) else {
                say("skip \(file.lastPathComponent): unreadable")
                continue
            }
            entries.append((file.deletingPathExtension().lastPathComponent, payload))
        }
        do {
            let packed = try BuiltInTransitionPrepPack.encode(entries, coarseWaveform: !full)
            try packed.write(to: output, options: .atomic)
            say("packed \(entries.count) tracks → \(output.path) (\(packed.count / 1024) KB, \(full ? "full" : "compact") waveform)")
        } catch {
            say("pack failed: \(error)")
        }
    }

    static func curl(_ url: URL, to file: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-sfL", "--max-time", "90", "-o", file.path, url.absoluteString]
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    static func write(_ entries: [[String: Any]], to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
        }
    }
}
#endif
