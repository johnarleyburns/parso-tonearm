import CoreGraphics
import Foundation

public struct DJGridLayout: Equatable, Sendable {
    public let size: CGSize
    public let columns: Int
    public let rows: Int
    public let gap: CGFloat
    public let cellWidth: CGFloat
    public let rowHeight: CGFloat

    public init(size: CGSize, columns: Int = 8, rows: Int = 8, gap: CGFloat = 6) {
        self.size = size
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.gap = gap
        cellWidth = max(0, (size.width - gap * CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns)))
        rowHeight = max(0, (size.height - gap * CGFloat(max(0, rows - 1))) / CGFloat(max(1, rows)))
    }

    public func frame(col: Int, row: Int, colSpan: Int = 1, rowSpan: Int = 1) -> CGRect {
        let safeCol = max(0, min(columns - 1, col))
        let safeRow = max(0, min(rows - 1, row))
        let safeColSpan = max(1, min(columns - safeCol, colSpan))
        let safeRowSpan = max(1, min(rows - safeRow, rowSpan))
        return CGRect(x: CGFloat(safeCol) * (cellWidth + gap),
                      y: CGFloat(safeRow) * (rowHeight + gap),
                      width: CGFloat(safeColSpan) * cellWidth + CGFloat(safeColSpan - 1) * gap,
                      height: CGFloat(safeRowSpan) * rowHeight + CGFloat(safeRowSpan - 1) * gap)
    }

    /// Compatibility spelling used by the first DJ grid implementation.
    public func frame(col: Int, row: Int, span: Int) -> CGRect {
        frame(col: col, row: row, colSpan: span)
    }
}

/// Row contract for the portrait active-deck controls. Keeping this pure
/// makes the requested control order unit-testable without a simulator.
public enum DJV2PortraitLayout {
    public static let jogSectionTopRow = 3
    public static let transportRow = 3
    public static let jogWheelRow = 4
    public static let jogWheelRowSpan = 3
    public static let padsRow = 4
    public static let padModeRow = 6
    public static let jogModeRow = 7
    public static let mixerFirstRow = 8
    public static let mixerVolumeRow = 9
    public static let mixerVolumeRowSpan = 2
    public static let mixerMeterColumns = (5, 6)
}

public enum DJWaveformSeekMapping {
    /// Horizontal movement follows the user's finger: right is forward,
    /// left is backward.
    public static func seconds(translation: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard translation.isFinite, width.isFinite, duration.isFinite,
              width > 0, duration > 0 else { return 0 }
        return Double(translation / width) * duration
    }
}

public enum DJWaveformPlaceholder {
    public static func shouldDrawSignal(waveformCount: Int) -> Bool {
        waveformCount > 0
    }
}

public enum DJReversePlaybackPolicy {
    public static func startPosition(enabled: Bool, isPlaying: Bool,
                                     current: Double, duration: Double) -> Double {
        guard enabled, !isPlaying, duration.isFinite, duration > 0,
              current.isFinite, current <= 0 else { return current }
        return duration
    }
}

public enum DJGridOverride {
    public static func positions(bpm: Double, firstBeat: Double, duration: Double,
                                 beatsPerBar: Int = 1) -> [Double] {
        guard bpm.isFinite, bpm > 0, firstBeat.isFinite, duration.isFinite, duration >= 0,
              beatsPerBar > 0 else { return [] }
        let interval = 60 / bpm * Double(beatsPerBar)
        guard interval.isFinite, interval > 0 else { return [] }
        let first = max(0, min(duration, firstBeat))
        return stride(from: first, through: duration, by: interval).map { $0 }
    }
}
public enum DJPadMode: String, Codable, Sendable {
    case hotCue
    case loop
    case fx
    case beatFX
    case mix
    case keyShift
    case grid
    // Kept for migration compatibility with the first implementation. New UI
    // uses the FX page and displays ECHO OUT there.
    case echo
}

