# Find Tab — promote "Find by sound" from a sheet to a real tab

Status: **planned, not implemented**. Written for an agentic coding session
to pick up and execute in full; every referenced type/file below was
confirmed to exist by reading the actual current source, not guessed.

## 1. Why

Owner report: "our Music tab doesn't look like the one we designed with the
mockups that have the interesting find by Sound button and unified find by
sound page (instead of this goofy and largely not working 'Find Music'
popup we should get rid of)."

A tab-bar redesign was mockup'd and partly planned once before
(`docs/plans/tab-bar-redesign.md`, published mockup
`https://claude.ai/artifact/BiqBPK4yH3sG55WEqppU7m`) — it proposed 5 tabs
(Listen, **Find**, Library, DJ, Settings), with Find promoted from a sheet to
a persistent tab defaulting to browsing the whole library. That plan predates
two things that have since happened and make it stale as written:

1. The My Music unification (`docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md`)
   merged Playlists+Library into one **My Music** tab and moved Sources into
   Settings, landing on the CURRENT 4-tab reality: `enum AppTab { case
   listen, myMusic, dj, settings }` (`Sources/App/AppState.swift`). The old
   plan's `AppTab` sketch (`listen, find, library, dj, settings`) no longer
   matches anything real.
2. The mood-based-listening feature (`docs/plans/mood-based-listening-plan.md`)
   shipped a SECOND, independent `DiscoverySearchViewModel` instance for the
   Listen tab's own mood-pill entry point — deliberately NOT the same
   instance "Find by sound" uses (see that plan's §2 audit note). Any Find
   tab work must not disturb that independence.

Separately, this session found a real, general-purpose gap while fixing an
identical symptom on the Listen tab (`fix(listen): surface why the mood Play
button is disabled`): `DiscoverySearchViewModel.screen` carries rich state
(`.modelMissing`, `.zeroIndexed`, `.loading`, `.noMatches`, ...) that
`DiscoverySearchView` already renders correctly — so "Find Music" itself is
NOT missing this handling (it already switches on `model.screen` in
`resultsSection`, confirmed by reading the file in full). The "goofy and
largely not working" complaint is therefore almost entirely about
**presentation** (a sheet with a "Done" button, small buried entry point),
not missing state-handling — good news: this is a smaller, lower-risk fix
than it might sound.

## 2. What already exists (confirmed by reading the code, not assumed)

- **`Sources/Features/Discovery/DiscoverySearchView.swift`** — full working
  screen. `resultsSection` already switches on every `DiscoverySearchScreenState`
  case with real UI (download-models button, retry, "your library is empty,"
  etc.) — nothing to add here. `.idle` (no query yet) already shows
  `libraryBrowseList`, a `LazyVStack` over `appState.allTracks` — "Find
  defaults to browsing your library" is **already implemented**, per the old
  plan's own "Already done" note; re-confirmed still true.
- **Entry point today**: `Sources/Features/Library/LibraryView.swift:79-96` —
  a `Button` reading "Find by sound, BPM or key" with a waveform icon, styled
  as a `glassSurface` capsule row sitting between the Artists/Albums/Songs/
  Genres picker and the index-status banner. Sets `appState.showSoundSearch
  = true`. Easy to miss; no dedicated visual identity of its own.
- **Presentation today**: `Sources/Features/RootView.swift:77` —
  `.sheet(isPresented: $appState.showSoundSearch) { DiscoverySearchView() }`.
  `DiscoverySearchView`'s own `NavigationStack` sets `.navigationTitle("Find
  Music")` and a `.toolbar { ToolbarItem(placement: .cancellationAction) {
  Button("Done") { dismiss() } } }` — the "Done" button that reads oddly for
  something meant to feel like a real destination, and the sheet-modal
  framing itself (covers the tab bar, requires a dismiss gesture) is the
  actual "popup" complaint.
- **`appState.soundSearchReference: Int64?`** — the existing one-shot
  launch-intent for "More like this" from Now Playing (sets a reference
  track, then `DiscoverySearchView`'s `.task` calls `vm.moreLikeThis
  (trackID:)` and clears it). Must keep working identically once Find is a
  tab, not just a sheet.
- **`Sources/App/DiscoveryRuntimeController.swift`** — `searchViewModel
  (appState:player:)` (memoized singleton, what "Find by sound" uses) vs.
  `makeSearchViewModel(appState:player:)` (non-memoized, what the Listen
  tab's mood entry point uses). Find tab must keep calling the MEMOIZED
  `searchViewModel(...)` — it's the same feature, same instance, just a
  different presentation container. Do not accidentally switch it to the
  non-memoized accessor.
- **Tab bar**: `Sources/Features/Chrome/GlassDock.swift:125-129` — a plain
  `[(AppTab, String, String)]` tuple array (case, SF Symbol, label) that
  `TabBar` reads generically; adding/removing a case is a one-line array
  edit plus the matching `AppTab`/`RootView` switch cases.
- **DJ tab removal** (separately researched this session, not yet decided/
  actioned — see `docs/plans/dj-transition-lab-removal-plan.md` once
  written): if it happens, the tab bar drops from 4 to 3 (Listen, My Music,
  Settings), leaving clean room to add Find back to 4 without crowding. This
  plan is written to work either way (§3.1 below) but the 4-tab outcome
  (Find replacing DJ's slot) is the recommended target — see §3.1.

## 3. Design

### 3.1 Tab count — two scenarios, one recommendation

**If DJ/Transition Lab is removed** (recommended path, tracked as its own
decision — do not bundle that removal into this plan's implementation; land
it as its own commit/plan first if the owner confirms it):

```
Listen · Find · My Music · Settings
```

Four tabs, same count as today — Find takes the tab-bar slot DJ vacates, in
tab-bar position 2 (right after Listen — the two "vertical" screens, active
listening and active discovery, sit next to each other; My Music, the
"horizontal" browse-your-whole-library screen, moves to position 3).

**If DJ/Transition Lab is kept**, Find becomes a 5th tab:

```
Listen · Find · My Music · DJ · Settings
```

Either way the `AppTab` enum, `RootView` switch, and `GlassDock` items array
changes are the same shape — just with or without the `.dj` case removed
alongside. **Do not guess which scenario applies when implementing** — confirm
with the owner whether DJ removal has landed first; if unsure, implement the
5-tab version (strictly additive, never destructive) and let a later DJ-removal
pass collapse it to 4.

### 3.2 `AppTab` and persistence

`Sources/App/AppState.swift`:

```swift
enum AppTab: Int, CaseIterable {
    case listen, find, myMusic, settings   // if DJ is gone
    // or: case listen, find, myMusic, dj, settings   // if DJ stays
}
```

This session already bumped the persistence key once for exactly this reason
(`"lastActiveTab.v2"`, comment: "AppTab's cases/raw-values changed... a stale
v1 integer must never be reinterpreted under the new enum"). **Bump it again**
— `"lastActiveTab.v3"` — same reasoning: `.settings`'s raw value shifts by
inserting `.find`, and a stale v2 integer would silently land on the wrong
tab after the update. Leave the restore/write logic (`didSet`, `init`)
otherwise unchanged, matching the v1→v2 precedent exactly.

### 3.3 Promote `DiscoverySearchView` to a tab

Add an `isTab: Bool = false` parameter (default `false` preserves every
existing sheet call site — Now Playing's "More like this" still opens it as
a sheet, unaffected):

```swift
struct DiscoverySearchView: View {
    var isTab: Bool = false
    ...
    var body: some View {
        NavigationStack {
            Group { ... }
            .navigationTitle(isTab ? "Find" : "Find Music")
            .navigationBarTitleDisplayMode(isTab ? .large : .inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .task { /* unchanged */ }
    }
}
```

`RootView.swift`'s tab switch:

```swift
case .find: DiscoverySearchView(isTab: true)
```

**Keep the sheet too, for the "More like this" launch-intent path only** —
Now Playing's "More like this" button should probably now just switch to the
Find tab with `appState.soundSearchReference` set (matching the
`pendingArtistFilter`/`pendingTransitionLabSet` cross-tab pattern this
session already uses twice), rather than opening a second, separate sheet
on top of the tab bar. Concretely: replace `appState.showSoundSearch = true`
at that one call site with `appState.soundSearchReference = trackID;
appState.tab = .find`. Grep for `showSoundSearch = true` to find every call
site before deciding whether any should keep the sheet behavior (only
justified if a caller is itself already inside a sheet/full-screen context
where switching tabs underneath it would feel wrong — check each one, don't
blanket-convert).

### 3.4 Remove the sheet from `RootView` and the button from `LibraryView`

- `Sources/Features/RootView.swift`: delete the
  `.sheet(isPresented: $appState.showSoundSearch) { DiscoverySearchView() }`
  modifier once every call site that set `showSoundSearch = true` has been
  converted per §3.3 (grep to confirm zero remaining references before
  deleting — do not delete while a caller still expects the sheet).
- `Sources/Features/Library/LibraryView.swift:79-96`: delete the "Find by
  sound, BPM or key" button entirely — its job is now the Find tab itself,
  reachable from the tab bar like everything else. Confirm nothing else in
  `LibraryView` depends on the vertical space it occupied shifting other
  elements unexpectedly (the segmented Picker above it and
  `IndexStatusBanner` below it should simply move up to fill the gap).
- `appState.showSoundSearch: Bool` itself: once nothing sets or reads it,
  delete the property too — don't leave a dead `@Published` behind.

### 3.5 Tab bar wiring

`Sources/Features/Chrome/GlassDock.swift`:

```swift
private let items: [(AppTab, String, String)] = [
    (.listen, "play.circle.fill", "Listen"),
    (.find, "magnifyingglass", "Find"),
    (.myMusic, "square.grid.2x2.fill", "My Music"),
    // (.dj, "waveform.path.ecg", "DJ"),  // only if DJ is kept — see §3.1
    (.settings, "gearshape.fill", "Settings")
]
```

`magnifyingglass` matches the old plan's choice and the mockup below; grep
for existing uses of that SF Symbol elsewhere in the app before finalizing
to confirm no visual collision with an unrelated control reads confusingly
similar in context (a quick scan found none, but re-check at implementation
time since the codebase moves).

### 3.6 What does NOT change

- `DiscoverySearchViewModel`/`DiscoverySearchContent`/`DiscoverySearchPresentation`
  — zero logic changes. This plan is a presentation/navigation change only.
- The Listen tab's mood entry point and its independent, non-memoized
  `DiscoverySearchViewModel` instance (`MoodEntryPointSection`,
  `DiscoveryRuntimeController.makeSearchViewModel`) — completely untouched,
  stays architecturally separate per the mood plan's own explicit design.
- `TrackDetailCard`'s rollout to `DiscoverySearchView`'s results (still a
  deliberately deferred follow-up per the mood plan's §3.6 scope note — this
  plan does not pull that forward either; Find's results keep their existing
  tap-to-play `DiscoverySearchResultRow` behavior unless the owner asks for
  that follow-up explicitly).

## 4. Non-goals

- No changes to the actual search/ranking/scoring pipeline — this is
  entirely about where and how the existing screen is presented.
- No BPM/key/scope filter UI redesign — those controls stay exactly as they
  are today, just inside a tab instead of a sheet.
- Does not itself remove the DJ tab or Transition Lab — that is a separate
  decision/plan (see `docs/plans/dj-transition-lab-removal-plan.md`); this
  plan is written to work whether or not that removal has happened (§3.1).
- Does not touch CarPlay, Settings, or the Watch app.

## 5. Implementation plan (for the agentic session)

1. Confirm with the owner (or check recent commits) whether the DJ/
   Transition Lab removal has landed, to pick the 4-tab or 5-tab `AppTab`
   shape (§3.1). Default to the 5-tab (additive-only) shape if unsure.
2. Add `.find` to `AppTab`, bump the persisted tab key to `"lastActiveTab.v3"`
   (§3.2).
3. Add `isTab: Bool = false` to `DiscoverySearchView`, conditionally
   suppressing the "Done" toolbar button and changing the nav title/style
   when `isTab` is true (§3.3).
4. Wire `case .find: DiscoverySearchView(isTab: true)` into `RootView`'s tab
   switch and add the `.find` entry to `GlassDock`'s `items` array (§3.5).
5. Grep every `appState.showSoundSearch = true` call site; convert each to
   the cross-tab `pendingArtistFilter`-style handoff (§3.3) unless a specific
   site has a real reason to keep the sheet — document that reason inline if
   so, don't leave it unexplained.
6. Delete the sheet modifier from `RootView`, the button from `LibraryView`,
   and `appState.showSoundSearch` itself once no call site needs it (§3.4).
7. `swift test` + `xcodebuild build`; manually verify: Find tab opens
   browsing the full library by default: typing/filtering still works
   identically to the old sheet; "More like this" from Now Playing still
   lands correctly pre-filled; tab persistence survives a relaunch; the
   Listen tab's mood entry point is still visibly independent (selecting
   pills there does not touch Find's own filters, and vice versa) — the
   exact same independence check the mood plan's own audit required.

## 6. Mockup

Published: <https://claude.ai/artifact/MPCTFFF3kjccKU66DvQJSv>. A static copy
of the same HTML lives at `docs/plans/mockups/find-tab-mockups.html` for
offline reference. Three states: default browse, an active find-by-sound
query with BPM/key filters and ranked results, and the explained empty
states (`.modelMissing`/`.zeroIndexed`) that already exist in
`DiscoverySearchPresentation` — included to make explicit that those are not
new work, just currently hidden behind the sheet's "popup" framing.

## 7. Audit checklist (once implemented)

- The Find tab opens directly into browsing the whole library — no blank
  state, no "type something to begin."
- Every existing "Find by sound" behavior (metadata vs. find-by-sound mode
  toggle, BPM/key filters, scope picker, refinement chips, "More like this")
  works identically to before — this is a container change, not a feature
  change; regression-check each one explicitly.
- "More like this" from Now Playing still correctly pre-fills the reference
  track and clears `appState.soundSearchReference` after consuming it
  exactly once (same one-shot-clear discipline as every other cross-tab
  handoff in this codebase).
- The Listen tab's mood pills and Find's own filters remain **provably
  independent** — selecting a mood pill never appears as a Find filter and
  vice versa, confirmed by having both visibly different states in the same
  session (the exact check the mood-based-listening plan's own audit
  required for the same reason).
- `appState.showSoundSearch` is either fully removed or, if a real remaining
  call site needs it, that site's reason is documented inline, not silently
  kept "just in case."
- Tab persistence (`"lastActiveTab.v3"`) correctly restores Find after a
  relaunch, and a stale v2/v1 integer never silently resolves to the wrong
  tab under the new raw values.
- If DJ was also removed in the same working session, the tab bar shows
  exactly 4 tabs with no leftover DJ remnants (icon, case, routing) anywhere.
