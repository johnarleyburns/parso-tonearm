import Foundation

extension AudioPlayer {
    /// Plays the blend from `outgoing` into `incoming` on the mix decks, from
    /// shortly before it starts: the same planner and mixer a mix uses, so the
    /// audition is exactly what the mix will play.
    public func auditionTransition(outgoing: TrackRow, incoming: TrackRow) {
        let outgoingID = outgoing.track.id ?? -1
        let incomingID = incoming.track.id ?? -1
        let steps = [
            MixStep(trackID: outgoingID, position: 0, effectiveBPM: 0),
            MixStep(trackID: incomingID, position: 1, effectiveBPM: 0)
        ]
        let source = MixPlan(steps: steps, excluded: [], summary: MixSummary(),
                             request: MixRequest(candidates: []))
        auditionRequested = true
        play(tracks: [outgoing, incoming], startAt: 0, source: .mix(source))
        auditionRequested = false
        mixDecks?.auditionNextBlend()
    }
}
