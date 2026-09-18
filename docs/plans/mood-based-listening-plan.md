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
- **Era/Vibe**: (deliberately left open — this category is the one most
  likely to need real catalog data to pick well; consider deriving
  candidate terms from actual genre/tag frequency in a representative
  library rather than hand-picking, during implementation)

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
2. Define `MoodPill` (id, label, queryTerm) and a starter taxonomy per
   §3.2 as a plain data file/array — no UI yet.
3. Build `MoodPillPicker`, a horizontally-scrolling capsule-chip row
   (styled per §3.1 point 3), taking `[MoodPill]` and a `Set<MoodPill.ID>`
   selection binding.
4. Build the prompt bar + pill row + Play CTA as a new section in
   `ListenView`, backed by a small new view-model (or extend
   `DiscoverySearchViewModel` — decide based on how entangled its
   `DiscoverySearchView`-specific state, like `bpmMinText`, is; a
   thin wrapper that composes a `DiscoverySearchViewModel` instance
   configured for text+refinements-only use is likely cleaner than adding
   Listen-tab-specific state to the existing view model).
5. Wire "Play" to `AudioPlayer.play(tracks:startAt:source:)` using the
   view model's current `results`.
6. Implement continuous extension per §3.3's flagged design decision —
   read `AudioPlayer`'s Keep Playing implementation fully first.
7. Implement "Shake it up."
8. Reorder `ListenView`'s existing sections below the new entry point;
   verify nothing becomes unreachable (same verification standard as the
   Settings/My Music simplification pass).
9. Add accessibility identifiers for the new controls (prompt field, each
   pill, Play button, Shake it up) so a future UI test can exercise this
   flow — following this session's `mymusic.scope.*`-style naming
   convention.
10. `swift test` + `xcodebuild build` + a real device/simulator pass
    playing a mood query end-to-end (this cannot be verified by compiling
    alone — actual result relevance needs a real library and real ears).

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
  selection) — a real qualitative check, not just "it compiles."
  Should specifically verify the two Discovery Search score
  components ranked as expected. If not run
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
