import Combine
import Foundation
import TonearmCore

/// The §41.8 `PreparationModel` over the `TrackPrepRepositing` seam. Pro, except
/// the analysis readout (FR-PREP-4), which is what a free user sees here.
///
/// The grid tools — nudge, tap-to-set-downbeat, ×2 / ÷2, tempo tap, undo — are
/// gated at the intent boundary by `ProCapability.isEnabled(.preparation)`
/// (Appendix T.3): a free user sees the readout and the locked tools, never the
/// grid state machine. Every mutating call appends to the authoritative
/// override log through the repository and re-reads the snapshot; nothing is
/// edited in place (§23.3).
@MainActor
public final class TrackPrepModel: ObservableObject {

    public let repository: any TrackPrepRepositing
    private let store: EntitlementStore
    /// The §26A render-model seam (plan 5.3). `nil` (the default in tests and
    /// the honest "no analysis to draw" state) keeps the surface on its grid
    /// readout; the prep surface wires the real `WaveformRepository` so the
    /// analysis pyramid becomes the backdrop for the grid tools.
    private let waveformRepository: (any WaveformRendering)?
    public let trackID: Int64

    @Published public private(set) var snapshot: TrackPrepSnapshot?
    @Published public private(set) var waveform: WaveformRenderModel?
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?

    /// Hooks the presenter wires to real playback (mockup `ipad/06` Preview ·
    /// Load to Deck). The prep surface itself only edits the grid.
    public var onPreview: (() -> Void)?
    public var onLoadToDeck: ((TrackPrepSnapshot) -> Void)?

    /// The per-track tempo-tap estimator (FR-PREP-5 tempo tap): taps arrive at
    /// the playhead's sample positions and collapse to a BPM on the third tap.
    public private(set) var tempoTapper: TempoTapper

    public init(repository: any TrackPrepRepositing,
                store: EntitlementStore,
                trackID: Int64,
                sampleRate: Double = 48_000,
                waveformRepository: (any WaveformRendering)? = nil) {
        self.repository = repository
        self.store = store
        self.trackID = trackID
        self.waveformRepository = waveformRepository
        self.tempoTapper = TempoTapper(sampleRate: sampleRate)
    }

    /// The one gate for the grid tools (Appendix T.3). Free users see the
    /// analysis readout only — the tools render locked (§40.4).
    public var isPreparationEnabled: Bool {
        ProCapability.isEnabled(.preparation, store)
    }

    // MARK: - Data

    /// Load (or reload) the prep read model. The view calls this on appear and
    /// after every grid edit. Also loads the §26A render model (the analysis
    /// pyramid + composed grid the waveform draws) — a grid edit changes the
    /// composed beats, so both are refreshed together.
    public func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            snapshot = try await repository.snapshot(trackID: trackID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshWaveform()
    }

    /// Reload the §26A render model for this track. `nil` when the track is
    /// unanalysed or no repository is wired — the honest empty state.
    public func refreshWaveform() async {
        guard let waveformRepository else {
            waveform = nil
            return
        }
        do {
            waveform = try await waveformRepository.renderModel(trackID: trackID)
        } catch {
            waveform = nil
        }
    }

    // MARK: - Grid tools (FR-PREP-5, gated)

    /// Drag-to-nudge: shift the grid by `samples` (haptic detents per beat in
    /// the view). Appends a `.nudge` correction.
    public func nudge(bySamples: Int64) async {
        await apply(.nudge, valueInt: bySamples)
    }

    /// Tap-to-set-downbeat: make `sample` the grid's beat 0. Appends a
    /// `.setDownbeat` correction.
    public func setDownbeat(atSample: Int64) async {
        await apply(.setDownbeat, valueInt: atSample)
    }

    /// ×2 BPM — a button, never a menu (FR-PREP-5).
    public func doubleBPM() async {
        await apply(.doubleBPM)
    }

    /// ÷2 BPM — a button, never a menu (FR-PREP-5).
    public func halveBPM() async {
        await apply(.halveBPM)
    }

    /// Set an explicit BPM — the tempo tap's target.
    public func setBPM(_ bpm: Double) async {
        await apply(.setBPM, valueDouble: bpm)
    }

    /// Register one tempo-tap at the playhead's sample; once enough taps have
    /// landed the estimate is applied as a `.setBPM` correction and returned.
    /// `nil` before the estimator has its three taps.
    @discardableResult
    public func tempoTap(atSample: Int64) async -> Double? {
        guard isPreparationEnabled else {
            lastError = "Grid correction is a Pro capability"
            return nil
        }
        guard let estimate = tempoTapper.tap(at: atSample) else { return nil }
        await apply(.setBPM, valueDouble: estimate)
        return estimate
    }

    /// Drop the tempo-tap estimator's remembered taps (e.g. when the surface
    /// disappears — a fresh tap pattern next visit should not inherit one).
    public func resetTempoTap() {
        tempoTapper.reset()
    }

    /// Pop the newest correction — "undo" restores exactly the prior
    /// authoritative grid because the log replays over the detected grid.
    public func undoLast() async {
        guard isPreparationEnabled else {
            lastError = "Grid correction is a Pro capability"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.undoLast(trackID: trackID)
            tempoTapper.reset()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func apply(_ op: GridCorrectionOp,
                       valueDouble: Double? = nil,
                       valueInt: Int64? = nil) async {
        guard isPreparationEnabled else {
            lastError = "Grid correction is a Pro capability"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.apply(op, trackID: trackID,
                                       valueDouble: valueDouble,
                                       valueInt: valueInt)
            tempoTapper.reset()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The pure tempo-tap estimator (FR-PREP-5): consecutive taps at sample
/// positions collapse to a BPM via the **median** interval, so a mistimed tap
/// pulls less than a mean would. Pure and deterministic — no timers, no clock
/// reads, no SwiftUI — so the collapse math is testable off-device.
public struct TempoTapper: Equatable, Sendable {
    /// The sample positions of the last taps, newest last.
    private(set) public var taps: [Int64] = []
    /// The track's sample rate the taps are expressed in.
    public let sampleRate: Double
    /// The estimator keeps at most this many taps (4 taps → 3 intervals).
    public static let tapWindow = 4

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    public var tapCount: Int { taps.count }

    public mutating func reset() {
        taps.removeAll()
    }

    /// Register a tap at `sample`; returns a BPM estimate once the window holds
    /// at least three taps (two intervals), `nil` before that. The interval
    /// between successive taps is the beat period; the median period gives the
    /// tempo.
    @discardableResult
    public mutating func tap(at sample: Int64) -> Double? {
        if taps.count == Self.tapWindow {
            taps.removeFirst()
        }
        taps.append(sample)
        guard taps.count >= 3 else { return nil }
        let periods = zip(taps.dropFirst(), taps).map { Double($0 - $1) }
        let medianPeriod = Self.median(periods)
        guard medianPeriod > 1 else { return nil }
        let seconds = medianPeriod / max(sampleRate, 1)
        return 60 / seconds
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
