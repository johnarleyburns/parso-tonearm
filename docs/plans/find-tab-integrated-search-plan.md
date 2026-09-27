# Find tab — integrated crate search

Status: implementation started; this supersedes the older standalone Find Music mockups.

The current product already has a navigation-shell Find Music screen and a portable sound-search
model. The updated design keeps that model, but makes the screen a crate-building surface: browsing
starts with the whole library, the search field filters metadata immediately, and compact musical
chips expose BPM and Camelot-key constraints without hiding the user's tracks behind a separate
search mode.

## Current design contract

- Use the existing glass/navigation language, current `Palette`, and current `TrackRowView` rather
  than introducing a second library row style.
- The screen opens in browse mode with all tracks, then narrows as the user types. Sound search remains
  available as a mode, but it is opt-in and never replaces browse/search.
- A filter tray contains min/max BPM, Camelot key, compatible-key mode, source, and crate actions.
  Invalid ranges are shown inline; they never silently produce an empty list.
- Every result exposes title, artist, album, BPM, Camelot key, duration, and a one-tap play action.
  A secondary action opens playlist assignment so the track can be added to a crate playlist;
  the existing playlist/Crate surfaces remain the source of truth for crate membership.
- The DJ surface remains the eight-row deck UI. Opening Find from DJ returns to the same deck with
  the chosen track ready to load; assembling a crate never changes playback on its own.
- Key matching uses the existing Camelot wheel semantics: exact key or compatible ±1 number with the
  same A/B letter, plus relative major/minor (A/B) compatibility where the current policy allows it.
- Analysis values come from `discovery_track_analysis` first and cached DJ prep second. Unknown values
  remain `—`; they are not fabricated from title text.
- iOS deployment floor is 27.0 so the current Liquid Glass APIs can be used without compatibility
  branches in the iOS surface.

## Delivery slices

1. Keep the portable filter/search state pure and test BPM range, Camelot normalization, compatible
   keys, empty/unknown metadata, and deterministic result ordering.
2. Add the integrated filter tray and result metadata row to `DiscoverySearchView`, preserving the
   existing sound-search model and browse-first behavior.
3. Add the DJ crate handoff: select a result, return to DJ, and load it into an available deck;
   later persistence can promote this transient selection into a named crate.
4. Feed cached DJ prep into the metadata display and keep the same values available to the eight-row
   waveform readout.
5. Verify Liquid Glass rendering on iOS 27, Dynamic Island safe areas, VoiceOver labels, and the
   existing UI smoke coverage.
