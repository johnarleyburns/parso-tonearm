# App Store Connect — what must be configured before a TestFlight alpha

**This is the owner's list.** No agent can do any of it, and none of it is verifiable from the
repo: the app can only report what the App Store tells it.

## 1 · The product

There is no paywall and no gated Pro feature — business decision, 2026-09 (`SupportDevelopmentStore.swift`).
Everything in the app, including the DJ decks, is free. The only purchase is a purely optional,
one-time contribution that unlocks nothing.

| Field | Value | Why |
|---|---|---|
| Product ID | `guru.parso.tonearm.support.dev` | `SupportDevelopmentStore.productID` and `Resources/Tonearm.storekit` both agree on this string; changing it strands every existing supporter flag. |
| Type | **Consumable** | A one-time contribution, not an unlock — consumables never appear in `Transaction.currentEntitlements`, so the app persists its own `isSupporter` flag locally instead of re-deriving it from StoreKit. |
| Reference name | Contribute to Development | Matches the `.storekit` file. |
| Family Sharing | **Off** | It unlocks nothing, so there's nothing to share. |
| Price | Owner's call | The app never hardcodes a price — it displays whatever ASC returns, localised. |
| Availability | All storefronts you intend to test from | A tester in a storefront where the product is not sold sees the honest "not available" state. |

The product must reach at least **"Ready to Submit"**. A product left in "Missing Metadata"
does not load, and the purchase button will (correctly) show the unavailable state.

## 2 · TestFlight

- Sandbox purchases in TestFlight are **free** and do not charge the tester — but they still
  require the product to exist and be loadable.
- Add testers to an **internal** group first; internal builds skip Beta App Review.
- The build must carry an increment of `CFBundleVersion`; CI does this.

## 3 · What to check in the app once the build is installed

1. Open Settings → Support Development. It must show a **real, localised price** on the
   Contribute button. If it says the purchase isn't available, the product is not configured or
   not loadable — stop here, that is this checklist failing, not the app.
2. Contribute. The Supporter badge must appear immediately, with no relaunch.
3. Delete and reinstall the app. The Supporter badge must **not** reappear on its own — a
   consumable never restores, and the app never claims otherwise (§ above).

## 4 · Local testing without App Store Connect

`Resources/Tonearm.storekit` carries the product for the simulator and for `swift test`. Xcode →
scheme → Options → StoreKit Configuration → `Tonearm.storekit`. This proves the *app's* flow; it
proves nothing about ASC, which is the whole point of §3 above.

## 5 · Privacy manifest / usage descriptions

`Resources/PrivacyInfo.xcprivacy` declares the required-reason API categories the app actually
uses (UserDefaults, file timestamps, disk space) — Apple has rejected uploads missing this
since 2024. If a future change adds a new required-reason API (check Apple's current list),
update this file in the same change, not as a follow-up.

## 6 · macOS platform

Adding macOS to this same App Store Connect app record (not a second listing) needs its own
screenshots at Mac-required resolutions and its own privacy-label pass — see the session notes
in `docs/plans/native-mac-app-plan.md` §4 for the Universal Purchase mechanics.
