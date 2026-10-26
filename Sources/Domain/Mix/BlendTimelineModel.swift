import Foundation

/// The Now Playing blend section: a textual and visual timeline of the outgoing track's
/// start / swap / end and the incoming track's, with the live position inside the blend.
/// Read-only; derived from the presentation and the playhead, it never touches audio.
public struct BlendTimelineModel: Sendable, Equatable {
    public enum Marker: String, Sendable, Equatable, CaseIterable {
        case start, swap, end

        public var label: String {
            switch self {
            case .start: String(localized: "Start", bundle: .module)
            case .swap: String(localized: "Swap", bundle: .module)
            case .end: String(localized: "End", bundle: .module)
            }
        }
    }

    public enum Stage: String, Sendable, Equatable {
        /// The blend has not begun; `secondsUntilStart` counts down.
        case upcoming
        /// First half of the blend, before the swap/drop point.
        case beforeSwap
        /// Second half, after the swap/drop point.
        case afterSwap
        /// The blend is over (incoming owns playback; the outgoing tail may ring out).
        case finished
    }

    public struct Point: Sendable, Equatable {
        public let marker: Marker
        /// Seconds into the track.
        public let time: Double
        public var text: String { marker.label + " " + BlendTimelineModel.clock(time) }
    }

    public let styleLabel: String
    public let outgoing: [Point]
    /// Empty when the incoming entry point is unknown.
    public let incoming: [Point]
    public let stage: Stage
    /// 0...1 through the blend; 0 before, 1 after.
    public let progress: Double
    public let secondsUntilStart: Double?
    public let secondsRemaining: Double?
    public let duration: Double

    /// nil unless an overlapping blend with known timing exists.
    public init?(_ p: TransitionPresentation, position: Double) {
        guard p.showsConnector, p.phase == .preparing || p.phase == .ready || p.isBlendingNow,
              p.actualStyle?.overlaps ?? p.plannedStyle?.overlaps ?? true,
              let range = p.overlapRange, range.upperBound > range.lowerBound else { return nil }
        let d = range.upperBound - range.lowerBound
        duration = d
        styleLabel = (p.actualStyle ?? p.plannedStyle ?? .smartBlend).label
        outgoing = Self.points(from: range.lowerBound, duration: d)
        incoming = p.entryTime.map { Self.points(from: $0, duration: d) } ?? []
        if p.phase == .outgoingTail || position >= range.upperBound {
            stage = .finished; progress = 1; secondsUntilStart = nil; secondsRemaining = 0
        } else if position >= range.lowerBound {
            let elapsed = position - range.lowerBound
            progress = min(max(elapsed / d, 0), 1)
            stage = progress < 0.5 ? .beforeSwap : .afterSwap
            secondsUntilStart = nil
            secondsRemaining = range.upperBound - position
        } else {
            stage = .upcoming; progress = 0
            secondsUntilStart = range.lowerBound - position
            secondsRemaining = nil
        }
    }

    private static func points(from start: Double, duration: Double) -> [Point] {
        [Point(marker: .start, time: start), Point(marker: .swap, time: start + duration / 2),
         Point(marker: .end, time: start + duration)]
    }

    /// The marker nearest behind the playhead; nil before the blend starts.
    public var currentMarker: Marker? {
        switch stage {
        case .upcoming: nil
        case .beforeSwap: .start
        case .afterSwap: .swap
        case .finished: .end
        }
    }

    public var statusText: String {
        switch stage {
        case .upcoming:
            String(localized: "Blend starts in", bundle: .module) + " " + Self.seconds(secondsUntilStart ?? 0)
        case .beforeSwap:
            String(localized: "Blending: before swap", bundle: .module) + " · " + Self.seconds(secondsRemaining ?? 0)
                + " " + String(localized: "left", bundle: .module)
        case .afterSwap:
            String(localized: "Blending: after swap", bundle: .module) + " · " + Self.seconds(secondsRemaining ?? 0)
                + " " + String(localized: "left", bundle: .module)
        case .finished:
            String(localized: "Blend complete", bundle: .module)
        }
    }

    public var outgoingText: String { Self.line(String(localized: "Out", bundle: .module), outgoing) }
    public var incomingText: String { Self.line(String(localized: "In", bundle: .module), incoming) }

    public func spokenSummary(outgoingTitle: String? = nil, incomingTitle: String? = nil) -> String {
        var parts: [String] = []
        if let outgoingTitle, let incomingTitle {
            parts.append(outgoingTitle + " " + String(localized: "into", bundle: .module) + " " + incomingTitle)
        }
        parts.append(styleLabel)
        parts.append(statusText)
        parts.append(outgoingText)
        if !incoming.isEmpty { parts.append(incomingText) }
        return parts.joined(separator: ", ")
    }

    private static func line(_ head: String, _ points: [Point]) -> String {
        guard !points.isEmpty else { return head + ": " + String(localized: "timing unknown", bundle: .module) }
        return head + "  " + points.map(\.text).joined(separator: " · ")
    }

    static func seconds(_ v: Double) -> String { "\(Int(max(v, 0).rounded())) s" }

    static func clock(_ v: Double) -> String {
        let t = Int(max(v, 0).rounded())
        return "\(t / 60):" + (t % 60 < 10 ? "0" : "") + "\(t % 60)"
    }
}
