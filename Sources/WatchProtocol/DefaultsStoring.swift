import Foundation

/// The subset of `UserDefaults` the app's preference stores actually use.
///
/// Production keeps `UserDefaults` (which conforms below, unchanged); tests
/// inject `InMemoryDefaultsStore` so no suite touches the real preferences
/// daemon, its IPC, or process-wide shared standard domain.
public protocol DefaultsStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func integer(forKey defaultName: String) -> Int
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    /// Used by the watch store's "reset requested" bootstrap path.
    func removePersistentDomain(forName domainName: String)
}

/// A store that can safely cross isolation boundaries (an in-memory dictionary
/// behind a lock, for example). `UserDefaults` itself is not `Sendable`; do not
/// add this conformance to it.
public protocol SendableDefaultsStoring: DefaultsStoring, Sendable {}

extension UserDefaults: DefaultsStoring {}

/// A thread-safe, process-local `DefaultsStoring` backed by a plain dictionary.
///
/// A test that models a relaunch should reuse the same instance across the
/// reconstructed objects, exactly like a real suite persists across launches.
public final class InMemoryDefaultsStore: DefaultsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: AnyObject] = [:]

    public init() {}

    public func object(forKey defaultName: String) -> Any? {
        lock.withLock { storage[defaultName] }
    }

    public func bool(forKey defaultName: String) -> Bool {
        lock.withLock { storage[defaultName] as? Bool ?? false }
    }

    public func data(forKey defaultName: String) -> Data? {
        lock.withLock { storage[defaultName] as? Data }
    }

    public func integer(forKey defaultName: String) -> Int {
        lock.withLock { storage[defaultName] as? Int ?? 0 }
    }

    public func string(forKey defaultName: String) -> String? {
        lock.withLock { storage[defaultName] as? String }
    }

    public func stringArray(forKey defaultName: String) -> [String]? {
        lock.withLock { storage[defaultName] as? [String] }
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock {
            storage[defaultName] = value.map { $0 as AnyObject }
        }
    }

    public func removeObject(forKey defaultName: String) {
        lock.withLock { storage[defaultName] = nil }
    }

    public func removePersistentDomain(forName domainName: String) {
        lock.withLock { storage.removeAll() }
    }
}