public enum DJLoadLibraryScope: String, CaseIterable, Identifiable, Sendable {
    case playlists = "Playlists"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    public var id: String { rawValue }

    public var browseMode: LibraryBrowseMode? {
        switch self {
        case .playlists: return nil
        case .artists: return .artists
        case .albums: return .albums
        case .songs: return .songs
        case .genres: return .genres
        }
    }
}

/// The compact musical metadata shown beside every candidate in the DJ load
/// browser. Values stay optional all the way to the UI: an unanalysed track
/// is not silently presented as 120 BPM or an invented key.
public struct DJLoadTrackInfo: Equatable, Sendable {
    public var bpm: Double?
    public var camelotKey: String?

    public init(bpm: Double? = nil, camelotKey: String? = nil) {
        self.bpm = bpm
        self.camelotKey = camelotKey
    }

    public var bpmLabel: String {
        guard let bpm, bpm.isFinite, bpm > 0 else { return "— BPM" }
        return String(format: "%.1f BPM", bpm)
    }

    public var keyLabel: String { "KEY \(DJKeyFormatter.format(camelotKey))" }
}

/// Pure validation/filtering for the non-semantic part of the DJ load
/// browser. Semantic mood/sound matching is delegated to the shared
/// DiscoverySearchViewModel; this keeps local playlist and browse filtering
/// deterministic and unit-testable.
public struct DJLoadTrackFilter: Equatable, Sendable {
    public var bpmMin: Double?
    public var bpmMax: Double?
    public var camelotKey: String?

    public init(bpmMin: Double? = nil, bpmMax: Double? = nil, camelotKey: String? = nil) {
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.camelotKey = camelotKey
    }

    public var isEmpty: Bool { bpmMin == nil && bpmMax == nil && camelotKey == nil }

    public func matches(_ info: DJLoadTrackInfo) -> Bool {
        if bpmMin != nil || bpmMax != nil {
            guard let bpm = info.bpm, bpm.isFinite, bpm > 0 else { return false }
            if let bpmMin, (!bpmMin.isFinite || bpm < bpmMin) { return false }
            if let bpmMax, (!bpmMax.isFinite || bpm > bpmMax) { return false }
        }
        if let camelotKey, !camelotKey.isEmpty {
            guard let expected = DJKeyFormatter.normalized(camelotKey),
                  let actual = DJKeyFormatter.normalized(info.camelotKey) else { return false }
            guard expected == actual else { return false }
        }
        return true
    }
}

public enum DJKeyFormatter {
    public static func format(_ raw: String?) -> String {
        normalized(raw) ?? "—"
    }

    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: #"^(1[0-2]|[1-9])[AB]$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    public static func shifted(_ raw: String?, semitones: Int) -> String {
        let value = format(raw)
        guard value != "—", semitones != 0 else { return value }
        let number = Int(value.dropLast()) ?? 1
        let letter = value.last!
        let shiftedNumber = ((number - 1 + semitones * 7) % 12 + 12) % 12 + 1
        let sign = semitones > 0 ? "+" : ""
        return "\(shiftedNumber)\(letter) \(sign)\(semitones)"
    }
}

public struct DJCueTransport: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case cueDown
        case cueUp
        case playTap
        case seek(Double)
        case trackEnded
    }

    public enum Action: Equatable, Sendable {
        case setCue(Double)
        case play
        case pause
        case jumpToCue
        case cuePlayPress
        case cuePlayRelease
        case seek(Double)
        case none
    }

    public private(set) var sampling = false
    public private(set) var playContinuesAfterCue = false

    public init() {}

    public mutating func reduce(_ input: Input, isPlaying: Bool, position: Double,
                                cuePoint: Double?) -> Action {
        switch input {
        case .cueDown:
            if isPlaying {
                sampling = false
                return .jumpToCue
            }
            let cue = cuePoint ?? position
            if abs(position - cue) > 0.01 { sampling = true; return .setCue(position) }
            sampling = true
            return .cuePlayPress
        case .cueUp:
            guard sampling else { return .none }
            sampling = false
            if playContinuesAfterCue { playContinuesAfterCue = false; return .none }
            return .cuePlayRelease
        case .playTap:
            if sampling { playContinuesAfterCue = true }
            return isPlaying ? .pause : .play
        case .seek(let value):
            return isPlaying ? .none : .seek(max(0, value))
        case .trackEnded:
            sampling = false
            playContinuesAfterCue = false
            return .pause
        }
    }
}

