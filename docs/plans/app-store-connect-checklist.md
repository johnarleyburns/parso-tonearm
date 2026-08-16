# App Store Connect — what must be configured before a TestFlight alpha

**This is the owner's list.** No agent can do any of it, and none of it is verifiable from the
repo: the app can only report what the App Store tells it, which is why the paywall now says
"Purchases aren't available right now" instead of showing an invented price (plan 6.2).

## 1 · The product

| Field | Value | Why |
|---|---|---|
| Product ID | `guru.parso.tonearm.pro` | The single DJ product (M4 decision 1 repurposed it in place). `ProEntitlement.productID`, `FoundersGrant.productID` and `Resources/Tonearm.storekit` all agree on this string; changing it strands every existing purchase. |
| Type | **Non-consumable** | One purchase, kept forever, restorable (FR-STORE-1/3). Not a subscription — the paywall says "not a subscription" in as many words. |
| Reference name | Platterhead DJ | Matches the `.storekit` file. |
| Family Sharing | **Enabled** | The paywall promises it ("Family Sharing included") and `FoundersGrant` has a `familyShared` grant path with its own test row (AT-STORE-4). Shipping with it off makes the sheet a lie. |
| Price | Owner's call — `DJ_PLATFORM_STRATEGY.md` §5.2 says $39.99, launch at $24.99 | **The app no longer hardcodes a price**; it displays whatever ASC returns, localised. Set it here and the app follows. |
| Availability | All storefronts you intend to test from | A tester in a storefront where the product is not sold gets the honest "not available" state, which is correct but confusing if unintended. |

The product must reach at least **"Ready to Submit"**. A product left in "Missing Metadata"
does not load, and the paywall will (correctly) show the unavailable state.

## 2 · TestFlight

- Sandbox purchases in TestFlight are **free** and do not charge the tester — but they still
  require the product to exist and be loadable. This is the failure this checklist exists to
  prevent.
- Add testers to an **internal** group first; internal builds skip Beta App Review.
- The build must carry an increment of `CFBundleVersion`; CI does this.

## 3 · What to check in the app once the build is installed

1. Open the **DJ** tab. The Purchase row says "Free tier · Not purchased".
2. Open the decks. The surface is dimmed with a lock chip — this is the designed free state
   (§40.4), not a bug.
3. Tap the lock chip. The sheet must show a **real, localised price** on the Buy button. If it
   says "Purchases aren't available right now", the product is not configured or not loadable —
   stop here, that is this checklist failing, not the app.
4. Buy. The decks must unlock **with no relaunch** (AT-STORE-2), and the Purchase row must read
   "Purchased".
5. Delete and reinstall the app, open the DJ tab, tap **Restore purchase**. It must return to
   "Purchased" without a receipt or a support ticket (FR-STORE-3). A restore that finds nothing
   now says so out loud rather than failing silently.
6. With a second Apple Account in the same family, confirm the row reads "Family Sharing".

## 4 · Local testing without App Store Connect

`Resources/Tonearm.storekit` carries the product for the simulator and for `swift test`. Xcode →
scheme → Options → StoreKit Configuration → `Tonearm.storekit`. This proves the *app's* flow; it
proves nothing about ASC, which is the whole point of §3 above.
