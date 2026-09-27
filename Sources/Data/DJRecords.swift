import Foundation
import GRDB

public struct DJMarkings: Codable, Equatable, Sendable {
    public var hotCues: [Int: Double]
    public var cuePointSeconds: Double?
    public var loopInSeconds: Double?
    public var loopOutSeconds: Double?
    public init(hotCues: [Int: Double] = [:], cuePointSeconds: Double? = nil,
                loopInSeconds: Double? = nil, loopOutSeconds: Double? = nil) {
        self.hotCues = hotCues; self.cuePointSeconds = cuePointSeconds
        self.loopInSeconds = loopInSeconds; self.loopOutSeconds = loopOutSeconds
    }
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

    public init(trackId: Int64, hotCuesJSON: String = "{}", cuePointSeconds: Double? = nil,
                loopInSeconds: Double? = nil, loopOutSeconds: Double? = nil,
                hotCuesUpdatedAt: Date? = nil, analysisPayload: Data? = nil,
                analysisAlgorithm: String? = nil, analysisPayloadVersion: Int? = nil,
                sourceSampleRate: Double? = nil, sourceFrameCount: Int64? = nil,
                bpm: Double? = nil, camelotKey: String? = nil,
                analysisUpdatedAt: Date? = nil, syncID: String? = nil) {
        self.trackId = trackId; self.hotCuesJSON = hotCuesJSON
        self.cuePointSeconds = cuePointSeconds; self.loopInSeconds = loopInSeconds
        self.loopOutSeconds = loopOutSeconds; self.hotCuesUpdatedAt = hotCuesUpdatedAt
        self.analysisPayload = analysisPayload; self.analysisAlgorithm = analysisAlgorithm
        self.analysisPayloadVersion = analysisPayloadVersion; self.sourceSampleRate = sourceSampleRate
        self.sourceFrameCount = sourceFrameCount; self.bpm = bpm; self.camelotKey = camelotKey
        self.analysisUpdatedAt = analysisUpdatedAt; self.syncID = syncID
    }

    public var markings: DJMarkings {
        let data = hotCuesJSON.data(using: .utf8) ?? Data()
        let raw = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        return DJMarkings(hotCues: raw.reduce(into: [:]) { $0[Int($1.key) ?? 0] = $1.value },
                          cuePointSeconds: cuePointSeconds, loopInSeconds: loopInSeconds,
                          loopOutSeconds: loopOutSeconds)
    }
}
