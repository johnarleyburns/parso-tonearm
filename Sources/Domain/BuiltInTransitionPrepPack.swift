import Foundation
#if canImport(Compression)
import Compression
#endif

/// The Mood Starter library's transition-prep payloads (beat grid, downbeats, sections, key,
/// loudness, waveform), computed on the Mac by BuiltInAnalyzer with the same `TrackGridAnalyzer`
/// the phone runs, so Build a Mix's transitions are ready on install instead of "Preparing…"
/// (which meant downloading and decoding every track on the phone).
///
/// A compact binary pack, LZFSE-compressed as a whole: beat and downbeat times are delta-encoded
/// in 0.1 ms steps (their regular spacing compresses very well) and waveform bins are quantised.
/// The iPhone pack carries one waveform bin per second; the Mac pack the full waveform.
public enum BuiltInTransitionPrepPack {
    public static let magic: [UInt8] = Array("PHTP".utf8)
    public static let formatVersion: UInt8 = 1
    /// 0.1 ms per tick for times.
    static let ticksPerSecond = 10_000.0

    public enum PackError: Error, Equatable {
        case badMagic, unsupportedVersion(UInt8), truncated, compression
    }

    // MARK: - Encode

    public static func encode(_ entries: [(id: String, payload: DJTrackPrepPayload)],
                              coarseWaveform: Bool) throws -> Data {
        var writer = Writer()
        writer.bytes(magic)
        writer.u8(formatVersion)
        writer.u32(UInt32(entries.count))
        for (id, original) in entries {
            var payload = original
            if coarseWaveform {
                payload.waveform = coarse(payload.waveform, duration: payload.duration)
            }
            writer.string(id)
            writer.string(payload.algorithmID)
            writer.u16(UInt16(clamping: payload.version))
            writer.f64(payload.sampleRate)
            writer.u8(UInt8(clamping: payload.channels))
            writer.i64(payload.sourceFrameCount)
            writer.f64(payload.duration)
            writer.f64(payload.bpm)
            writer.f32(Float(payload.tempoConfidence))
            writer.u8(payload.isConstantTempo ? 1 : 0)
            writer.u8(UInt8(clamping: payload.key.tonic))
            writer.string(payload.key.mode)
            writer.string(payload.key.camelot)
            writer.string(payload.key.openKey)
            writer.f32(Float(payload.key.confidence))
            writer.times(payload.beatPositions)
            writer.times(payload.downbeatPositions)
            writer.u32(UInt32(payload.sections.count))
            for section in payload.sections {
                writer.i64(Int64((section.start * ticksPerSecond).rounded()))
                writer.string(section.kind)
                writer.i32(Int32(clamping: section.bar))
            }
            let bands = payload.waveform.map(\.bandRMS.count).max() ?? 0
            writer.u32(UInt32(payload.waveform.count))
            writer.u8(UInt8(clamping: bands))
            for bin in payload.waveform {
                writer.i16(quantizeSigned(bin.min))
                writer.i16(quantizeSigned(bin.max))
                writer.u16(quantizeLevel(bin.rms))
                for band in 0..<bands {
                    writer.u16(quantizeLevel(bin.bandRMS.indices.contains(band) ? bin.bandRMS[band] : 0))
                }
            }
            writer.u8(UInt8(clamping: payload.loudness.count))
            for value in payload.loudness { writer.f64(value) }
        }
        return try compress(writer.data)
    }

    // MARK: - Decode

