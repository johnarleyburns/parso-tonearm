import Foundation

/// How a transition is described to the listener. Wider than the engine's
/// `TransitionStyle` so styles the engine may add later still render honestly.
public enum TransitionDisplayStyle: String, Sendable, Equatable, CaseIterable {
    case phraseBlend, beatMatched, bassSwap, doubleDrop, plainCrossfade, gapless
    /// An engine style this build does not know by name.
    case smartBlend

    public init(_ style: TransitionStyle) {
        switch style {
        case .gapless: self = .gapless
        case .beatmatchedBlend: self = .beatMatched
        case .phraseFade: self = .phraseBlend
        case .plainCrossfade: self = .plainCrossfade
        }
    }

    /// Unknown names map to the generic "Smart blend" rather than failing.
    public init(rawEngineStyle: String) {
        switch rawEngineStyle {
        case "gapless": self = .gapless
        case "beatmatchedBlend": self = .beatMatched
        case "phraseFade": self = .phraseBlend
        case "plainCrossfade": self = .plainCrossfade
        case "bassSwap": self = .bassSwap
        case "doubleDrop": self = .doubleDrop
        default: self = .smartBlend
        }
    }

    public var label: String {
        switch self {
        case .phraseBlend: String(localized: "Phrase-matched", bundle: .module)
        case .beatMatched: String(localized: "Beat-matched", bundle: .module)
        case .bassSwap: String(localized: "Bass swap", bundle: .module)
        case .doubleDrop: String(localized: "Double drop", bundle: .module)
        case .plainCrossfade: String(localized: "Plain crossfade", bundle: .module)
        case .gapless: String(localized: "Gapless continuation", bundle: .module)
        case .smartBlend: String(localized: "Smart blend", bundle: .module)
        }
    }

    /// Spoken form, e.g. "phrase-matched blend".
    public var spokenLabel: String {
        switch self {
        case .phraseBlend: String(localized: "phrase-matched blend", bundle: .module)
        case .beatMatched: String(localized: "beat-matched blend", bundle: .module)
        case .bassSwap: String(localized: "bass swap blend", bundle: .module)
        case .doubleDrop: String(localized: "double drop blend", bundle: .module)
        case .plainCrossfade: String(localized: "plain crossfade", bundle: .module)
        case .gapless: String(localized: "gapless continuation", bundle: .module)
        case .smartBlend: String(localized: "smart blend, details unavailable", bundle: .module)
        }
    }

    /// Whether two tracks are audible together for this style.
    public var overlaps: Bool { self != .gapless }
}

/// What the edge between the playing track and the next one is doing right now.
public enum TransitionRuntimePhase: String, Sendable, Equatable {
    /// No next track: end of queue.
    case noEdge
    /// A later queue edge: nothing is planned until it becomes the next edge.
    case notPlanned
    case preparing
    /// Planned and prepared; the overlap has not begun.
    case ready
    /// Both tracks are audible.
    case overlap
    /// The incoming track owns playback but the outgoing one is still audible.
    case outgoingTail
    /// The engine fell back to something quieter than the plan.
    case fallback
}

public enum TransitionDiagramSegment: String, Sendable, Equatable {
    case outgoing, overlap, incoming
}

/// A stable, privacy-safe snapshot consumed by Now Playing and the queue.
/// Contains no file paths; only track IDs, style, timing and wording.
public struct TransitionPresentation: Sendable, Equatable {
    public var phase: TransitionRuntimePhase
    public var plannedStyle: TransitionDisplayStyle?
    /// The style that will actually play (differs from planned after a downgrade).
    public var actualStyle: TransitionDisplayStyle?
    public var outgoingTrackID: Int64?
    public var incomingTrackID: Int64?
    /// Seconds in the outgoing track; nil when unknown.
    public var overlapRange: ClosedRange<Double>?
    public var secondsUntilOverlap: Double?
    public var secondsRemaining: Double?
    public var confidence: Double?
    public var reasons: [TransitionReason]
    public var preparation: GridPrepState?
    /// Why the renderer executed differently from the plan (from the execution snapshot), if it did.
    public var executionReason: TransitionExecutionReason?

