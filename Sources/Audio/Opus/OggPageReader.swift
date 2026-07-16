import Foundation

public enum OggOpusError: Error, Equatable {
    case notOgg
    case notOpus
    case chainedStream
    case truncated
    case malformedPage
}

/// Parsed header fields from the `OpusHead` identification packet (RFC 7845 §5.1).
public struct OpusHead: Equatable {
    public let channelCount: Int
    /// Samples (at 48 kHz) to discard from the decoded output start. Maps to the
    /// CAF `pakt` priming frames — this guards the start-click trap.
    public let preSkip: Int
    /// Original input sample rate (informational only; Opus always decodes at 48 kHz).
    public let inputSampleRate: Int
    public let outputGain: Int
    public let channelMappingFamily: Int
}

/// Result of demuxing an Ogg-encapsulated Opus stream into raw Opus packets plus
/// the metadata the CAF writer needs. The reader reassembles packets across page
/// boundaries (255-lacing continuation) and rejects chained streams (multiple BOS).
public struct OggOpusStream: Equatable {
    public let head: OpusHead
    /// Raw Opus audio packets, in order, ready to be concatenated into a CAF
    /// `data` chunk. Excludes the two header packets (OpusHead, OpusTags).
    public let audioPackets: [Data]
    /// Granule position of the final page — total 48 kHz samples of decodable
    /// output including pre-skip.
    public let finalGranule: Int64
    /// Sum of every audio packet's decoded sample count at 48 kHz. Used with
    /// `finalGranule` to derive the CAF `pakt` remainder frames (trailing gap).
    public let decodedSampleCount: Int64
}

/// Parses Ogg pages (RFC 3533) carrying an Opus logical stream (RFC 7845).
public enum OggPageReader {
    private static let capturePattern: [UInt8] = Array("OggS".utf8)

    public struct Page {
        let headerType: UInt8
        let granulePosition: Int64
        let serialNumber: UInt32
        let segments: [Int]      // lacing values
        let body: Data
        var isBOS: Bool { headerType & 0x02 != 0 }
        var isEOS: Bool { headerType & 0x04 != 0 }
        var isContinuation: Bool { headerType & 0x01 != 0 }
    }

    public static func parse(_ data: Data) throws -> OggOpusStream {
        let bytes = [UInt8](data)
        var offset = 0
        var pages: [Page] = []
        var serial: UInt32?

        while offset + 27 <= bytes.count {
            guard Array(bytes[offset..<offset + 4]) == capturePattern else {
                throw OggOpusError.notOgg
            }
            let headerType = bytes[offset + 5]
            let granule = readInt64LE(bytes, offset + 6)
            let pageSerial = readUInt32LE(bytes, offset + 14)
            let segCount = Int(bytes[offset + 26])
            let segTableStart = offset + 27
            guard segTableStart + segCount <= bytes.count else { throw OggOpusError.truncated }
            let segments = (0..<segCount).map { Int(bytes[segTableStart + $0]) }
            let bodyLen = segments.reduce(0, +)
            let bodyStart = segTableStart + segCount
            guard bodyStart + bodyLen <= bytes.count else { throw OggOpusError.truncated }
            let body = Data(bytes[bodyStart..<bodyStart + bodyLen])

            let page = Page(headerType: headerType, granulePosition: granule,
                            serialNumber: pageSerial, segments: segments, body: body)

            // Reject chained streams: a second BOS page (with a different serial)
            // signals a fresh logical stream concatenated after the first.
            if page.isBOS && !pages.isEmpty {
                throw OggOpusError.chainedStream
            }
            if let s = serial {
                if page.serialNumber != s { throw OggOpusError.chainedStream }
            } else {
                serial = page.serialNumber
            }

            pages.append(page)
            offset = bodyStart + bodyLen
        }

        guard !pages.isEmpty else { throw OggOpusError.notOgg }

        // Reassemble packets across pages using lacing values. A 255 value means
        // the packet continues; any value < 255 (including 0) terminates it.
        var packets: [Data] = []
        var current = Data()
        var currentOpen = false
        for page in pages {
            var segIndex = 0
            var cursor = page.body.startIndex
            for lacing in page.segments {
                let segEnd = page.body.index(cursor, offsetBy: lacing)
                current.append(page.body[cursor..<segEnd])
                cursor = segEnd
                currentOpen = true
                if lacing < 255 {
                    packets.append(current)
                    current = Data()
                    currentOpen = false
                }
                segIndex += 1
            }
            _ = segIndex
        }
        // A packet left open at end-of-stream is a truncation.
        if currentOpen && !current.isEmpty {
            throw OggOpusError.truncated
        }

        guard packets.count >= 2 else { throw OggOpusError.truncated }

        // Packet 0 is OpusHead; packet 1 is OpusTags (skipped). The rest are audio.
        let head = try parseOpusHead(packets[0])
        let audioPackets = Array(packets.dropFirst(2))

        let decoded = audioPackets.reduce(Int64(0)) { $0 + Int64(Self.packetSampleCount($1)) }
        let finalGranule = pages.last?.granulePosition ?? 0

        return OggOpusStream(head: head, audioPackets: audioPackets,
                             finalGranule: finalGranule, decodedSampleCount: decoded)
    }

    public static func parseOpusHead(_ packet: Data) throws -> OpusHead {
        let b = [UInt8](packet)
        guard b.count >= 19 else { throw OggOpusError.notOpus }
        guard Array(b[0..<8]) == Array("OpusHead".utf8) else { throw OggOpusError.notOpus }
        let channels = Int(b[9])
        let preSkip = Int(b[10]) | (Int(b[11]) << 8)
        let inputRate = Int(b[12]) | (Int(b[13]) << 8) | (Int(b[14]) << 16) | (Int(b[15]) << 24)
        let outputGain = Int(b[16]) | (Int(b[17]) << 8)
        let mappingFamily = Int(b[18])
        return OpusHead(channelCount: channels, preSkip: preSkip,
                        inputSampleRate: inputRate, outputGain: outputGain,
                        channelMappingFamily: mappingFamily)
    }

    // MARK: - Opus packet duration (RFC 6716 §3.1)

    /// Frame size in samples at 48 kHz for each of the 32 TOC configurations.
    private static let frameSizeByConfig: [Int] = [
        480, 960, 1920, 2880,   // 0-3   SILK NB
        480, 960, 1920, 2880,   // 4-7   SILK MB
        480, 960, 1920, 2880,   // 8-11  SILK WB
        480, 960,               // 12-13 Hybrid SWB
        480, 960,               // 14-15 Hybrid FB
        120, 240, 480, 960,     // 16-19 CELT NB
        120, 240, 480, 960,     // 20-23 CELT WB
        120, 240, 480, 960,     // 24-27 CELT SWB
        120, 240, 480, 960      // 28-31 CELT FB
    ]

    /// Decoded sample count (at 48 kHz) for one Opus packet, from its TOC byte.
    public static func packetSampleCount(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSize = frameSizeByConfig[min(config, frameSizeByConfig.count - 1)]
        let code = Int(toc & 0x03)
        let frameCount: Int
        switch code {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        default:
            // Code 3: frame count is in the low 6 bits of the byte after the TOC.
            let bytes = [UInt8](packet)
            frameCount = bytes.count > 1 ? Int(bytes[1] & 0x3F) : 1
        }
        return frameSize * frameCount
    }

    // MARK: - Little-endian readers

    private static func readInt64LE(_ b: [UInt8], _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) }
        return Int64(bitPattern: v)
    }

    private static func readUInt32LE(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * i) }
        return v
    }
}
