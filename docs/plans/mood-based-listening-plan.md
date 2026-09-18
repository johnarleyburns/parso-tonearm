# Mood-Based Listening — Listen Tab Redesign Plan

Status: **implemented** (commits `69f09c7`/`b2921a9` on `main`; see §8 for
the post-implementation audit). Originally written for an agentic coding
session to pick up and execute in full; every referenced type/file below was
confirmed to exist by reading the actual current source, not guessed.

## 1. Why

Competitor research (docs/plans — see the CarPlay/competitor-gaps plan's
sibling research) found this app's Listen tab is stats-first: "Jump Back
In," "Listening Stats," "Favorites" — a passive dashboard, not an entry
point into discovery. Every competitor (Plex/Plexamp, Apple Music,
Spotify) leads with some form of active, low-effort discovery instead.

Separately, research into the sibling repo `johnarleyburns/parso-acalum-
ios-app` found a concrete, already-proven UI pattern worth adapting: a
free-text prompt bar plus a curated set of mood/feeling "pills," combined
into one query, feeding a **continuous stream** rather than a static
result list or a playlist the user has to build by hand. This plan adapts
that pattern to this app's own catalog shape (archive.org + self-hosted
libraries, not Acalum's public-domain-classical-specific set) and its
already-built CLAP semantic-search infrastructure.

## 2. What already exists (confirmed by reading the code, not assumed)

- **`Sources/Features/Discovery/DiscoverySearchView.swift`** — a real,
  working semantic search screen, reachable today via "Find by sound, BPM
  or key" (`Sources/Features/Library/LibraryView.swift`) and from Now
  Playing's "More like this" (`appState.soundSearchReference`). Not new ML
  work — it already does on-device CLAP text-embedding search.
- **`Sources/Discovery/DiscoverySearchViewModel.swift`** — `@Published var
  searchText`, `positiveRefinements`/`negativeRefinements: [String]` (via
  `addMoreLike(_:)`/`addLessLike(_:)`/`removeMoreLike(_:)`/
  `removeLessLike(_:)`), `scope`, `bpmMinText`/`bpmMaxText`,
  `compatibleKey`. `currentQuery()` already combines ALL of these into one
  `DiscoverySearchQuery` object submitted to `DiscoverySearchCoordinator`
  — this is architecturally the same shape as Acalum's
  `DiscoveryContext { prompt, selectedPills }`, just without a curated
  pill taxonomy on top of the free-text refinement terms (today the UI
  exposes refinements as a manually-typed "Add a term" field with
  More/Less buttons, not selectable chips).
- **`FlowChips`** (referenced in `DiscoverySearchView.swift`'s
  `refinements` section) — an existing wrapping-chip component already
  used for `positiveRefinements`/`negativeRefinements` display. Reusable
  styling base for mood pills, though it renders removable result chips,
  not a fixed selectable palette — a new `MoodPillPicker` component is
  still needed (see §5).
