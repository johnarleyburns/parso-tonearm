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
    func setMasterLevel(_ value: Double) {
        masterLevel = max(0, min(1, value))
        UserDefaults.standard.set(masterLevel, forKey: "dj.masterLevel")
        audio.setMasterLevel(masterLevel)
    }

    func setOutputMode(_ mode: DJOutputMode) {
        outputMode = mode
        audio.setOutputMode(mode, cueA: cueA, cueB: cueB)
    }

    func toggleCue(_ id: DJDeckID) {
        if id == .a { cueA.toggle() } else { cueB.toggle() }
        audio.setCue(deck: id, enabled: id == .a ? cueA : cueB,
                     outputMode: outputMode,
                     cueA: cueA,
                     cueB: cueB)
    }

    func stopAll() {
        glideTasks.values.forEach { $0.cancel() }
        glideTasks.removeAll()
        for id in scratching { audio.endScratch(deck: id) }
        scratching.removeAll()
        for id in DJDeckID.allCases {
            deck(id).isPlaying = false
            audio.pause(deck: id)
        }
        audio.stop()
    }

    func seek(_ id: DJDeckID, by amount: Double) {
        seek(id, to: deck(id).position + amount)
    }

    func seek(_ id: DJDeckID, to value: Double) {
        let deck = deck(id)
        let position = max(0, min(deck.duration, value))
        deck.position = position
        audio.seek(deck: id, position: position)
    }

    func quantizedPosition(_ deck: DJDeckState, _ position: Double) -> Double {
        guard deck.quantize else { return max(0, min(deck.duration, position)) }
        var grid = deck.beatPositions
        if grid.isEmpty, let bpm = deck.bpm, bpm > 0 {
            let spacing = 60 / bpm
            let count = max(0, Int((deck.duration / spacing).rounded()))
            grid = (0...count).map { Double($0) * spacing }
        }
        guard let nearest = grid.min(by: { abs($0 - position) < abs($1 - position) }) else { return position }
        return max(0, min(deck.duration, nearest))
    }

    func tick() {
        audio.pollEvents()
        enforceRecordingStorage()
        for id in DJDeckID.allCases {
            let deck = deck(id)
            let position = min(deck.duration, audio.position(for: id))
            if abs(deck.position - position) >= 0.005 { deck.position = position }
            if !scratching.contains(id) {
                let isPlaying = audio.isPlaying(for: id)
                if deck.isPlaying != isPlaying { deck.isPlaying = isPlaying }
            }
            if deck.duration > 0, deck.position >= deck.duration - 0.05, !audio.isPlaying(for: id) {
                deck.position = deck.duration
                deck.isPlaying = false
            }
            let loopActive = audio.isLoopActive(for: id)
            if deck.loopActive != loopActive { deck.loopActive = loopActive }
            if deck.loopExitPending && !loopActive { deck.loopExitPending = false }
            deck.peakMeter = Double(audio.peakMeter(for: id))
            deck.peakHold = Double(audio.peakHold(for: id))
        }
    }

    func enforceRecordingStorage() {
        guard recording, Date().timeIntervalSince(lastStorageCheck) >= 1 else { return }
        lastStorageCheck = Date()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let available = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage
        guard DJRecordingStoragePolicy.decision(availableBytes: available) == .stop else { return }
        recording = false
        recordingStartedAt = nil
        audio.setRecording(false)
        ToastCenter.shared.error("Recording stopped — free at least 200 MB to continue")
    }

    func cancelGlide(_ id: DJDeckID) {
        glideTasks[id]?.cancel()
        glideTasks[id] = nil
    }
}
