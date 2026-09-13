import Combine
import CoreGraphics
import Foundation
import TonearmCore

/// Engine start/stop, the telemetry consumption loop, and the §34A.5 liveness
/// watchdog's response to a stopped graph. Split out of `WorkspaceModel.swift`
/// (a pure reorganization, same convention as the other
/// `WorkspaceModel+*.swift` files) — this is the model's engine-lifecycle
/// surface: `begin()`/`end()` bookend the session, `apply(_:)` is the one
/// telemetry sample handler, and the liveness/recovery methods are its
/// downstream reaction to the graph dying (NFR-REL-2).
extension WorkspaceModel {

    /// Start the engine, the display-rate pump, and the telemetry subscription.
    /// The view calls this on appear and `end()` on disappear. Also consumes the
    /// §34A.4 session responses (the recording flush/new-segment path) and
    /// reconciles any crashed recordings (plan 5.11).
    public func begin() throws {
        try engine.start()
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            guard let self else { return }
            for await value in engine.telemetry {
                self.apply(value)
            }
        }
        pump?.start()
        startConsumingSessionResponses()
        startObservingConfigurationChanges()
        Task { [weak self] in
            await self?.reconcileRecordings()
        }
    }

    /// `AVAudioEngineConfigurationChange` (§34A.5) — the fast path to the same
    /// honest state the stall detector reaches on its own, arriving with a
    /// reason attached instead of two seconds later without one.
    private func startObservingConfigurationChanges() {
        configurationChangeTask?.cancel()
        configurationChangeTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.engine.configurationChanges() {
                // AVAudioEngine posts this *after* stopping itself. If it is
                // somehow still running, the graph absorbed the change and
                // there is nothing to report — saying otherwise would train the
                // user to ignore the banner.
                guard !self.engine.isGraphRunning else { continue }
                self.liveness.report(.configurationChange)
                if self.engineStopped == nil {
                    self.handleEngineStopped(.configurationChange)
                }
            }
        }
    }

    public func end() {
        telemetryTask?.cancel()
        telemetryTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        midiTask?.cancel()
        midiTask = nil
        drawerIdleTask?.cancel()
        drawerIdleTask = nil
        pump?.stop()
        engine.stop()
        IdleTimerScope.update(anyDeckPlaying: false)
    }

    /// Drive one telemetry sample now (the pump does this at display cadence;
    /// the offline harness calls it directly). §40.3.
    public func pumpTelemetryNow() {
        engine.pushTelemetry()
    }

    public func setPumpPaused(_ paused: Bool) {
        pump?.setPaused(paused)
    }

    /// Fold the telemetry sample into the liveness watchdog (NFR-REL-2).
    ///
    /// Runs on every sample, before anything else reads the telemetry, because
    /// the state it produces changes what the rest of `apply` is allowed to
    /// claim — most of all the recording timer.
    private func observeLiveness(_ value: EngineTelemetry, now: Date = Date()) {
        let playing = value.deckA.playing || value.deckB.playing
        let state = liveness.observe(masterSample: value.masterSample,
                                     anyDeckPlaying: playing,
                                     isRunning: engine.isGraphRunning,
                                     now: now)
        switch state {
        case .live:
            return
        case .stopped(let reason):
            guard engineStopped == nil else { return }
            handleEngineStopped(reason)
        }
    }

    /// The graph stopped. Tell the truth, then save what can be saved.
    ///
    /// Order matters: the flags that make the UI stop lying are set *first* and
    /// synchronously, so there is no window in which the timer keeps running
    /// while an async finalize is in flight. Only then does the recording get
    /// closed out — and it is closed out rather than abandoned, because the
    /// encoder's flushed segments are a real recording (NFR-REL-2) and the user
    /// should get the twenty minutes that did happen instead of nothing.
    private func handleEngineStopped(_ reason: EngineLiveness.StopReason) {
        engineStopped = reason
        let wasRecording = isRecording
        if wasRecording {
            engineStopRecordingOutcome = "Saving what was recorded up to that point…"
            Task { [weak self] in
                guard let self else { return }
                await self.finalizeRecordingAfterEngineStop()
            }
        }
        IdleTimerScope.update(anyDeckPlaying: false)
    }

    /// Close out a recording whose engine died under it. The audio already on
    /// disk is the guarantee §37.3 was built around, so this is the ordinary
    /// stop path — not a special case — and its failure is reported rather than
    /// swallowed.
    private func finalizeRecordingAfterEngineStop() async {
        await stopRecording()
        // `stopRecording` publishes the finished mix when the join and the
        // journal both succeeded. When it did not, the flushed segments are
        // still on disk and §37.3's `reconcile()` salvages them on next
        // appear — so the honest message is "recovered later", never "lost".
        engineStopRecordingOutcome = finishedMix == nil
            ? "The recording could not be finalised now — Recorded Mixes will recover it."
            : "The recording was saved up to the moment the engine stopped."
    }

    /// Try to bring the graph back (§34A.5). Never automatic: a set that
    /// restarts itself mid-transition is worse than one that waits to be told,
    /// and the human is standing right there.
    public func recoverEngine() async {
        guard !isRecoveringEngine else { return }
        isRecoveringEngine = true
        defer { isRecoveringEngine = false }
        do {
            try engine.recoverGraph()
            liveness.recovered()
            engineStopped = nil
            engineStopRecordingOutcome = nil
        } catch {
            engineStopRecordingOutcome =
                "The engine could not be restarted (\(error.localizedDescription)). "
                + "Leave the decks and come back to rebuild the audio graph."
        }
    }

    private func apply(_ value: EngineTelemetry) {
        telemetry = value
        observeLiveness(value)
        // A stopped graph renders nothing, so nothing below this line is true
        // of it: the elapsed timer would run on a stale clock and the timeline
        // would log track starts that never sounded.
        if engineStopped != nil { return }
        if isRecording {
            // Decision 14's elapsed chip: the recorded frames are exactly the
            // master-clock frames captured by the tap (§37.2), so elapsed is
            // `(masterSample − start) / sampleRate`.
            recordingElapsed = Double(value.masterSample - recordingStartSample) / engine.sampleRate
            // §37.4 (plan 5.12): a deck's not-playing → playing edge is a
            // track start — log it for the mix's timeline.
            if value.deckA.playing && !wasDeckAPlaying {
                recordTimelineEvent(for: .a)
            }
            if value.deckB.playing && !wasDeckBPlaying {
                recordTimelineEvent(for: .b)
            }
        }
        wasDeckAPlaying = value.deckA.playing
        wasDeckBPlaying = value.deckB.playing
        let playing = value.deckA.playing || value.deckB.playing
        if playing != anyDeckPlaying {
            anyDeckPlaying = playing
            IdleTimerScope.update(anyDeckPlaying: playing)
        }
        // §26A.7: the waveform detail is one pyramid level coarser at
        // `.serious`. Rebuild a deck's render model when the thermal state
        // crosses the shed line (rare; the build runs off the main actor).
        let thermal = WaveformThermal.current
        if thermal != lastWaveformThermal {
            lastWaveformThermal = thermal
            rebuildAllWaveforms()
        }
    }

    /// Log "the deck started playing its loaded track" into the §37.4 timeline
    /// (plan 5.12). The offset is the recording's own frames (§37.2).
    private func recordTimelineEvent(for deck: Deck) {
        guard let trackID = loadedTrackIDs[deck] else { return }
        recordingTimeline.record(trackID: trackID,
                                 deck: deck == .a ? "A" : "B",
                                 startOffsetSec: recordingElapsed)
    }
}