public enum DJJogMode: String, Codable, CaseIterable, Sendable {
    case vinyl
    case cdj
}

public enum DJBeatFXAction: Equatable, Sendable {
    case nextKind, previousBeat, nextBeat, toggle
    case assign(String)
    case depth(Double)
}

public enum DJDeckMode: Sendable { case vinyl, slip, reverse, quantize }

public enum DJJogAction: Equatable, Sendable {
    case nudge(Double)
    case scratch(Double)
    case frameSearch(Double)
    case seek(Double)
}

public enum DJJogMapper {
    /// Maps a platter-angle delta to the CDJ action for the active deck.
    /// `angle` is in radians and may cross ±π between samples.
    public static func action(angle: Double, isPlaying: Bool, vinyl: Bool,
                             bpm: Double, tempoRange: Double = 16) -> DJJogAction {
        let delta = normalizedAngle(angle)
        guard delta.isFinite else { return .seek(0) }
        if isPlaying {
            return vinyl ? .scratch(delta * 48_000) : .nudge(max(-1, min(1, delta * 4)))
        }
        // The paused top plate is always the precision frame-search surface.
        // VINYL only changes the playing behavior; the outer ring is handled
        // by the surface/model as beat-based seek.
        return .frameSearch(delta * 0.06)
    }

    /// Converts a paused platter rotation into a stateful seek. The app uses
    /// this instead of PAE's transient frame-search command while stopped so
    /// the displayed position and the audio engine share the same endpoint.
    public static func pausedSeekSeconds(angle: Double, outerRing: Bool, bpm: Double) -> Double {
        let delta = normalizedAngle(angle)
        guard delta.isFinite else { return 0 }
        if outerRing {
            // One full turn is four bars / sixteen beats.
            return delta * (60 / max(1, bpm)) * 16 / (2 * .pi)
        }
        return delta * 0.06
    }

    public static func tempoStep(angle: Double, current: Double, range: Double) -> Double {
        let raw = current + angle * 1.2 * 10
        let stepped = (raw * 10).rounded() / 10
        return max(-abs(range), min(abs(range), stepped))
    }

    private static func normalizedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var value = value
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}

public struct DJHotCueSlot: Equatable, Sendable {
    public let bank: Int
    public let index: Int

    public init(bank: Int, index: Int) {
        self.bank = bank
        self.index = index
    }
}

public enum DJHotCueMapping {
    /// Tonearm exposes eight pads while PAE stores four slots per hot-cue bank.
    public static func slot(_ number: Int) -> DJHotCueSlot? {
        guard (1...8).contains(number) else { return nil }
        let zeroBased = number - 1
        return DJHotCueSlot(bank: zeroBased / 4, index: zeroBased % 4)
    }
}

public enum DJKnobMapping {
    public static func cfxLabel(_ value: Double) -> String {
        let v = max(0, min(1, value))
        if abs(v - 0.5) <= 0.02 { return "OFF" }
        return v < 0.5 ? "LPF \(Int(((0.5 - v) * 200).rounded()))" : "HPF \(Int(((v - 0.5) * 200).rounded()))"
    }

    public static func isolatorDB(_ value: Double) -> Double? {
        let v = max(0, min(1, value))
        if v <= 0.03 { return nil }
        if v <= 0.5 { return -26 * (1 - v / 0.5) }
        return 6 * ((v - 0.5) / 0.5)
    }

