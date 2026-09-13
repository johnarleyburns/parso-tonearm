import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - Recording (§37.2, FR-ENG-7; plan 5.10, decision 14)

    /// The record toggle every performance surface drives (decision 14): starts
    /// the §37.2 tap + encoder, or stops and finalizes. Forwarding is async —
    /// the engine's encoder is an actor and `stopRecording` returns the
    /// finished recording (5.11 consumes it for the `mix` rows).
    public func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    /// Start recording: forward to the engine, then mirror the session state
    /// (decision 14). A graph without a record tap is an honest unavailable
    /// state — the chip stays off, it never lies about recording. Once the tap
    /// + encoder are live, the §37.3 journal opens the in-progress `mix` row —
    /// a journal failure aborts the recording rather than running journal-less
    /// (a crash would then lose a recording the app believes is safe).
    public func startRecording() async {
        guard !isRecording else { return }
        let directory: URL
        do {
            directory = try await engine.startRecording()
        } catch {
            return
        }
        guard engine.isRecording else { return }
        if let recordingService {
            do {
                try await recordingService.begin(outputDirectory: directory)
            } catch {
                // The engine is live but nothing will be recoverable — unwind
                // honestly instead of recording silently without a journal.
                _ = try? await engine.stopRecording()
                return
            }
        }
        recordingStartSample = engine.masterSample
        recordingElapsed = 0
        // A fresh §37.4 timeline (§37.4, plan 5.12), and the playing-edge
        // detector reset so a deck already playing at record time logs its
        // current track at ~0:00.
        recordingTimeline = MixTimeline()
        wasDeckAPlaying = false
        wasDeckBPlaying = false
        transitionEvents = []
        finishedMix = nil
        isRecording = true
    }

    /// Stop recording: forward, finalize, write the `mix`/`mix_asset` rows and
    /// join the segments (plan 5.11), persist the §37.4 timeline (plan 5.12),
    /// then mirror the session state off and surface the finished mix for the
    /// review listen (FR-REC-6).
    public func stopRecording() async {
        guard isRecording else { return }
        let output = try? await engine.stopRecording()
        if let output, let recordingService {
            let journal = recordingJournalConfiguration()
            finishedMix = try? await recordingService.finalize(
                output: output, journal: journal, timeline: recordingTimeline)
        }
        isRecording = engine.isRecording
        recordingTimeline = MixTimeline()
        wasDeckAPlaying = false
        wasDeckBPlaying = false
    }

    /// Clear the finished mix — the performance surfaces call this when the
    /// review-listen sheet is dismissed, so a finished recording is presented
    /// exactly once.
    public func dismissFinishedMix() {
        finishedMix = nil
    }

    /// Recover every crashed recording — the §37.3 `reconcile()` on workspace
    /// appear (plan 5.11, NFR-REL-2): stale `recording` rows become `complete`
    /// (segments joined) or `corrupt`. Idempotent; the result is surfaced by
    /// 5.12's Mixes view, not here.
    public func reconcileRecordings() async {
        guard let recordingService else { return }
        _ = try? await recordingService.reconcile()
    }

    /// The engine configuration in force — the self-describing payload for the
    /// regression suite's `mix-journal.json` (dj-regression-suite §7, hook 5.11).
    private func recordingJournalConfiguration() -> RecordingJournalConfiguration {
        RecordingJournalConfiguration(sampleRate: engine.sampleRate,
                                      limiterCeiling: engine.limiterCeiling,
                                      masterBPM: telemetry.masterBPM,
                                      echoBeatsA: echoBeatsA,
                                      echoBeatsB: echoBeatsB,
                                      droppedFrames: Int64(engine.droppedRecordFrames),
                                      events: transitionEvents)
    }

    // MARK: - Transition journal (dj-regression-suite §7)

    /// The recording-relative master-clock sample — the same basis §37.4's
    /// timeline entries use, so a journal event and a `mix_track_event` are
    /// comparable against the same recording.
    var currentRecordingSample: Int64 {
        engine.masterSample - recordingStartSample
    }

    /// Append one transition event, but only while recording — a gesture made
    /// before the record light is on is a rehearsal, not part of the mix.
    func recordTransition(_ event: RecordingJournalEvent) {
        guard isRecording else { return }
        transitionEvents.append(event)
    }

    /// Where a control was when the **gesture** now moving it began.
    ///
    /// A transition is a movement, not a value. A finger dragging an EQ knob to
    /// the kill sends dozens of small changes on the way down, and comparing
    /// each one only against the one before it never sees a fall from unity to
    /// kill — it sees thirty tiny steps and recognises nothing. So changes
    /// arriving in quick succession are treated as one gesture, holding the
    /// value the control had when it started, and each gesture may only announce
    /// itself once.
    ///
    /// (`gestures` is declared as a stored property on `WorkspaceModel` itself —
    /// see WorkspaceModel.swift — because Swift extensions cannot hold stored
    /// instance properties.)
    /// The quiet gap that separates one gesture from the next. Comfortably
    /// longer than a drag's frame interval and far shorter than the musical
    /// distance between two transitions.
    private static let gestureGap: TimeInterval = 0.4

    private func gestureOrigin(_ key: String, current: Float, now: Date = Date()) -> Float {
        if let entry = gestures[key], now.timeIntervalSince(entry.touched) <= Self.gestureGap {
            gestures[key] = (entry.origin, now, entry.fired)
            return entry.origin
        }
        gestures[key] = (current, now, false)
        return current
    }

    private func gestureHasFired(_ key: String) -> Bool { gestures[key]?.fired ?? false }

    private func markGestureFired(_ key: String) {
        guard let entry = gestures[key] else { return }
        gestures[key] = (entry.origin, entry.touched, true)
    }

    // `deckID`/`midiDeckID` moved to WorkspaceModel.swift (core file) — they
    // are shared by this file, WorkspaceModel+Mixer.swift and
    // WorkspaceModel+Library.swift.

    /// The Bass Swap (§26A.3, transition 1): one deck's low band is killed
    /// while the other's low is already killed — the low end changes hands and
    /// the mids stay put. The `outgoing` deck is the one whose low falls.
    func detectBassSwap(deck: Deck, newLow: Float) {
        let key = "eq.low.\(deckID(deck))"
        let previous = gestureOrigin(key, current: deck == .a ? eqALow : eqBLow)
        let other = deck == .a ? eqBLow : eqALow
        guard !gestureHasFired(key), previous >= -0.25, newLow <= -0.75, other <= -0.25 else {
            return
        }
        markGestureFired(key)
        recordTransition(RecordingJournalEvent(kind: "transition.bassSwap",
                                               atSample: currentRecordingSample,
                                               outgoing: deckID(deck),
                                               incoming: deckID(deck == .a ? .b : .a)))
    }

    /// The Filter Transition (transition 2): a sweep leaving centre toward the
    /// high-pass side (`filter` fires at the sweep's top), then the return to
    /// centre — the hard bypass (§35.3) — as its own event so the analyzer can
    /// prove low returns to its pre-sweep level. The return is caught by
    /// *state* (the filter was engaged, now it is in the bypass region) rather
    /// than a crossing threshold, because a real sweep's last step can land
    /// anywhere in the bypass band.
    func detectFilter(deck: Deck, newKnob: Float) {
        let engaged = deck == .a ? filterEngagedA : filterEngagedB
        // Mark the sweep where it **starts** — the knob leaving the bypass band
        // is the moment the DJ began moving it, and a filter transition is the
        // movement, so marking the far end would put the whole sweep before its
        // own mark where nothing measuring it can see it (§53.9 row 2). The
        // engaged flag is what makes it fire once: a sweep arrives as a long
        // run of small changes, and every one of them crosses some threshold.
        // 0.05 is the knob leaving the bypass band, which is where the hand
        // started moving — mark any later and the low is already going by the
        // time the mark lands, so nothing measuring the sweep forward from it
        // sees the sweep.
        if !engaged, newKnob >= 0.05 {
            setFilterEngaged(true, for: deck)
            recordTransition(RecordingJournalEvent(kind: "transition.filter",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        } else if engaged, newKnob < 0.02 {
            // The return to centre is its own mark: §35.3 says centre is a hard
            // bypass, and the analyzer proves the low came back to exactly
            // where it was.
            setFilterEngaged(false, for: deck)
            recordTransition(RecordingJournalEvent(kind: "transition.filterBypass",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        }
    }

    // `filterEngagedA`/`filterEngagedB` are declared as stored properties on
    // `WorkspaceModel` itself (see WorkspaceModel.swift) for the same reason
    // as `gestures` above.
    private func setFilterEngaged(_ value: Bool, for deck: Deck) {
        switch deck {
        case .a: filterEngagedA = value
        case .b: filterEngagedB = value
        }
    }

    /// The Fader Cut (transition 4) vs Echo Out (transition 3): a channel
    /// fader dropped to the floor is an Echo Out when that deck's §35A echo is
    /// running (the tail is post-fader and keeps ringing), else a plain cut.
    func detectChannelFader(deck: Deck, newGain: Float) {
        let key = "fader.\(deckID(deck))"
        let previous = gestureOrigin(key, current: deck == .a ? channelA : channelB)
        guard !gestureHasFired(key), previous >= 0.5, newGain <= 0.05 else { return }
        markGestureFired(key)
        if echoEnabled(deck) {
            recordTransition(RecordingJournalEvent(kind: "transition.echoOut",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck),
                                                   echoDivision: echoBeats(deck)))
        } else {
            recordTransition(RecordingJournalEvent(kind: "transition.faderCut",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        }
    }

    /// The Blend (transition 5): the crossfader sweeping **into the centre
    /// region** from either side (§35.4), where both decks are audible. Caught
    /// by the new position landing in `|x| ≤ 0.1` while the previous position
    /// was beyond it on that deck's side — so a stepped sweep fires exactly
    /// once as it reaches centre, and a park *away* from centre never does.
    func detectCrossfader(_ newPosition: Float) {
        let previous = crossfader
        let centered = abs(newPosition) <= 0.1
        if centered, previous <= -0.1 {
            recordTransition(RecordingJournalEvent(kind: "transition.blend",
                                                   atSample: currentRecordingSample,
                                                   outgoing: "a", incoming: "b"))
        } else if centered, previous >= 0.1 {
            recordTransition(RecordingJournalEvent(kind: "transition.blend",
                                                   atSample: currentRecordingSample,
                                                   outgoing: "b", incoming: "a"))
        }
    }

    /// Consume the §34A.4 session responses (plan 5.11): `.began` flushes the
    /// recording segment so the interruption costs at most the in-flight one
    /// (NFR-REL-2); `.ended` opens a **new** segment. Decks are never
    /// auto-played — the resume is the human's call (§34A.4). Route-change
    /// responses are the engine's concern, not the journal's.
    func startConsumingSessionResponses() {
        guard let session, interruptionTask == nil else { return }
        interruptionTask = Task { [weak self] in
            let responses = await session.responses
            for await response in responses {
                await self?.handleSession(response)
            }
        }
    }

    /// The recording's half of one session response. Only the two §34A.4 rows
    /// touch a recording; everything else is deliberately ignored here (decks
    /// pause/renegotiate elsewhere, and an interruption never resumes playback).
    func handleSession(_ response: SessionPolicy.Response) async {
        guard isRecording else { return }
        switch response {
        case .flushSegmentAndCapturePlayheads:
            try? await engine.interruptRecordingForInterruption()
        case .resume:
            try? await engine.resumeRecordingFromInterruption()
        default:
            break
        }
    }

}
