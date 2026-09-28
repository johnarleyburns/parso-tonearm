// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ParsoAudioAnalysis
import TonearmCore

/// The hard, local portion of the My Music filter bar.  Keeping this policy
/// outside SwiftUI makes the BPM/key and DJ Mix Match rules deterministic and
/// testable, while the sound/mood text remains owned by the shared Discovery
/// search screen.
public struct MyMusicFilter: Equatable, Sendable {
    public var bpmMin: Double?
    public var bpmMax: Double?
    public var key: String?
    public var mixBPM: Double?
    public var mixKey: String?

    public init(bpmMin: Double? = nil, bpmMax: Double? = nil, key: String? = nil,
                mixBPM: Double? = nil, mixKey: String? = nil) {
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.key = key
        self.mixBPM = mixBPM
        self.mixKey = mixKey
    }

    public var isEmpty: Bool {
        bpmMin == nil && bpmMax == nil && key == nil && mixBPM == nil && mixKey == nil
    }

    public func matches(_ info: DJLoadTrackInfo) -> Bool {
        guard DJLoadTrackFilter(bpmMin: bpmMin, bpmMax: bpmMax, camelotKey: key).matches(info)
        else { return false }

        guard mixBPM != nil || mixKey != nil else { return true }
        guard let bpm = mixBPM, let key = mixKey,
              let referenceKey = CamelotKey(code: key),
              let candidateBPM = info.bpm,
              let candidateKey = info.camelotKey.flatMap(CamelotKey.init(code:)) else {
            return false
        }
        return MusicalMatchPolicy.matches(
            candidateBPM: candidateBPM,
            candidateKey: candidateKey,
            reference: MusicalMatchReference(bpm: bpm, camelot: referenceKey))
    }
}
