#if !os(watchOS)
import TonearmCore

/// Bridges `EmbeddingSpace.current` into the plain `StarterEmbeddingContract` that
/// `TonearmCore`'s starter read/write/merge functions take — `TonearmCore` cannot import
/// `TonearmDiscovery` (the dependency runs the other way), so this is the one place that
/// constructs the contract from the real, installed embedding space.
extension EmbeddingSpace {
    public var starterContract: StarterEmbeddingContract {
        StarterEmbeddingContract(fingerprint: fingerprint, dimensions: dimensions)
    }
}
#endif
