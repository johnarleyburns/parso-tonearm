import Foundation

/// Read-only view model for the Now Playing transition disclosure. Derived from
/// `TransitionPresentation`; it never schedules or changes audio.
public struct TransitionDisclosure: Sendable, Equatable {
    public enum Section: String, Sendable, Equatable {
        case outgoing, overlap, incoming

        public var label: String {
            switch self {
            case .outgoing: String(localized: "Outgoing", bundle: .module)
            case .overlap: String(localized: "Overlap", bundle: .module)
            case .incoming: String(localized: "Incoming", bundle: .module)
            }
        }
    }

    public let outgoingTrackID: Int64?
    public let incomingTrackID: Int64?
    /// The section currently audible.
    public let section: Section
    /// Match type wording, e.g. "Beat-matched".
    public let matchType: String
    /// 0...1 through the overlap; nil when timing is unknown or nothing overlaps.
    public let overlapProgress: Double?

    /// nil when there is no blend to disclose (the no-transition fallback).
    public init?(_ presentation: TransitionPresentation, position: Double) {
        guard presentation.isBlendingNow, presentation.phase != .fallback,
              presentation.outgoingTrackID != nil, presentation.incomingTrackID != nil,
              let style = presentation.actualStyle ?? presentation.plannedStyle else { return nil }
        outgoingTrackID = presentation.outgoingTrackID
        incomingTrackID = presentation.incomingTrackID
        matchType = style.label
        if presentation.phase == .outgoingTail {
            section = .incoming
            overlapProgress = presentation.overlapRange == nil ? nil : 1
        } else if let range = presentation.overlapRange {
            section = .overlap
            let span = max(range.upperBound - range.lowerBound, 0.001)
            overlapProgress = min(max((position - range.lowerBound) / span, 0), 1)
        } else {
            section = .overlap
            overlapProgress = nil
        }
    }

    public var progressPercent: Int? { overlapProgress.map { Int(($0 * 100).rounded()) } }

    /// Spoken summary appended to the card's VoiceOver value.
    public var spokenSummary: String {
        var text = "\(section.label), \(matchType)"
        if let progressPercent {
            text += ", " + String(localized: "overlap", bundle: .module) + " \(progressPercent) %"
        }
        return text
    }
}
