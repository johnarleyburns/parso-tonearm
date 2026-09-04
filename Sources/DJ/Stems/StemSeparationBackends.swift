import Foundation
import ParsoAudioNeural

/// Adapts one `ModelResourceService` tag to `ParsoAudioNeural`'s
/// `NeuralModelProviding` seam, so `SpleeterStemModel` can be driven by the
/// same ODR plumbing every other model on this app already uses.
private struct ModelResourceTagSource: NeuralModelProviding {
    let resource: ModelResourceService
    let tag: ModelTag

    var isAvailable: Bool {
        get async { await resource.isAvailable(tag) }
    }

    func modelURL() async throws -> URL {
        guard let url = await resource.url(for: tag) else {
            throw NeuralModelError.modelUnavailable
        }
        return url
    }
}

/// Composes this app's `SeparationBackendRegistry` (Phase 7c,
/// current_status.md "Phase 7"): Spleeter registered and **active by
/// default** (the author's licensing determination — MIT code + weights;
/// see `SpleeterStemModel.swift`'s header in `ParsoAudioNeural`); Demucs
/// registered but inactive (its pretrained weights are not established as
/// commercially clean — same doc, "The Demucs finding").
///
/// Swapping the active backend, including to a future BS-RoFormer-class
/// model once one is cleanly licensed, is exactly `registry.register(...)`
/// for the new conformance + `registry.setActive(...)` — nothing else in the
/// separation pipeline (`StemSeparator`, `StemCache`, `StemService`) changes.
public enum StemSeparationBackends {
    public static let demucs = SeparationBackendID(rawValue: "demucs")

    /// - Parameter resource: the app's `ModelResourceService` (ODR delivery
    ///   for both `.spleeterStems` and `.stems`).
    public static func makeRegistry(resource: ModelResourceService) async -> SeparationBackendRegistry {
        let registry = SeparationBackendRegistry(default: .spleeter)
        await registry.register(.spleeter) {
            SpleeterStemModel(source: ModelResourceTagSource(resource: resource, tag: .spleeterStems))
        }
        await registry.register(demucs) {
            DemucsStemModel(resource: resource)
        }
        return registry
    }
}
