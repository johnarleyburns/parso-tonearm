import Foundation
import ParsoAudioCore

/// One-shot MP3 re-encode of a recorded mix for the finish screen's export
/// (Phase 9, docs/GPL-BACKENDS.md) — via LAME (`LAMEEncoder`), not PAE's
/// built-in Glint, because this app has made its own licensing call to carry
/// LGPL-2.1 LAME (see that doc). The mix's actual recording stays M4A/AAC
/// (FR-REC-7 honesty, `RecordingFinishModel.formatLabel`); this is a
/// destination format offered only at export time, never the recorded file.
public enum MP3MixExporter {
    public enum Error: Swift.Error {
        case sourceUnreadable(Swift.Error)
        case encodeFailed(Swift.Error)
    }

    /// Decodes `assetURL` (the recorded M4A) and writes an MP3 to
    /// `destination` at `bitrateKbps`. Runs the decode + encode synchronously
    /// on the calling thread/task — callers on `@MainActor` should hop off
    /// main first (e.g. `Task.detached`), since a long mix can take real time
    /// to transcode.
    public static func export(assetURL: URL, bitrateKbps: Int, to destination: URL) throws {
        let buffer: ParsoAudioCore.PCMBuffer
        do {
            buffer = try AudioFileReader(url: assetURL, container: .auto).readAll()
        } catch {
            throw Error.sourceUnreadable(error)
        }
        do {
            let writer = try AudioFileWriter(
                url: destination, format: buffer.format,
                codec: .mp3(bitrate: bitrateKbps),
                mp3Encoder: LAMEEncoder()
            )
            try writer.write(buffer)
            try writer.finish()
        } catch {
            throw Error.encodeFailed(error)
        }
    }
}
