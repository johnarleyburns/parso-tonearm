import Foundation

/// What the Now Playing "Blending now" card shows, derived from the reconciled presentation and
/// the renderer's execution snapshot. Read-only; it never schedules or changes audio.
public struct OverlapCardModel: Sendable, Equatable {
    public enum Rail: String, Sendable, Equatable, CaseIterable {
        case outgoing, overlapNow, incoming

        public var label: String {
            switch self {
            case .outgoing: String(localized: "Out", bundle: .module)
            case .overlapNow: String(localized: "Overlap now", bundle: .module)
            case .incoming: String(localized: "In", bundle: .module)
            }
        }
    }

    public let outgoingTrackID: Int64
    public let incomingTrackID: Int64
    /// The style the renderer executed (or, lacking a snapshot, the plan's), never a promise.
    public let executedStyle: TransitionDisplayStyle
    public let rail: Rail
    /// 0...1 through the overlap; nil when timing is unknown.
    public let progress: Double?
    /// Seconds of the outgoing track still audible; 0 while only its tail rings out.
    public let outgoingRemaining: Double?
    /// Seconds the incoming track has been audible on the common clock.
    public let incomingEntry: Double?

    /// nil unless two tracks are actually audible together.
    public init?(_ p: TransitionPresentation, snapshot: TransitionExecutionSnapshot?, position: Double) {
        guard p.isBlendingNow, let out = p.outgoingTrackID, let inc = p.incomingTrackID else { return nil }
        if let snapshot, !snapshot.executedAsOverlap { return nil }
        guard let style = p.actualStyle ?? p.plannedStyle else { return nil }
        outgoingTrackID = out
        incomingTrackID = inc
        executedStyle = style
        var duration: Double?
        if let snapshot, snapshot.overlapFrames > 0, snapshot.sampleRate > 0 {
            duration = Double(snapshot.overlapFrames) / snapshot.sampleRate
        } else if let range = p.overlapRange {
            duration = range.upperBound - range.lowerBound
        }
        if p.phase == .outgoingTail {
            rail = .incoming
            progress = duration == nil ? nil : 1
            outgoingRemaining = 0
            incomingEntry = duration
        } else if let range = p.overlapRange, let duration, duration > 0 {
            rail = .overlapNow
            let elapsed = min(max(position - range.lowerBound, 0), duration)
            progress = elapsed / duration
            outgoingRemaining = duration - elapsed
            incomingEntry = elapsed
        } else {
            rail = .overlapNow
            progress = nil; outgoingRemaining = nil; incomingEntry = nil
        }
    }

    public var title: String { String(localized: "Blending now", bundle: .module) }

    /// "Beat-matched", "Phrase-matched", "Crossfade" ... as executed.
    public var styleLabel: String {
        switch executedStyle {
        case .plainCrossfade: String(localized: "Crossfade", bundle: .module)
        case .gapless: String(localized: "Sequential", bundle: .module)
        default: executedStyle.label
        }
    }

    public static func seconds(_ v: Double) -> String { "\(Int(v.rounded())) s" }

    public var outgoingCaption: String {
        guard let outgoingRemaining else { return "" }
        return outgoingRemaining > 0
            ? seconds(outgoingRemaining) + " " + String(localized: "left", bundle: .module)
            : String(localized: "fading out", bundle: .module)
    }

    public var incomingCaption: String {
        incomingEntry.map { String(localized: "in at", bundle: .module) + " " + Self.seconds($0) } ?? ""
    }

    private func seconds(_ v: Double) -> String { Self.seconds(v) }

    /// One concise VoiceOver value: style, phase, remaining and entry timing.
    public func spokenSummary(outgoingTitle: String?, incomingTitle: String?) -> String {
        var parts: [String] = []
        if let outgoingTitle, let incomingTitle {
            parts.append(String(localized: "Blending", bundle: .module) + " \(outgoingTitle) "
                + String(localized: "into", bundle: .module) + " \(incomingTitle)")
        } else {
            parts.append(title)
        }
        parts.append(styleLabel)
        parts.append(rail.label)
        if let outgoingRemaining, outgoingRemaining > 0 {
            parts.append("\(Int(outgoingRemaining.rounded())) " + String(localized: "seconds remaining", bundle: .module))
        }
        if let incomingEntry {
            parts.append(String(localized: "incoming for", bundle: .module) + " \(Int(incomingEntry.rounded())) "
                + String(localized: "seconds", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }
}
