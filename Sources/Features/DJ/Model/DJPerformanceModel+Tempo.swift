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
    func setBeatFX(action: DJBeatFXAction) {
        switch action {
        case .nextKind: beatFXKind = (beatFXKind + 1) % 12
        case .previousBeat: beatFXBeatIndex = max(0, beatFXBeatIndex - 1)
        case .nextBeat: beatFXBeatIndex = min(7, beatFXBeatIndex + 1)
        case .toggle: beatFXOn.toggle()
        case .assign(let value): beatFXAssignment = value
        case .depth(let value): beatFXDepth = value
        }
        audio.setBeatFX(kind: beatFXKind, beat: beatFXBeatIndex, depth: beatFXDepth,
                        assignment: beatFXAssignment, enabled: beatFXOn)
    }

    func loopResize(_ id: DJDeckID, factor: Double) {
        guard let start = deck(id).loopIn, let end = deck(id).loopOut else { return }
        let newEnd = min(deck(id).duration, start + (end - start) * factor)
        deck(id).loopOut = newEnd
        audio.setLoop(deck: id, start: start, end: newEnd, active: deck(id).loopActive)
        saveMarkings(deck(id))
    }

    func beatJump(_ id: DJDeckID, direction: Double) {
        let beats = deck(id).loopOut.flatMap { out in
            deck(id).loopIn.map { max(1, Int(((out - $0) * (deck(id).bpm ?? 120) / 60).rounded())) }
        } ?? 4
        seek(id, by: direction * Double(beats) * 60 / max(1, deck(id).bpm ?? 120))
    }

    func loopLengthLabel(_ id: DJDeckID) -> String {
        let index = max(0, min(DJLoopState.lengths.count - 1, deck(id).loopSetIndex))
        return String(Int(DJLoopState.lengths[index]))
    }

    func tapTempo(_ id: DJDeckID) {
        let now = Date()
        var taps = tapTimes[id, default: []].filter { now.timeIntervalSince($0) < 2.5 }
        taps.append(now)
        tapTimes[id] = Array(taps.suffix(8))
        guard taps.count >= 4 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        setBPMOverride(id, value: 60 / average)
    }

    func shiftKeyInternal(_ id: DJDeckID, by amount: Int) {
        deck(id).keyShiftSemitones = max(-12, min(12, deck(id).keyShiftSemitones + amount))
        audio.setPitchShift(deck: id, semitones: deck(id).keyShiftSemitones)
        saveGrid(deck(id))
    }

    func setBPMOverride(_ id: DJDeckID, value: Double) {
        let deck = deck(id)
        guard value.isFinite, value > 20 else { return }
        deck.bpmOverride = min(300, max(20, value))
        deck.bpm = deck.bpmOverride
        deck.tempo = deck.bpmOverride ?? deck.tempo
        applyGridToAudio(deck)
        saveGrid(deck)
    }

    func adjustGrid(_ id: DJDeckID, by seconds: Double) {
        let deck = deck(id)
        deck.firstBeatOverride = (deck.firstBeatOverride ?? deck.beatPositions.first ?? 0) + seconds
        applyGridToAudio(deck)
        saveGrid(deck)
    }

    func setGridHere(_ id: DJDeckID) {
        let deck = deck(id)
        let bpm = deck.bpm ?? 120
        let beat = 60 / bpm
        let snapped = deck.quantize ? (deck.position / beat).rounded() * beat : deck.position
        let delta = max(0, snapped) - (deck.beatPositions.first ?? 0)
        adjustGrid(id, by: delta)
    }

    func resetGrid(_ id: DJDeckID) {
        let deck = deck(id)
        deck.bpmOverride = nil; deck.firstBeatOverride = nil
        if let bpm = deck.analyzedBPM, let firstBeat = deck.analyzedFirstBeat {
            deck.bpm = bpm
            deck.tempo = bpm * (1 + deck.tempoPercent / 100)
            audio.setBeatGrid(deck: id, bpm: bpm, firstBeat: firstBeat)
            deck.beatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration)
            deck.downbeatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration, beatsPerBar: 4)
        }
        saveGrid(deck)
    }

    func applyGridToAudio(_ deck: DJDeckState) {
        guard let bpm = deck.bpm ?? deck.bpmOverride, bpm > 0 else { return }
        let firstBeat = deck.firstBeatOverride ?? deck.beatPositions.first ?? 0
        audio.setBeatGrid(deck: deck.id, bpm: bpm, firstBeat: firstBeat)
        deck.beatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration)
        deck.downbeatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration, beatsPerBar: 4)
    }

    func makeBeatPositions(bpm: Double, firstBeat: Double, duration: Double, beatsPerBar: Int = 1) -> [Double] {
        DJGridOverride.positions(bpm: bpm, firstBeat: firstBeat, duration: duration, beatsPerBar: beatsPerBar)
    }

    func doneTool(_ id: DJDeckID) { deck(id).padMode = deck(id).previousPadMode }

    func saveGrid(_ deck: DJDeckState) {
        guard let id = deck.row?.id, id >= 0 else { return }
        Task {
            try? await store.saveDJGrid(bpmOverride: deck.bpmOverride,
                                        firstBeatOverride: deck.firstBeatOverride,
                                        keyShiftSemitones: deck.keyShiftSemitones,
                                        trackId: id)
            await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: id)
        }
    }

}
