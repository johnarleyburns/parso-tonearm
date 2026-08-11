import Foundation

/// Binary BLOB layouts for dense analysis arrays (Appendix C — normative).
///
/// All layouts are little-endian and begin with a 4-byte magic that lets a
/// reader reject a mismatched blob and trigger regeneration (§17, §46.2) rather
/// than misparse.
public enum AnalysisBlobLayouts {

    // MARK: - FrameFeatures

    /// Feature values per frame in a fixed order (the `featureMask` bitmask).
    public enum Feature: UInt8, CaseIterable, Sendable {
        case centroid = 0
        case rolloff = 1
        case flux = 2
        case rms = 3
        case zcr = 4
        case bandEnergy = 5

        public var maskValue: Int {
            1 << rawValue
        }
    }

    public struct FrameFeaturesHeader {
        public var featureCount: UInt16
        public var frameCount: UInt32
        public var hopSeconds: Float32
        public var fftSize: Int
        public var sampleRate: Int
        public var featureMask: Int
    }

    /// Layout: `{u32 magic=0x54524646, u16 version, u16 featureCount, u32 frameCount,
    /// f32 hopSeconds, u32 fftSize, u32 sampleRate, u32 featureMask}`
    /// then `frameCount × featureCount × f32` row-major (feature order fixed).
    public static func encodeFrameFeatures(_ frames: [SpectralFrame],
                                           hopSeconds: Double,
                                           fftSize: Int,
                                           sampleRate: Int,
                                           version: Int) -> Data {
        var data = Data()
        appendMagic("FRFF", to: &data)
        appendU16(UInt16(version), to: &data)
        appendU16(UInt16(Feature.allCases.count), to: &data)
        appendU32(UInt32(frames.count), to: &data)
        appendF32(Float(hopSeconds), to: &data)
        appendU32(UInt32(fftSize), to: &data)
        appendU32(UInt32(sampleRate), to: &data)
        let mask = Feature.allCases.reduce(0) { $0 | $1.maskValue }
        appendU32(UInt32(mask), to: &data)

        for frame in frames {
            appendF32(frame.centroid, to: &data)
            appendF32(frame.rolloff, to: &data)
            appendF32(frame.flux, to: &data)
            appendF32(frame.rms, to: &data)
            appendF32(frame.zcr, to: &data)
            for b in 0..<8 { appendF32(frame.bandEnergy[b], to: &data) }
        }
        return data
    }

    /// Decodes to the number of frames, feature count and a column view for one
    /// feature — enough for readers and tests without boxing every value.
    public static func decodeFrameFeatures(_ data: Data) throws -> (frameCount: Int, featureCount: Int, values: [Float]) {
        var reader = DataReader(data)
        guard let magic = reader.read4(), magic == "FRFF" else { throw BlobError.badMagic }
        _ = try reader.u16()   // version
        let featureCount = Int(try reader.u16())
        let frameCount = Int(try reader.u32())
        _ = try reader.f32()   // hopSeconds
        _ = try reader.u32()   // fftSize
        _ = try reader.u32()   // sampleRate
        _ = try reader.u32()   // featureMask

        let total = frameCount * featureCount
        var values: [Float] = []
        values.reserveCapacity(total)
        for _ in 0..<total {
            values.append(try reader.f32())
        }
        return (frameCount, featureCount, values)
    }

    // MARK: - OnsetEnvelope

    /// Layout: `{u32 magic=0x5445534e, u16 version, u16 _reserved, u32 count, f32 hopSeconds}`
    /// then `count × f32`.
    public static func encodeOnsetEnvelope(_ envelope: [Float],
                                           frameRateHz: Double,
                                           version: Int) -> Data {
        var data = Data()
        appendMagic("NESO", to: &data)
        appendU16(UInt16(version), to: &data)
        appendU16(0, to: &data)
        appendU32(UInt32(envelope.count), to: &data)
        appendF32(Float(frameRateHz), to: &data)
        for v in envelope { appendF32(v, to: &data) }
        return data
    }

    public static func decodeOnsetEnvelope(_ data: Data) throws -> (count: Int, frameRateHz: Double, values: [Float]) {
        var reader = DataReader(data)
        guard let magic = reader.read4(), magic == "NESO" else { throw BlobError.badMagic }
        _ = try reader.u16()   // version
        _ = try reader.u16()   // reserved
        let count = Int(try reader.u32())
        let frameRateHz = Double(try reader.f32())
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try reader.f32()) }
        return (count, frameRateHz, values)
    }

    // MARK: - Helpers

    public enum BlobError: Error { case badMagic }

    private static func appendMagic(_ s: String, to data: inout Data) {
        data.append(contentsOf: Array(s.utf8))
    }

    private static func appendU16(_ v: UInt16, to data: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ v: UInt32, to data: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendF32(_ v: Float, to data: inout Data) {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private struct DataReader {
        private let data: Data
        private var index = 0
        init(_ data: Data) { self.data = data }

        mutating func read4() -> String? {
            guard index + 4 <= data.count else { return nil }
            let bytes = Array(data[index..<(index + 4)])
            index += 4
            return String(bytes: bytes, encoding: .ascii)
        }

        mutating func u16() throws -> UInt16 {
            guard index + 2 <= data.count else { throw BlobError.badMagic }
            let v = data[index..<(index + 2)].withUnsafeBytes { $0.load(as: UInt16.self) }
            index += 2
            return v.littleEndian
        }

        mutating func u32() throws -> UInt32 {
            guard index + 4 <= data.count else { throw BlobError.badMagic }
            let v = data[index..<(index + 4)].withUnsafeBytes { $0.load(as: UInt32.self) }
            index += 4
            return v.littleEndian
        }

        mutating func f32() throws -> Float {
            let raw = try u32()
            return Float(bitPattern: raw)
        }
    }
}
