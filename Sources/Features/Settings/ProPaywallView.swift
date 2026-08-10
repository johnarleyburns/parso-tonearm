import SwiftUI
import TonearmCore

/// Pro unlock sheet. M0 retires the only purchasable feature (remote
/// libraries); nothing is paid yet, so this view is no longer presented from
/// any touchpoint. It stays in the target so the StoreKit boundary
/// (`ProStore` + this view) survives for the next milestone, which introduces
/// `EntitlementStore` and the DJ capability (Appendix T.2–T.4).
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ProPaywallModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("ONE-TIME · YOURS FOREVER")
                    .font(.system(size: 11, weight: .semibold)).kerning(2)
                    .foregroundStyle(Palette.brass)
                    .padding(.top, 22)
                Text("Platterhead Pro")
                    .font(.system(size: 24, weight: .heavy))
                    .padding(.top, 8)
                Text("Platterhead DJ is coming. Decks, mixing, stems, recording and hardware.")
                    .font(.system(size: 14)).foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2).padding(.bottom, 16)

                Button {
                    Task { await model.restore() }
                } label: {
                    Text("Restore Purchase")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity).frame(height: 52)
                }
                .padding(.top, 12)

                Text("Everything in the free tier is free, forever: all formats · gapless · EQ · iCloud sync · smart playlists · tag editor · duplicate detection · all 10 remote-library providers · zero telemetry.")
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
}
