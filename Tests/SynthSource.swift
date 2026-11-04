import Foundation
@testable import TonearmCore

/// A silent, range-free deck source for tests that only need an opened `StarterDeckSource`.
final class SynthSource: StarterDeckSource, @unchecked Sendable {
    let sampleRate: Double
    let totalFrames: Int64
    private let lock = NSLock()
    private var cancelledFlag = false
    init(low: Double, high: Double, seconds: Double, rate: Double = 44_100) {
        sampleRate = rate; totalFrames = Int64(seconds * rate)
    }
    var isCancelled: Bool { lock.withLock { cancelledFlag } }
    func cancel() { lock.withLock { cancelledFlag = true } }
    func read(startFrame: Int64, count: Int) throws -> [[Float]] {
        if isCancelled { throw ReleaseRangeError.cancelled }
        let n = Int(max(0, min(Int64(count), totalFrames - startFrame)))
        let out = [Float](repeating: 0, count: n)
        return [out, out]
    }
}
