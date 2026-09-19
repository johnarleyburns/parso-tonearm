# Built-in mood starter index — guarantee results on first launch

Status: **planned, then executed same session** (see §6 for what actually
shipped vs. what remains a deliberate follow-up). Written for/by the same
agentic session that implemented it — every referenced file/type below was
confirmed to exist by reading the actual current source, not guessed.

## 1. Why

Owner, live-debugging the mood-based-listening feature: "to prevent nothing
showing on default, what i'd like is to include at least the things the
user can onboard as a 'default index' shipped with the app... and by
default select something like calm so we are guaranteed to have results
there when it loads (when the models are actually loaded)." Follow-up:
"since we're on a mac and we have clap here we should be able to pre-build
this onboarding index for them (just a union of all the possible onboarding
selections they could make that have indexable tracks like chopin, etc)."

Two things were already shipped earlier in this same session and are NOT
re-litigated here: `ListenView`'s "What's the mood?" section correctly gates
on real readiness (`modelResourceAvailable && coverage.complete > 0`) and
auto-selects "Calm" once nothing else is selected. Both are necessary but
not sufficient — on a fresh install with an empty or not-yet-indexed
library, `coverage.complete` is `0` and there is nothing to select "Calm"
into. This plan is the missing piece: real, always-available content that
gets indexed essentially immediately, so `coverage.complete > 0` becomes
true within seconds of first launch rather than depending on the owner's
own (possibly large, possibly network-dependent) library finishing
indexing first.

## 2. Two designs considered, and why the simpler one won

### 2a. Rejected: pre-compute embeddings offline, bundle static vectors

The obvious-sounding approach — run the CLAP model on a curated set of
audio *now*, on this Mac, and ship the resulting vectors as a bundled
resource the app loads at launch — was investigated in real depth:

- The exact production model files already exist locally
  (`Resources/Models/CLAPAudioEncoder.mlpackage`,
  `Resources/Models/CLAPTextEncoder.mlpackage` — confirmed via
  `Config/models-odr.yml`), and `Package.swift` already declares
  `.macOS(.v15)` as a supported platform.
- `ParsoAudioNeural`'s `CoreMLSemanticModel`/`SemanticPreprocess` (the exact
  Swift frontend + CoreML wrapper `BoundedIndexWorker` uses on-device) are
  plain `Foundation`/`CoreML`/`Accelerate` code with no iOS-only
  dependency — genuinely runnable in a macOS command-line tool.
- **This was still rejected** for tonight's execution: it means building
  and maintaining a *second*, parallel embedding pipeline (a new
  executable target, its own file-decoding/PCM plumbing, its own
  bundled-vector storage format, its own versioning story when the CLAP
  model itself is upgraded) that duplicates logic the app's real,
  already-tested `BoundedIndexWorker` pipeline already gets right. More
  moving parts, more places to be subtly wrong, with no way to verify
  correctness live before the owner wakes up.

### 2b. Chosen: seed real library tracks, let the existing pipeline index them

`Sources/Audio/BuiltInContentProvider.swift` already ships three real,
CC0-licensed ambient audio files (`ambient-rain`/`ambient-ocean`/
`ambient-flowing-water`, from Freesound, bundled as app resources) — but
today they are **purely synthetic** `TrackRow`s (`Track(id: nil, ...)`,
`sourceId: -1`), never inserted into the real `track`/`album`/`source`/
`asset` tables, played only through a separate ambient-loop code path
(`AudioPlayer+Ambient.swift`) that bypasses the entire library/search/queue
system. Telling: `BuiltInContentProvider.row(for:)` already constructs its
synthetic `Asset` with `kind: .builtIn` — a real `AssetKind` case that
already exists and is already handled in `DiscoveryReconciler
.isLocallyResolvable(_:)` (`case .localRef, .managedCopy, .builtIn:`) —
strong evidence this was anticipated, just never finished.

**The plan: insert real rows for these three tracks once, at bootstrap.**
Once they're real `track` rows with a resolvable `.builtIn` asset,
`DiscoveryReconciler.bootstrapAllTracks()` (the existing, already-correct
mechanism that queues any untagged real track for indexing) picks them up
automatically — no new embedding code, no new model invocation, no new
storage format. They are tiny, local, on-disk, network-independent files,
so they should win the race to finish indexing before or alongside
whatever else is in the queue, on every fresh install, every time.

## 3. The real gap this surfaced: `.builtIn` has no URL resolver yet

`DiscoveryReconciler.isLocallyResolvable(_:)` treats `.builtIn` as eligible
whenever `asset.relPath != nil` — but the two places that actually turn an
`Asset` into a readable/playable `URL` do not know what to do with
`.builtIn` at all:

- **`Sources/Discovery/AnalysisAssetResolver.swift`** (`resolveURL(for:)`,
  used by `BoundedIndexWorker` to read audio windows for indexing) —
  falls through bookmark → remote-file-URL → `relPath` **relative to
  Application Support**. A `.builtIn` asset's real file lives in the app
  **bundle**, not Application Support, so this would silently never
  resolve, and the seeded tracks would sit in `waitingForAsset` forever.
