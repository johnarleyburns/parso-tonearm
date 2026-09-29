import Foundation
import Combine
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDiscovery

@MainActor
extension DJPerformanceModel {
    func setPadMode(_ id: DJDeckID, mode: DJPadMode) {
        let deck = deck(id)
        if mode == .keyShift || mode == .grid {
            deck.previousPadMode = deck.padMode
            deck.padMode = mode
            return
        }
        if mode == .fx {
            if deck.padMode == .fx {
                deck.padMode = .beatFX
            } else {
                deck.padMode = .fx
            }
        } else if mode == .loop && deck.padMode == .loop {
            toggleLoop(id)
        } else {
            if deck.padMode == .loop, deck.loopActive {
                audio.reloopExit(deck: id)
                deck.loopActive = false
                deck.loopExitPending = false
            }
            if deck.padMode == .fx || deck.padMode == .beatFX { audio.disarmEchoOut(deck: id); deck.echoOutArmed = false }
            deck.padMode = mode
        }
    }

    func toggleDeckMode(_ id: DJDeckID, _ mode: DJDeckMode) {
        let deck = deck(id)
        switch mode {
        case .vinyl: deck.vinyl.toggle(); audio.setVinyl(deck: id, enabled: deck.vinyl)
        case .slip: deck.slip.toggle(); audio.setSlip(deck: id, enabled: deck.slip)
        case .reverse:
            deck.reverse.toggle()
            audio.setReverse(deck: id, enabled: deck.reverse)
            let start = DJReversePlaybackPolicy.startPosition(enabled: deck.reverse,
                                                               isPlaying: deck.isPlaying,
                                                               current: deck.position,
                                                               duration: deck.duration)
            if start != deck.position { seek(id, to: start) }
        case .quantize: deck.quantize.toggle(); audio.setQuantize(deck: id, enabled: deck.quantize)
        }
    }

    func setPadAction(_ id: DJDeckID, index: Int, pressed: Bool = false) {
        let deck = deck(id)
        switch deck.padMode {
        case .hotCue:
            guard (0..<8).contains(index) else { return }
            activateCue(index + 1, deck: id)
        case .beatLoop:
            guard DJPerformPages.autoLoopBeats.indices.contains(index) else { return }
            autoLoop(id, beats: DJPerformPages.autoLoopBeats[index])
        case .loop:
            if index < 8 { loopPad(index, deck: id) }
        case .beatJump:
            guard DJPerformPages.beatJumpBeats.indices.contains(index) else { return }
            let beats = DJPerformPages.beatJumpBeats[index]
            beatJump(id, direction: beats / max(1, abs(beats)))
        case .fx:
            let beats = [0.25, 0.5, 1.0, 2.0]
            if index < 4 { echoPad(beats[index], deck: id, pressed: pressed) }
            else if index == 4, pressed { toggleEcho(id) }
            else if index == 5, pressed { audio.loopRoll(deck: id, beats: 0.5) }
            else if index == 6, pressed { audio.setReverb(deck: id, enabled: true) }
            else if index == 7, pressed { audio.brake(deck: id) }
        case .beatFX:
            switch index {
            case 0: setBeatFX(action: .nextKind)
            case 1: setBeatFX(action: .previousBeat)
            case 2: setBeatFX(action: .nextBeat)
            case 3: setBeatFX(action: .toggle)
            case 4: setBeatFX(action: .assign("A"))
            case 5: setBeatFX(action: .assign("B"))
            case 6: setBeatFX(action: .assign("M"))
            case 7: setBeatFX(action: .depth(min(1, beatFXDepth + 0.1)))
            default: break
            }
        case .mix:
            switch index {
            case 0: setTrim(.a, value: deckA.trim + 0.05)
            case 1: setTrim(.b, value: deckB.trim + 0.05)
            case 2: autoGain.toggle()
            case 3: toggleRecording()
            case 4: setIsolator(0, value: DJFaderMapping.snapped(isolatorLow + 0.05))
            case 5: setIsolator(1, value: DJFaderMapping.snapped(isolatorMid + 0.05))
            case 6: setIsolator(2, value: DJFaderMapping.snapped(isolatorHigh + 0.05))
            case 7: flatMix()
            default: break
            }
        case .keyShift:
            switch index {
            case 0: shiftKeyInternal(id, by: -1)
            case 1: shiftKeyInternal(id, by: 1)
            case 2: shiftKeyInternal(id, by: -2)
            case 3: shiftKeyInternal(id, by: 2)
            case 4: toggleKeySync(id)
            case 5: shiftKeyInternal(id, by: -deck.keyShiftSemitones)
            case 6: toggleMasterTempo(id)
            case 7: doneTool(id)
            default: break
            }
        case .grid:
            switch index {
            case 0: adjustGrid(id, by: -0.01)
            case 1: adjustGrid(id, by: 0.01)
            case 2: setGridHere(id)
            case 3: tapTempo(id)
            case 4: setBPMOverride(id, value: (deck.bpmOverride ?? deck.bpm ?? 120) / 2)
            case 5: setBPMOverride(id, value: (deck.bpmOverride ?? deck.bpm ?? 120) * 2)
            case 6: resetGrid(id)
            case 7: doneTool(id)
            default: break
            }
        case .echo:
            break
        }
    }

}
