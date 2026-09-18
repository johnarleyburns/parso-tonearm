# Mood-Based Listening — Listen Tab Redesign Plan

Status: **planned, not implemented**. Written for an agentic coding session
to pick up and execute in full; every referenced type/file below was
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
a song row opens its detail card (§3.6); tapping an artist row navigates
to that artist's track list (reuse whatever `LibraryView`'s own artist
drill-down UI already is, rather than building a new screen).

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
  query is active (§3.1–3.3). Adds the track as a positive signal to the
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
- Does not touch the DJ/Transition Lab, My Music, Settings, or CarPlay
  surfaces.

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
   Listen-tab-specific state to the existing view model).
6. Wire "Play" to `AudioPlayer.play(tracks:startAt:source:)` using
   `results.map(\.track)` from the view model.
7. Implement continuous extension per §3.3's flagged design decision —
   read `AudioPlayer`'s Keep Playing implementation fully first.
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
    cross into the My Music tab landed on that specific artist. Consume
    it once in `MyMusicView`/`LibraryView` the same way
    `TransitionLabTabView.consumePendingSeed()` does.
13. Build `TrackDetailCard` (§3.6) as a shared, reusable sheet — artwork/
    title/artist/duration/source plus Play Now / Add to Queue / Include
    in current mood (mood-context only, via `addMoreLike(_:)` — NOT
    `moreLikeThis(trackID:)`, see §3.6's audit note) / Dismiss, wired to
    the existing `playSingle(_:)`/`appendToQueue(_:)`/`insertNext(_:)` on
    `AudioPlayer` — no new playback logic.
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
- No duplicate CLAP model download/load triggered by having two entry
  points (Listen tab's new picker + the existing "Find by sound" screen)
  into the same underlying search — confirm they share the same
  `DiscoveryRuntimeController.shared.searchViewModel(...)`-style
  singleton path rather than each spinning up independent state.
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
- `Sources/DJ/Features/VibeSearch/` was actually resolved one way or the
  other (deleted, or reduced to just the extracted `SuggestionChips`
  utility) — not left sitting as a second, still-dead, still-orphaned
  implementation of the same idea now that a third (this plan's) exists.