- **`Sources/Audio/AudioPlayer+Loading.swift`** (`buildItem(for:)`, used
  for ordinary — non-ambient — playback) — same gap: `relPath` only ever
  resolves via `managedURL(rel)` (also Application-Support-relative).
  Without a fix, tapping one of these tracks from My Music/search/Top 10
  (once they're real, browsable library rows) would fail to play.

Both needed a `.builtIn` case added, resolving via
`BuiltInContentProvider.bundledAudioURL(forChannelId:)` — keyed by storing
the ambient track's `channelId` (e.g. `"ambient-rain"`) in `asset.relPath`,
not a bare filename, so the resolver has what it needs to look the bundle
resource up.

## 4. Design

### 4.1 Seeding

A new one-time (idempotent) bootstrap step, `AppState.seedBuiltInLibraryContentIfNeeded()`,
called from `AppState.bootstrap()` alongside the existing legacy-repair
steps (`fixLegacySourceTitles()`, `repairDuplicatePlaylistsOnce()` —
matching that same "run once, cheaply check first" pattern):

1. Check whether a `Source` matching a stable identity for built-in content
   already exists (mirroring `firstSource(title:kind:)`'s existing
   find-or-create pattern elsewhere in this codebase) — skip entirely if
   so, so this never re-inserts duplicates across app updates/relaunches.
2. If not: insert one `Source` (title "Built-in Sounds", `kind: .local` —
   there is no dedicated "built-in" `SourceKind` and adding one is out of
   scope for tonight; `.local` is accurate enough, and the asset-level
   `.builtIn` kind is what actually matters for resolution/indexing), one
   `Album` ("Ambient Sounds", matching what the synthetic construction
   already uses), then for each of `BuiltInContentProvider.tracks`: a real
   `Track` row (using the file's **real** duration — fetched once via
   `AVURLAsset.load(.duration)` on the bundled file, not the synthetic
   path's hardcoded `0`) and a real `Asset` row (`kind: .builtIn,
   relPath: ambient.channelId`).
3. `AppState.reload()` afterward so the freshly-seeded tracks show up in
   `allTracks` immediately, same as any other import.

### 4.2 Resolution fixes

Both `AnalysisAssetResolver.resolveURL(for:)` and
`AudioPlayer+Loading.buildItem(for:)` gain a `.builtIn` branch:

```swift
if asset.kind == .builtIn, let channelId = asset.relPath,
   let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
    return /* resolved, no security scope needed — it's an app bundle resource */
}
```

Placed before the generic `relPath` (Application-Support) fallback in each,
so a `.builtIn` asset never even attempts the wrong path.

### 4.3 What this deliberately does NOT change

- `BuiltInContentProvider`'s existing **ambient-loop** playback path
  (`AudioPlayer+Ambient.swift`, the "Ambient" playlist) is untouched — it
  already works, and continues to resolve these files directly via
  `bundledAudioURL(forChannelId:)` without going through the generic
  `Asset` resolver at all. The same three tracks are now reachable via
  *two* paths (the special ambient loop, and now also normal library
  playback/search) — both correct, neither replaces the other.
- No new `AssetKind`, no new DB table, no schema migration. `.builtIn`
  already existed; this plan finishes wiring it rather than inventing
  something new.
- No change to `DiscoveryReconciler`'s eligibility logic — it already
  correctly treats `.builtIn` as indexable; the gap was purely in URL
  resolution, not eligibility.

## 5. Non-goals (this pass)

- **Broader mood-category coverage** (upbeat/intense/vocal-forward/
  electronic/classical/"Chopin, etc.") is explicitly **not** attempted
  tonight. The three existing built-in tracks are calm ambient nature
  sounds — they solve the "Calm" default concretely and honestly, but do
  not span the other 11 mood pills. Sourcing additional genuinely-licensed
  audio (public-domain classical from IMSLP/Musopen, explicitly
  redistribution-permitted CC tracks, or a different integration with the
  existing Jamendo *streaming* connector that does not require permanently
  bundling third-party content pulled through their API — bundling
  API-sourced audio into the app binary is a real licensing/ToS question,
  not just a curation one) is a **deliberate follow-up requiring the
  owner's explicit sign-off on specific tracks and their licenses** — not
  something to decide or execute unilaterally overnight. Session
  autonomy has real limits here: this is a genuine legal/content-rights
  judgment call, not an engineering one.
- Does not give these tracks any special ranking boost in search results —
  they compete on real CLAP similarity like any other indexed track, which
  is the honest behavior (CLAUDE.md: never fabricate a stronger signal than
  what's real).
- Does not hide/flag these tracks as "system content" in My Music/Recently
  Added/etc. — they are real, licensed, pleasant ambient tracks; showing
  them as ordinary library content (as the existing "Ambient" playlist
  already does) is simpler and no worse than inventing a new "hidden
  built-in content" visibility concept for tonight's scope.

## 6. What actually shipped (filled in during/after execution)

- [x] `.builtIn` resolution added to `AnalysisAssetResolver.swift` and
      `AudioPlayer+Loading.swift`.
- [x] `AppState.seedBuiltInLibraryContentIfNeeded()` added and wired into
      `bootstrap()`.
- [x] Real duration fetched and stored per track instead of the synthetic
      path's hardcoded `0`.
- [x] `swift test` / `xcodebuild build` both green.
- [ ] **Not verified live tonight**: whether indexing of these three
      tracks actually completes promptly on a real device and whether
      "Calm" genuinely shows them moments after first launch. This needs a
      real device/simulator run — the owner should verify this specific
      end-to-end path first thing, since no live phone session was
      available to confirm it before this was committed.