    public init(phase: TransitionRuntimePhase, plannedStyle: TransitionDisplayStyle? = nil,
                actualStyle: TransitionDisplayStyle? = nil, outgoingTrackID: Int64? = nil,
                incomingTrackID: Int64? = nil, overlapRange: ClosedRange<Double>? = nil,
                secondsUntilOverlap: Double? = nil, secondsRemaining: Double? = nil,
                confidence: Double? = nil, reasons: [TransitionReason] = [],
                preparation: GridPrepState? = nil, executionReason: TransitionExecutionReason? = nil) {
        self.executionReason = executionReason
        self.phase = phase
        self.plannedStyle = plannedStyle
        self.actualStyle = actualStyle
        self.outgoingTrackID = outgoingTrackID
        self.incomingTrackID = incomingTrackID
        self.overlapRange = overlapRange
        self.secondsUntilOverlap = secondsUntilOverlap
        self.secondsRemaining = secondsRemaining
        self.confidence = confidence
        self.reasons = reasons
        self.preparation = preparation
    }

    public static let none = TransitionPresentation(phase: .noEdge)

    /// Reconciles a plan-derived presentation with what the renderer actually reported. The plan
    /// may promise an overlap; only the snapshot says whether one is audible. nil leaves it as is.
    public func applying(_ snapshot: TransitionExecutionSnapshot?) -> TransitionPresentation {
        guard let snapshot, showsConnector, phase != .notPlanned else { return self }
        var r = self
        r.executionReason = snapshot.reason
        if let requested = snapshot.requestedStyle, r.plannedStyle == nil { r.plannedStyle = requested }
        if let planned = snapshot.plannedStyle { r.plannedStyle = planned }
        switch snapshot.phase {
        case .denied, .cancelled:
            r.phase = .fallback
            r.actualStyle = nil
            r.overlapRange = nil; r.secondsRemaining = nil; r.secondsUntilOverlap = nil
            return r
        case .upcoming, .overlapping, .handedOff, .completed: break
        }
        guard let executed = snapshot.executedStyle else { return r }
        r.actualStyle = executed
        if !executed.overlaps {
            // Sequential handoff: never present two audible tracks.
            r.overlapRange = nil; r.secondsRemaining = nil; r.secondsUntilOverlap = nil
            if r.phase == .overlap || r.phase == .outgoingTail { r.phase = .fallback }
            return r
        }
        switch snapshot.phase {
        case .upcoming:
            // A renderer-scheduled overlapping edge is real even without a legacy TransitionPlan.
            if r.phase == .fallback || r.phase == .overlap {
                r.phase = .ready
                r.secondsRemaining = nil
                r.secondsUntilOverlap = 0
            }
        case .overlapping:
            if r.phase == .fallback || r.phase == .ready || r.phase == .preparing {
                r.phase = .overlap
            }
        case .handedOff:
            if r.phase == .fallback || r.phase == .ready || r.phase == .preparing || r.phase == .overlap {
                r.phase = .outgoingTail
            }
        case .completed:
            if r.phase == .fallback || r.phase == .overlap || r.phase == .outgoingTail {
                r.phase = .ready
                r.secondsRemaining = nil
            }
        case .denied, .cancelled:
            break // handled by the existing truthful fallback branch above
        }
        return r
    }

