import Foundation

public enum WidgetSnapshotStore {
    public static let appGroupIdentifier = "group.guru.parso.tonearm"
    private static let snapshotKey = "guru.parso.tonearm.widget.snapshot.v1"

    public static func load(now: Date = Date()) -> WidgetSnapshot {
        guard
            let defaults = sharedDefaults(),
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else {
            return .empty(now: now)
        }
        return snapshot
    }

    public static func save(_ snapshot: WidgetSnapshot) {
        guard
            let defaults = sharedDefaults(),
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }
        defaults.set(data, forKey: snapshotKey)
    }

    private static func sharedDefaults() -> UserDefaults? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            print("WidgetSnapshotStore: App Group suite \(appGroupIdentifier) unavailable — check entitlements")
            return nil
        }
        return defaults
    }
}
