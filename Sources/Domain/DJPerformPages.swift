import Foundation

public enum DJPerformPages {
    public static let tabs: [(mode: DJPadMode, title: String)] = [
        (.hotCue, "Hot Cue"), (.beatLoop, "Loop"), (.fx, "Pad FX"), (.beatJump, "Beat Jump")
    ]

    public static let autoLoopBeats: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
    public static let beatJumpBeats: [Double] = [-1, 1, -4, 4, -16, 16, -32, 32]

    public static func alternate(of mode: DJPadMode) -> DJPadMode? {
        switch mode {
        case .beatLoop: return .loop
        case .loop: return .beatLoop
        case .fx: return .beatFX
        case .beatFX: return .fx
        default: return nil
        }
    }

    public static func padLabel(mode: DJPadMode, index: Int, state: DJPadLabelState) -> (title: String, caption: String) {
        switch mode {
        case .hotCue:
            if let position = state.hotCuePosition {
                return (state.hotCueName ?? "Cue \(index + 1)", "\(index + 1) · \(time(position))")
            }
            return ("\(index + 1)", "tap to set")
        case .beatLoop:
            let beats = autoLoopBeats[safe: index] ?? 1
            return (fraction(beats), state.activeLoopBeats == beats ? "looping" : "beats")
        case .loop:
            let titles = ["In", "Out", "Set \(state.loopLength)", state.loopExitPending ? "Exit" : "Enter", "½×", "2×", "← \(state.loopLength)", "\(state.loopLength) →"]
            let captions = ["", "", "", state.loopExitPending ? "next pass" : "", "", "", "", ""]
            return (titles[safe: index] ?? "", captions[safe: index] ?? "")
        case .fx:
            let titles = ["Echo ¼", "Echo ½", "Echo 1", "Echo 2", "Echo Out", "Roll", "Reverb", "Brake"]
            let caption = index < 4 || index == 5 || index == 6 || index == 7 ? "hold" : (state.echoOutArmed ? "armed" : "")
            return (titles[safe: index] ?? "", caption)
        case .beatFX:
            let titles = ["Type", "← Beat", "Beat →", state.beatFXOn ? "On" : "Off", "Ch A", "Ch B", "Master", "Level"]
            let captions = [state.beatFXType, "", state.beatFXDivision, "", "", "", "", "\(Int(state.beatFXDepth * 100))%"]
            return (titles[safe: index] ?? "", captions[safe: index] ?? "")
        case .beatJump:
            let beats = beatJumpBeats[safe: index] ?? 1
            let title = beats < 0 ? "← \(abs(Int(beats)))" : "\(Int(beats)) →"
            let caption: String
            switch abs(beats) { case 1: caption = "beat"; case 4: caption = "1 bar"; case 16: caption = "4 bars"; default: caption = "8 bars" }
            return (title, caption)
        case .keyShift:
            let labels = [("♭ −1", ""), ("♯ +1", ""), ("♭ −2", ""), ("♯ +2", ""), ("Key Sync", ""), ("Reset", ""), ("Key Lock", ""), ("Done", "")]
            return labels[safe: index] ?? ("", "")
        case .grid:
            let labels = [("← Grid", ""), ("Grid →", ""), ("1.1 Here", ""), ("Tap", ""), ("BPM ÷2", ""), ("BPM ×2", ""), ("Reset", ""), ("Done", "")]
            return labels[safe: index] ?? ("", "")
        default:
            return ("", "")
        }
    }

    private static func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func fraction(_ value: Double) -> String {
        switch value { case 0.25: return "¼"; case 0.5: return "½"; default: return String(Int(value)) }
    }
}

public struct DJPadLabelState: Sendable, Equatable {
    public var hotCuePosition: Double?
    public var hotCueName: String?
    public var activeLoopBeats: Double?
    public var loopLength: String
    public var loopExitPending: Bool
    public var echoOutArmed: Bool
    public var beatFXType: String
    public var beatFXDivision: String
    public var beatFXOn: Bool
    public var beatFXDepth: Double

    public init(hotCuePosition: Double? = nil, hotCueName: String? = nil, activeLoopBeats: Double? = nil,
                loopLength: String = "4", loopExitPending: Bool = false, echoOutArmed: Bool = false,
                beatFXType: String = "Echo", beatFXDivision: String = "1/2", beatFXOn: Bool = false,
                beatFXDepth: Double = 0.5) {
        self.hotCuePosition = hotCuePosition; self.hotCueName = hotCueName; self.activeLoopBeats = activeLoopBeats
        self.loopLength = loopLength; self.loopExitPending = loopExitPending; self.echoOutArmed = echoOutArmed
        self.beatFXType = beatFXType; self.beatFXDivision = beatFXDivision; self.beatFXOn = beatFXOn; self.beatFXDepth = beatFXDepth
    }
}

public enum DJChipReadout {
    public static func text(bpm: Double?, remaining: Double, isPlaying: Bool, synced: Bool,
                            loadPhase: String?, onAir: Bool) -> String {
        if let loadPhase { return loadPhase.capitalized + "…" }
        guard let bpm, bpm.isFinite, bpm > 0 else { return isPlaying ? "— · playing" : "— · cued" }
        if synced { return "\(String(format: "%.1f", bpm)) · SYNC" }
        if isPlaying {
            let seconds = max(0, Int(remaining.rounded()))
            return "\(onAir ? "● " : "")\(String(format: "%.1f", bpm)) · −\(String(format: "%d:%02d", seconds / 60, seconds % 60))"
        }
        return "\(String(format: "%.1f", bpm)) · cued"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
