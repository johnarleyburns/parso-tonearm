import SwiftUI
import TonearmCore

/// Business decision (2026-09): Tonearm has no gated Pro features — see
/// `current_status.md`. This replaces the old Pro-purchase entry point with
/// the one purchase that remains: a purely optional, one-time contribution
/// that never unlocks anything, only sets the permanent Supporter flag the
/// home view's badge reads. It never imports StoreKit itself — that stays
/// behind `SupportDevelopmentStore` in `Sources/Pro/`.
struct SupportDevelopmentCard: View {
    @ObservedObject private var store = SupportDevelopmentStore.shared
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Contribute to Development").font(.system(size: 13, weight: .bold))
                Spacer()
                if store.isSupporter {
                    Label("Supporter", systemImage: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.brass)
                        .accessibilityIdentifier("settings.support.badge")
                }
            }

            Text("Everything here is free, forever. If you'd like to help fund development, "
                 + "this is a purely optional, one-time contribution — it doesn't unlock anything, "
                 + "it just marks your account as a supporter.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)

            if store.isSupporter {
                Text("Thank you for your support.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier("settings.support.thanks")
            } else {
                Button {
                    Task {
                        lastError = nil
                        let ok = await store.purchase()
                        if !ok {
                            lastError = "The contribution did not complete. Nothing was charged — please try again."
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchasing {
                            ProgressView().controlSize(.small)
                        }
                        Text(store.purchasing ? "Purchasing…" : "Contribute · \(store.displayPrice)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.purchasing || !store.isPurchaseAvailable)
                .accessibilityIdentifier("settings.support.buy")

                if let lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .task { await store.loadProduct() }
    }
}