    public static func decode(_ packed: Data) throws -> [String: DJTrackPrepPayload] {
        var reader = Reader(try decompress(packed))
        guard try reader.bytes(4) == magic else { throw PackError.badMagic }
        let version = try reader.u8()
        guard version == formatVersion else { throw PackError.unsupportedVersion(version) }
        let count = try reader.u32()
        var result: [String: DJTrackPrepPayload] = [:]
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            let id = try reader.string()
            let algorithmID = try reader.string()
            let payloadVersion = Int(try reader.u16())
            let sampleRate = try reader.f64()
            let channels = Int(try reader.u8())
            let frames = try reader.i64()
            let duration = try reader.f64()
            let bpm = try reader.f64()
            let tempoConfidence = Double(try reader.f32())
            let constant = try reader.u8() == 1
            let key = DJTrackPrepPayload.Key(
                tonic: Int(try reader.u8()), mode: try reader.string(), camelot: try reader.string(),
                openKey: try reader.string(), confidence: Double(try reader.f32()))
            let beats = try reader.times()
            let downbeats = try reader.times()
            var sections: [DJTrackPrepPayload.Section] = []
            for _ in 0..<(try reader.u32()) {
                let start = Double(try reader.i64()) / ticksPerSecond
                sections.append(.init(start: start, kind: try reader.string(), bar: Int(try reader.i32())))
            }
            let binCount = try reader.u32()
            let bands = Int(try reader.u8())
            var waveform: [DJTrackPrepPayload.WaveformBin] = []
            waveform.reserveCapacity(Int(binCount))
            for _ in 0..<binCount {
                let low = dequantizeSigned(try reader.i16())
                let high = dequantizeSigned(try reader.i16())
                let rms = dequantizeLevel(try reader.u16())
                var bandRMS: [Float] = []
                for _ in 0..<bands { bandRMS.append(dequantizeLevel(try reader.u16())) }
                waveform.append(.init(min: low, max: high, rms: rms, bandRMS: bandRMS))
            }
            var loudness: [Double] = []
            for _ in 0..<(try reader.u8()) { loudness.append(try reader.f64()) }
            result[id] = DJTrackPrepPayload(
                version: payloadVersion, algorithmID: algorithmID, sampleRate: sampleRate, channels: channels, sourceFrameCount: frames, duration: duration,
                bpm: bpm, tempoConfidence: tempoConfidence, beatPositions: beats,
                downbeatPositions: downbeats, isConstantTempo: constant, key: key, sections: sections,
                waveform: waveform, loudness: loudness)
        }
        return result
    }

    // MARK: - Waveform

    /// One bin per second: min of mins, max of maxes, RMS of RMS (per band).
    public static func coarse(_ bins: [DJTrackPrepPayload.WaveformBin],
                              duration: Double) -> [DJTrackPrepPayload.WaveformBin] {
        let target = max(1, Int(duration.rounded(.up)))
        guard bins.count > target else { return bins }
        func rms(_ values: [Float]) -> Float {
            (values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count))).squareRoot()
        }
        return (0..<target).map { index in
            let lower = index * bins.count / target
            let upper = min(bins.count, max(lower + 1, (index + 1) * bins.count / target))
            let slice = bins[lower..<upper]
            let bandCount = slice.map(\.bandRMS.count).max() ?? 0
            return .init(min: slice.map(\.min).min() ?? 0, max: slice.map(\.max).max() ?? 0,
                         rms: rms(slice.map(\.rms)),
                         bandRMS: (0..<bandCount).map { band in
                             rms(slice.map { $0.bandRMS.indices.contains(band) ? $0.bandRMS[band] : 0 })
                         })
        }
    }

    static func quantizeSigned(_ value: Float) -> Int16 {
        Int16((max(-1, min(1, value.isFinite ? value : 0)) * 32_767).rounded())
    }
    static func dequantizeSigned(_ value: Int16) -> Float { Float(value) / 32_767 }
    /// Levels are square-root companded so quiet passages (the leading-silence check works at
    /// -50 dBFS) keep their resolution.
    static func quantizeLevel(_ value: Float) -> UInt16 {
        UInt16((max(0, min(1, value.isFinite ? value : 0)).squareRoot() * 65_535).rounded())
    }
    static func dequantizeLevel(_ value: UInt16) -> Float {
        let root = Float(value) / 65_535
        return root * root
    }

    // MARK: - Compression

    static func compress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        do { return try (data as NSData).compressed(using: .lzfse) as Data }
        catch { throw PackError.compression }
        #else
        return data
        #endif
    }

    static func decompress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        do { return try (data as NSData).decompressed(using: .lzfse) as Data }
        catch { throw PackError.compression }
        #else
        return data
        #endif
    }

    // MARK: - Binary I/O

    struct Writer {
        var data = Data()
        mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }
        mutating func u8(_ value: UInt8) { data.append(value) }
        mutating func u16(_ value: UInt16) { append(value.littleEndian) }
        mutating func i16(_ value: Int16) { append(value.littleEndian) }
        mutating func u32(_ value: UInt32) { append(value.littleEndian) }
        mutating func i32(_ value: Int32) { append(value.littleEndian) }
        mutating func i64(_ value: Int64) { append(value.littleEndian) }
        mutating func f32(_ value: Float) { append(value.bitPattern.littleEndian) }
        mutating func f64(_ value: Double) { append(value.bitPattern.littleEndian) }
        mutating func string(_ value: String) {
            let utf8 = Array(value.utf8.prefix(Int(UInt16.max)))
            u16(UInt16(utf8.count))
            bytes(utf8)
        }
        /// Seconds → 0.1 ms ticks, delta-encoded (absolute ticks are rounded first, so error never
        /// accumulates).
        mutating func times(_ values: [Double]) {
            u32(UInt32(values.count))
            var previous: Int64 = 0
            for value in values {
                let ticks = Int64((value * BuiltInTransitionPrepPack.ticksPerSecond).rounded())
                i64Varint(ticks - previous)
                previous = ticks
            }
        }
        /// Zig-zag varint: regular beat gaps take 2–3 bytes before compression.
        mutating func i64Varint(_ value: Int64) {
            var zigzag = UInt64(bitPattern: (value << 1) ^ (value >> 63))
            repeat {
                var byte = UInt8(zigzag & 0x7F)
                zigzag >>= 7
                if zigzag != 0 { byte |= 0x80 }
                data.append(byte)
            } while zigzag != 0
        }
        private mutating func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
    }

    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= data.count else { throw PackError.truncated }
            defer { offset += count }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + count])
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { try integer() }
        mutating func i16() throws -> Int16 { try integer() }
        mutating func u32() throws -> UInt32 { try integer() }
        mutating func i32() throws -> Int32 { try integer() }
        mutating func i64() throws -> Int64 { try integer() }
        mutating func f32() throws -> Float { Float(bitPattern: try integer()) }
        mutating func f64() throws -> Double { Double(bitPattern: try integer()) }
        mutating func string() throws -> String {
            let count = Int(try u16())
            return String(decoding: try bytes(count), as: UTF8.self)
        }
        mutating func times() throws -> [Double] {
            let count = try u32()
            var values: [Double] = []
            values.reserveCapacity(Int(count))
            var ticks: Int64 = 0
            for _ in 0..<count {
                ticks += try i64Varint()
                values.append(Double(ticks) / BuiltInTransitionPrepPack.ticksPerSecond)
            }
            return values
        }
        mutating func i64Varint() throws -> Int64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try u8()
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                guard shift < 64 else { throw PackError.truncated }
            }
            return Int64(bitPattern: (result >> 1)) ^ -Int64(bitPattern: result & 1)
        }
        private mutating func integer<T: FixedWidthInteger>() throws -> T {
            let raw = try bytes(MemoryLayout<T>.size)
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { buffer in
                for (index, byte) in raw.enumerated() { buffer[index] = byte }
            }
            return T(littleEndian: value)
        }
    }
}
