import SwiftUI
import TonearmCore

/// Pro unlock sheet. Presented ONLY from gated touchpoints —
/// never on launch, never interrupting playback.
struct ProPaywallView: View {
    var entryPoint: ProPaywallEntryPoint = .generic
    var onProCompletion: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ProPaywallModel()

    /// GPL "build Pro from source" link (Ground: Tonearm is GPL-3.0).
    private let repoURL = URL(string: "https://github.com/anomalyco/parso-tonearm")!

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("ONE-TIME · YOURS FOREVER")
                    .font(.system(size: 11, weight: .semibold)).kerning(2)
                    .foregroundStyle(Palette.brass)
                    .padding(.top, 22)
                Text("Remote Libraries")
                    .font(.system(size: 24, weight: .heavy))
                    .padding(.top, 8)
                Text("\(model.displayPrice) · no subscription, no account")
                    .font(.system(size: 14)).foregroundStyle(Palette.ink2)
                    .padding(.top, 2).padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.features) { feature in
                        featureRow(feature)
                    }
                }
                .padding(.horizontal, 4)

                Button {
                    Task {
                        let didBecomePro = await model.purchase()
                        await completeIfNeeded(didBecomePro)
                    }
                } label: {
                    Group {
                        if model.purchasing { ProgressView().tint(.black) }
                        else { Text(model.isPro ? "Purchased" : "Unlock Remote Libraries") }
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0x101214))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Palette.brass, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(model.purchasing || model.isPro)
                .padding(.top, 14)

                HStack(spacing: 4) {
                    Button("Restore Purchase") {
                        Task {
                            let didBecomePro = await model.restore()
                            await completeIfNeeded(didBecomePro)
                        }
                    }
                        .font(.system(size: 12))
                    Text("·").foregroundStyle(Palette.ink3)
                    Link("build Pro from source", destination: repoURL)
                        .font(.system(size: 12))
                }
                .tint(Palette.ink2)
                .padding(.top, 12)

                Text("Everything else is free, forever: FLAC · Opus · gapless · EQ · iCloud sync · parametric EQ · smart playlists · tag editor · duplicate detection · Archive libraries · zero telemetry.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 20).padding(.bottom, 28)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.libraryBackground.ignoresSafeArea())
        .task { model.refresh() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(Palette.ink3)
            }
            .padding(16)
        }
    }

    private func featureRow(_ feature: ProPaywallModel.Feature) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ok)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title).font(.system(size: 14, weight: .semibold))
                Text(feature.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func completeIfNeeded(_ didBecomePro: Bool) async {
        switch AddRemoteLibraryProFlow.presentationAfterProCompletion(
            entryPoint: entryPoint,
            didBecomePro: didBecomePro
        ) {
        case .showAddRemoteLibraryCompletion:
            onProCompletion?()
            dismiss()
        case .none:
            break
        }
    }
}