    public static func display(_ value: Double) -> String {
        guard let db = isolatorDB(value) else { return "KILL" }
        if abs(db) < 0.05 { return "0 dB" }
        return db > 0 ? "+\(String(format: "%.1f", db))" : "\(Int(db.rounded())) dB"
    }

    public static func adjusted(_ value: Double, delta: Double) -> Double {
        let next = max(0, min(1, value + delta))
        return abs(next - 0.5) <= 0.02 ? 0.5 : next
    }
}

public enum DJFaderMapping {
    public static func value(handleCenter: CGFloat, firstCenter: CGFloat,
                             lastCenter: CGFloat) -> Double {
        guard lastCenter > firstCenter else { return 0.5 }
        return max(0, min(1, Double((handleCenter - firstCenter) / (lastCenter - firstCenter))))
    }

    public static func snapped(_ value: Double) -> Double {
        abs(value - 0.5) <= 0.015 ? 0.5 : max(0, min(1, value))
    }
}

/// The bass crossfader and the channel LOW isolator share one DSP parameter.
/// Keep their combination pure so the audio adapter cannot accidentally make
/// the last control touched win over the other one.
public enum DJBassEQMapping {
    public static func combined(lowKnob: Double, bassBlend: Double, deckA: Bool) -> Double? {
        guard let low = DJKnobMapping.isolatorDB(lowKnob) else { return nil }
        let blend = max(0, min(1, bassBlend))
        let attenuation: Double = deckA
            ? (blend > 0.5 ? -24 * (blend - 0.5) * 2 : 0)
            : (blend < 0.5 ? -24 * (0.5 - blend) * 2 : 0)
        return max(-60, min(6, low + attenuation))
    }
}

public struct DJLoopState: Equatable, Sendable {
    public var inPoint: Double?
    public var outPoint: Double?
    public var active = false
    public var exitPending = false
    public var setIndex = 2 // 4 beats
    public var setApplied = false

    public static let lengths: [Double] = [1, 2, 4, 8, 16, 32]

    public init(inPoint: Double? = nil, outPoint: Double? = nil) {
        self.inPoint = inPoint; self.outPoint = outPoint
    }

    public mutating func pressIn(at position: Double, isPlaying: Bool) {
        inPoint = max(0, position); outPoint = nil; active = false; exitPending = false; setApplied = false
    }

    public mutating func pressOut(at position: Double) {
        guard let start = inPoint, position > start else { return }
        outPoint = position; setApplied = false
    }

    public mutating func pressSet(bpm: Double, duration: Double) {
        guard let start = inPoint, bpm > 0 else {
            setIndex = (setIndex + 1) % Self.lengths.count; return
        }
        if !setApplied {
            outPoint = min(duration, start + Self.lengths[setIndex] * 60 / bpm)
            setApplied = true
        } else {
            setIndex = (setIndex + 1) % Self.lengths.count
            outPoint = min(duration, start + Self.lengths[setIndex] * 60 / bpm)
        }
    }

    public mutating func pressEnter() {
        guard inPoint != nil, outPoint != nil else { return }
        if active { exitPending.toggle() } else { active = true; exitPending = false }
    }
}

public enum DJControlID: String, CaseIterable, Sendable {
    case info, title, loadA, loadB, waveformA, waveformB, jog, vinyl, slip, reverse, quantize
    case cue, play, sync, key, hotCue, loop, fx, mix, pad1, pad2, pad3, pad4, pad5, pad6, pad7, pad8
    case tempo, range, reset, masterTempo, tap, eqHi, eqMid, eqLow, cfx, bass, crossfader
    case channelFaderA, channelFaderB, cueA, cueB, volume, phones, cueMaster, output, record
    case keyShift, grid, beatFX, echoOut, loopIn, loopOut, loopSet, loopEnter, loopExit, loopHalf, loopDouble, beatJump
}

public struct DJHelpTopic: Equatable, Sendable {
    public let title: String
    public let body: String
    public let keywords: String
    public let controls: [DJControlID]
    public init(title: String, body: String, keywords: String = "", controls: [DJControlID] = []) {
        self.title = title; self.body = body; self.keywords = keywords; self.controls = controls
    }
}

