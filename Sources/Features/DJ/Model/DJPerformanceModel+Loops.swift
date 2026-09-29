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
    func activateCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil, (1...8).contains(number) else { return }
        cancelGlide(id)
        if let hotLoop = deck.hotLoops[number] {
            deck.loopIn = hotLoop.loopIn
            deck.loopOut = hotLoop.loopOut
            deck.loopActive = true
            seek(id, to: hotLoop.position)
            audio.setLoop(deck: id, start: hotLoop.loopIn, end: hotLoop.loopOut, active: true)
            if !deck.isPlaying { deck.isPlaying = true; audio.play(deck: id, position: hotLoop.position, rate: deck.tempoRatio) }
            return
        }
        if let position = deck.hotCues[number] {
            seek(id, to: position)
            audio.jumpHotCue(number, deck: id)
        } else {
            if deck.loopActive, let start = deck.loopIn, let end = deck.loopOut, end > start {
                deck.hotLoops[number] = DJHotLoop(position: deck.position, loopIn: start, loopOut: end,
                                                  color: deck.hotCueColors[number] ?? (number - 1) % 8)
            } else {
                deck.hotCues[number] = quantizedPosition(deck, deck.position)
                deck.hotCueColors[number] = (number - 1) % 8
                audio.setHotCue(number, deck: id, position: deck.position)
            }
            saveMarkings(deck)
        }
    }

    func deleteCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        guard (1...8).contains(number) else { return }
        deck.hotCues[number] = nil
        deck.hotLoops[number] = nil
        deck.hotCueColors[number] = nil
        audio.deleteHotCue(number, deck: id)
        saveMarkings(deck)
    }

    func clearHotCues(_ id: DJDeckID) {
        let deck = deck(id)
        deck.hotCues.removeAll()
        deck.hotCueColors.removeAll()
        deck.hotLoops.removeAll()
        for slot in 1...8 { audio.deleteHotCue(slot, deck: id) }
        saveMarkings(deck)
    }

    func cueDown(_ id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        if deck.isPlaying {
            audio.jumpToCue(deck: id); stop(deck: id)
        } else if let cue = deck.cuePoint, abs(deck.position - cue) <= 0.01 {
            audio.cuePlayPress(deck: id)
        } else {
            deck.cuePoint = quantizedPosition(deck, deck.position); audio.setCue(deck: id, position: deck.cuePoint ?? deck.position); audio.cuePlayPress(deck: id); saveMarkings(deck)
        }
    }

    func cueUp(_ id: DJDeckID) { audio.cuePlayRelease(deck: id); deck(id).position = audio.position(for: id) }

    func clearCue(_ id: DJDeckID) {
        deck(id).cuePoint = nil
        saveMarkings(deck(id))
    }

    func clearLoop(_ id: DJDeckID) {
        let state = deck(id)
        if state.loopActive || state.loopExitPending { audio.reloopExit(deck: id) }
        state.loopIn = nil
        state.loopOut = nil
        state.loopActive = false
        state.loopExitPending = false
        state.loopSetApplied = false
        saveMarkings(state)
    }

    func minimapSeek(_ id: DJDeckID, x: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, width > 0, deck.duration > 0 else { return }
        seek(id, to: deck.duration * Double(max(0, min(width, x)) / width))
    }

    func toggleEcho(_ id: DJDeckID) {
        let deck = deck(id)
        deck.echoOutArmed.toggle()
        if deck.echoOutArmed { audio.armEchoOut(deck: id) }
        else { audio.disarmEchoOut(deck: id) }
    }

    func toggleLoop(_ id: DJDeckID) {
        let deck = deck(id)
        if deck.padMode == .loop {
            deck.padMode = .hotCue
            if deck.loopActive || deck.loopExitPending { audio.reloopExit(deck: id) }
            deck.loopActive = false
            deck.loopExitPending = false
        } else {
            if deck.padMode == .fx || deck.padMode == .beatFX { audio.disarmEchoOut(deck: id) }
            deck.padMode = .loop
        }
    }

    /// Starts or exits an automatically quantized loop from the Focus Deck
    /// beat-loop page. The audio engine remains the source of truth for the
    /// loop; this method only supplies the page-level interaction contract.
    func autoLoop(_ id: DJDeckID, beats: Double) {
        let state = deck(id)
        guard state.row != nil, beats.isFinite, beats > 0, state.tempo > 0 else { return }
        if state.loopActive {
            audio.reloopExit(deck: id)
            state.loopActive = false
            state.loopExitPending = false
            return
        }
        let start = quantizedPosition(state, state.position)
        let end = min(state.duration, start + beats * 60 / state.tempo)
        guard end > start else { return }
        state.loopIn = start
        state.loopOut = end
        state.loopActive = true
        state.loopExitPending = false
        audio.setLoop(deck: id, start: start, end: end, active: true)
        saveMarkings(state)
    }

    func echoPad(_ value: Double, deck id: DJDeckID, pressed: Bool) {
        let deck = deck(id); guard deck.padMode == .fx else { return }
        deck.echoPad = pressed ? value : nil
        if pressed { audio.setEcho(deck: id, enabled: true, beats: value) }
        else { audio.setEcho(deck: id, enabled: false, beats: value) }
    }

    func loopPad(_ pad: Int, deck id: DJDeckID) {
        let deck = deck(id); guard deck.padMode == .loop else { return }
        switch pad {
        case 0:
            deck.loopIn = quantizedPosition(deck, deck.position)
            deck.loopOut = nil
            deck.loopActive = false
            deck.loopExitPending = false
            deck.loopSetApplied = false
            audio.loopIn(deck: id)
            if deck.isPlaying {
                deck.cuePoint = deck.loopIn
                audio.setCue(deck: id, position: deck.loopIn ?? deck.position)
            }
            saveMarkings(deck)
        case 1:
            guard let start = deck.loopIn, deck.position > start else { return }
            deck.loopOut = quantizedPosition(deck, deck.position); deck.loopActive = false; audio.setLoop(deck: id, start: start, end: deck.loopOut ?? deck.position, active: false); saveMarkings(deck)
        case 2:
            guard let start = deck.loopIn, deck.tempo > 0 else { return }
            let lengths = DJLoopState.lengths
            if deck.loopSetApplied { deck.loopSetIndex = (deck.loopSetIndex + 1) % lengths.count }
            let end = min(deck.duration, start + lengths[deck.loopSetIndex] * 60 / deck.tempo)
            deck.loopSetApplied = true
            deck.loopOut = end; audio.setLoop(deck: id, start: start, end: end, active: false); saveMarkings(deck)
        case 3:
            guard deck.loopIn != nil, deck.loopOut != nil else { return }
            if deck.loopExitPending {
                audio.cancelLoopExit(deck: id)
                deck.loopExitPending = false
            } else if deck.loopActive {
                audio.exitLoopAtEnd(deck: id)
                deck.loopExitPending = true
            }
            else { audio.setLoopActive(deck: id, active: true); deck.loopActive = true; deck.loopExitPending = false }
        case 4:
            loopResize(id, factor: 0.5)
        case 5:
            loopResize(id, factor: 2)
        case 6:
            beatJump(id, direction: -1)
        case 7:
            beatJump(id, direction: 1)
        default:
            break
        }
    }

    func stop(deck id: DJDeckID) {
        let state = deck(id)
        state.isPlaying = false
        audio.stop(deck: id, echoOut: state.echoOutArmed)
    }

    func saveMarkings(_ deck: DJDeckState) {
        guard let id = deck.row?.id, id >= 0 else { return }
        let markings = DJMarkings(hotCues: deck.hotCues, hotCueColors: deck.hotCueColors,
                                  hotLoops: deck.hotLoops, cuePointSeconds: deck.cuePoint,
                                  loopInSeconds: deck.loopIn, loopOutSeconds: deck.loopOut)
        Task { try? await store.saveDJMarkings(markings, trackId: id) }
        Task { await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: id) }
    }

}
