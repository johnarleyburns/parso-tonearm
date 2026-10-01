import Foundation

/// Watch redesign A2 — what the Smart Stack widget shows: whatever is playing on either device.
/// The watch app writes it to the shared App Group; the widget extension only reads it.
public struct WatchNowPlayingWidgetState: Codable, Equatable, Sendable {
    public enum Target: String, Codable, Sendable { case watch, iPhone }

    public var title: String
    public var subtitle: String
    public var target: Target
    public var isPlaying: Bool
    /// Elapsed seconds at `anchorDate`; the widget projects forward while playing.
    public var elapsed: Double
    public var duration: Double
    public var anchorDate: Date
    public var colorHex: String?

    public init(title: String, subtitle: String, target: Target, isPlaying: Bool, elapsed: Double,
                duration: Double, anchorDate: Date, colorHex: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.target = target
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
        self.anchorDate = anchorDate
        self.colorHex = colorHex
    }

    /// When the current item started, for `ProgressView(timerInterval:)` while playing.
    public var startDate: Date { anchorDate.addingTimeInterval(-max(0, elapsed)) }
    public var endDate: Date { startDate.addingTimeInterval(max(duration, elapsed + 1)) }

    /// A widget reload is only worth it when what the card shows structurally changes.
    public func differsStructurally(from other: WatchNowPlayingWidgetState?) -> Bool {
        guard let other else { return true }
        return title != other.title || isPlaying != other.isPlaying || target != other.target
            || abs((startDate.timeIntervalSince1970) - other.startDate.timeIntervalSince1970) > 3
    }
}

/// The shared store (App Group `group.guru.parso.tonearm`).
public enum WatchNowPlayingWidgetStore {
    public static let appGroup = "group.guru.parso.tonearm"
    static let key = "watch.nowPlayingWidget.v1"

    public static func save(_ state: WatchNowPlayingWidgetState?, defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: appGroup)
        guard let state else { store?.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(state) { store?.set(data, forKey: key) }
    }

    public static func load(defaults: UserDefaults? = nil) -> WatchNowPlayingWidgetState? {
        let store = defaults ?? UserDefaults(suiteName: appGroup)
        guard let data = store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchNowPlayingWidgetState.self, from: data)
    }
}
