import Foundation
import GRDB
import TonearmCore

/// Output + persistence: turn sequenced slots into an `AutoPlaylistResult`/
/// `[AutoPlaylistItem]` pair and write brief + result + items. Split out of
/// `PlaylistGenerator.swift`; `makeResult`/`makeItems`/`makeSlots`/`persist`
/// are all called from `generate(_:)` (core file) and `replaceSlot(slot:)`
/// (`PlaylistGenerator+Interactions.swift`), so they stay `internal` (not
/// `private`).
extension PlaylistGenerator {
    func makeResult(slots: [SequencedSlot], candidates: [TrackFeatures],
                    request: PlaylistGenerationRequest) -> AutoPlaylistResult {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        let totalSeconds = slots.reduce(0) {
            $0 + Int((byID[$1.trackID]?.durationSec ?? 0).rounded())
        }
        let arcErrors = slots.compactMap { slot -> Double? in
            guard let actual = slot.actualEnergy else { return nil }
            return abs(actual - slot.targetEnergy)
        }
        let arcError = arcErrors.isEmpty ? 0 : arcErrors.reduce(0, +) / Double(arcErrors.count)
        let costs = slots.dropFirst().map(\.transitionCostIn)
        let meanTransitionCost = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)

        return AutoPlaylistResult(briefID: 0,
                                  playlistID: nil,
                                  smartCrateID: nil,
                                  generatedAt: Date(),
                                  totalSeconds: totalSeconds,
                                  arcError: arcError,
                                  meanTransitionCost: meanTransitionCost,
                                  analysisVersion: AnalysisVersions.embedding)
    }

    func makeItems(slots: [SequencedSlot], locks: [Int: Int64]) -> [AutoPlaylistItem] {
        slots.map { slot in
            AutoPlaylistItem(resultID: 0,
                             trackID: slot.trackID,
                             position: slot.position,
                             locked: locks[slot.position] != nil,
                             targetEnergy: slot.targetEnergy,
                             actualEnergy: slot.actualEnergy ?? PlaylistSequencer.neutral,
                             transitionCostIn: slot.transitionCostIn,
                             semanticScore: slot.semanticScore)
        }
    }

    func makeSlots(tracks: [TrackFeatures], request: PlaylistGenerationRequest,
                   semanticScores: [Int64: Double]) -> [SequencedSlot] {
        let arcTarget = (0..<tracks.count).map { index -> Double in
            let t = tracks.count > 1 ? Double(index) / Double(tracks.count - 1) : 0
            return request.arc.value(at: t)
        }
        return tracks.enumerated().map { index, track in
            SequencedSlot(position: index,
                          trackID: track.trackID,
                          targetEnergy: arcTarget[index],
                          actualEnergy: track.energy,
                          transitionCostIn: index == 0 ? 0
                            : PlaylistSequencer.transitionCost(tracks[index - 1], track,
                                                               request.constraints),
                          semanticScore: semanticScores[track.trackID] ?? PlaylistSequencer.neutral)
        }
    }

    func persist(request: PlaylistGenerationRequest, result: AutoPlaylistResult,
                 items: [AutoPlaylistItem]) async throws
        -> (brief: AutoPlaylistBrief, result: AutoPlaylistResult, items: [AutoPlaylistItem]) {
        let existingID = lastBriefID
        return try await pool.write { db in
            let now = Date()
            var brief: AutoPlaylistBrief
            if let existingID, let existing = try AutoPlaylistBrief.fetchOne(db, key: existingID) {
                brief = existing
                brief.prompt = request.prompt
                brief.arcKind = request.arc.kindCode
                brief.arcPointsJSON = request.arc.pointsJSON
                brief.targetSeconds = request.targetSeconds.map { Int($0.rounded()) }
                brief.targetTrackCount = request.targetTrackCount
                brief.constraintsJSON = try request.constraints.encodedJSONString()
                brief.seedTrackID = request.seedTrackID
                brief.seedCrateID = request.seedCrateID
                brief.randomSeed = Int64(bitPattern: request.randomSeed)
                brief.updatedAt = now
                try brief.update(db)
            } else {
                brief = AutoPlaylistBrief(syncID: UUID().uuidString,
                                          prompt: request.prompt,
                                          arcKind: request.arc.kindCode,
                                          arcPointsJSON: request.arc.pointsJSON,
                                          targetSeconds: request.targetSeconds.map { Int($0.rounded()) },
                                          targetTrackCount: request.targetTrackCount,
                                          constraintsJSON: try request.constraints.encodedJSONString(),
                                          seedTrackID: request.seedTrackID,
                                          seedCrateID: request.seedCrateID,
                                          randomSeed: Int64(bitPattern: request.randomSeed),
                                          createdAt: now,
                                          updatedAt: now)
                try brief.insert(db)
            }
            guard let briefID = brief.id else { throw PlaylistGeneratorError.persistFailed }
            var storedResult = result
            storedResult.briefID = briefID
            try storedResult.insert(db)
            guard let resultID = storedResult.id else { throw PlaylistGeneratorError.persistFailed }
            var storedItems: [AutoPlaylistItem] = []
            storedItems.reserveCapacity(items.count)
            for var item in items {
                item.resultID = resultID
                try item.insert(db)
                storedItems.append(item)
            }
            return (brief, storedResult, storedItems)
        }
    }
}
