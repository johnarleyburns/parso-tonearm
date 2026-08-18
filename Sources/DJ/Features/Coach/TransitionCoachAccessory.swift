import SwiftUI

/// The §41.18 coach's entry + overlay, added to every performance surface
/// (the iPad workspace and the compact solo/twin postures). When closed it is
/// a single always-tappable "Transitions" pill — **free tier**, so it sits
/// outside the Pro gate's dimmed, non-interactive surface and is reachable
/// before purchase (FR-TRANS-6). When opened it dims the surface (the decks
/// keep playing underneath — the §42.7b drawer discipline) and floats the
/// `TransitionCoachView` panel, while the surface lights the real controls in
/// `highlightedIdentifiers` (§41.18's "highlighted in place").
///
/// The host sets `.environment(\.coachHighlights, …)` from the model so the
/// shared controls draw their glow — this view owns only the entry and the
/// panel.
public struct TransitionCoachAccessory: View {
    @ObservedObject var model: TransitionCoachModel

    public init(model: TransitionCoachModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.isPresented {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismiss() }
                    .transition(.opacity)

                TransitionCoachView(model: model)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                entryButton
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isPresented)
    }

    /// The always-tappable entry: a compact "Transitions" pill at the top
    /// centre of the surface. Carries the `dj.coach` identifier (the §53.11
    /// contract — VoiceOver and the regression suite can both find it).
    private var entryButton: some View {
        Button {
            model.present()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.4), radius: 4)
        .padding(.top, 6).padding(.trailing, 10)
        .accessibilityLabel("Transitions")
        .accessibilityIdentifier("dj.coach")
        .transition(.opacity)
    }
}
