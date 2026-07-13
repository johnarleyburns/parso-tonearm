# 05 — Pro IAP + iCloud Sync Setup Plan

Status: READY TO IMPLEMENT · Companion to `04-tonearm-implementation-plan.md`
(which shipped the Pro entitlement, gates, Opus, and EQ in code).

This document covers the **operational setup** (App Store Connect, Developer
portal, signing) for the Pro in-app purchase and the **new iCloud sync feature**
added to the Pro tier.

## Facts (verified against this repo, 2026-07-12)

- Bundle ID: `guru.parso.tonearm` · Product name: *Platterhead* · Team: `3264Y8YUGV`
- Pro product ID: `guru.parso.tonearm.pro` (`Sources/Pro/ProEntitlement.swift:21`),
  **non-consumable**, one-time **$9.99** (D5; `Resources/Tonearm.storekit`).
- StoreKit code already wired: `ProStore` (purchase/restore/observe),
  `ProEntitlement` (private-init, verified-only), `ProFeature` gates.
- Data layer: **GRDB SQLite** at `Application Support/Tonearm/library.sqlite`
  (`Sources/Data/LibraryStore.swift`), 11 tables (`Sources/Data/Schema.swift`,
  currently at migration `v6`). Custom artwork = image files in
  `Application Support/Tonearm/Artwork`. Local files referenced by
  **device-specific security-scoped bookmarks** (`Sources/Data/BookmarkVault.swift`).
- No existing CloudKit/ubiquity scaffolding.
- Release signing is **Manual** with profile `Parso Platterhead App Store`
  (`project.yml:69-71`, `ExportOptions.plist`), imported in CI from secret
  `PROVISIONING_PROFILE_BASE64` (`.github/workflows/ios.yml:158-165`).

## Verified provisioning profile

Adopt `~/Downloads/Parso_Platterhead_App_Store-4.mobileprovision`. Inspected and
confirmed complete:

| Field | Value | Status |
|---|---|---|
| Name | `Parso Platterhead App Store` | ✅ matches repo specifier (no rename needed) |
| App ID | `3264Y8YUGV.guru.parso.tonearm` | ✅ correct bundle ID |
| Team | `3264Y8YUGV` | ✅ |
| iCloud container | `iCloud.guru.parso.tonearm` | ✅ matches bundle ID |
| iCloud environments | `Production` + `Development` | ✅ |
| iCloud services | `*` (CloudKit) | ✅ |
| APNs | `aps-environment = production` | ✅ Push present (CKSyncEngine change delivery) |
| Distribution | `get-task-allow=false`, no devices, `beta-reports-active=true` | ✅ App Store/TestFlight |
| Expiry | 2027-05-06 | ✅ |

**Container name locked in:** `iCloud.guru.parso.tonearm` everywhere.

---

## Part A — App Store Connect: Pro purchase

The code is already wired; `Resources/Tonearm.storekit` is **local-testing only**.
The real product must be created server-side with a matching product ID.

**A1. Prerequisites (account level).**
- App Store Connect → **Business**: sign the **Paid Applications Agreement** and
  complete tax/banking. IAPs will not load (`Product.products` returns empty)
  until this is active.
- Confirm the app record exists for bundle `guru.parso.tonearm`; create it if not.

**A2. Create the In-App Purchase.**
- ASC → app → **Monetization → In-App Purchases → +**
  - Type: **Non-Consumable**
  - Reference Name: `Tonearm Pro`
  - Product ID: `guru.parso.tonearm.pro` (must match `ProEntitlement.productID`
    exactly, character-for-character)
  - Price: **$9.99** price point (live price comes from ASC, not the `.storekit`)
  - Localization (English):
    - Display Name (≤30 chars): `Tonearm Pro`
    - Description (≤255 chars): *"A one-time unlock for power-user conveniences:
      2 GB & 10 GB cache presets, deeper prefetch, folder watch, a 10-band EQ, and
      iCloud library sync — plus CarPlay when it ships. FLAC, Opus, gapless, and
      privacy stay free for everyone."*
  - Review screenshot of the paywall + review notes.
  - Availability: all territories (or choice).
- Attach the IAP to the app version under **In-App Purchases** on the version
  page. A non-consumable may be submitted with the first app version.

**A3. Sandbox testing.**
- ASC → **Users and Access → Sandbox → Testers**: create a sandbox Apple ID.
- On device, sign into Sandbox and test **purchase + Restore**.
- Local dev continues to use `Resources/Tonearm.storekit` via the scheme's
  StoreKit configuration (already set in `project.yml`), no sandbox needed.

