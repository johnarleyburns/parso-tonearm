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
    func setBass(_ value: Double) {
        bassFader = value
        deckA.eqLow = value
        deckB.eqLow = value
        audio.setEQ(deck: .a, high: deckA.eqHigh, mid: deckA.eqMid, low: value)
        audio.setEQ(deck: .b, high: deckB.eqHigh, mid: deckB.eqMid, low: value)
        audio.setBassBlend(value)
    }

    func setCrossfader(_ value: Double) {
        crossfader = value
        audio.setCrossfader(value)
    }

    func setChannelLevel(_ id: DJDeckID, value: Double) {
        if id == .a { deckA.channelLevel = value } else { deckB.channelLevel = value }
        audio.setChannelLevel(deck: id, value: value)
    }

    func setEQ(_ id: DJDeckID, high: Double? = nil, mid: Double? = nil, low: Double? = nil) {
        let deck = deck(id)
        if let high { deck.eqHigh = high }
        if let mid { deck.eqMid = mid }
        if let low { deck.eqLow = low }
        audio.setEQ(deck: id, high: deck.eqHigh, mid: deck.eqMid, low: deck.eqLow)
    }

    func setColorFX(_ id: DJDeckID, value: Double) { deck(id).colorFX = value; audio.setColorFX(deck: id, value: value) }

    func setTrim(_ id: DJDeckID, value: Double) {
        deck(id).trim = DJFaderMapping.snapped(value)
        audio.setTrim(deck: id, value: deck(id).trim)
    }

    func flatMix() {
        deckA.eqHigh = 0.5; deckA.eqMid = 0.5; deckA.eqLow = 0.5; deckA.colorFX = 0.5
        deckB.eqHigh = 0.5; deckB.eqMid = 0.5; deckB.eqLow = 0.5; deckB.colorFX = 0.5
        isolatorLow = 0.5; isolatorMid = 0.5; isolatorHigh = 0.5
        audio.setEQ(deck: .a, high: 0.5, mid: 0.5, low: 0.5)
        audio.setEQ(deck: .b, high: 0.5, mid: 0.5, low: 0.5)
        audio.setColorFX(deck: .a, value: 0.5); audio.setColorFX(deck: .b, value: 0.5)
        audio.setIsolator(low: 0.5, mid: 0.5, high: 0.5)
    }

    func setHeadphoneLevel(_ value: Double) { headphoneLevel = value; audio.setHeadphoneLevel(value) }
    func setCueMasterMix(_ value: Double) { cueMasterMix = value; audio.setCueMasterMix(value) }
    func setIsolator(_ which: Int, value: Double) {
        switch which { case 0: isolatorLow = value; case 1: isolatorMid = value; default: isolatorHigh = value }
        audio.setIsolator(low: isolatorLow, mid: isolatorMid, high: isolatorHigh)
    }

    func toggleRecording() {
        if !recording {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
            let available = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage
            switch DJRecordingStoragePolicy.decision(availableBytes: available) {
            case .stop:
                ToastCenter.shared.error("Not enough storage to record — free at least 200 MB first")
                return
            case .warn:
                ToastCenter.shared.info("Low storage — recording will stop at 200 MB free")
            case .allow:
                break
            }
        }
        recording.toggle(); recordingStartedAt = recording ? Date() : nil
        audio.setRecording(recording)
    }

}