    /// Maps today's plan, preparation state and playback position to a snapshot.
    /// - Parameters:
    ///   - position: seconds into the outgoing track (ignored while `outgoingTail`).
    ///   - outgoingTail: the incoming track already owns playback but the outgoing
    ///     one is still audible; the displayed edge stays A→B until it is not.
    public static func make(plan: TransitionPlan?, preparation: GridPrepState?, hasNext: Bool = true,
                            position: Double = 0, outgoingTail: Bool = false) -> TransitionPresentation {
        guard let plan else {
            guard hasNext else { return .none }
            return TransitionPresentation(phase: preparing(preparation) ? .preparing : .fallback,
                                          preparation: preparation)
        }
        let planned = TransitionDisplayStyle(plan.style)
        let actual = planned
        let planned0 = plan.downgradedFrom.map(TransitionDisplayStyle.init) ?? planned
        var result = TransitionPresentation(
            phase: .ready, plannedStyle: planned0, actualStyle: actual,
            outgoingTrackID: plan.fromTrackID, incomingTrackID: plan.toTrackID,
            confidence: plan.confidence, reasons: plan.reasons, preparation: preparation)
        if preparing(preparation) { result.phase = .preparing }
        if !actual.overlaps { return result }
        let seconds = plan.overlapSeconds > 0 ? plan.overlapSeconds : nil
        if let seconds, plan.exitTime > 0 {
            result.overlapRange = plan.exitTime...(plan.exitTime + seconds)
        }
        if outgoingTail {
            result.phase = .outgoingTail
        } else if let range = result.overlapRange {
            if position >= range.lowerBound, position < range.upperBound {
                result.phase = .overlap
                result.secondsRemaining = range.upperBound - position
            } else {
                result.secondsUntilOverlap = max(0, range.lowerBound - position)
            }
        }
        if result.phase == .ready, preparing(preparation) { result.phase = .preparing }
        return result
    }

    private static func preparing(_ state: GridPrepState?) -> Bool {
        switch state {
        case .queued, .downloading, .analyzing, .notPrepared, .waitingForNetwork, .waitingForWiFi: true
        case .ready, .failed, .cancelled, nil: false
        }
    }

    // MARK: - Text

    public var isBlendingNow: Bool { phase == .overlap || phase == .outgoingTail }

    public var showsConnector: Bool { phase != .noEdge }

    public var isFallback: Bool { phase == .fallback }

    private var styleLabel: String { (actualStyle ?? plannedStyle)?.label ?? TransitionDisplayStyle.smartBlend.label }

    private var preparationLabel: String? {
        switch preparation {
        case .ready?: String(localized: "Ready", bundle: .module)
        case .none: nil
        case .some(let state): Self.prepWord(state)
        }
    }

    private static func prepWord(_ state: GridPrepState) -> String {
        switch state {
        case .ready: String(localized: "Ready", bundle: .module)
        case .notPrepared, .queued, .downloading, .analyzing:
            String(localized: "Preparing", bundle: .module)
        case .waitingForNetwork: String(localized: "Waiting for network", bundle: .module)
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .cancelled: String(localized: "Stopped", bundle: .module)
        }
    }

    /// Why the edge fell back, if the plan says so. Never a path or a raw error.
    public var fallbackDetail: String? {
        guard phase == .fallback else { return nil }
        switch executionReason {
        case .admissionDenied?: return String(localized: "Blend denied: not safe to overlap these tracks", bundle: .module)
        case .lateForPlannedBlend?: return String(localized: "Sequential handoff: the planned blend could not start in time", bundle: .module)
        case .gaplessEdge?: return String(localized: "Sequential handoff: these tracks play gaplessly", bundle: .module)
        case .plainFadeEdge?: return String(localized: "Plain fade", bundle: .module)
        case .queueChanged?, .replaced?: return String(localized: "Blend cancelled: the queue changed", bundle: .module)
        case .interrupted?, .stopped?, .restarted?: return String(localized: "Blend cancelled: playback was interrupted", bundle: .module)
        case nil: break
        }
        if actualStyle?.overlaps == false {
            return String(localized: "Sequential handoff, no blend", bundle: .module)
        }
        return String(localized: "No smart blend plan for this transition", bundle: .module)
    }

    /// The queue connector text, e.g. "Phrase-matched · 12 s · Ready".
    public var connectorLabel: String {
        switch phase {
        case .noEdge: return ""
        case .notPlanned:
            return String(localized: "Transition planned when up next", bundle: .module)
        case .fallback:
            return String(localized: "Continuous playback — smart blend unavailable", bundle: .module)
        case .preparing:
            let head = plannedStyle?.label ?? String(localized: "Smart blend", bundle: .module)
            return "\(head) · " + String(localized: "Preparing", bundle: .module)
        case .ready, .overlap, .outgoingTail:
            var parts = [styleLabel]
            if actualStyle?.overlaps == true, let range = overlapRange {
                parts.append(Self.seconds(range.upperBound - range.lowerBound))
            }
            if let preparationLabel { parts.append(preparationLabel) }
            return parts.joined(separator: " · ")
        }
    }

