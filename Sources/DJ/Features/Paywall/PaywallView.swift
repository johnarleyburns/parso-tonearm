import SwiftUI

/// The §41.16 / §42.10 paywall sheet (mockups `ipad/13a`, `ipad/13b`,
/// `iphone/08`, plan 4.13) over `PaywallModel`. It consumes `isPro` and calls
/// `purchase()`/`restore()` — it **never imports StoreKit** (App. T.3, §6.3).
///
/// Copy rules per §40.4 + Appendix T.7: one-time price, "yours forever",
/// Family Sharing, the explicit "everything you have now stays free" line, the
/// GPLv3 build-it-yourself note, and a visible Restore button. Absent by
/// design: countdowns, strikethrough anchors, scarcity language, and any
/// framing of the free tier as a trial. The optional 10-minute trial
/// (FR-STORE-6) is **not** implemented in M4 (plan §2.10).
public struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var model: PaywallModel

    public init(model: PaywallModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                priceRow
                featureGrid
                freeTierPanel
                pillRow
                gplNote
                actionRow
            }
            .padding(24)
        }
        .background(Color(red: 0.043, green: 0.047, blue: 0.071).ignoresSafeArea())
        .foregroundStyle(Color.primary)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button {
                model.dismiss()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .interactiveDismissDisabled(model.isPurchasing)
        // Ask the store for the real, localised price when the sheet appears —
        // a user who launched offline still gets a true number here rather than
        // whatever the app last guessed.
        .task { await model.loadProduct() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ONE-TIME · YOURS FOREVER")
                .font(.system(size: 11, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.accentColor)
            Text("Turn your library into an instrument.")
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.6)
            Text("One purchase. Yours forever. Works on your iPhone, your iPad, and anything we ship next.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var priceRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text(model.displayPrice)
                .font(.system(size: 44, weight: .heavy, design: .default))
                .tracking(-1.6)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 5) {
                Text("One time · not a subscription")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.14), in: Capsule())
                Text("Family Sharing included · no account · no renewal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }

    private var featureGrid: some View {
        let features: [(String, String)] = [
            ("Two decks", "with sample-accurate beat sync, key lock and quantized triggering"),
            ("Full mixer", "— 3-band isolator EQ, filter sweep, crossfader, master limiter"),
            ("Stem separation", "— vocals, drums, bass and everything else, as independent faders"),
            ("Hot cues, loops and grid editing", ", synced between your devices"),
            ("Record your sets", " to M4A with the full tracklist, and export them anywhere"),
            ("USB-C controllers and MIDI-learn", ", with profiles for the popular ones already built in"),
            ("Split-cue monitoring", " so you can pre-listen with a $10 cable"),
            ("Apple Watch remote", " for recording and the next track"),
        ]
        let columns = sizeClass == .regular
            ? [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
            : [GridItem(.flexible(), alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(features.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.green)
                        .padding(.top, 1)
                    Text(verbatim: pair.0)
                        .font(.system(size: 13, weight: .semibold))
                    + Text(pair.1)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 16)
    }

    private var freeTierPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything you have now stays free.")
                        .font(.system(size: 13, weight: .bold))
                    Text("All ten remote libraries, vibe search, auto-playlists, every format, the EQ, the cache, iCloud sync — free, permanently, and a test in our CI fails the build if anyone ever tries to change that. We are not taking anything away to sell it back to you.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
        .padding(.bottom, 16)
    }

    private var pillRow: some View {
        let pills = ["No subscription, ever",
                     "Works offline forever once bought",
                     "No account, no telemetry",
                     "GPLv3 — build it yourself instead"]
        return FlowLayout(spacing: 8) {
            ForEach(pills, id: \.self) { pill in
                Text(pill)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.bottom, 16)
    }

    private var gplNote: some View {
        (Text("Platterhead is free software. If you'd rather not pay, clone the repository, delete the four-line entitlement check, and build it. We mean that — it's written into the architecture spec. Buying gets you the signed build, the updates, and our continued ability to do this. ")
            .foregroundStyle(.secondary)
         + Text("github.com/johnarleyburns/parso-tonearm")
            .foregroundStyle(Color.accentColor))
            .font(.system(size: 11))
            .lineSpacing(2)
            .padding(.bottom, 16)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            // The store could not answer: say so plainly instead of offering a
            // Buy button that cannot work. On a fresh TestFlight build whose
            // App Store Connect product is missing or unapproved, this is the
            // first thing a tester meets — and "Purchases aren't available"
            // sends them to us, while a failing Buy button sends them looking
            // for what they did wrong.
            if model.isStoreUnavailable {
                VStack(spacing: 6) {
                    Text("Purchases aren’t available right now")
                        .font(.system(size: 15, weight: .bold))
                    Text("The App Store didn’t offer this product on this device. "
                         + "Check your connection and try again — nothing has been charged.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityIdentifier("dj.paywall.unavailable")
            } else {
                Button {
                    Task { await model.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isPurchasing {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isPurchasing ? "Purchasing…"
                             : "Buy Platterhead DJ · \(model.displayPrice)")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPurchasing || !model.isPurchaseAvailable)
                .accessibilityIdentifier("dj.paywall.buy")
            }

            Button {
                Task { await model.restore() }
            } label: {
                Text(model.isRestoring ? "Restoring…" : "Restore purchase")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .disabled(model.isPurchasing || model.isRestoring)
            .accessibilityIdentifier("dj.paywall.restore")

            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }
}
