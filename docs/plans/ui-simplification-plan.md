# UI Simplification Plan

Status: **implemented** (items 1, 2, 3, 4, 5, 6 below), in the commit
following the pre-commit hook change / README update / remote-node backfill
fix.

## Goal

Keep all existing functionality; reduce what's visible in the main flow by
hiding/offloading rarely-used or one-time-setup surfaces behind progressive
disclosure, so the app reads as seamless and streamlined rather than a flat
stack of equally-weighted controls.

## Findings (ranked by impact vs. effort)

1. **Settings is a flat ~13-card stack, no grouping.** `SettingsView` renders
   Music Libraries, Cache, Behavior, Keep Playing, Watch, Tools, Jamendo,
   Sync, Clear Cache, Custom Artwork, Privacy, Supporter, About all as
   equal-weight top-level cards in one scroll.
   **Change:** group into 3–4 sections (Playback, Library & Storage,
   Account/About) with disclosure; collapse low-frequency items (Jamendo key,
   Clear Cache, Custom Artwork, third-party notices) under a single
   "Advanced" expandable section.
   **Preserves:** every setting — just re-tiered by frequency of use.
   Impact: high. Effort: low.

2. **Cache management exposes raw byte-preset buttons + custom MB entry
   inline, always visible.** Four preset buttons + custom button + an
   alert-based numeric entry sit on the main Settings scroll for a
   set-it-once-and-forget-it value.
   **Change:** collapse to one summary row ("Streaming Cache: 2 GB · 640 MB
   used") that opens a small sheet for adjustment.
   Impact: medium. Effort: low.

3. **Transition Lab's two-track picker is fully manual for the common
   single-pair case.** Every session starts with two empty "Choose…" slots
   requiring two sheet round-trips, even though the dominant real path
   ("Practice transitions" from a playlist) is already streamlined via Set
   Practice.
   **Change:** default the outgoing slot to Now Playing / the last-played
   track when Transition Lab is opened without a seed, cutting one picker
   interaction for the common case.
   **Preserves:** manual override via the existing picker button.
   Impact: medium. Effort: medium.

4. **My Music's Music/Playlists segmented picker stacks a second scope layer
   on top of `LibraryView`'s own internal Artists/Albums/Songs/Genres
   picker.** Already flagged in `MyMusicView`'s own doc comment as "a
   pragmatic first cut."
   **Change:** flatten My Music into one unified scope bar (Music /
   Playlists / Artists / Albums / Songs / Genres, however the merge reads
   best) removing a full layer of navigation chrome.
   **Preserves:** every browse mode, just one picker instead of two nested
   ones.
   Impact: medium. Effort: medium.

5. **`PlaylistDetailView`'s overflow menu mixes frequent and rare actions
   un-tiered.** Rename, Download All, Download All to Watch, Remove All from
   Watch, and Practice Transitions sit as flat menu items.
   **Change:** nest the two Watch-related bulk actions under an "Apple
   Watch" submenu.
   Impact: low. Effort: low.

6. **Leftover Pro-era scaffolding still visible.** `ProToolsView` sheet is
   still named "Tools" with no Pro framing left; About row still shows
   literal "Platterhead 0.1" version text.
   **Change:** naming/copy pass now that Pro is fully gone. No functional
   change needed, but stale naming reads as unfinished.
   Impact: low. Effort: low.

7. **Tab bar (4 tabs: Listen / My Music / DJ / Settings) is already at the
   plan's target minimal state.** No further tab-level cuts recommended.

## Non-goals

- No feature removal — every setting, action, and browse mode listed above
  stays reachable, just relocated or behind one extra tap.
- No change to the DJ/Transition Lab flow beyond item 3's smart default.

## Implementation notes for the follow-up commit

- Items 1, 2, 5, 6 are self-contained SwiftUI restructuring in
  `SettingsView.swift` and `PlaylistsView.swift` — no data model changes.
- Item 3 touches `TransitionLabTabView.swift`'s pending-seed consumption path
  (`consumePendingSeed`) — needs a fallback that reads "now playing" or most
  recently played track from `AppState`/`LibraryStore` when no explicit seed
  was set.
- Item 4 is the largest: requires reconciling `LibraryView`'s internal scope
  enum with `MyMusicView`'s top-level Music/Playlists picker into one control
  — do this last, after 1/2/5/6/3 are done and tested, since it's the one
  with real layout/navigation-stack risk.
- After implementing, manually verify Settings, My Music, and Transition Lab
  each still reach every previously-reachable action and setting — this is a
  visibility/grouping change, not a deletion, so nothing should become
  actually unreachable.
