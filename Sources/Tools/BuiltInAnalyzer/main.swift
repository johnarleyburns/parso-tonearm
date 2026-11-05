#if !os(watchOS)
import CryptoKit
import Foundation
import ParsoAudioAnalysis
import StarterGeneratorSupport

// Dev-only offline tool: adds tempo, key and energy to the bundled mood-starter index
// (data/mood-starter/source-index.json) so Build a Mix can place the built-in tracks on a
// fresh install. BuiltInEmbedder only produced the sound embedding; the app seeded those tracks
// with musical analysis marked unsupported, so Generate had nothing with BPM + key to order.
//
// Mirrors BoundedIndexWorker's musical-analysis stage exactly: a window of
// `musicalAnalysisMaxSeconds` centred on the track, read by `WindowedAudioReader` at its target
// rate, run through `LeanAnalysis`, key stored as the Camelot code.
//
// Usage: swift run BuiltInAnalyzer <builtin-mood-index.json> [parallelism]
// Each track's audio is downloaded to a temp file, analysed, then deleted. Progress is written
// back to the index every 25 tracks, and tracks that already carry analysis are skipped, so an
// interrupted run resumes where it stopped.

@main
struct BuiltInAnalyzer {
    static func main() async {
        let args = CommandLine.arguments
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

    /// `BUILTIN_ANALYZER_AUDIO_DIR`: read `<dir>/<id>.mp3` when it is there instead of
    /// downloading the track again (the starter expansion downloads each track once, for the
    /// embedder and this tool).
    static let audioDirectory = ProcessInfo.processInfo.environment["BUILTIN_ANALYZER_AUDIO_DIR"]
        .map { URL(fileURLWithPath: $0) }

    static func analyse(_ entry: Entry) async -> Analysis? {
        if let local = audioDirectory?.appendingPathComponent("\(entry.id).mp3"),
           FileManager.default.fileExists(atPath: local.path) {
            return await analyseFile(local, entry: entry)
        }
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
        return await analyseFile(temp, entry: entry)
    }

    static func analyseFile(_ temp: URL, entry: Entry) async -> Analysis? {
        await Task.detached(priority: .utility) { () -> Analysis? in
            let reader = WindowedAudioReader()
            let duration = entry.duration ?? 0
            guard duration > 0 else { return nil }
            // BoundedIndexWorker's musical-analysis window.
            let scope = min(60, duration)
            let start = max(0, duration / 2 - scope / 2)
            guard let pcm = try? reader.readWindow(url: temp, startSeconds: start, windowSeconds: scope),
                  !pcm.isEmpty else { return nil }
            let audio = AnalysisAudio(sampleRate: reader.targetSampleRate, channels: [pcm])
            let musical = LeanAnalysis.run(audio)
            return Analysis(bpm: musical.bpm, key: musical.key?.camelot.code,
                           energy: musical.energy.map { Double($0.scalar) }, scopeSeconds: scope)
        }.value
    }

    /// Progress for the person running the tool (stdout, unbuffered).
    static func say(_ line: String) {
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
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
