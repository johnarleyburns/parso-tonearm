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
}

public enum WatchStoreBootstrap {
    public static let schema = Schema([WatchStoreMetadata.self])
    public static func inMemory() throws -> ModelContainer { try makeContainer(inMemory: true) }
    public static func open() -> WatchStoreBootstrapResult {
        open(persistent: { try makeContainer(inMemory: false) }, recovery: { try makeContainer(inMemory: true) })
    }
    public static func open(
        persistent: () throws -> ModelContainer,
        recovery: () throws -> ModelContainer
    ) -> WatchStoreBootstrapResult {
        do { return .init(container: try persistent(), state: .ready, recoveryNotice: nil) }
        catch {
            do { return .init(container: try recovery(), state: .recovered, recoveryNotice: "Your watch library is being recovered.") }
            catch { return .init(container: nil, state: .degraded, recoveryNotice: "Your watch library is unavailable. Try reopening Platterhead.") }
        }
    }
    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration("PlatterheadWatch", schema: schema,
            isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
