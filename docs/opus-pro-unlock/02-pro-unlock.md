# 02 — Pro Unlock (one-time), EQ, Folder Watch, Cache Presets

## A. Product shape

- StoreKit 2 non-consumable, `$9.99` lifetime (optional `$7.99` launch intro).
  No subscription SKUs: there are no recurring costs to justify one, and the
  target audience (Doppler's reviews are the evidence) buys one-time and
  resents subscriptions.
- Never gate identity features: formats (FLAC/Opus/MP3), near-gapless, IA
  sources, local import, privacy. A CI test pins this (03, T2.4).
- Coexists with `ContributionSupportView`: the support view remains for
  goodwill; the Pro sheet is the feature unlock. Link them ("Already
  supporting? Pro is how features get funded").

## B. Entitlement architecture (Cladiron pattern, standalone)

New module dir `Core/Services/Pro/`:
- `ProEntitlement.swift` — struct with **private init**, constructible only
  from a StoreKit-verified `Transaction` (`Transaction.currentEntitlements`).
  The only way to obtain one is verification; no scattered booleans.
- `ProFeature.swift` — `enum ProFeature { case cachePresets, prefetchDepth,
  folderWatch, eq, carplay }` + `static func isEnabled(_ f: ProFeature) ->
  Bool` reading a cached entitlement (UserDefaults-persisted verification
  result with periodic revalidation) so airplane-mode users keep Pro.
- CI lint: `import StoreKit` permitted only under `Core/Services/Pro/` and the
  paywall view. All gating call sites use `ProFeature.isEnabled`.
- Privacy: verification is on-device (StoreKit 2 local verification); no
  receipts leave the device, no server, no analytics events.

## C. Gated features

### Cache presets (Pro)
`CacheManager` gains a user-facing budget for the `StreamingCache` pool:
free 500 MB (default), Pro adds 2 GB and 10 GB presets. Eviction stays
last-access (xattr) based. Downgrade rule: entitlement absent → over-budget
content evicts lazily via the normal policy; never bulk-delete on launch.

### Prefetch depth (Pro)
Free: next queued track only (this also powers "Opus when ready" and
near-gapless — it is deliberately free). Pro: depth N (default 3) or whole
list, with a Wi-Fi-only toggle. Prefetch respects the derivative policy
(prefers Opus) and the cache budget; skipping a track cancels its in-flight
fetch (reuse `CachingResourceLoaderDelegate.shutdown` semantics).

### Folder watch (Pro)
Extends `LocalFileImportService`: security-scoped bookmarks on user-chosen
folders; rescan on app foreground; `NSFilePresenter` while active. New files
appear in the library without manual re-import.

### EQ (Pro)
`Core/Services/Playback/EQ/`:
- `MTAudioProcessingTap` attached via `AVPlayerItem.audioMix` — valid for
  progressive/file assets, which is all this app plays.
- 10-band biquad cascade (31 Hz–16 kHz ISO bands), presets Flat / Concert
  hall / Spoken / 78 rpm + user presets persisted alongside existing settings
  storage.
- Bypass must be bit-transparent (null test in CI with an offline render).
- Tap lifecycle pitfalls: the tap must be detached before item teardown
  (integrate with the same teardown path that calls delegate `shutdown()`),
  and reattached on the preloaded next item for near-gapless continuity.

### CarPlay (deferred)
Included in the Pro promise ("when it ships"), planned separately —
`CPNowPlayingTemplate` + list templates interact with QueueManager and needs
its own plan folder.

## D. Paywall sheet

Follow mockup screen 3: one-time price, five features, Restore Purchases,
GPL line ("you can also build Pro from source" — link to repo README section).
Presentation rules: only from gated touchpoints (cache settings, prefetch
control, folder-watch setting, EQ button); never on launch; never interrupts
playback. Free-tier facts footer states what stays free forever.
