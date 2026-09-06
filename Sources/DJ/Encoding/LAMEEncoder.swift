import CLAMEBridge
import Foundation
import ParsoAudioCore

/// This app's `MP3Encoding` conformance (PAE `docs/BYO-CODEC.md`), backed by
/// a real vendored LAME 3.100 (`Sources/CLAMEBridge`, LGPL-2.1 — see that
/// target's `vendor/lame-3.100/COPYING` and this repo's `ATTRIBUTION.md`).
/// PAE's own `ParsoAudioCore` never imports or links LAME; this type is the
/// only place in the dependency graph that does, and it lives entirely in
/// this app's own package. See `docs/GPL-BACKENDS.md` for why this app opts
/// into LAME instead of PAE's default Glint encoder for its MP3 exports.
public struct LAMEEncoder: MP3Encoding {
    public init() {}

    public func encode(_ buffer: ParsoAudioCore.PCMBuffer, bitrateKbps: Int) throws -> Data {
        let frameCount = buffer.frameCount
        let channelCount = buffer.channelCount
        guard frameCount > 0, channelCount == 1 || channelCount == 2 else {
            throw AudioFileError.writeFailed("LAME encode: unsupported channel count \(channelCount)")
        }

        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for c in 0..<channelCount {
            let src = buffer.channel(c)
            for f in 0..<frameCount {
                interleaved[f * channelCount + c] = src[f]
            }
        }

        var outSize: Int32 = 0
        let encoded: UnsafeMutablePointer<UInt8>? = interleaved.withUnsafeBufferPointer { samples in
            app_lame_encode(samples.baseAddress,
                             Int32(frameCount),
                             Int32(channelCount),
                             Int32(buffer.format.sampleRate.rounded()),
                             Int32(bitrateKbps),
                             &outSize)
        }
        guard let encoded, outSize > 0 else {
            throw AudioFileError.writeFailed("LAME encode failed (bitrate \(bitrateKbps) kbps, \(channelCount)ch @ \(buffer.format.sampleRate) Hz)")
        }
        defer { app_lame_free(encoded) }
        return Data(bytes: encoded, count: Int(outSize))
    }
}