    /// The compact Now Playing card text.
    public var cardTitle: String {
        switch phase {
        case .noEdge: return ""
        case .notPlanned: return String(localized: "Next", bundle: .module)
        case .fallback: return String(localized: "Continuous playback", bundle: .module)
        case .overlap, .outgoingTail:
            return String(localized: "Blending now", bundle: .module) + " · " + styleLabel
        case .preparing, .ready:
            var text = String(localized: "Next", bundle: .module) + " · " + styleLabel
            if let until = secondsUntilOverlap {
                text += " · " + String(localized: "in", bundle: .module) + " " + Self.seconds(until)
            }
            return text
        }
    }

    /// Concise VoiceOver label. Titles are supplied by the caller so the model stays ID-only.
    public func accessibilityLabel(outgoingTitle: String? = nil, incomingTitle: String? = nil) -> String {
        switch phase {
        case .noEdge: return String(localized: "No next transition", bundle: .module)
        case .notPlanned: return String(localized: "Transition planned when up next", bundle: .module)
        case .fallback:
            return String(localized: "Next transition, continuous playback. Smart blend unavailable", bundle: .module)
        case .overlap, .outgoingTail:
            if let outgoingTitle, let incomingTitle {
                var text = String(localized: "Blending", bundle: .module) + " \(outgoingTitle) "
                    + String(localized: "into", bundle: .module) + " \(incomingTitle)"
                if let secondsRemaining { text += "; \(Self.spoken(secondsRemaining)) " + String(localized: "remaining", bundle: .module) }
                return text
            }
            return String(localized: "Blending now", bundle: .module) + ", " + (actualStyle ?? .smartBlend).spokenLabel
        case .preparing, .ready:
            var text = String(localized: "Next transition", bundle: .module) + ", " + (actualStyle ?? plannedStyle ?? .smartBlend).spokenLabel
            if let until = secondsUntilOverlap { text += " " + String(localized: "in", bundle: .module) + " \(Self.spoken(until))" }
            return text
        }
    }

    /// VoiceOver value: preparation state, plus confidence when known.
    public var accessibilityValue: String {
        var parts: [String] = []
        if let preparation { parts.append(Self.prepWord(preparation)) }
        if let confidence, confidence > 0 {
            parts.append(String(localized: "Confidence", bundle: .module) + " \(Int(confidence * 100)) %")
        }
        return parts.joined(separator: ", ")
    }

    /// The diagram sections to draw, in order. Empty when there is nothing to draw
    /// (no edge, fallback, or unknown timing), so the view simplifies instead of guessing.
    public var diagramSegments: [TransitionDiagramSegment] {
        switch phase {
        case .noEdge, .fallback, .notPlanned: []
        case .preparing, .ready, .overlap, .outgoingTail:
            overlapRange == nil ? [] : [.outgoing, .overlap, .incoming]
        }
    }

    /// Playhead 0...1 across the diagram (outgoing / overlap / incoming thirds), nil when not drawable.
    public func playhead(position: Double) -> Double? {
        guard let range = overlapRange else { return nil }
        let lead = max(range.lowerBound - (range.upperBound - range.lowerBound), 0)
        if position < range.lowerBound {
            let span = max(range.lowerBound - lead, 0.001)
            return min(max((position - lead) / span, 0), 1) / 3
        }
        if position < range.upperBound {
            return 1.0 / 3 + (position - range.lowerBound) / (range.upperBound - range.lowerBound) / 3
        }
        return 2.0 / 3 + min((position - range.upperBound) / max(range.upperBound - range.lowerBound, 0.001), 1) / 3
    }

    private static func seconds(_ value: Double) -> String { "\(Int(value.rounded())) s" }

    private static func spoken(_ value: Double) -> String {
        let n = Int(value.rounded())
        return n == 1 ? String(localized: "1 second", bundle: .module) : "\(n) " + String(localized: "seconds", bundle: .module)
    }
}
