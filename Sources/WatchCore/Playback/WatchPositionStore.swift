import Foundation
import TonearmWatchProtocol

public enum WatchPositionStore {
    private static let positionKey = "guru.parso.tonearm.watch.playback.position"

    public static func save(_ snapshot: WatchQueueSnapshot,
                            defaults: (any DefaultsStoring)? = nil) {
        let ud: any DefaultsStoring = defaults ?? UserDefaults.standard
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        ud.set(data, forKey: positionKey)
    }

    public static func load(defaults: (any DefaultsStoring)? = nil) -> WatchQueueSnapshot? {
        let ud: any DefaultsStoring = defaults ?? UserDefaults.standard
        guard let data = ud.data(forKey: positionKey),
              let snapshot = try? JSONDecoder().decode(WatchQueueSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    public static func clear(defaults: (any DefaultsStoring)? = nil) {
        let ud: any DefaultsStoring = defaults ?? UserDefaults.standard
        ud.removeObject(forKey: positionKey)
    }

    /// Returns the saved position or nil if no saved state or corrupt data.
    /// Corrupt data triggers a clear so the next save starts fresh.
    public static func loadOrClear(defaults: (any DefaultsStoring)? = nil) -> WatchQueueSnapshot? {
        let ud: any DefaultsStoring = defaults ?? UserDefaults.standard
        guard let data = ud.data(forKey: positionKey) else { return nil }
        if let snapshot = try? JSONDecoder().decode(WatchQueueSnapshot.self, from: data) {
            return snapshot
        }
        ud.removeObject(forKey: positionKey)
        return nil
    }
}
