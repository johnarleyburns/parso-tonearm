import Foundation
import SwiftData

@Model
public final class WatchStoreMetadata {
    @Attribute(.unique) public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public enum WatchStoreLaunchState: String, Equatable, Sendable { case opening, ready, recovered, degraded }

public struct WatchStoreBootstrapResult: @unchecked Sendable {
    public let container: ModelContainer?
    public let state: WatchStoreLaunchState
    public let recoveryNotice: String?
    public let quarantinedStoreURL: URL?
    /// Audio that survived a store rebuild. Names and sizes only — see `WatchRecoverableFileSnapshot`.
    public let recoverableFiles: [WatchRecoverableFileSnapshot]
    /// Where watch audio lives, so callers can build a repository without recomputing the path.
    public let audioDirectory: URL?

    public init(container: ModelContainer?, state: WatchStoreLaunchState, recoveryNotice: String?,
                quarantinedStoreURL: URL?, recoverableFiles: [WatchRecoverableFileSnapshot],
                audioDirectory: URL? = nil) {
        self.container = container; self.state = state; self.recoveryNotice = recoveryNotice
        self.quarantinedStoreURL = quarantinedStoreURL; self.recoverableFiles = recoverableFiles
        self.audioDirectory = audioDirectory
    }
}

public enum WatchStoreBootstrap {
    public static let schema = Schema(WatchSchemaV1.models)
    public static let storeName = "PlatterheadWatch"

    public static func inMemory() throws -> ModelContainer { try makeContainer(inMemory: true, storeURL: nil) }

    public static func open() -> WatchStoreBootstrapResult {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(storeName, isDirectory: true)
        return open(storeURL: root.appendingPathComponent("library.store"),
                    audioDirectory: root.appendingPathComponent("WatchAudio", isDirectory: true))
    }

    /// Never `fatalError`s. On an unreadable store the failed files are moved to a dated quarantine
    /// directory, a fresh store is opened in their place, and the audio directory is left untouched
    /// so downloaded tracks can be adopted back after the phone reconciles.
    public static func open(storeURL: URL, audioDirectory: URL, now: Date = Date()) -> WatchStoreBootstrapResult {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        if let container = try? makeContainer(inMemory: false, storeURL: storeURL) {
            return .init(container: container, state: .ready, recoveryNotice: nil,
                         quarantinedStoreURL: nil, recoverableFiles: [], audioDirectory: audioDirectory)
        }

        let quarantined = quarantine(storeURL: storeURL, now: now)
        let retained = WatchLibraryRepository.recoverableFiles(at: audioDirectory)
        do {
            let container = try makeContainer(inMemory: false, storeURL: storeURL)
            return .init(container: container, state: .recovered,
                         recoveryNotice: "Your watch library was rebuilt. Downloaded music is safe and will be checked against your iPhone.",
                         quarantinedStoreURL: quarantined, recoverableFiles: retained, audioDirectory: audioDirectory)
        } catch {
            return .init(container: nil, state: .degraded,
                         recoveryNotice: "Your watch library is unavailable. Downloaded music has been kept — reopen Platterhead to try again.",
                         quarantinedStoreURL: quarantined, recoverableFiles: retained, audioDirectory: audioDirectory)
        }
    }

    public static func open(
        persistent: () throws -> ModelContainer,
        recovery: () throws -> ModelContainer
    ) -> WatchStoreBootstrapResult {
        do { return .init(container: try persistent(), state: .ready, recoveryNotice: nil, quarantinedStoreURL: nil, recoverableFiles: []) }
        catch {
            do { return .init(container: try recovery(), state: .recovered, recoveryNotice: "Your watch library is being recovered.", quarantinedStoreURL: nil, recoverableFiles: []) }
            catch { return .init(container: nil, state: .degraded, recoveryNotice: "Your watch library is unavailable. Try reopening Platterhead.", quarantinedStoreURL: nil, recoverableFiles: []) }
        }
    }

    private static func makeContainer(inMemory: Bool, storeURL: URL?) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(storeName, schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(storeName, schema: schema,
                isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: WatchSchemaMigrationPlan.self, configurations: configuration)
    }

    /// Moves the store and its sidecars aside rather than deleting them, so a failed upgrade can be
    /// diagnosed later. Returns the quarantine directory when anything was actually moved.
    private static func quarantine(storeURL: URL, now: Date) -> URL? {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = storeURL.deletingLastPathComponent().appendingPathComponent("Quarantine/\(stamp)", isDirectory: true)
        var moved = false
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
                moved = true
            } catch { continue }
        }
        return moved ? destination : nil
    }
}

public enum WatchSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [WatchStoreMetadata.self, WatchTrackModel.self, WatchAssetModel.self, WatchPlaylistModel.self,
         WatchPlaylistEntryModel.self, WatchDownloadJobModel.self, WatchDownloadRootModel.self,
         WatchPlaybackStateModel.self, WatchSyncStateModel.self]
    }
}

/// One shipped version so far. Additive model changes migrate lightweight through this plan; a
/// change that cannot, gets a `WatchSchemaV2` and an explicit stage here.
public enum WatchSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [WatchSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
