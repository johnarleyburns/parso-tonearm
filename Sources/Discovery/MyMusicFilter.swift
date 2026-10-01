// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ParsoAudioAnalysis
import TonearmCore

/// The hard, local portion of the My Music filter bar.  Keeping this policy
/// outside SwiftUI makes the DJ Mix Match rules deterministic and testable.
public struct MyMusicFilter: Equatable, Sendable {
    public var bpmMin: Double?
    public var bpmMax: Double?
    public var key: String?
    public var mixBPM: Double?
    public var mixBPMRange: ClosedRange<Double>?
    public var mixKey: String?

    public init(bpmMin: Double? = nil, bpmMax: Double? = nil, key: String? = nil,
                mixBPM: Double? = nil, mixBPMRange: ClosedRange<Double>? = nil,
                mixKey: String? = nil) {
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.key = key
        self.mixBPM = mixBPM
        self.mixBPMRange = mixBPMRange
        self.mixKey = mixKey
    }

    public var isEmpty: Bool {
        bpmMin == nil && bpmMax == nil && key == nil && mixBPM == nil
            && mixBPMRange == nil && mixKey == nil
    }

    public func matches(_ info: DJLoadTrackInfo) -> Bool {
        guard DJLoadTrackFilter(bpmMin: bpmMin, bpmMax: bpmMax, camelotKey: key).matches(info)
        else { return false }

        guard mixBPM != nil || mixBPMRange != nil || mixKey != nil else { return true }

        if let range = mixBPMRange {
            guard let candidateBPM = info.bpm, range.contains(candidateBPM) else { return false }
        } else if let bpm = mixBPM, let candidateBPM = info.bpm {
            guard let range = MusicalMatchPolicy.bpmRange(for: bpm), range.contains(candidateBPM)
            else { return false }
        } else if mixBPM != nil {
            return false
        }

        if let key = mixKey {
            guard let referenceKey = CamelotKey(code: key),
                  let candidateKey = info.camelotKey.flatMap(CamelotKey.init(code:)),
                  MusicalMatchPolicy.compatibleKeys(for: referenceKey).contains(candidateKey)
            else { return false }
        }
        return true
    }
}
