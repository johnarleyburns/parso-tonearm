import Foundation

/// The deck's beat grid (from `beat_grid` + `grid_correction`), a pure value
/// the quantize math and CDJ loop-length conversion read (§30.3, §33.2).
public struct DeckGrid: Sendable, Equatable {
    /// Track sample (in the deck's own sample space) of grid beat 0.
    public var referenceSample: Double
    public var bpm: Double
    public var beatsPerBar: Int
    public var sampleRate: Double

    public init(referenceSample: Double = 0, bpm: Double = 120,
                beatsPerBar: Int = 4, sampleRate: Double = 48_000) {
        self.referenceSample = referenceSample
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.sampleRate = sampleRate
    }

    public var samplesPerBeat: Double {
        60.0 * sampleRate / max(bpm, 1)
    }

    public var samplesPerBar: Double {
        samplesPerBeat * Double(max(beatsPerBar, 1))
    }
}

/// Quantize resolution — the grid division a quantized trigger lands on (§30.3).
public enum QuantizeResolution: UInt8, Sendable {
    case halfBeat = 0
    case beat = 1
    case bar = 2
    case fourBars = 3

    /// The number of beats this resolution spans (`beatsPerBar` for a bar).
    public func divisionCount(beatsPerBar: Int) -> Double {
        let bars = Double(max(beatsPerBar, 1))
        switch self {
        case .halfBeat: return 0.5
        case .beat: return 1
        case .bar: return bars
        case .fourBars: return bars * 4
        }
    }
}

/// The master clock — the device sample timeline in absolute frames (§30.1).
///
/// All engine scheduling is expressed in absolute samples on this timeline.
/// The render thread advances it by the callback frame count; the value is
/// published to the control side through an atomic after each callback (§30.1).
public struct DeckClock: Sendable, Equatable {
    public var masterSample: Int64
    public var sampleRate: Double

    public init(masterSample: Int64 = 0, sampleRate: Double = 48_000) {
        self.masterSample = masterSample
        self.sampleRate = sampleRate
    }

    public mutating func advance(by frameCount: Int64) {
        masterSample += frameCount
    }
}

/// A pre-decoded, interleaved-float PCM source for one deck (§29.2 source node,
/// §12.2 ownership-transfer).
///
/// `DeckSource` is a **pure value** — no references, no ARC traffic — so it
/// crosses the RT boundary safely: the control side boxes it into a heap
/// allocation and hands the raw pointer over via `loadArm`; the render thread
/// reads it with `UnsafeRawPointer.load(as: DeckSource.self)`, which is a plain
/// memory load with no allocation, no lock, and no retain (§12.3, §46.2).
///
/// `@unchecked Sendable`: the contained `UnsafeRawPointer` is not itself
/// `Sendable`, but the value is immutable and never touches ARC, so crossing
/// the boundary as a raw pointer is exactly the intended transfer (§12.2).
public struct DeckSource: @unchecked Sendable {
    /// Interleaved `Float` PCM, `frameCount` frames of `channelCount` channels.
    public let pcm: UnsafeRawPointer
    public let frameCount: Int64
    public let channelCount: Int
    public let sampleRate: Double
    public let grid: DeckGrid

    public init(pcm: UnsafeRawPointer, frameCount: Int64, channelCount: Int,
                sampleRate: Double, grid: DeckGrid) {
        self.pcm = pcm
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.grid = grid
    }
}
