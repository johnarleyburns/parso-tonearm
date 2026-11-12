import Foundation

/// Spoken labels, values and hints for Up Next rows and header controls, so
/// VoiceOver and Switch Control get the same information sighted users see.
public enum QueueAccessibility {
    public static let minimumTargetSide: Double = 44

    public static func rowLabel(position: Int, title: String, artist: String,
                                provenance: KeepPlayingProvenance? = nil) -> String {
        let name = artist.isEmpty ? title : "\(title), \(artist)"
        let base = "\(position), \(name)"
        guard let provenance else { return base }
        return "\(base), \(provenance.accessibilitySuffix)"
    }

    public static func rowValue(isCurrent: Bool, isUpNext: Bool = false, duration: Double? = nil) -> String {
        var parts: [String] = []
        if isCurrent { parts.append("Now playing") } else if isUpNext { parts.append("Up next") }
        if let duration, duration > 0 { parts.append(spokenDuration(duration)) }
        return parts.joined(separator: ", ")
    }

    /// "3 minutes 5 seconds" — spoken, not the "3:05" clock face.
    public static func spokenDuration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.minutes, .seconds], width: .wide, zeroValueUnits: .hide)
        return Duration.seconds(total).formatted(style)
    }

    public static func rowHint(isCurrent: Bool) -> String {
        isCurrent ? "Currently playing" : "Plays this track now"
    }

    public static func reorderLabel(isReordering: Bool) -> String {
        isReordering ? "Done Reordering" : "Reorder Up Next"
    }

    public static func keepPlayingValue(isOn: Bool) -> String {
        isOn ? "on" : "off"
    }

    public static let keepPlayingHint = "Toggles adding similar tracks when the queue ends"
    public static let removeActionName = "Remove from queue"
}