public enum DJHelpSearch {
    public static func filter(_ topics: [DJHelpTopic], query: String) -> [DJHelpTopic] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return topics }
        return topics.filter { topic in
            let haystack = [topic.title, topic.body, topic.keywords].joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// The help sheet is deliberately data-driven so the visible gesture guide,
/// search index, and coverage audit cannot drift apart as controls are added.
public enum DJHelpContent {
    public static let sections: [DJHelpTopic] = [
        DJHelpTopic(title: "Start here", body: "The top row is deck A, LOAD A, LOAD B and deck B. Tap a track card or waveform to select the active deck; its color frames the jog, pads and transport. LOAD opens My Music with full search plus Playlists, Artists, Albums, Songs and Genres. Hold LOAD for one second before replacing an on-air deck.", keywords: "begin start layout active deck load search library playlist", controls: [.title, .info, .loadA, .loadB, .waveformA, .waveformB]),
        DJHelpTopic(title: "Performance pads: choose what they do", body: "HOT CUE has eight cues. LOOP has IN, OUT, SET n, ENTER/EXIT, halve, double and beat jump. FX has PAD FX and, on a second tap, BEAT FX. MIX has trim, auto gain, recording, isolators and FLAT. Hold KEY for KEY SHIFT or TAP for GRID; DONE returns to the previous pad page.", keywords: "pads hot cue loop fx mix key shift grid", controls: [.hotCue, .loop, .fx, .mix, .pad1, .pad2, .pad3, .pad4, .pad5, .pad6, .pad7, .pad8, .keyShift, .grid]),
        DJHelpTopic(title: "Play and cue (CDJ CUE)", body: "PLAY toggles playback. While stopped, CUE sets a cue; hold it to preview from the cue and release to return. While playing, CUE back-cues and pauses. CUE then PLAY latches playback after release. The cue, hot cues and loop are saved with the track.", keywords: "cue play pause preview back cue cdj transport", controls: [.cue, .play]),
        DJHelpTopic(title: "Jog wheel", body: "With VINYL on, touching and turning the platter scratches; with VINYL off it nudges. While paused, the ring seeks and the top plate frame-searches. SLIP preserves the underlying timeline. REV reverses playback and Q quantizes beat actions.", keywords: "jog platter scratch nudge seek frame search vinyl slip reverse quantize", controls: [.jog, .vinyl, .slip, .reverse, .quantize]),
        DJHelpTopic(title: "Waveforms and finding your place", body: "The centered playhead shows the detailed waveform, beat grid and bar phase. Drag while paused to seek, pinch to zoom, and tap the overview band to jump. Tap the time to switch elapsed and remaining. Read BPM, tempo %, Camelot key, ON AIR, MASTER, SYNC, MT and ECHO OUT chips here.", keywords: "waveform needle search zoom elapsed remaining beat grid phase bpm key", controls: [.waveformA, .waveformB]),
        DJHelpTopic(title: "Hot cues", body: "In HOT CUE mode, tap an empty pad to store the current position, tap a lit pad to jump, and hold a lit pad for one second to delete. Eight positions are persisted per track and synchronized.", keywords: "hot cue pads set trigger jump delete save sync", controls: [.hotCue, .pad1, .pad2, .pad3, .pad4, .pad5, .pad6, .pad7, .pad8]),
        DJHelpTopic(title: "Loops and beat jump", body: "IN and OUT store a loop without starting it. SET cycles 1, 2, 4, 8, 16 and 32 beats from the current tempo. ENTER starts it; EXIT finishes the current pass, and pressing ENTER again cancels the exit. Halve, double and beat jump use the current SET length.", keywords: "loop in out set enter exit reloop half double beat jump", controls: [.loop, .loopIn, .loopOut, .loopSet, .loopEnter, .loopExit, .loopHalf, .loopDouble, .beatJump]),
        DJHelpTopic(title: "Tempo, sync and key", body: "Drag TEMPO, cycle RANGE, RESET to the analyzed BPM, toggle MT, or tap TAP four times to set a BPM override. SYNC follows the master deck; hold SYNC to make this deck master. KEY toggles key sync; hold KEY for semitone shift and the shifted Camelot readout. Hold TAP for GRID correction.", keywords: "tempo pitch range reset tap bpm sync master key key shift grid camelot", controls: [.tempo, .range, .reset, .masterTempo, .tap, .sync, .key, .keyShift, .grid]),
        DJHelpTopic(title: "Deck modes", body: "VINYL selects platter behavior, SLIP preserves the timeline during performance gestures, REV reverses the deck, and Q quantizes cues, loops, jumps and seeks.", keywords: "vinyl slip reverse quantize deck mode", controls: [.vinyl, .slip, .reverse, .quantize]),
        DJHelpTopic(title: "Pad FX", body: "FX PAD provides momentary ¼, ½, 1 and 2 beat echoes, plus ROLL, REVERB and BRAKE. ECHO OUT arms an end-of-track echo; it is shown as a waveform chip and is used when stopping the deck.", keywords: "pad fx echo echo out roll reverb brake", controls: [.fx, .echoOut]),
        DJHelpTopic(title: "Beat FX", body: "Tap FX a second time for BEAT FX. Choose the type, step the beat division, toggle ON, assign A, B or MASTER, and adjust LEVEL/depth.", keywords: "beat fx type beat level channel assign master on", controls: [.beatFX]),
        DJHelpTopic(title: "Mixer", body: "HI, MID, LOW and CFX follow the active deck in portrait and show both decks in landscape. Use BASS and X-FADE for the blend, channel faders for levels, and the post-fader meters for monitoring. MIX also exposes trim, auto gain, isolators and FLAT.", keywords: "mixer eq hi mid low cfx bass crossfader channel fader meter trim gain isolator flat", controls: [.eqHi, .eqMid, .eqLow, .cfx, .bass, .crossfader, .channelFaderA, .channelFaderB, .mix]),
        DJHelpTopic(title: "Headphones, output and master", body: "CUE A/B sends either deck to headphones. PHONES sets headphone level, CUE/MST blends cue and master, VOL controls the master output, and OUTPUT cycles STEREO, SPLIT L and SPLIT R. Landscape shows the master meter.", keywords: "headphones cue monitor phones cue master volume output stereo split master meter", controls: [.cueA, .cueB, .volume, .phones, .cueMaster, .output]),
        DJHelpTopic(title: "Record your mix", body: "REC records the master output to the app's Documents folder. It is available in the title bar, mixer and MIX page; the red state indicates an active recording.", keywords: "record recording mix rec documents", controls: [.record]),
        DJHelpTopic(title: "Track prep and sync", body: "The library stores waveform analysis, BPM, key, cue point, eight hot cues, loop, BPM/grid/key fixes and source identity. Cached analysis makes a second load immediate. CloudKit sync uses source identity first and normalized metadata fallback; unmatched records wait until the track is imported.", keywords: "track prep analysis cache save cloudkit sync identity pending backup reanalyze", controls: [.loadA, .loadB]),
        DJHelpTopic(title: "CDJ-3000 and DDJ-FLX4 → Platterhead", body: "The coverage map is implemented here: transport, CDJ CUE, jog, waveform, hot cues, loops, tempo, sync, key, deck modes, PAD FX, BEAT FX, mixer, headphones, output, recording, track prep and the added GRID and KEY SHIFT tools.", keywords: "cdj 3000 ddj flx4 coverage map equivalent", controls: [.info]),
        DJHelpTopic(title: "Hardware-only (not in the app)", body: "Media slots, network link, jog tension adjustment and hardware display settings remain hardware-only. They are intentionally documented so the coverage audit is explicit.", keywords: "hardware only media slots network link tension display", controls: [])
    ]
}
