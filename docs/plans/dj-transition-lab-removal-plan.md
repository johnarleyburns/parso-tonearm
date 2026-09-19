# Remove Transition Lab and the DJ tab

Status: **researched, not planned in full / not implemented**. Owner request:
"study removing Transition Lab and the DJ tab entirely as I don't find them
useful." This document captures that research so a future session can turn
it into a full implementation plan without re-deriving it — it is not itself
a step-by-step implementation plan yet.

## 1. What Transition Lab actually does today

The `.dj` tab (`Sources/App/AppState.swift`'s `AppTab`) routes to
`TransitionLabTabView` (`Sources/Features/DJ/TransitionLabTabView.swift`) —
confirmed this session, replacing an earlier belief that the DJ tab was the
auto-playlist beam-search generator (that generator was already dead code,
deleted separately this session: `chore(dj): delete orphaned auto-playlist
generator (beam search)`). Transition Lab lets the user pick two tracks and
get phrase-aware DJ transition suggestions from `TransitionPlanner`, then
preview one — either a single pair, or "Set Practice" (walking a whole
playlist's adjacent pairs), reachable from Playlists via
`appState.pendingTransitionLabSet`.

## 2. Full removal scope

- `Sources/Features/DJ/TransitionLabTabView.swift`
- `Sources/DJ/Features/TransitionLab/` — `TransitionLabModel.swift`,
  `TransitionAnalysisRepository.swift`, `TransitionLabAssetResolver.swift`
- The `.dj` case in `AppTab` (`Sources/App/AppState.swift`), its
  `RootView.swift` routing (`case .dj: TransitionLabTabView()`), and its
  tab-bar entry in `Sources/Features/Chrome/GlassDock.swift`'s `items` array
- `appState.pendingTransitionLabSet` (`AppState.swift`) and its origin call
  site — the "Practice transitions" action in
  `Sources/Features/Playlists/PlaylistsView.swift`
- Matching test files under `Tests/DJTests/` for the above types

## 3. `TonearmDJ` — almost the entire target is already dead

Checked whether anything else in the live app needs `TonearmDJ` for
something unrelated to Transition Lab: **no.** Specifically:

- `GigCrateRepository`/`DJLibraryStore` — the two "live" record types
  (`DJPlaylist`/`DJPlaylistItem`) preserved during this session's earlier
  auto-playlist-generator cleanup (kept because these two types looked used)
  — are, on closer inspection, **never actually constructed anywhere in the
  live app either**. They were dead code from the same DJ-mixer-workspace
  deletion, just not yet noticed. This means essentially nothing under
  `Sources/DJ/` (Analysis, Engine, Stems, Recording, Session, Semantic, Perf
  — roughly 550KB of source) has a live caller once Transition Lab is gone.
- The one real outside dependency: `Sources/App/TonearmApp.swift` calls
  `DJDatabase.defaultDatabaseURL()`/`.mixesDirectory`/`.cachesDirectory` at
  launch to clean up stale DJ cache files. Needs a small decision: keep a
  tiny `DJDatabase` stub just for these paths, or drop the cleanup entirely
  (the cache files just stay on disk — not harmful, just not tidied).
- Two files have a vestigial, unused `import TonearmDJ`:
  `Sources/Features/Sources/AddServerSheet.swift` (or wherever it actually
  lives — re-confirm at implementation time) and `Sources/Features/
  Onboarding/OnboardingView.swift`. Trivial to remove.

**Conclusion: `TonearmDJ` can very likely be deleted almost entirely**, not
just have its tab wiring removed. Confirm this claim fresh at implementation
time (re-run the same "what actually calls this" grep sweep) before deleting
the whole target — this research is current as of this session, but code
moves.

## 4. Database tables

Transition Lab owns `transition_full_analysis` and
`transition_playlist_edge` (via `TransitionAnalysisRepository`), plus
whatever the rest of the already-dead DJ cluster owns (auto_playlist_*,
etc. — some already orphaned from the earlier cleanup this session did).
**Recommendation: leave them as historical schema debt**, matching how this
session already treated the auto-playlist tables when deleting that dead
code — do not write a real drop-table migration. A schema migration that
removes tables is a one-way door or with the DB state; parked tables have
been treated as safely retire-in-place elsewhere in this codebase.

## 5. Scope estimate

Larger than the earlier VibeSearch/auto-playlist-generator cleanups this
session did (an entire tab plus a whole SwiftPM target, not just a few
orphaned files scattered in one directory), but **low-risk**: every piece
traces back to the one `.dj` tab entry point with no surprise live
dependents found. This is mechanical cleanup work, not exploratory
archaeology — the bulk of the real effort is likely in the
`Package.swift`/`project.yml` target-removal bookkeeping and re-running
`make project`, not in untangling hidden couplings.

## 6. Tab-bar consequence (relevant to the Find tab plan)

Removing `.dj` drops the tab bar from 4 tabs to 3: Listen, My Music,
Settings. See `docs/plans/find-tab-plan.md` §3.1 — this is the
recommended trigger for landing the Find tab in the vacated slot, keeping
the tab count at 4 rather than growing it to 5. **Land this removal (or a
firm decision not to) before implementing the Find tab plan**, so that plan
doesn't have to guess which `AppTab` shape to target.

## 7. What this document does not yet cover

This is research, not a step-by-step implementation plan. Before executing,
a real implementation plan should still:

- Re-confirm the file list above against current `main` (code moves).
- Decide the `TonearmApp.swift` DJ-cache-cleanup question (§3) explicitly.
- Decide the exact `AppTab` raw-value/persistence-key bump (mirroring the
  `"lastActiveTab.v1"` → `"v2"` precedent this session already used twice
  for enum-shape changes) — needed regardless of whether Find lands in the
  same pass.
- Spell out the `Package.swift`/`project.yml` target-removal steps
  concretely once someone is actually doing the deletion, since exact
  target/dependency graph details were not re-verified line-by-line here.
