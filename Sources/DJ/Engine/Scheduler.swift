import Foundation

/// Pure sample-accurate event scheduling (§30.2–30.3).
///
/// The scheduler holds no state and does no I/O — it is the pure kernel the
/// render layer composes inside the callback (the §32.3 pure/shell split): the
/// render thread *applies* the absolute master-timeline frame a function here
/// returns. Everything is deterministic and unit-testable off any device.
public enum Scheduler {

    /// The next grid division boundary **strictly after** `sample` (§30.3).
    ///
    /// A trigger already sitting on a boundary moves to the *next* one — that is
    /// what a DJ expects from "quantize": you press just before the beat and it
    /// lands on that beat, never on the one you already passed.
    public static func quantizedBoundary(after sample: Int64, resolution: QuantizeResolution,
                                         grid: DeckGrid) -> Int64 {
        let divisionSamples = grid.samplesPerBeat
            * resolution.divisionCount(beatsPerBar: grid.beatsPerBar)
        let relative = Double(sample) - grid.referenceSample
        let division = (relative / divisionSamples).rounded(.down) + 1
        return Int64(grid.referenceSample + division * divisionSamples)
    }

    /// The absolute master-timeline sample at which a trigger targeting
    /// `targetSample` fires (§30.2).
    ///
    /// Unquantized: immediately, at `masterSample` (the current callback's frame
    /// 0 — "applied at the next render boundary", §34.1). Quantized: on the next
    /// grid boundary after `playhead`, translated into master frames through the
    /// deck's current `rate`. Exact for `rate == 1`; the tempo-mapped refinement
    /// lands with commit 4.5's time-pitch.
    public static func triggerFrame(playhead: Int64, masterSample: Int64, targetSample: Int64,
                                    quantized: Bool, resolution: QuantizeResolution,
                                    grid: DeckGrid, rate: Double) -> Int64 {
        guard quantized else { return masterSample }
        let boundary = quantizedBoundary(after: playhead, resolution: resolution, grid: grid)
        let framesUntil = Double(boundary - playhead) / max(rate, 0.000_1)
        return masterSample + Int64(framesUntil)
    }
}
