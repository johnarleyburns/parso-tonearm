import Foundation
import AudioToolbox

/// Writes an Opus-in-CAF file (Apple Core Audio Format) that AVFoundation can
/// decode natively, from raw Opus packets demuxed out of an Ogg container.
///
/// CAF stores Opus at a fixed 48 kHz sample rate. The mandatory `pakt` (packet
/// table) chunk carries priming/remainder frame counts so the decoder trims the
/// encoder pre-skip (start click) and the trailing padding (gap) — see `01 §C`.
enum CAFOpusWriter {

    enum WriterError: Error { case noPackets }

    static let sampleRate: Double = 48000

    /// Builds the complete CAF file bytes for the given demuxed Opus stream.
    static func makeCAF(from stream: OggOpusStream) throws -> Data {
        guard !stream.audioPackets.isEmpty else { throw WriterError.noPackets }

        var out = Data()
        out.append(fileHeader())
        out.append(descChunk(channels: stream.head.channelCount))
        out.append(magicCookieChunk(channels: stream.head.channelCount,
                                     preSkip: stream.head.preSkip))
        out.append(channelLayoutChunk(channels: stream.head.channelCount))
        out.append(packetTableChunk(stream: stream))
        out.append(dataChunk(packets: stream.audioPackets))
        return out
    }

    /// Convenience: demux + write in one step.
    static func makeCAF(fromOgg data: Data) throws -> Data {
        try makeCAF(from: try OggPageReader.parse(data))
    }

    // MARK: - Chunks

    // caff header: 'caff', version=1, flags=0
    private static func fileHeader() -> Data {
        var d = Data()
        d.append(fourCC("caff"))
        d.append(beUInt16(1))   // mFileVersion
        d.append(beUInt16(0))   // mFileFlags
        return d
    }

    // 'desc' — CAFAudioDescription (always 32 bytes of payload).
    private static func descChunk(channels: Int) -> Data {
        var payload = Data()
        payload.append(beFloat64(sampleRate))                 // mSampleRate
        payload.append(fourCC("opus"))                        // mFormatID (kAudioFormatOpus)
        payload.append(beUInt32(0))                           // mFormatFlags
        payload.append(beUInt32(0))                           // mBytesPerPacket (variable → 0)
        payload.append(beUInt32(0))                           // mFramesPerPacket (variable → 0)
        payload.append(beUInt32(UInt32(channels)))            // mChannelsPerFrame
        payload.append(beUInt32(0))                           // mBitsPerChannel (compressed → 0)
        return chunk("desc", payload)
    }

    // 'kuki' — Opus magic cookie, mirroring what CoreAudio's own encoder writes:
    // version(0x0800), sample rate, frames-per-packet, negative pre-skip
    // (priming), channels. CoreAudio uses this to configure the Opus decoder.
    private static func magicCookieChunk(channels: Int, preSkip: Int) -> Data {
        var payload = Data()
        payload.append(beUInt32(0x0000_0800))          // cookie version marker
        payload.append(beUInt32(48000))                // sample rate
        payload.append(beUInt32(960))                  // frames per packet (nominal)
        payload.append(beInt32(Int32(-preSkip)))       // negative pre-skip / priming
        payload.append(beUInt32(UInt32(channels)))     // channels
        payload.append(beUInt32(0))
        payload.append(beUInt32(0))
        return chunk("kuki", payload)
    }

    // 'chan' — CAFChannelLayout. Required for AVFoundation to open multi-channel
    // Opus-in-CAF; mono/stereo use the well-known UseChannelLayoutTag values.
    private static func channelLayoutChunk(channels: Int) -> Data {
        // kAudioChannelLayoutTag_Mono = (100 << 16) | 1
        // kAudioChannelLayoutTag_Stereo = (101 << 16) | 2
        let tag: UInt32 = channels >= 2 ? ((101 << 16) | 2) : ((100 << 16) | 1)
        var payload = Data()
        payload.append(beUInt32(tag))    // mChannelLayoutTag
        payload.append(beUInt32(0))      // mChannelBitmap
        payload.append(beUInt32(0))      // mNumberChannelDescriptions
        return chunk("chan", payload)
    }

    // 'pakt' — CAFPacketTableHeader + variable-length packet descriptions.
    // With mBytesPerPacket == mFramesPerPacket == 0 in `desc`, each entry carries
    // BOTH the packet byte size AND its decoded frame count as big-endian base-128
    // varints. `mPrimingFrames` == OpusHead pre-skip (guards the start click);
    // `mRemainderFrames` is the trailing padding derived from final-page granule
    // vs the decoded total (guards the trailing gap) — see `01 §C`.
    private static func packetTableChunk(stream: OggOpusStream) -> Data {
        let packets = stream.audioPackets
        let priming = Int64(stream.head.preSkip)
        let validFrames = max(0, stream.finalGranule - priming)
        let remainder = max(0, stream.decodedSampleCount - stream.finalGranule)

        var payload = Data()
        payload.append(beInt64(Int64(packets.count)))         // mNumberPackets
        payload.append(beInt64(validFrames))                  // mNumberValidFrames
        payload.append(beInt32(Int32(priming)))               // mPrimingFrames
        payload.append(beInt32(Int32(remainder)))             // mRemainderFrames

        for packet in packets {
            payload.append(varint(UInt64(packet.count)))                       // byte size
            payload.append(varint(UInt64(OggPageReader.packetSampleCount(packet)))) // frames
        }
        return chunk("pakt", payload)
    }

    // 'data' — mEditCount (4 bytes) followed by the concatenated Opus packets.
    private static func dataChunk(packets: [Data]) -> Data {
        var payload = Data()
        payload.append(beUInt32(0))  // mEditCount
        for packet in packets { payload.append(packet) }
        return chunk("data", payload)
    }

    // MARK: - Chunk framing

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        d.append(fourCC(type))
        d.append(beInt64(Int64(payload.count)))   // mChunkSize (signed 64-bit BE)
        d.append(payload)
        return d
    }

    // MARK: - Big-endian encoders (CAF is big-endian)

    private static func fourCC(_ s: String) -> Data { Data(s.utf8) }

    private static func beUInt16(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    private static func beUInt32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
              UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func beInt32(_ v: Int32) -> Data { beUInt32(UInt32(bitPattern: v)) }

    private static func beUInt64(_ v: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8((v >> (8 * (7 - i))) & 0xFF) }
        return Data(bytes)
    }

    private static func beInt64(_ v: Int64) -> Data { beUInt64(UInt64(bitPattern: v)) }

    private static func beFloat64(_ v: Double) -> Data { beUInt64(v.bitPattern) }

    /// Big-endian base-128 varint (high bit set on all but the final byte), the
    /// encoding CAF uses for packet-table size entries.
    private static func varint(_ value: UInt64) -> Data {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return Data(bytes.reversed())
    }
}