**A4. Code:** none required for the IAP itself. Follow-up only: add `icloudSync`
to the feature set (Part C) and mirror the description into the paywall + local
`.storekit`.

---

## Part B — Developer portal, entitlements & signing (iCloud/CloudKit)

**B1. App ID capabilities** (Certificates, IDs & Profiles → Identifiers →
`guru.parso.tonearm`). Both already reflected in profile -4:
- **iCloud** (with CloudKit)
- **Push Notifications** (CKSyncEngine relies on silent APNs pushes for automatic
  change tracking)
- CloudKit container **`iCloud.guru.parso.tonearm`** created and assigned.
- Note: **In-App Purchase** is not an App ID capability toggle (auto-enabled;
  gated by the Paid Apps agreement). **CarPlay Audio** is a separate
  Apple-approved entitlement — **deferred** (non-goal this cycle).

**B2. Entitlements file (new) `Sources/App/Tonearm.entitlements`:**
```
com.apple.developer.icloud-container-identifiers   = [iCloud.guru.parso.tonearm]
com.apple.developer.ubiquity-container-identifiers = [iCloud.guru.parso.tonearm]
com.apple.developer.icloud-services                = CloudKit
com.apple.developer.icloud-container-environment   = Production (Development in Debug)
aps-environment                                    = production (development in Debug/Automatic)
```
- Do **not** add `ubiquity-kvstore-identifier` — EQ presets + settings go through
  **CloudKit**, not key-value store. (Harmless that the profile carries it;
  entitlements must be a subset of the profile, which holds.)
- Wire via `CODE_SIGN_ENTITLEMENTS: Sources/App/Tonearm.entitlements` in the
  `Tonearm` target base settings in `project.yml`.

**B3. Info.plist (project side, `project.yml` inline info):**
- Add `remote-notification` to `UIBackgroundModes` (currently `[audio]`) so
  CloudKit silent pushes wake the app for background sync.

**B4. Signing wiring — profile -4 (Name unchanged, so minimal edits):**
- `project.yml:71` `PROVISIONING_PROFILE_SPECIFIER: "Parso Platterhead App Store"`
  → **no change** (name matches).
- `ExportOptions.plist` `provisioningProfiles[guru.parso.tonearm]` → **no change**.
- **CI secret** `PROVISIONING_PROFILE_BASE64` → **update** with
  `base64 -i ~/Downloads/Parso_Platterhead_App_Store-4.mobileprovision`.
  The CI decode path (`.github/workflows/ios.yml:165`) already writes
  `Parso_Platterhead_App_Store.mobileprovision` — no filename change needed.
- Confirm the CI distribution cert (`APPLE_CERTIFICATE_BASE64`) identity is
  included in this profile (same team/cert — should already hold).

**B5. CloudKit schema deployment.**
- Development schema auto-creates from first writes (record types in Part C).
- **Before shipping, deploy schema to Production** in the CloudKit Console — a
  required manual step, else production users get silent no-sync.

---

## Part C — iCloud sync (Pro-gated)

**Decisions locked in:** sync **playlists + favorites + IA sources/library +
play history + custom artwork + EQ presets/settings**; local-file sources sync as
**metadata marked "not on this device"**; engine is **CKSyncEngine** (iOS 17+,
fine at our iOS 18 target); privacy stance = **optional, off by default, user's
own iCloud account**. EQ presets + settings go through **CloudKit** (not KVS).

**C1. Make it a Pro feature.**
- Add `case icloudSync` to `ProFeature` (a convenience — allowed).
- Update `Tests/FreeTierRegistryTests.swift`: expected set becomes the **6** cases
  `{cachePresets, prefetchDepth, folderWatch, eq, carplay, icloudSync}` and
  `count == 6`. This is a deliberate, reviewed change to the pinned free/paid
  contract (identity features remain ungated).
- Add an **iCloud Sync** toggle in Settings, **default OFF**, gated by
  `ProFeature.isEnabled(.icloudSync)` — locked → presents `ProPaywallView`
  (same pattern as cache/prefetch/folder-watch). Add "iCloud sync" as a 6th line
  on the paywall (`ProPaywallModel.features`).

**C2. Stable sync identity (schema `v7`).**
- GRDB rows use autoincrement `Int64` PKs — not safe as cross-device identity.
  Add a `syncID` (UUID `TEXT`) column to synced tables via migration `v7`:
  `source`, `album`, `track`, `asset`, `playlist`, `playlist_item`, `favorite`,
  `play_history`, `custom_artwork`. Backfill existing rows with UUIDs.
- Keep local `Int64` PKs for internal FK joins; use `syncID` for CloudKit record
  names and cross-references.

