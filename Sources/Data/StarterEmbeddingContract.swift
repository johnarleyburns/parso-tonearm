import Foundation

/// The embedding-space identity a starter catalog's rows must match: `EmbeddingSpace.current`'s
/// `fingerprint`/`dimensions`, crossing the module boundary as a plain value.
///
/// `TonearmCore` (where `StarterLibrary`/`BuiltInMoodTrack` live) cannot import `TonearmDiscovery`
/// (where `EmbeddingSpace` lives) — `TonearmDiscovery` depends on `TonearmCore`, not the other way
/// around. Every starter read/write/merge call that must validate against the installed embedding
/// space takes this contract as a parameter instead; `EmbeddingSpace.current.starterContract`
/// (`Sources/Discovery/EmbeddingSpace+Starter.swift`) builds one from the real, current space.
public struct StarterEmbeddingContract: Equatable, Sendable {
    public let fingerprint: String
    public let dimensions: Int

    public init(fingerprint: String, dimensions: Int) {
        self.fingerprint = fingerprint
        self.dimensions = dimensions
    }
}
