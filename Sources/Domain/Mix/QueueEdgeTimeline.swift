import Foundation

/// Read-only per-edge row model for the Queue transition timeline. Derived from
/// `TransitionPresentation`; it never schedules audio or alters a decision, and
/// it promises nothing the presentation does not carry (no boundary without a
/// known overlap range, no "ready" without a ready preparation state).
public struct QueueEdgeTimeline: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case phrase, beat, other, fallback, unplanned
    }

    public enum Availability: String, Sendable, Equatable {
        case ready, preparing, waiting, failed, stopped, unknown, unavailable, notPlanned
    }

    public let kind: Kind
    public let availability: Availability
    /// Where the outgoing track starts to give way, e.g. "Out 2:05"; nil when timing is unknown.
    public let outgoingBoundary: String?
    /// Where the incoming track is fully in, e.g. "In 2:17"; nil when timing is unknown.
    public let incomingBoundary: String?
    public let kindLabel: String
    public let availabilityLabel: String

    public init(_ presentation: TransitionPresentation) {
        switch presentation.phase {
        case .noEdge, .notPlanned:
            kind = .unplanned
        case .fallback:
            kind = .fallback
        case .preparing, .ready, .overlap, .outgoingTail:
            switch presentation.actualStyle ?? presentation.plannedStyle {
            case .phraseBlend?: kind = .phrase
            case .beatMatched?: kind = .beat
            default: kind = .other
            }
        }
        kindLabel = switch kind {
        case .phrase: String(localized: "Phrase", bundle: .module)
        case .beat: String(localized: "Beat", bundle: .module)
        case .other: (presentation.actualStyle ?? presentation.plannedStyle)?.label ?? String(localized: "Blend", bundle: .module)
        case .fallback: String(localized: "Fallback", bundle: .module)
        case .unplanned: String(localized: "Not planned yet", bundle: .module)
        }

        switch presentation.phase {
        case .noEdge, .notPlanned: availability = .notPlanned
        case .fallback: availability = .unavailable
        case .preparing, .ready, .overlap, .outgoingTail:
            switch presentation.preparation {
            case .ready?: availability = .ready
            case .failed?: availability = .failed
            case .cancelled?: availability = .stopped
            case .waitingForNetwork?, .waitingForWiFi?: availability = .waiting
            case .notPrepared?, .queued?, .downloading?, .analyzing?: availability = .preparing
            case nil: availability = presentation.phase == .preparing ? .preparing : .unknown
            }
        }
        availabilityLabel = switch availability {
        case .ready: String(localized: "Ready", bundle: .module)
        case .preparing: String(localized: "Preparing", bundle: .module)
        case .waiting:
            presentation.preparation == .waitingForWiFi
                ? String(localized: "Waiting for Wi-Fi", bundle: .module)
                : String(localized: "Waiting for network", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .stopped: String(localized: "Stopped", bundle: .module)
        case .unknown: String(localized: "Availability unknown", bundle: .module)
        case .unavailable: String(localized: "Blend unavailable", bundle: .module)
        case .notPlanned: String(localized: "Planned when up next", bundle: .module)
        }

        // Boundaries only for overlapping blends with known timing and a usable edge.
        if let range = presentation.overlapRange, presentation.actualStyle?.overlaps == true,
           kind == .phrase || kind == .beat || kind == .other, availability != .failed {
            outgoingBoundary = String(localized: "Out", bundle: .module) + " " + Self.clock(range.lowerBound)
            incomingBoundary = String(localized: "In", bundle: .module) + " " + Self.clock(range.upperBound)
        } else {
            outgoingBoundary = nil
            incomingBoundary = nil
        }
    }

    /// Visible text, e.g. "Phrase · Out 2:05 → In 2:17 · Ready".
    public var summary: String {
        var parts = [kindLabel]
        if let outgoingBoundary, let incomingBoundary { parts.append("\(outgoingBoundary) → \(incomingBoundary)") }
        if kind != .unplanned { parts.append(availabilityLabel) }
        return parts.joined(separator: " · ")
    }

    public var accessibilityLabel: String {
        var text = String(localized: "Transition", bundle: .module) + ", " + kindLabel
        if let outgoingBoundary, let incomingBoundary {
            text += ", " + String(localized: "outgoing track", bundle: .module) + " " + outgoingBoundary.lowercased()
                + ", " + String(localized: "incoming track", bundle: .module) + " " + incomingBoundary.lowercased()
        } else if kind == .phrase || kind == .beat || kind == .other {
            text += ", " + String(localized: "timing unavailable", bundle: .module)
        }
        if kind != .unplanned { text += ", " + availabilityLabel }
        return text
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}