**C3. Sync layer — `Sources/Sync/` (new).**
- `CloudSyncEngine.swift`: wraps **`CKSyncEngine`** against the **private
  database** in container `iCloud.guru.parso.tonearm`. Handles state
  serialization, `fetchChanges`, `sendChanges`, conflict resolution
  (last-writer-wins by record `modificationDate`, except play-history which is
  additive/merge-max).
- `RecordMapping.swift`: pure, testable `GRDB row ⇄ CKRecord` mappers per type.
  Record types: `Source`, `Album`, `Track`, `Asset`, `Playlist`, `PlaylistItem`,
  `Favorite`, `PlayEvent`, `CustomArtwork`, `AppSettings` (EQ gains/enabled/user
  presets + synced prefs). Parent refs via `syncID`.
- `CustomArtwork`: sync the image **file** as a `CKAsset`; download into
  `Application Support/Tonearm/Artwork` on pull.
- Change tracking: lightweight `pending_sync` queue (or GRDB `TransactionObserver`)
  so local writes enqueue records for the engine.

**C4. Local-file handling.**
- Sync `Source`/`Track`/`Asset` metadata but **not** the device-specific
  `bookmark` blob.
- Where an asset has no resolvable local file on a device, surface it as
  unavailable (reuse `Asset.unsupportedReason` or add a `needsReimport` flag) —
  track shows but greyed / "not on this device"; re-import re-links it.
  IA/remote (URL-based) sources resolve normally cross-device.

**C5. Lifecycle & gating.**
- Start the engine only when Pro **and** the toggle is ON; check
  `CKContainer.accountStatus` and no-op gracefully (with a hint) if the user
  isn't signed into iCloud.
- Trigger sync on launch, on foreground (alongside the existing folder-watch
  rescan hook in `TonearmApp`), and on local writes.
- On Pro downgrade or toggle OFF: stop the engine, leave local data intact
  (mirror the cache "lazy, never bulk-delete" rule).

**C6. Privacy copy.**
- Update `SettingsView` privacy card + `PrivacyView`: iCloud sync is **optional,
  off by default, uses the user's own iCloud account (not a Platterhead server)**,
  and syncs only library metadata/playlists/artwork/settings — never streamed
  cache audio. Adjust "No accounts" → "No accounts of ours; optional Apple iCloud
  sync."

**C7. Tests (`TonearmTests`, XCTest, pure logic — no networked CloudKit).**
- `RecordMappingTests`: round-trip each type row ⇄ CKRecord; parent-ref integrity
  via `syncID`; local-bookmark omission.
- `SyncMergeTests`: last-writer-wins for playlists/favorites/settings; additive
  merge for play history; deletion tombstones.
- `SyncGatingTests`: engine no-ops without Pro/toggle/iCloud account; downgrade
  stops without data loss.
- Migration test: `v7` backfills `syncID` for existing rows.
- Update `FreeTierRegistryTests` for the 6th case.
- CKSyncEngine networked paths are integration-only (excluded from the unit job);
  keep DB/mapping/merge logic pure and unit-tested (repo convention).

---

## Sequencing & risks

1. **Part A** first (independent; unblocks revenue; no code beyond existing).
2. **Part B** next (portal + entitlements + **CI secret update with profile -4**).
3. **Part C** last, in order: schema `v7` → mapping (pure, tested) → CKSyncEngine
   wiring → gating/UI → privacy copy → **deploy CloudKit schema to Production
   before release**.

**Key risks:**
- (a) Paid Apps agreement blocks IAP loading until signed.
- (b) Manual Release signing: use profile -4 (already carries iCloud + Push +
  correct bundle ID/container); update the CI `PROVISIONING_PROFILE_BASE64` secret
  or archive signing fails.
- (c) CloudKit schema must be promoted to Production or shipping users get silent
  no-sync.
- (d) Adding `icloudSync` intentionally changes the `FreeTierRegistryTests`
  contract (6 cases) — deliberate.
- (e) Without `remote-notification` background mode + Push, sync degrades to
  launch/foreground/manual only.

## Definition of done

Pro IAP live and sandbox-verified (purchase + restore) · entitlements file +
`remote-notification` wired · CI signing green with profile -4 · schema `v7`
migration + `syncID` backfill · `CloudSyncEngine` syncing the six data categories
with local files marked unavailable cross-device · Settings toggle default-OFF,
Pro-gated, paywall lists iCloud sync · privacy copy updated · CloudKit schema
deployed to Production · all new tests green in `TonearmTests` ·
`FreeTierRegistryTests` updated to 6 cases.
