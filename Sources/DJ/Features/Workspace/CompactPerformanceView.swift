import SwiftUI

// MARK: - Orientation switch

/// The iPhone performance surface (§42.1): **orientation is the mode switch**.
/// Portrait renders the solo-deck `SoloDeckView`, landscape the twin-deck
/// `TwinDeckView` — both over the **one** `WorkspaceModel` and the one live
/// engine. Rotating mid-playback is a view change only: the container owns the
/// engine lifecycle (begin/end, scene-phase pump pausing, deferred system
/// gestures), so a rotation never stop/starts the engine and changes no engine
/// state (FR-ENG-10, AT-TWIN-1).
///
/// There is no toggle, no setting and no button — the surface follows the
/// device orientation, mapping `verticalSizeClass` (`.compact` = landscape =
/// twin, `.regular` = portrait = solo) onto the model's view-only
/// `compactPosture`.
public struct CompactPerformanceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// The review-listen sheet (FR-REC-6, plan 5.12) — presented the moment a
    /// recording finalises, exactly as on the iPad workspace.
    @State private var finishMix: DJMix?
    /// The §41.18 transition coach (plan 5.13, FR-TRANS-6) — free, so its entry
    /// sits outside the Pro gate and is reachable before purchase; when open it
    /// lights the real controls the selected lesson moves.
    @StateObject private var coach = TransitionCoachModel()

    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            switch model.compactPosture {
            case .solo:
                SoloDeckView(model: model, managesLifecycle: false)
            case .twin:
                TwinDeckView(model: model, managesLifecycle: false)
            }
        }
        .overlay {
            // The §41.18 coach — a free "Transitions" pill on both compact
            // postures; opening it floats the dismissible panel over the
            // still-playing surface.
            TransitionCoachAccessory(model: coach)
        }
        .environment(\.coachHighlights,
                      coach.isPresented ? coach.highlightedIdentifiers : [])
        .preferredColorScheme(.dark)
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear {
            applyPosture()
            try? model.begin()
        }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            model.setPumpPaused(phase != .active)
        }
        .onChange(of: verticalSizeClass) { _, _ in
            applyPosture()
        }
        .onChange(of: model.finishedMix) { _, mix in
            if let mix { finishMix = mix }
        }
        .sheet(item: $finishMix) { mix in
            RecordingFinishView(mix: mix)
                .onDisappear { model.dismissFinishedMix() }
        }
    }

    /// Portrait (`.regular` vertical size class) is the solo-deck posture,
    /// landscape (`.compact`) the twin-deck one (§42.1).
    private func applyPosture() {
        let posture: WorkspaceModel.CompactPosture =
            verticalSizeClass == .compact ? .twin : .solo
        if model.compactPosture != posture {
            model.setPosture(posture)
        }
    }
}
