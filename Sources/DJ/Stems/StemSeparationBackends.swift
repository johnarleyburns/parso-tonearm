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
/// current_status.md "Phase 7"). Both backends are registered; **Demucs is
/// active by default** as of Phase 9 (docs/GPL-BACKENDS.md) — the author's
/// own licensing call for this app specifically, made independently of
/// PAE's own stance (PAE's README still names Spleeter as *its*
/// recommended default for consumers who haven't made that call). Spleeter
/// stays registered as a fallback backend (e.g. for a future device-class
/// or licensing-mode switch) but is not selected unless explicitly
/// activated.
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
        let registry = SeparationBackendRegistry(default: demucs)
        await registry.register(.spleeter) {
            SpleeterStemModel(source: ModelResourceTagSource(resource: resource, tag: .spleeterStems))
        }
        await registry.register(demucs) {
            DemucsStemModel(resource: resource)
        }
        return registry
    }
}
