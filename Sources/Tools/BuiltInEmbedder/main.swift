#if !os(watchOS)
import AVFoundation
import CoreML
import Foundation
import ParsoAudioNeural
import TonearmDiscovery

// Dev-only offline tool: pre-computes CLAP embeddings for a batch of audio
// files (the bundled built-in mood-starter library — Jamendo + archive.org
// classical, docs/plans/builtin-mood-starter-index-plan.md) so the app can
// seed `discovery_embedding` rows directly from a bundled JSON manifest
// instead of running BoundedIndexWorker's on-device pipeline for these
// tracks. Not shipped in the app target; run manually via `swift run
// BuiltInEmbedder <audio-dir> <output.json>`. Mirrors BoundedIndexWorker's
// real finalizeEmbeddingOutcome pipeline (read windows -> pool -> quantize)
// exactly, so the vectors it produces are bit-for-bit what on-device
// indexing would have produced for the same audio.

struct EmbeddedTrack: Codable {
    let id: String
    let dimensions: Int
    let scale: Double
    let quantizedVectorBase64: String
}

@main
struct BuiltInEmbedder {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write("usage: BuiltInEmbedder <audio-dir> <output.json>\n".data(using: .utf8)!)
            exit(1)
        }
        let audioDir = URL(fileURLWithPath: args[1])
        let outputURL = URL(fileURLWithPath: args[2])

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let encoderPackageURL = repoRoot.appendingPathComponent("Resources/Models/CLAPAudioEncoder.mlpackage")
        let melURL = repoRoot.appendingPathComponent("Resources/CLAP/mel_filterbank_slaney_64.bin")

        guard FileManager.default.fileExists(atPath: encoderPackageURL.path) else {
            FileHandle.standardError.write("model not found at \(encoderPackageURL.path)\n".data(using: .utf8)!)
            exit(1)
        }

        let melFilterBank: [Float]
        do {
            melFilterBank = try EmbeddingModelSpec.loadMelFilterBank(from: melURL)
        } catch {
            FileHandle.standardError.write("mel filterbank load failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        let spec = EmbeddingModelSpec.musicCLAP(melFilterBank: melFilterBank)

        let loadableURL: URL
        do {
            loadableURL = try CompiledModelCache.loadableURL(for: encoderPackageURL)
        } catch {
            FileHandle.standardError.write("model compile failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        let encoder = CoreMLSemanticModel(kind: .audio, url: loadableURL, spec: spec, computeUnits: .cpuAndGPU)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        else {
            FileHandle.standardError.write("cannot list \(audioDir.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let audioFiles = entries.filter { ["mp3", "m4a", "wav", "flac"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let reader = WindowedAudioReader()
        var results: [EmbeddedTrack] = []

        for (index, fileURL) in audioFiles.enumerated() {
            let id = fileURL.deletingPathExtension().lastPathComponent
            print("[\(index + 1)/\(audioFiles.count)] \(id)")

            let duration = try? await AVURLAsset(url: fileURL).load(.duration).seconds
            guard let duration, duration.isFinite, duration > 0 else {
                print("  skip: cannot read duration")
                continue
            }

            let windowStarts = DiscoverySamplingPolicy.windowStarts(durationSeconds: duration)
            var windowVectors: [[Float]] = []
            for start in windowStarts {
                do {
                    let pcm = try reader.readWindow(url: fileURL, startSeconds: start, windowSeconds: 10)
                    let logMel = try SemanticPreprocess.logMel(clip: pcm, spec: spec)
                    let embedding = try await encoder.embedAudio(logMel: logMel)
                    guard embedding.allSatisfy({ $0.isFinite }) else { continue }
                    windowVectors.append(embedding)
                } catch {
                    print("  window @\(start)s failed: \(error)")
                }
            }
            guard !windowVectors.isEmpty else {
                print("  skip: no usable windows")
                continue
            }
            let pooled = SemanticPooling.pool(windowVectors, strategy: spec.pooling)
            guard !pooled.isEmpty, pooled.allSatisfy({ $0.isFinite }) else {
                print("  skip: pooling produced non-finite vector")
                continue
            }
            let (int8, scale) = VectorQuantization.quantize(pooled)
            let data = VectorQuantization.data(int8)
            results.append(EmbeddedTrack(
                id: id, dimensions: pooled.count, scale: Double(scale),
                quantizedVectorBase64: data.base64EncodedString()))
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(results)
            try data.write(to: outputURL)
            print("wrote \(results.count) embeddings to \(outputURL.path)")
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

#endif
