import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - Per-deck queues (§41.9c, FR-ENG-13; plan 5.1)

    /// A deck's current queue (its source + rows). Both decks stay independent:
    /// `selectQueue(_:for:)` touches only the named deck (FR-ENG-13).
    public func queue(for deck: Deck) -> DeckQueue {
        deck == .a ? queueA : queueB
    }

    public func importedCrate(for deck: Deck) -> DeckQueueSource? {
        deck == .a ? importedCrateA : importedCrateB
    }

    public func availableCratePlaylists() async -> [CratePlaylistSummary] {
        await crateImporter.availablePlaylists()
    }

    public func cratePlaylistTracks(_ id: Int64) async -> [CrateTrackSummary] {
        await crateImporter.tracks(in: id)
    }

    public func importCrate(playlistID: Int64, title: String,
                            into deck: Deck) async {
        isImportingCrate = true
        crateImportError = nil
        defer { isImportingCrate = false }
        do {
            let result = try await crateImporter.importCrate(playlistID: playlistID, title: title)
            if deck == .a { importedCrateA = result.source } else { importedCrateB = result.source }
            await selectQueue(result.source, for: deck)
            if result.skipped > 0 {
                crateImportError = "\(result.skipped) tracks are not on this device."
            }
        } catch {
            crateImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The deck's current load state — the crate rows render it.
    public func loadState(for deck: Deck) -> DeckLoadState {
        deck == .a ? loadStateA : loadStateB
    }

    /// The loaded track's title for a deck, resolved from its queue's rows
    /// (which carry the same `trackID` the load gesture used). `nil` until a
    /// track is loaded — the honest "nothing loaded" state, surfaced on the
    /// surface's accessibility tree as `dj.deck.<a|b>.loaded`.
    public func loadedTrackTitle(for deck: Deck) -> String? {
        guard let id = loadedTrackIDs[deck] else { return nil }
        return queue(for: deck).rows.first { $0.trackID == id }?.title
    }

    /// Refresh the selectable queues and re-read each deck's current queue's
    /// rows. Called when the workspace's browse surface appears (and when a new
    /// playlist is saved). Never changes what is loaded or playing.
    public func refreshDeckQueues() async {
        availableQueues = (try? await library.availableQueues()) ?? []
        await reloadQueue(for: .a)
        await reloadQueue(for: .b)
    }

    /// Point one deck at a source. **The other deck is untouched** — setting
    /// deck A's queue never changes deck B's (FR-ENG-13), and neither queue ever
    /// advances on its own (there is no auto-play-next on a deck, §41.9c).
    public func selectQueue(_ source: DeckQueueSource, for deck: Deck) async {
        let rows = (try? await library.rows(in: source)) ?? []
        switch deck {
        case .a: queueA = DeckQueue(source: source, rows: rows)
        case .b: queueB = DeckQueue(source: source, rows: rows)
        }
    }

    /// The one gesture that loads a library track to a deck (FR-ENG-13,
    /// §41.9c): resolve → FR-LIB-8 gate → decode off the main actor → hand the
    /// `DeckSource` to the engine, keeping the §12.2 box alive. The engine is
    /// touched **only** on a successful load. After the full mix is armed, the
    /// deck's stems are resolved (§36.5): a prepared set is armed and the
    /// faders go live; otherwise the deck plays the full mix with the honest
    /// `unavailable` status.
    public func load(_ deck: Deck, trackID: Int64) async {
        setLoadState(.loading(trackID: trackID), for: deck)
        switch await library.load(trackID: trackID) {
        case .loaded(let box):
            engine.load(deck, source: box.source)
            sourceBoxes[deck] = box
            loadedTrackIDs[deck] = trackID
            setLoadState(.loaded(trackID: trackID), for: deck)
            rebuildWaveform(for: deck)
            await resolveStems(for: deck, trackID: trackID, grid: box.source.grid)
        case .refused(let readiness):
            let reason = Self.unavailableReason(readiness)
            setLoadState(.refused(trackID: trackID, reason: reason), for: deck)
        case .failed(let failure):
            setLoadState(.failed(trackID: trackID, message: failure.message), for: deck)
        }
    }

    /// Load a crate selection and immediately put it on air. The browse
    /// surface is the field-test user's track selection gesture; leaving the
    /// deck merely armed made the UI appear inert and required a second,
    /// hidden transport action before any music could be heard.
    public func loadAndPlay(_ deck: Deck, trackID: Int64) async {
        await load(deck, trackID: trackID)
        guard case .loaded = loadState(for: deck) else { return }
        play(deck)
    }

    // MARK: - Per-deck stems (§36.5, §35.1; plan 5.8)

    /// The deck's stem status — `prepared` makes the STEMS faders live.
    public func stemStatus(_ deck: Deck) -> DeckStemStatus {
        deck == .a ? stemStatusA : stemStatusB
    }

    /// A stem voice's gain target (0…1.5, unity default).
    public func stemGain(_ deck: Deck, stem: SeparationVoice) -> Float {
        controls(deck).gains[stem] ?? 1
    }

    /// Whether a stem voice is muted.
    public func stemIsMuted(_ deck: Deck, stem: SeparationVoice) -> Bool {
        controls(deck).muted.contains(stem)
    }

    /// Whether a stem voice is soloed.
    public func stemIsSoloed(_ deck: Deck, stem: SeparationVoice) -> Bool {
        controls(deck).soloed.contains(stem)
    }

    /// Move a stem voice's gain fader (0…1.5). Forwarded — and mirrored — only
    /// when the deck's stems are prepared: an unprepared fader is **fully
    /// inert**, because a fader that moves while doing nothing is §36.5's exact
    /// prohibition ("never a fader that looks live and does nothing").
    public func setStemGain(_ deck: Deck, stem: SeparationVoice, gain: Float) {
        guard stemStatus(deck) == .prepared else { return }
        let clamped = min(StemControlState.maxGain, max(0, gain))
        let previous = controls(deck).gains[stem] ?? 0
        setControls(deck) { $0.gains[stem] = clamped }
        engine.setStemGain(deck, stem: stem, gain: clamped)
        resetMidiPickup(for: .stemGain(deck: midiDeckID(deck), stem: stem))
        // S8: the DJ stem lane's journal mark — a fader pulled to the floor
        // while recording is the gesture the host analyzer measures
        // (`stem.fader`, §53.9 settled-state band check). Fires once, on the
        // downward crossing, so a drag sends exactly one mark.
        if isRecording, previous > 0.1, clamped <= 0.1 {
            recordTransition(RecordingJournalEvent(kind: "stem.fader",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck),
                                                   stem: stem.rawValue))
        }
    }

    /// Mute a stem voice — its gain target ramps to 0. Inert unless prepared
    /// (§36.5's honest-fader rule).
    public func setStemMute(_ deck: Deck, stem: SeparationVoice, muted: Bool) {
        guard stemStatus(deck) == .prepared else { return }
        setControls(deck) {
            if muted { $0.muted.insert(stem) } else { $0.muted.remove(stem) }
        }
        engine.setStemMute(deck, stem: stem, muted: muted)
    }

    /// Solo a stem voice — when any voice is soloed, only soloed voices sound.
    /// Inert unless prepared.
    public func setStemSolo(_ deck: Deck, stem: SeparationVoice, soloed: Bool) {
        guard stemStatus(deck) == .prepared else { return }
        setControls(deck) {
            if soloed { $0.soloed.insert(stem) } else { $0.soloed.remove(stem) }
        }
        engine.setStemSolo(deck, stem: stem, soloed: soloed)
    }

    /// The deck's stem control state (the mirrored gain/mute/solo state).
    private func controls(_ deck: Deck) -> StemControlState {
        deck == .a ? stemControlsA : stemControlsB
    }

    /// Reassign a deck's control state through a mutation, publishing the new
    /// value so the faders follow.
    private func setControls(_ deck: Deck,
                             _ mutate: (inout StemControlState) -> Void) {
        var state = controls(deck)
        mutate(&state)
        switch deck {
        case .a: stemControlsA = state
        case .b: stemControlsB = state
        }
    }

    /// Resolve a just-loaded deck's stems (§36.5): a cached, version-matched
    /// set is armed and the status goes `prepared`; otherwise the deck plays
    /// the full mix with the honest `unavailable` status. The engine is armed
    /// or disarmed exactly once per load.
    private func resolveStems(for deck: Deck, trackID: Int64,
                              grid: DeckGrid) async {
        setStemStatus(.unavailable, for: deck)
        engine.armStemSet(deck, stemSet: nil)
        stemSetBoxes[deck] = nil
        setControls(deck) { state in
            state = StemControlState()
        }
        guard let prepared = try? await stemProvider.preparedStems(trackID: trackID, grid: grid)
        else {
            return // honest unavailable → full mix, faders disabled
        }
        engine.armStemSet(deck, stemSet: prepared.stemSet)
        stemSetBoxes[deck] = prepared
        setStemStatus(.prepared, for: deck)
    }

    /// Report that a separation job for the deck's loaded track has started
    /// (driven by the §36.3 service in 5.9). The faders stay disabled — the
    /// honest `separating` status renders until the set is prepared and armed.
    public func markStemSeparation(_ deck: Deck) {
        setStemStatus(.separating, for: deck)
    }

    private func setStemStatus(_ status: DeckStemStatus, for deck: Deck) {
        switch deck {
        case .a: stemStatusA = status
        case .b: stemStatusB = status
        }
    }

    // MARK: - Per-deck waveform render models (§26A, plan 5.3)

    /// A deck's §26A render model — `nil` until it loads an analysed track, or
    /// for an unanalysed track (the honest empty state). The views draw from
    /// this and take the live playhead from telemetry.
    public func waveform(for deck: Deck) -> WaveformRenderModel? {
        deck == .a ? waveformA : waveformB
    }

    /// Whether a deck currently has a track loaded (drives the waveform's
    /// empty-state wording — "not analysed" vs "load a track").
    public func hasLoadedTrack(_ deck: Deck) -> Bool {
        loadedTrackIDs[deck] != nil
    }

    /// Rebuild every loaded deck's render model — on a load, and on a §26A.7
    /// thermal crossing. Runs off the main actor and publishes back.
    func rebuildAllWaveforms() {
        rebuildWaveform(for: .a)
        rebuildWaveform(for: .b)
    }

    private func rebuildWaveform(for deck: Deck) {
        guard let trackID = loadedTrackIDs[deck] else {
            setWaveform(nil, for: deck)
            return
        }
        let repository = waveformRepository
        Task.detached { [weak self] in
            let model = try? await repository.renderModel(trackID: trackID)
            await self?.publishWaveform(model, for: deck)
        }
    }

    @MainActor
    private func publishWaveform(_ model: WaveformRenderModel?, for deck: Deck) {
        lastWaveformThermal = WaveformThermal.current
        setWaveform(model, for: deck)
    }

    private func setWaveform(_ model: WaveformRenderModel?, for deck: Deck) {
        switch deck {
        case .a: waveformA = model
        case .b: waveformB = model
        }
    }

    private func reloadQueue(for deck: Deck) async {
        let current = queue(for: deck)
        let rows = (try? await library.rows(in: current.source)) ?? []
        switch deck {
        case .a: queueA = DeckQueue(source: current.source, rows: rows)
        case .b: queueB = DeckQueue(source: current.source, rows: rows)
        }
    }

    private func setLoadState(_ state: DeckLoadState, for deck: Deck) {
        switch deck {
        case .a: loadStateA = state
        case .b: loadStateB = state
        }
    }

    /// The user-facing wording for a refused load (FR-LIB-8) — the crate rows
    /// and the workspace readout share it.
    public static func unavailableReason(_ readiness: DeckReadiness) -> String {
        switch readiness {
        case .ready: return "Ready"
        case .unavailable(let reason): return reason
        }
    }
}
