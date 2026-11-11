import SwiftUI
import TonearmCore

/// Tonearm's one optional purchase: a compact raised disclosure row matching
/// `../parso-voxglass`'s Support row. It never unlocks anything — a successful
/// contribution only sets the permanent Supporter flag the Listen badge reads.
/// It never imports StoreKit itself; that stays behind `SupportDevelopmentStore`.
struct SupportDevelopmentCard: View {
    @ObservedObject private var store = SupportDevelopmentStore.shared

    var body: some View {
        Button {
            Task { await activate() }
        } label: {
            SettingsRow(icon: "heart.fill", title: titleKey, detail: Text(detailText),
                        trailingIcon: nil)
        }
        .buttonStyle(.plain)
        .disabled(store.purchasing)
        .accessibilityIdentifier("settings.support")
        .task { await store.loadProduct() }
    }

    private var titleKey: LocalizedStringKey {
        store.isSupporter ? "Thanks for supporting Platterhead" : "Contribute to Development"
    }

    private var detailText: String {
        if store.isSupporter { return String(localized: "You have the Supporter badge") }
        if let message = store.purchaseErrorMessage { return message }
        if let reason = store.unavailableReason { return reason }
        return String(localized: "A one-time, optional \(store.displayPrice) — every feature is already free")
    }

    private func activate() async {
        guard !store.isSupporter, !store.purchasing else { return }
        if store.isPurchaseAvailable {
            await store.purchase()
        } else {
            await store.loadProduct()
        }
    }
}
