import Combine
import Foundation

/// The Recorded Mixes screen's model (§41.12, mockup `ipad/10`; plan 5.12):
/// the finished-mix library and the on-device storage readout. FR-REC-5 — mixes
/// are ordinary playable items and this screen is **free**: it is not Pro-gated
/// (a user whose entitlement has not restored yet still plays what they
/// recorded). Recordings are user content and are never auto-evicted (§43.6).
@MainActor
public final class MixesModel: ObservableObject {
    /// One library row — the mix plus the honesty its state carries (§46.2: a
    /// `corrupt` row is shown, never silently dropped).
    public struct Row: Identifiable, Equatable {
        public var id: Int64 { mix.id ?? 0 }
        public let mix: DJMix

        public init(mix: DJMix) {
            self.mix = mix
        }
    }

    @Published public private(set) var rows: [Row] = []
    /// Total on-device size of finished mixes (mockup `ipad/10`'s storage card).
    @Published public private(set) var storageBytes: Int64 = 0
    @Published public private(set) var isLoaded = false

    public let repository: any MixServicing

    public init(repository: any MixServicing = MixRepository()) {
        self.repository = repository
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var summaryText: String {
        "\(rows.count) mix\(rows.count == 1 ? "" : "es") · \(Self.formattedBytes(storageBytes))"
    }

    public func begin() async {
        do {
            rows = try await repository.completedMixes().map(Row.init)
            storageBytes = try await repository.mixStorageBytes()
        } catch {
            // A failed read is an honest empty list with the storage unchanged
            // — never a crash (§46.2).
            rows = []
        }
        isLoaded = true
    }

    /// Delete a mix (row + user-content audio) and refresh.
    public func delete(_ row: Row) async {
        guard let mixID = row.mix.id else { return }
        try? await repository.deleteMix(mixID: mixID)
        await begin()
    }

    public func mixStorageText() -> String {
        Self.formattedBytes(storageBytes)
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
