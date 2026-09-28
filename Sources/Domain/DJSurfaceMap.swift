import Foundation

public enum DJSurfaceTier: Sendable, Equatable {
    case always
    case mixer
    case deckOptions
}

public enum DJSurfaceHome: Sendable, Equatable {
    case deckChips, waveform, transport, padTabs, pads, tempoRow, dock, titleBar
    case mixerChannels, mixerMaster, deckOptions, toolPage
}

public enum DJSurfaceMap {
    public static func home(for control: DJControlID) -> (DJSurfaceTier, DJSurfaceHome) {
        switch control {
        case .title, .loadA, .loadB: return (.always, .deckChips)
        case .waveformA, .waveformB, .jog: return (.always, .waveform)
        case .cue, .play, .sync: return (.always, .transport)
        case .hotCue, .loop, .fx, .beatJump: return (.always, .padTabs)
        case .pad1, .pad2, .pad3, .pad4, .pad5, .pad6, .pad7, .pad8: return (.always, .pads)
        case .tempo, .masterTempo: return (.always, .tempoRow)
        case .crossfader: return (.always, .dock)
        case .record: return (.always, .titleBar)
        case .loopIn, .loopOut, .loopSet, .loopEnter, .loopExit, .loopHalf, .loopDouble:
            return (.always, .pads)
        case .echoOut, .beatFX: return (.always, .pads)
        case .eqHi, .eqMid, .eqLow, .cfx, .channelFaderA, .channelFaderB, .cueA, .cueB, .volume, .phones, .cueMaster:
            return (.mixer, .mixerChannels)
        case .mix, .bass, .output: return (.mixer, .mixerMaster)
        case .vinyl, .slip, .reverse, .quantize, .range, .reset, .tap:
            return (.deckOptions, .deckOptions)
        case .key, .keyShift, .grid: return (.deckOptions, .toolPage)
        case .info: return (.deckOptions, .deckOptions)
    }
}
}
