import SwiftUI

/// The iPad DJ workspace (mockup `ipad/07-dj-workspace.html`, §41.9b) over the
/// single session `WorkspaceModel` (plan 4.6). The §41.9b arrangement is the
/// club-standard one: the two decks' waveforms stack on one shared playhead at
/// the top (§26A.5), and below them each deck column carries the performance
/// controls in their club positions — jog centred with the **tempo fader on the
/// outer edge** (rule 4), **eight pads** under their mode selector (rule 5),
/// and **CUE left of PLAY** at the deck's inner base (rule 3). The centre mixer
/// column is the **per-channel strip** pair (rule 1: TRIM → HI → MID → LOW →
/// FILTER above a vertical channel fader and a CUE button) with the crossfader
/// horizontal and bottom-centre (rule 2).
///
/// The gate is `WorkspaceModel.isDecksEnabled` (App. T.3): free users see the
/// real surface dimmed to ~35%, controls inert, with a single lock chip —
/// nothing is blurred, nothing is hidden (§40.4, §41.15). The bottom system
/// gesture is deferred so the crossfader surface stays reachable
/// (§42.7b). Screen auto-lock scoping (§34A.6) is applied by the model from
/// telemetry, never from a view's lifetime.
///
/// Accessibility identifiers follow §53.11 (`dj.deck.<a|b>.<play|cue|filter|
/// fader>`, `dj.deck.<a|b>.eq.<low|mid|high>`, `dj.mixer.crossfader`,
/// `dj.fx.echo`, `dj.master.bar`) — part of each control's contract, not test
/// scaffolding (plan decision 27).
public struct WorkspaceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase

    /// The contextual paywall sheet (mockup `ipad/13b`, plan 4.13) — presented
    /// only when the user taps the lock chip (FR-STORE-5, §40.4).
    @State private var showingPaywall = false
    /// The review-listen sheet (FR-REC-6, plan 5.12): presented the moment a
    /// recording finalises (`model.finishedMix`), cleared on dismiss.
    @State private var finishMix: DJMix?
    /// The §41.18 transition coach (plan 5.13, FR-TRANS-6) — **free tier**, so
    /// its entry sits outside the Pro gate's dimmed surface and is reachable
    /// before purchase. When open, the workspace lights the real controls the
    /// selected lesson moves (§41.18).
    @StateObject private var coach = TransitionCoachModel()

    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            if model.isDecksEnabled {
                workspace
            } else {
                ZStack(alignment: .topTrailing) {
                    workspace
                        .opacity(0.35)
                        .allowsHitTesting(false)
                    Button {
                        showingPaywall = true
                    } label: {
                        lockChip
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
        .overlay {
            // The §41.18 coach: a free, always-tappable "Transitions" pill and,
            // when open, the dismissible panel over the still-playing surface.
            TransitionCoachAccessory(model: coach)
        }
        .overlay(alignment: .topTrailing) {
            // The M2 soft-takeover catch indicator: which MIDI control needs
            // moving, and which way (plan dj-midi-alpha M2).
            MidiCatchIndicator(model: model)
                .padding(.top, 56).padding(.trailing, 12)
        }
        // NFR-REL-2: a stopped graph makes every readout below false at once.
        .engineStoppedBanner(model)
        .environment(\.coachHighlights,
                      coach.isPresented ? coach.highlightedIdentifiers : [])
        .preferredColorScheme(.dark)
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear { try? model.begin() }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            model.setPumpPaused(phase != .active)
        }
        .onChange(of: model.finishedMix) { _, mix in
            if let mix { finishMix = mix }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(model: PaywallModel(store: model.store))
        }
        .sheet(item: $finishMix) { mix in
            RecordingFinishView(mix: mix)
                .onDisappear { model.dismissFinishedMix() }
        }
    }

    private var workspace: some View {
        VStack(spacing: WorkspaceModel.ModuleGeometry.columnGap) {
            WaveformRegion(model: model)
            HStack(spacing: WorkspaceModel.ModuleGeometry.columnGap) {
                DeckColumnView(model: model, deck: .a, isMaster: true) { intent in
                    model.jogTransport(for: .a).route(intent)
                }
                MixerColumnView(model: model)
                DeckColumnView(model: model, deck: .b, isMaster: false) { intent in
                    model.jogTransport(for: .b).route(intent)
                }
            }
        }
        .padding(WorkspaceModel.ModuleGeometry.outerPadding)
    }

    private var lockChip: some View {
        Label("Platterhead DJ · one-time", systemImage: "lock.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            // §53.11: present exactly when the surface is gated — so a run
            // that lost its entitlement fails as "the decks are locked"
            // rather than as a hundred gestures landing on an inert view.
            .accessibilityIdentifier("dj.paywall.lock")
    }
}
