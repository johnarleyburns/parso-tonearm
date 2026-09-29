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
    func toggle(_ id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying.toggle()
        if deck.isPlaying {
            audio.setReverse(deck: id, enabled: deck.reverse)
            audio.play(deck: id, position: deck.position, rate: deck.tempoRatio)
        }
        else { stop(deck: id) }
    }

    func selectDeck(_ id: DJDeckID) { activeDeck = id }

    func deckIsOnAir(_ id: DJDeckID) -> Bool {
        let channel = id == .a ? deckA.channelLevel : deckB.channelLevel
        let crossGain = id == .a ? (crossfader <= 0.5 ? 1 : (1 - crossfader) * 2)
                                 : (crossfader >= 0.5 ? 1 : crossfader * 2)
        return deck(id).isPlaying && channel > 0.05 && crossGain > 0.05
    }

    func setPlaying(_ playing: Bool, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying = playing
        if playing { audio.play(deck: id, position: deck.position, rate: deck.tempoRatio) }
        else { stop(deck: id) }
    }

    func nudge(_ id: DJDeckID, direction: Double) {
        cancelGlide(id)
        seek(id, by: direction / 75)
    }

    /// Maps the platter's outer ring and top plate to the same transport
    /// vocabulary used by the hardware handoff: outer-ring nudge while
    /// playing, vinyl scratch on the top plate, and frame/beat search while
    /// paused.
    func jog(_ id: DJDeckID, angle: Double, outerRing: Bool) {
        let state = deck(id)
        if !state.isPlaying {
            // A stopped jog must update the model position as well as the
            // engine position. Calling transient PAE frameSearch here leaves
            // the model at the old beat, so the release-time quantize pass
            // snaps the track back by several seconds.
            seek(id, by: DJJogMapper.pausedSeekSeconds(angle: angle,
                                                       outerRing: outerRing,
                                                       bpm: state.tempo))
            return
        }
        let action = DJJogMapper.action(angle: angle, isPlaying: state.isPlaying,
                                        vinyl: state.vinyl, bpm: state.tempo)
        switch action {
        case .nudge(let amount):
            nudge(id, direction: outerRing ? amount : amount * 0.35)
        case .scratch(let samples):
            guard !outerRing else { nudge(id, direction: samples / 48_000); return }
            if !scratching.contains(id) { scratching.insert(id); audio.beginScratch(deck: id) }
            audio.scratch(deck: id, seconds: -samples / 48_000)
        case .frameSearch(let seconds):
            audio.frameSearch(deck: id, seconds: outerRing ? seconds * 2 : seconds)
        case .seek(let seconds):
            seek(id, by: seconds * (outerRing ? 2 : 1))
        }
    }

    func movePaused(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        cancelGlide(id)
        seek(id, by: DJWaveformSeekMapping.seconds(translation: pixels,
                                                    width: width,
                                                    duration: deck.duration))
    }

    func snapIfQuantized(_ id: DJDeckID) {
        let state = deck(id)
        guard state.quantize else { return }
        seek(id, to: quantizedPosition(state, state.position))
    }

    func scratch(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard deck.isPlaying, deck.duration > 0, width > 0 else { return }
        if !scratching.contains(id) {
            scratching.insert(id)
            audio.beginScratch(deck: id)
        }
        audio.scratch(deck: id, seconds: -Double(pixels / width) * min(deck.duration, 2))
    }

    func endScratch(_ id: DJDeckID) {
        guard scratching.remove(id) != nil else { return }
        audio.endScratch(deck: id)
    }

    func beginScratch(_ id: DJDeckID) {
        guard deck(id).isPlaying else { return }
        scratching.insert(id)
        audio.beginScratch(deck: id)
    }

    func flick(_ id: DJDeckID, translation: CGFloat, predictedTranslation: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        cancelGlide(id)
        let remaining = predictedTranslation - translation
        let seconds = -Double(remaining / width) * min(deck.duration, 3)
        guard seconds.isFinite, abs(seconds) > 0.005 else { return }

        glideTasks[id] = Task { @MainActor [weak self] in
            var velocity = seconds / 0.35
            while abs(velocity) > 0.01 {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, !Task.isCancelled, !self.deck(id).isPlaying else { return }
                self.seek(id, by: velocity * 0.016)
                velocity *= 0.90
            }
            self?.glideTasks[id] = nil
        }
    }

    func changeTempo(_ id: DJDeckID, zoom: CGFloat) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        let step = zoom > 1 ? -0.1 : 0.1
        deck.tempo = max(20, min(300, ((deck.tempo + step) * 10).rounded() / 10))
        audio.setRate(deck: id, rate: deck.tempoRatio)
    }

    func setTempoPercent(_ id: DJDeckID, value: Double) {
        let deck = deck(id)
        guard !deck.syncEnabled else { return }
        deck.tempoPercent = max(-deck.tempoRange, min(deck.tempoRange, (value * 10).rounded() / 10))
        if let bpm = deck.bpm { deck.tempo = bpm * (1 + deck.tempoPercent / 100) }
        audio.setRate(deck: id, rate: deck.tempoRatio)
    }

    func cycleTempoRange(_ id: DJDeckID) {
        let values = [6.0, 10.0, 16.0, 100.0]
        let index = values.firstIndex(of: deck(id).tempoRange) ?? 1
        deck(id).tempoRange = values[(index + 1) % values.count]
    }

    func resetTempo(_ id: DJDeckID) {
        deck(id).tempoPercent = 0
        if let bpm = deck(id).bpm { deck(id).tempo = bpm }
        deck(id).syncEnabled = false
        audio.setRate(deck: id, rate: 1)
    }

    func toggleSync(_ id: DJDeckID) {
        let deck = deck(id)
        guard DJSyncAvailabilityPolicy.canSync(bpm: deck.bpm) else {
            ToastCenter.shared.info("Sync needs a BPM — analysis is still running")
            return
        }
        deck.syncEnabled.toggle()
        if deck.syncEnabled {
            audio.sync(deck: id)
            masterDeck = id == .a ? .b : .a
        }
    }

    func toggleKeySync(_ id: DJDeckID) {
        let state = deck(id)
        state.keySync.toggle()
        if state.keySync {
            audio.keySync(deck: id, to: id == .a ? .b : .a)
        }
    }

    func shiftKey(_ id: DJDeckID, by amount: Int) {
        shiftKeyInternal(id, by: amount)
    }

    func toggleMasterTempo(_ id: DJDeckID) {
        let state = deck(id)
        state.masterTempo.toggle()
        audio.setKeyLock(deck: id, enabled: state.masterTempo)
    }

    func makeMaster(_ id: DJDeckID) { audio.setAsMaster(deck: id); masterDeck = id; deck(id).syncEnabled = false }

    func isMaster(_ id: DJDeckID) -> Bool { masterDeck == id }

}
