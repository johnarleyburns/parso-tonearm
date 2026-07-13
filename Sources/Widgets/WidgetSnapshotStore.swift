import Foundation

enum WidgetSnapshotStore {
    static let appGroupIdentifier = "group.guru.parso.tonearm"
    private static let snapshotKey = "guru.parso.tonearm.widget.snapshot.v1"

    static func load(now: Date = Date()) -> WidgetSnapshot {
        guard
            let defaults = sharedDefaults(),
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else {
            return .empty(now: now)
        }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard
            let defaults = sharedDefaults(),
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }
        defaults.set(data, forKey: snapshotKey)
    }

    private static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