- **`AudioPlayer`'s Keep Playing extension** (`Sources/Audio/AudioPlayer.
  swift`, `keepPlayingEnabled`/`keepPlayingBatchSize`/
  `maybeExtendKeepPlayingQueue()`) — already extends a queue with
  similar-sounding tracks as it nears its end. This is the existing
  mechanism a "continuous stream" needs; no new queue-extension engine
  required, just a different seed (a mood query's results instead of "the
  last-played track").
- **What does NOT exist**: a curated pill taxonomy, a combined prompt+pill
  entry point living in the Listen tab itself, and — confirmed by reading
  `DiscoverySearchCoordinator.swift` — the exact scoring blend (CLAP-
  cosine vs. any lexical component) wasn't traceable from the coordinator
  file alone in this research pass; **verify the actual blend in
  `TonearmDiscovery`'s scoring code before assuming it matches Acalum's
  0.62/0.38 CLAP/tag split** — it may differ, and the pill design below
  should not hard-code an assumption about it.
- **Real gap found auditing this plan, second pass**:
  `DiscoveryRuntimeController.searchViewModel(appState:player:)` — the
  function `DiscoverySearchView.task` calls to get its view model — is a
  **memoized whole-app singleton** (`private var searchVM:
  DiscoverySearchViewModel?`; `if let searchVM { return searchVM }`). If
  the Listen tab's mood entry point called this same function, it would
  get the exact same instance "Find by sound" uses and mutate the exact
  same `searchText`/`positiveRefinements`/`scope` — selecting mood pills
  here would corrupt (or be corrupted by) whatever filters the user has
  set on the Find by Sound screen, and vice versa. The underlying
  `DiscoveryAssembly` (CLAP model resources) is *also* memoized
  separately (`private var assembly: DiscoveryAssembly?`), so the fix is
  cheap: the Listen tab's view model must construct its **own**
  `DiscoverySearchCoordinator`/`DiscoverySearchViewModel`, reusing the
  same shared `assembly.search` service (no duplicate model load —
  `makeAssembly()` already memoizes that independently of `searchVM`),
  rather than calling `DiscoveryRuntimeController.shared.
  searchViewModel(...)` and getting the Find-by-sound screen's own
  instance back. This corrects an error in this plan's own earlier
  audit-checklist wording (§7 used to say the opposite).
- **Real find, auditing this plan before implementation started**:
  `Sources/DJ/Features/VibeSearch/VibeSearchModel.swift` and
  `VibeSearchView.swift` (872 lines total) already implement almost
  exactly this idea — a query-text field, additive `positiveTerms`/
  `negativeTerms` chips (`+ hypnotic`/`− vocals`, Capsule-styled),
  and, most valuably, **`SuggestionChips.seed(from: LibraryDescriptorSummary,
  limit:)`** — a pure, deterministic function that derives chip text
  ("steady around 124 BPM," "in 8B," "high energy") from the *library's
  own* real BPM/Camelot-key/energy/duration distribution, never a
  hand-picked list. This directly answers §3.2's open "Era/Vibe" category
  question below — **read and likely adapt `SuggestionChips` instead of
  hand-picking that category's pills**.

  **But it's dead code** — confirmed via `grep` that nothing outside
  `TonearmDJ` references `TonearmDJ.LibraryView` (the only place
  `VibeSearchView` is constructed), the same class of orphaned leftover
  from the DJ-mixer-workspace deletion earlier this session, just missed
  in that pass because it lives in a sibling `VibeSearch/` directory, not
  `Workspace/`. Two real implications for the implementing session:
  1. Its query-combination model differs from what §3.1 proposes here —
     `VibeSearchView`'s suggestion chips call `model.updateQuery(chip)`,
     which **replaces** the query text, not an additive refinement the
     way this plan's pills add to `positiveRefinements` alongside
     unchanged free text. Don't assume the two are interchangeable;
     decide deliberately which combination model the Listen tab wants
     (this plan's own §3.1 point 4 — additive, matching Acalum — is
     still the recommendation, just be aware `VibeSearchModel` itself
     does it differently).
  2. This is now a second, undeleted piece of DJ-mixer-era dead code
     (`DiscoveryReconciler`'s earlier audit found similar orphans). Raise
     with the owner whether to delete it outright (consistent with the
     rest of that cleanup) or adapt `SuggestionChips` into a small,
     standalone, `TonearmDiscovery`-side utility before deleting the rest
     of the file around it — don't silently leave it or silently delete
     it without flagging the `SuggestionChips` logic is worth keeping.

## 3. Design

### 3.1 Entry point: prompt bar + pills replace the current Listen tab top

The current `ListenView` (`Sources/Features/Listen/ListenView.swift`)
opens with `ScreenHeader(title: "Listen")` then goes straight into "Jump
Back In" → "Listening Stats" → "Favorites". The redesign:

1. `ScreenHeader(title: "Listen")` stays.
2. **New**: a prompt bar (`TextField`, placeholder text rotating through a
   few evocative examples — "sunday morning coffee," "focus, no vocals,"
   "storm outside" — styled like `DiscoverySearchView`'s existing
   `FilterFieldStyle` search field) directly below the header.
3. **New**: a horizontally-scrolling row of mood pills directly below the
   prompt bar (see §3.2 for the taxonomy) — visually modeled on
   `MyMusicView.scopePicker`'s capsule-chip pattern
   (`Sources/Features/MyMusic/MyMusicView.swift`, added this session:
   `Capsule()` fill, `Palette.brassDeep` when selected, `Color.white.
   opacity(0.07)` otherwise) rather than `FlowChips`' removable-chip
   styling, since pills here are a fixed palette the user toggles, not an
   accumulating list of typed terms.
4. Text and pills are **additive, not either/or** (matching Acalum): both
   feed one `DiscoverySearchQuery` — the prompt becomes `text`, each
   selected pill contributes to `positiveRefinements`.
5. A primary call-to-action button ("Play" / a large brass-filled circular
   play glyph, matching `ScreenHeader`'s existing `+` button styling)
   starts the generative queue from the current prompt+pills state.
   Changing pills/prompt while already playing updates the *upcoming*
   queue non-destructively (mirrors Acalum's "Update upcoming" vs. "Play
   now" distinction) rather than yanking the currently-playing track.
6. Below the entry point: "Jump Back In" / "Listening Stats" / "Favorites"
   move down, not away — see §3.3.

### 3.2 Pill taxonomy (first draft — needs a real content pass, not a guess)

Acalum's 23 pills across 4 categories (Sound/Style/Tradition/Listening
Mode) were curated for a public-domain-classical catalog. This app's
catalog shape is different (archive.org live recordings/bootlegs, ambient/
electronic, self-hosted personal libraries) — **do not port Acalum's pill
text verbatim**. Draft categories to validate against a real library
during implementation:

- **Energy**: Calm · Upbeat · Intense · Mellow
- **Setting**: Focus · Background · Deep Listen · Sleep
- **Character**: Instrumental · Vocal-forward · Acoustic · Electronic
- **Era/Vibe**: derive from the library's own real descriptor distribution
  rather than hand-picking — `SuggestionChips.seed(from:
  LibraryDescriptorSummary, limit:)` (`Sources/DJ/Features/VibeSearch/
  VibeSearchModel.swift`, currently dead code — see §2) already does
  exactly this (BPM band, dominant Camelot key, energy, duration → chip
  text like "steady around 124 BPM"/"high energy"). Adapt it rather than
  writing a second version of the same deterministic-chip idea.

Each pill needs, like Acalum's, an embedding phrase (fed into
`positiveRefinements`, e.g. "Calm" → `"calm, relaxed, low energy"`) —
keep these editable in one place (a `MoodPill` struct with `id`,
`label`, `queryTerm`), not scattered across the view, so the taxonomy can
be iterated on without touching UI code.

### 3.3 Continuous queue, not a static result list

Acalum's key UX difference from a traditional search result list: no
manual "build a playlist" step. Adapting this:

- "Play" seeds `AudioPlayer.play(tracks:startAt:source:)` with the top N
  scored results from the mood query (reuse `DiscoverySearchViewModel`'s
  existing result pipeline — do not build a second one).
- As the queue nears its end, extend it with more results from the SAME
  mood query rather than falling back to generic Keep Playing similarity
  — this likely means `AudioPlayer`'s extension logic needs a pluggable
  "extension source" concept (currently keyed off the last-played track's
  similarity; a mood-seeded queue should keep pulling from the mood
  query's result set / re-run it periodically for freshness) — a real
  design decision for the implementing session, not fully specified here;
  flag it explicitly rather than guess `AudioPlayer`'s exact extension
  point without reading `maybeExtendKeepPlayingQueue()`'s full
  implementation first.
- A "Shake it up" affordance (Acalum's term) re-rolls the result set
  without changing the prompt/pills — useful when the first batch doesn't
  land; needs no new backend, just re-submitting the same query and
  taking a different slice/order of results if the coordinator supports
  that, or a light client-side shuffle of the returned set otherwise.
- **Real gap found auditing this plan, third pass**: the published
  mockup's "Now Playing a mood" screen shows "matched: calm"/"matched:
  focus" chips under the current track, and its own annotation describes
  them as showing "which selected pills the current track actually
  scored on." This plan never specified that feature or how to build it
  — checked `RankBreakdownDisplay.Component`
  (`Sources/Discovery/DiscoverySearchPresentation.swift`, the same
  structure the §7 audit checklist already points at for verifying the
  scoring blend) and it carries generic score components (e.g.
  "similarity") with **no per-refinement-term attribution** — there is
  no existing way to know which *specific* selected pill (as opposed to
  the query as a whole) caused a given track to rank highly, and a fused
  CLAP embedding of several combined terms may not even make that
  meaningful to compute. Two honest options for the implementing
  session, pick one deliberately rather than build the mockup's exact
  claim by accident: (a) show the chips as **context** — the pills
  currently selected, not a per-track "why this matched" explanation
  (cheap, matches what's actually knowable) — or (b) treat true
  per-pill attribution as its own separately-scoped follow-up requiring
  new scoring work, and drop the chips (or relabel them) from this
  pass. Recommendation: (a), and reword the mockup/UI copy to something
  like "vibing with: Calm, Focus" rather than "matched," which
  overclaims a causal explanation the data doesn't support.

### 3.4 Existing content — demoted, not deleted

Consistent with this session's own Settings-simplification precedent
(progressive disclosure over flat equal-weight surfaces, docs/plans/ui-
simplification-plan.md): "Jump Back In," "Listening Stats," and
"Favorites" stay fully reachable, just below the new mood entry point
instead of being the first thing shown. No feature removal.

### 3.5 Listening Stats — Top 10 Songs / Top 10 Artists, both tappable

Real gap in the current `statsCard` (`ListenView.swift`): it only ever
shows a single `topLine("Top Artist", …)` / `topLine("Top Track", …)` —
one name each, not a list, and neither is tappable. Owner feedback:
expand to a **Top 10 Songs** list and a **Top 10 Artists** list, each row
tappable to jump to that song (play it / open its detail card — see
§3.6) or that artist (open a filtered track list for that artist, using
`LibraryStore.tracks(forArtist:)` — the same query the CarPlay
implementation already uses — for the DATA; do not build a second
artist-track query).

**Real gap found auditing this section**: "reuse the artist drill-down"
undersells the actual work. `LibraryView`'s artist drill-down
(`navigationDestination(for: LibraryBrowse.Entry.self)`) is pushed onto
**its own** `NavigationStack` — reachable only from inside `LibraryView`/
`MyMusicView` itself, not from a different root tab. Tapping a Top Artist
row on the *Listen* tab needs a real cross-tab deep link: switch
`appState.tab = .myMusic`, select the Artists scope, and land on that
specific artist — there's no existing mechanism for "jump into another
tab already drilled into a specific destination." The pattern to copy
is the one-shot launch-intent `@Published` property this session already
used twice for exactly this kind of cross-tab handoff —
`appState.pendingTransitionLabSet` (playlist → DJ tab) and
`appState.soundSearchReference` (track → search sheet). Add a matching
`appState.pendingArtistFilter: String?` (or similar), consumed once by
`MyMusicView`/`LibraryView` on appear the same way `TransitionLabTabView.
consumePendingSeed()` does, then cleared. Do not assume a simpler
same-screen push will work — the artist list and the Listen tab are
different tabs today.

**Real gap found auditing this section a second time (4th pass overall)**:
even the corrected design above understates the work by one more layer.
`TransitionLabTabView.consumePendingSeed()` is a bad direct comparison —
it just sets local `@State` on the DJ tab's own top-level view; no
navigation push is involved. Landing on a specific artist's tracks is a
**pushed** `navigationDestination(for: LibraryBrowse.Entry.self)`
destination two levels deep (My Music tab → Artists scope → that one
artist), and confirmed via `grep` that `MyMusicView`'s `NavigationStack {
… }` (`Sources/Features/MyMusic/MyMusicView.swift`) takes no `path:`
argument — there is currently no way to programmatically push anything
onto it from outside a user's own `NavigationLink` tap. Two real changes
needed, not one: (1) convert that `NavigationStack` to
`NavigationStack(path: $someNavigationPath)` with a bound path the view
owns — use SwiftUI's type-erased `NavigationPath`, not a typed array/enum:
this one stack already carries two different `navigationDestination`
types today (`Playlist.self` from the embedded `PlaylistsView`, `String.
self` for the "ambient" row) plus `LibraryBrowse.Entry.self` once this
change lands, and `NavigationPath.append(_:)` accepts any `Hashable`
without needing them unified under one shared type; (2) on consuming
`pendingArtistFilter`, rebuild artist entries via
`LibraryBrowse.sections(for: .artists, rows:)` (the only existing way to
produce an `Entry` — there's no "look up by artist name" helper), find
the matching entry by title, and `append` it to the bound path. Budget
this as real navigation-architecture work, not a one-line consume-and-set
like the DJ tab's pattern.

**Already mostly there**: `ListeningStats.Summary.topTracks: [TrackRank]`
/ `topArtists: [NameRank]` (`Sources/Domain/ListeningStats.swift`) are
already ranked arrays, not single values — the UI just only ever reads
`.first`. `TrackRank.row: TrackRow` carries everything needed to open a
track's detail card directly; `NameRank.name: String` is enough to open
an artist's filtered track list. `ListeningStats.summarize(events:
tracks:rankLimit:)` defaults `rankLimit` to 5 — `AppState.reload()`'s
call site (`Sources/App/AppState.swift`) needs to pass `rankLimit: 10`
to actually get ten of each; everything downstream (`TrackRank`/
`NameRank` arrays) already scales with that parameter without further
changes.

**UI**: replace the two single `topLine` rows with two short vertical
lists (rank number, title/name, play count), each row a button — tapping
a song row opens its detail card (§3.6); tapping an artist row sets
`appState.pendingArtistFilter` and switches `appState.tab = .myMusic`,
per the cross-tab handoff above — not a same-screen push.

### 3.6 Tapping a track opens a detail card — not an instant play

Owner feedback, and it applies beyond just this plan's new mood surface:
tapping a track today (`ListenView`'s cards, `LibraryView`'s rows,
`DiscoverySearchView`'s results — all confirmed via `grep` to call
`player.play(tracks:startAt:source:)` directly on tap) starts playback
immediately with no confirmation and no information shown first. Real
report: "it seems jarring to just start playing it — I expect to see
details about the song first."

**This is a cross-cutting interaction change, not Listen-tab-only** —
scoped into this plan because that's where it was raised, but implement
it once as a shared component and apply it everywhere a track row is
tapped (My Music/`LibraryView`, search results/`DiscoverySearchView`,
Listen's mood results and Top 10 Songs, Jump Back In, Favorites), not as
a one-off special case inside `ListenView`.

**Design**: a `TrackDetailCard` sheet (artwork, title, artist/album,
duration, source) presented on tap instead of calling `play(...)`
directly, offering:
- **Play Now** — `player.playSingle(row)` (already exists, currently a
  context-menu-only action — see `TrackContextMenu`,
  `Sources/Features/Components.swift`).
- **Add to Queue** — `player.appendToQueue(row)` (already exists,
  same file). Consider also surfacing the existing `insertNext(row)`
  ("Play Next") here rather than dropping it — the context menu already
  has both and users may rely on the distinction.
- **Include in current mood** — new; only relevant/shown when a mood
  query is active (§3.1–3.3). **Real gap found auditing this plan, third
  pass: where does "a mood query is active" actually live such that a
  shared `TrackDetailCard` can check it from an unrelated screen?**
  `TrackDetailCard` is designed to be used from My Music, search results,
  Jump Back In, and Favorites too (§3.6) — none of those have a reference
  to the Listen tab's own local mood view-model instance (step 5's "thin
  wrapper," scoped to `ListenView`). Confirmed via `Sources/Audio/
  AudioPlayer+QueueSource.swift` that `AudioPlayer`'s existing
  `@Published var queueSource: QueueSource` — already globally
  observable app-wide, exactly what this needs — has no case for "this
  queue came from a mood query" (`.source`/`.playlist`/`.library`/
  `.ambient`/`.none` only). This is also exactly what §3.3's
  already-flagged "extension source" design question needs to know
  (whether to extend the queue by re-running the mood query or fall back
  to generic Keep Playing similarity) — **one mechanism should resolve
  both**: add a `.mood(...)` case to `QueueSource` carrying whatever the
  extension logic and "Include in current mood" both need (at minimum
  the query itself, or a reference back to the mood view-model instance
  that owns it), set when "Play" starts a mood queue. Any screen can then
  check `AudioPlayer.shared.queueSource` to decide whether to show
  "Include in current mood," and the extension logic can branch on it
  the same way. Adds the track as a positive signal to the
  live view-model via the existing **additive** mechanism —
  `addMoreLike(_:)`, the same call the "More like/Less like" refinement
  chips already use. **Real design flaw caught auditing this plan: do
  NOT use `moreLikeThis(trackID:)` for this** — despite the name
  sounding right, `moreLikeThis` sets `referenceTrackID`, which
  `DiscoverySearchViewModel.refresh()` treats as an *exclusive
  alternate mode* (`if let referenceTrackID { submitToCoordinator(...)
  return }` — it short-circuits before the text+refinements path even
  runs). Calling it here would silently **replace** the active mood
  query with pure "similar to this one track" mode, discarding the
  prompt and every selected pill — the opposite of "include in current
  mood." `addMoreLike(_:)` is the correct primitive; `moreLikeThis` is
  for the separate "Find by sound → More like this" entry point only.
- **Dismiss** — closes the sheet, no action, no playback change.

**Reuses, doesn't replace**: `TrackContextMenu`'s long-press menu can
stay as-is for users who prefer it (secondary-action muscle memory) —
this changes what a plain *tap* does, not what's reachable at all. Every
action the card offers already exists on `AudioPlayer`/
`DiscoverySearchViewModel` today; this is a presentation change (show a
card first) wired to existing calls, not new playback logic.

**Scope/effort note for the implementing session**: touching every
track-row tap site across `LibraryView`/`DiscoverySearchView`/
`ListenView` is a wider-reaching change than the rest of this plan and
should be its own reviewed step — get the mood-specific Listen tab work
(§3.1–3.5) solid first, then apply `TrackDetailCard` there, then extend
to My Music and search results as a deliberate follow-up pass so each
surface's row-tap change can be verified independently (same "verify
nothing becomes unreachable" discipline as the Settings/My Music
simplification pass earlier this session).

## 4. Non-goals

- No new ML model, no new embedding infrastructure — this is a UI/UX
  layer on top of the existing CLAP search pipeline.
- No change to `DiscoverySearchView`/"Find by sound" itself — it keeps
  working exactly as it does today as the power-user/precise-filter path
  (BPM, key, scope, metadata mode). The Listen tab's mood entry point is
  a separate, simpler front door into the same underlying search, not a
  replacement for it.
- Does not touch the DJ/Transition Lab, Settings, or CarPlay surfaces.
- **My Music is NOT fully out of scope — this bullet used to claim
  otherwise, contradicting §3.5 and §3.6 below; caught auditing this
  plan a third time.** Two narrow, deliberate touches to `MyMusicView`/
  `LibraryView` are in scope: (1) consuming
  `appState.pendingArtistFilter` on appear (§3.5, step 12) — required
  for a Top Artist row to go anywhere at all; (2) `TrackDetailCard`'s
  eventual rollout there (§3.6, step 14) — explicitly sequenced as a
  deliberate follow-up, not bundled into the same change, but still
  part of this plan's arc, not a separate undertaking. Everything else
  about My Music (its own browse UI, scope bar, playlist features) is
  genuinely untouched.

## 5. Implementation plan (for the agentic session)

1. **Read `DiscoverySearchCoordinator.swift` and the `TonearmDiscovery`
   scoring code in full** before writing any query logic — confirm the
   actual text+refinement scoring blend and the coordinator's async
   submission contract (`submit(query:referenceTrackID:completion:)`
   seen in `DiscoverySearchViewModel.swift`). Do not assume it matches
   Acalum's weights.
2. **Read `Sources/DJ/Features/VibeSearch/VibeSearchModel.swift` in full**
   and decide with the owner whether to (a) delete it outright as
   leftover DJ-mixer dead code, or (b) extract `SuggestionChips` (and
   `LibraryDescriptorSummary`) into a small standalone utility first,
   then delete the rest — do not silently leave it orphaned a second
   time, and do not silently delete real, reusable logic without asking.
3. Define `MoodPill` (id, label, queryTerm) and a starter taxonomy per
   §3.2 as a plain data file/array — no UI yet. The Era/Vibe category
   should come from the (possibly-extracted) `SuggestionChips` logic per
   step 2, not be hand-picked.
4. Build `MoodPillPicker`, a horizontally-scrolling capsule-chip row
   (styled per §3.1 point 3), taking `[MoodPill]` and a `Set<MoodPill.ID>`
   selection binding.
5. Build the prompt bar + pill row + Play CTA as a new section in
   `ListenView`, backed by a small new view-model (or extend
   `DiscoverySearchViewModel` — decide based on how entangled its
   `DiscoverySearchView`-specific state, like `bpmMinText`, is; a
   thin wrapper that composes a `DiscoverySearchViewModel` instance
   configured for text+refinements-only use is likely cleaner than adding
   Listen-tab-specific state to the existing view model). **Do not** call
   `DiscoveryRuntimeController.shared.searchViewModel(...)` for this — it
   returns a memoized whole-app singleton shared with the "Find by sound"
   screen (§2's audit note) — construct a separate
   `DiscoverySearchCoordinator`/`DiscoverySearchViewModel`, reusing the
   same underlying `assembly.search` service so the CLAP model itself
   isn't loaded twice. Concretely: `assembly`/`makeAssembly()` are
   `private` to `DiscoveryRuntimeController` and `searchViewModel(...)`
   is its only exposed accessor today — there is no existing way to reach
   the shared service without the memoized view model attached. Add a
   second, non-memoizing method there (e.g. `makeSearchViewModel
   (appState:player:) async -> DiscoverySearchViewModel`, calling the
   same `makeAssembly()` but constructing a fresh
   `DiscoverySearchCoordinator`/`DiscoverySearchViewModel` every call
   instead of caching one) for the Listen tab to use instead.
6. Add a `.mood(...)` case to `QueueSource`
   (`Sources/Audio/AudioPlayer+QueueSource.swift`) per §3.6's audit note
   — carrying whatever step 7's extension logic and "Include in current
   mood" (step 13) both need. Wire "Play" to `AudioPlayer.play(tracks:
   startAt:source:)` using `results.map(\.track)` from the view model,
   passing `source: .mood(...)`.
7. Implement continuous extension per §3.3's flagged design decision —
   read `AudioPlayer`'s Keep Playing implementation fully first; branch
   on `queueSource` being `.mood` to re-query instead of falling back to
   generic similarity.
8. Implement "Shake it up."
9. Reorder `ListenView`'s existing sections below the new entry point;
   verify nothing becomes unreachable (same verification standard as the
   Settings/My Music simplification pass).
10. Add accessibility identifiers for the new controls (prompt field,
    each pill, Play button, Shake it up) so a future UI test can
    exercise this flow — following this session's `mymusic.scope.*`-
    style naming convention.
11. Bump `AppState.reload()`'s `ListeningStats.summarize(…)` call to
    `rankLimit: 10`; replace `statsCard`'s single top-artist/top-track
    lines with two tappable top-10 lists per §3.5. Song rows open
    `TrackDetailCard` (step 13).
12. Add `appState.pendingArtistFilter: String?` (or similar), matching
    the `pendingTransitionLabSet`/`soundSearchReference` one-shot
    launch-intent pattern (§3.5's audit note), for artist-row taps to
    cross into the My Music tab landed on that specific artist. Convert
    `MyMusicView`'s plain `NavigationStack { … }` to `NavigationStack
    (path: $navigationPath)` with an owned, bound path (§3.5's second
    audit note — there is no way to programmatically push into it today).
    On appear with a pending filter set: switch to the Artists scope,
    rebuild entries via `LibraryBrowse.sections(for: .artists, rows:)`,
    find the matching entry by title, `append` it to the path, then clear
    `pendingArtistFilter`.
13. Build `TrackDetailCard` (§3.6) as a shared, reusable sheet — artwork/
    title/artist/duration/source plus Play Now / Add to Queue / Include
    in current mood (shown only when `AudioPlayer.shared.queueSource` is
    `.mood` — see step 6 — via `addMoreLike(_:)` on the active mood view-
    model — NOT `moreLikeThis(trackID:)`, see §3.6's audit note) /
    Dismiss, wired to the existing `playSingle(_:)`/`appendToQueue(_:)`/
    `insertNext(_:)` on `AudioPlayer` — no new playback logic.
14. Wire `TrackDetailCard` into the Listen tab's own tap sites first
    (mood results, Top 10 Songs, Jump Back In, Favorites) and verify end-
    to-end before touching `LibraryView`/`DiscoverySearchView` — per
    §3.6's scope note, extending to My Music and search results is a
    deliberate follow-up step, not bundled into the same change.
15. `swift test` + `xcodebuild build` + a real device/simulator pass
    playing a mood query end-to-end, opening a track's detail card from
    every wired entry point, and confirming Top 10 lists jump correctly
    (this cannot be verified by compiling alone — actual result relevance
    needs a real library and real ears).

## 6. Mockups

Published mockup board (Listen tab: default state, pills selected +
playing state, and the demoted stats section):
<https://claude.ai/artifact/MVHBc6uTsAVcSWGrCoCvcE>. A static copy of the
same HTML lives at `docs/plans/mockups/mood-listening-mockups.html` for
offline reference.

## 7. Audit checklist (once implemented)

- Every currently-reachable Listen tab action (share stats, tap a
  favorite, tap a Jump Back In card) still reachable after reordering.
- Mood query results actually differ meaningfully pill-to-pill on a real
  library (not just re-shuffling the same top tracks regardless of
  selection) — a real qualitative check, not just "it compiles." Inspect
  a few real results' `DiscoverySearchResult.breakdown: RankBreakdown?`
  (surfaced today via `DiscoverySearchViewModel.scoreComponents(for:)` →
  `RankBreakdownDisplay.Component`) to confirm the components you'd
  expect actually moved. If anything looks off, run
  `swift test --filter DiscoverySearch` — the existing scoring tests
  should catch a broken blend before this new UI ships on top of it.
- The Listen tab's mood picker and the existing "Find by sound" screen
  have **independent** `DiscoverySearchViewModel` state (selecting mood
  pills here must not appear as filters there, or vice versa) while
  **sharing** the underlying `DiscoveryAssembly`/CLAP model resources (no
  second model load). Confirmed by reading the code that
  `DiscoveryRuntimeController.shared.searchViewModel(...)` returns a
  memoized whole-app singleton — the Listen tab must NOT call that
  function directly (§2's audit note); it needs its own coordinator/view-
  model instance built from the same shared `assembly.search`.
- Continuous-queue extension doesn't fight with the existing Keep
  Playing toggle/settings (`Settings → Keep Playing`) — a user who
  disabled Keep Playing globally should not have it silently reappear
  via the mood queue's continuation, unless that's a deliberate,
  disclosed exception worth calling out in the Settings copy.
- Top 10 Songs/Artists actually show ten (not five) on a library large
  enough to have that many distinct plays, and each row's tap target
  goes to the right place — a song opens `TrackDetailCard` for that
  exact track, an artist row opens that exact artist's tracks, not a
  stale/wrong reference from a reused row view.
- `TrackDetailCard`'s Play Now / Add to Queue / Include in current mood
  each produce the exact outcome the label promises (Play Now doesn't
  silently queue instead of playing, Add to Queue doesn't interrupt
  what's already playing) — verify against `AudioPlayer.playSingle`/
  `appendToQueue`/`insertNext`'s actual documented behavior, not assumed
  behavior.
- "Include in current mood" is hidden (not shown disabled) when no mood
  query is active, per §3.6 — confirm this rather than assume it, since
  showing a mood action with no mood context would be confusing.
- Every tap site `TrackDetailCard` was wired into (Listen tab first, then
  My Music/search results if that follow-up pass happened) shows the
  card and no longer calls `play(tracks:startAt:source:)` directly on
  tap — grep for remaining direct-play-on-tap call sites the same way
  this plan's own research did, to confirm none were missed.
- "Include in current mood" calls `addMoreLike(_:)`, never
  `moreLikeThis(trackID:)` — confirm by checking that selecting it while
  a mood query is active leaves the prompt text and selected pills
  unchanged (§3.6's audit note: `moreLikeThis` would silently replace
  the whole query instead of adding to it).
- An artist row's tap lands on the exact artist tapped, on a fresh
  `appState.pendingArtistFilter`-style handoff — not a stale value left
  over from a previous tap (same one-shot-clear discipline
  `pendingTransitionLabSet`/`soundSearchReference` already follow: cleared
  immediately after being consumed, per §3.5's audit note).
- `MyMusicView`'s `NavigationStack` actually uses a bound `path:` now
  (§3.5's second audit note) — and normal user-driven taps into
  Playlists/artists/albums/songs still work exactly as before; converting
  to a bound path is a real behavior change to `NavigationStack` itself,
  not a no-op, so regression-check ordinary navigation there too, not
  just the new pending-filter path.
- `Sources/DJ/Features/VibeSearch/` was actually resolved one way or the
  other (deleted, or reduced to just the extracted `SuggestionChips`
  utility) — not left sitting as a second, still-dead, still-orphaned
  implementation of the same idea now that a third (this plan's) exists.
- The Listen tab's mood view model was built via a new, non-memoizing
  `DiscoveryRuntimeController` accessor (§5 step 5) — not via
  `searchViewModel(...)` — and selecting mood pills on the Listen tab
  provably does not change anything visible on the "Find by sound" screen
  (and vice versa) when both are open in the same session.
- `QueueSource` gained a `.mood(...)` case (or equivalent), set when
  "Play" starts a mood queue; `TrackDetailCard`'s "Include in current
  mood" option correctly shows/hides based on `AudioPlayer.shared.
  queueSource` from **every** wired call site, not just from within the
  Listen tab's own view.

## 8. Post-implementation audit (5th pass overall)

Implemented in full (commit `69f09c7`) and re-verified against every item in
§7's checklist and every one of §5's 15 steps directly against the merged
code, not just against this plan's description of it. Two real gaps found
and fixed in a follow-up commit (`b2921a9`) before this pass closed out:

- **§3.1 point 5 ("Update upcoming" vs. "Play now") was not implemented at
  all in the first pass** — `startMoodPlayback()` always called
  `player.play(tracks:startAt:0,...)`, which restarts from track 0 even if
  a mood queue from the same view model is already playing. Fixed by adding
  `AudioPlayer.updateUpcoming(with:source:)` (truncates the queue after the
  current index and appends the fresh results, via the existing
  `QueueEditor`/`applyQueueEdit` machinery — no new playback engine code),
  used by both "Play" and "Shake it up" whenever `player.queueSource` is
  already `.mood(thisModel)` and playback is active.
- **§3.6's "Consider also surfacing `insertNext(row)` ('Play Next')...
  users may rely on the distinction" was dropped in the first pass** —
  `TrackDetailCard` only had Play Now/Add to Queue. Restored as a third
  action between them, wired to the existing `insertNext(_:)`.

Every other checklist item verified by direct code read, not assumption:
independent `DiscoverySearchViewModel` instances (`makeSearchViewModel`
non-memoizing, confirmed no call site uses the memoized `searchViewModel`
for the Listen tab); Keep Playing's `.mood` extension branch sits behind the
same `keepPlayingEnabled` gate as every other source (`maybeExtendKeepPlayingQueue`'s
`KeepPlayingPicker.shouldAttemptExtension` check runs before the branch is
ever reached, so disabling Keep Playing globally silently disables the mood
continuation too, not a disclosed exception); Top 10 Songs/Artists read
`rankLimit: 10` end to end; every Listen-tab track-tap site (Jump Back In,
Favorites, mood results, Top 10 Songs) sets `selectedTrackForDetail` instead
of calling `player.play(...)` directly (grepped for remaining direct-tap-
play call sites — the only one left is the Play/Shake-it-up CTA itself,
which is supposed to call play); "Include in current mood" calls
`moodSource.addPositiveTerm(_:)` → `addMoreLike(_:)`, never
`moreLikeThis(trackID:)`; it renders only when `player.queueSource` is
`.mood`, hidden not disabled; `pendingArtistFilter` is a one-shot `@Published
String?` cleared immediately on consumption in `MyMusicView`, matching
`pendingTransitionLabSet`/`soundSearchReference`; `MyMusicView`'s
`NavigationStack` takes a bound `NavigationPath` and ordinary
Playlists/Artists/Albums/Songs/Genres taps were unaffected (full
`xcodebuild build` + `swift test` — 1568/1568 — passed after the
conversion); `VibeSearch` and the DJ-module `LibraryView`/`LibraryModel`
were deleted outright (not left half-orphaned), with the one reusable piece
(`SuggestionChips`/`LibraryDescriptorSummary`) extracted to
`Sources/Domain/SuggestionChips.swift` and re-covered by
`Tests/SuggestionChipsTests.swift`.

**Not verifiable by static audit** (§7's own item 2 flags this — "a real
qualitative check, not just 'it compiles'"): whether mood query results
actually differ meaningfully pill-to-pill on a real library, and the full
on-device/simulator pass §5 step 15 calls for (playing a mood query end-to-
end, opening a detail card from every wired entry point, confirming Top 10
lists jump correctly). Both remain open until exercised on a real device or
simulator with a real library — do that before relying on this feature
being *good*, as opposed to merely correct by inspection.

Extending `TrackDetailCard` to My Music (`LibraryView`) and search results
(`DiscoverySearchView`) remains correctly deferred per §3.6's own scope
note — confirmed not silently done, not silently forgotten: neither file
was touched by this implementation.
