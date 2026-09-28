import Foundation
import GRDB

public struct DJMarkings: Codable, Equatable, Sendable {
    public var hotCues: [Int: Double]
    public var hotCueColors: [Int: Int]
    public var hotLoops: [Int: DJHotLoop]
    public var cuePointSeconds: Double?
    public var loopInSeconds: Double?
    public var loopOutSeconds: Double?
    public init(hotCues: [Int: Double] = [:], hotCueColors: [Int: Int] = [:],
                hotLoops: [Int: DJHotLoop] = [:], cuePointSeconds: Double? = nil,
                loopInSeconds: Double? = nil, loopOutSeconds: Double? = nil) {
        self.hotCues = hotCues; self.cuePointSeconds = cuePointSeconds
        self.hotCueColors = hotCueColors; self.hotLoops = hotLoops
        self.loopInSeconds = loopInSeconds; self.loopOutSeconds = loopOutSeconds
    }
}

public struct DJHotLoop: Codable, Equatable, Sendable {
    public var position: Double
    public var loopIn: Double
    public var loopOut: Double
    public var color: Int

    public init(position: Double, loopIn: Double, loopOut: Double, color: Int = 0) {
        self.position = position; self.loopIn = loopIn; self.loopOut = loopOut; self.color = color
    }
}

struct DJStoredCue: Codable {
    var t: Double
    var c: Int
    var loopIn: Double?
    var loopOut: Double?
}
public struct DJTrackPrep: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dj_track_prep"
    public var trackId: Int64
    public var hotCuesJSON: String
    public var cuePointSeconds: Double?
    public var loopInSeconds: Double?
    public var loopOutSeconds: Double?
    public var hotCuesUpdatedAt: Date?
    public var analysisPayload: Data?
    public var analysisAlgorithm: String?
    public var analysisPayloadVersion: Int?
    public var sourceSampleRate: Double?
    public var sourceFrameCount: Int64?
    public var bpm: Double?
    public var camelotKey: String?
    public var analysisUpdatedAt: Date?
    public var syncID: String?
    public var bpmOverride: Double?
    public var firstBeatOverride: Double?
    public var keyShiftSemitones: Int

    public init(trackId: Int64, hotCuesJSON: String = "{}", cuePointSeconds: Double? = nil,
                loopInSeconds: Double? = nil, loopOutSeconds: Double? = nil,
                hotCuesUpdatedAt: Date? = nil, analysisPayload: Data? = nil,
                analysisAlgorithm: String? = nil, analysisPayloadVersion: Int? = nil,
                sourceSampleRate: Double? = nil, sourceFrameCount: Int64? = nil,
                bpm: Double? = nil, camelotKey: String? = nil,
                analysisUpdatedAt: Date? = nil, syncID: String? = nil,
                bpmOverride: Double? = nil, firstBeatOverride: Double? = nil,
                keyShiftSemitones: Int = 0) {
        self.trackId = trackId; self.hotCuesJSON = hotCuesJSON
        self.cuePointSeconds = cuePointSeconds; self.loopInSeconds = loopInSeconds
        self.loopOutSeconds = loopOutSeconds; self.hotCuesUpdatedAt = hotCuesUpdatedAt
        self.analysisPayload = analysisPayload; self.analysisAlgorithm = analysisAlgorithm
        self.analysisPayloadVersion = analysisPayloadVersion; self.sourceSampleRate = sourceSampleRate
        self.sourceFrameCount = sourceFrameCount; self.bpm = bpm; self.camelotKey = camelotKey
        self.analysisUpdatedAt = analysisUpdatedAt; self.syncID = syncID
        self.bpmOverride = bpmOverride; self.firstBeatOverride = firstBeatOverride
        self.keyShiftSemitones = keyShiftSemitones
    }

    public var markings: DJMarkings {
        let data = hotCuesJSON.data(using: .utf8) ?? Data()
        if let stored = try? JSONDecoder().decode([String: DJStoredCue].self, from: data) {
            var hotCues: [Int: Double] = [:]
            var colors: [Int: Int] = [:]
            var loops: [Int: DJHotLoop] = [:]
            for (key, cue) in stored {
                guard let slot = Int(key), (1...8).contains(slot) else { continue }
                if let loopIn = cue.loopIn, let loopOut = cue.loopOut, loopOut > loopIn {
                    loops[slot] = DJHotLoop(position: cue.t, loopIn: loopIn, loopOut: loopOut, color: cue.c)
                } else {
                    colors[slot] = cue.c
                    hotCues[slot] = cue.t
                }
            }
            return DJMarkings(hotCues: hotCues, hotCueColors: colors, hotLoops: loops,
                              cuePointSeconds: cuePointSeconds, loopInSeconds: loopInSeconds,
                              loopOutSeconds: loopOutSeconds)
        }
        let raw = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        return DJMarkings(hotCues: raw.reduce(into: [:]) { if let slot = Int($1.key) { $0[slot] = $1.value } },
                          cuePointSeconds: cuePointSeconds, loopInSeconds: loopInSeconds,
                          loopOutSeconds: loopOutSeconds)
    }
}
