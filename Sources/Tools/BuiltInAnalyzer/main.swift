#if !os(watchOS)
import CryptoKit
import Foundation
import ParsoAudioAnalysis
import TonearmCore
import TonearmDiscovery

// Dev-only offline tool: adds tempo, key and energy to the bundled mood-starter index
// (data/mood-starter/source-index.json) so Build a Mix can place the built-in tracks on a
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
        if args.count >= 4, args[1] == "build-starter" {
            let dims = args.firstIndex(of: "--embedding-dims").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            buildStarter(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                         embeddingDimensions: dims ?? 128)
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
            entries[index]["bpm"] == nil && entries[index]["analysisUnavailable"] == nil
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
                group.addTask { (index, await analyse(entry)) }
            }
            for _ in 0..<parallelism { enqueue() }
            while let (index, analysis) = await group.next() {
                done += 1
                if let analysis {
                    entries[index]["bpm"] = analysis.bpm
                    entries[index]["key"] = analysis.key
                    entries[index]["energy"] = analysis.energy
                    entries[index]["analysisScopeSeconds"] = analysis.scopeSeconds
                } else {
                    entries[index]["analysisUnavailable"] = true
                }
                let id = entries[index]["id"] as? String ?? "?"
                say("[\(done)/\(pending.count)] \(id) \(analysis.map { "bpm \($0.bpm.map { String(format: "%.1f", $0) } ?? "—") key \($0.key ?? "—")" } ?? "unavailable")")
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

    /// `embeddingDimensions`: principal-component coordinates per track (0: full embeddings).
    static func buildStarter(source: URL, output: URL, embeddingDimensions: Int) {
        do {
            let sourceData = try Data(contentsOf: source)
            let tracks = try JSONDecoder().decode([BuiltInMoodTrack].self, from: sourceData)
            var hasher = SHA256()
            hasher.update(data: sourceData)
            hasher.update(data: Data("format-\(StarterLibrary.formatVersion)-emb\(embeddingDimensions)".utf8))
            let contentVersion = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            try StarterLibraryWriter.create(
                at: output, tracks: tracks,
                meta: ["content_version": contentVersion, "track_count": String(tracks.count),
                       "embedding_dims": String(embeddingDimensions > 0 ? embeddingDimensions : tracks.first?.dimensions ?? 0),
                       "built_at": ISO8601DateFormatter().string(from: Date())],
                embeddingDimensions: embeddingDimensions > 0 ? embeddingDimensions : nil)
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            say("starter DB → \(output.path): \(tracks.count) tracks, \(size / 1_024) KB, content \(contentVersion)")
        } catch {
            say("build-starter failed: \(error)")
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
