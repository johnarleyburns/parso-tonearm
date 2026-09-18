# CarPlay + Competitor Gap-Closing Plan

Status: **in progress**. Follows the competitor research (Plex/Plexamp,
Apple Music, Spotify) done earlier this session.

## 1. CarPlay — headline item, now unblocked

The `com.apple.developer.carplay-audio` entitlement was pending Apple
approval (README's Roadmap said so explicitly); it's now granted. Verified
before starting: there was **zero** CarPlay code in the repo — no scene
delegate, no entitlement key, nothing. This plan implements a real, working
CarPlay Audio App surface, not a stub.

**Design**: CarPlay is just another surface over the existing playback
engine — no new state, no duplicated Now Playing logic. Now Playing
controls come for free from the app's existing `MPNowPlayingInfoCenter`/
`MPRemoteCommandCenter` wiring (`SystemPlaybackBridge`); CarPlay only needed
a template-based way to *browse* into the same `AudioPlayer.play(tracks:
startAt:source:)` call the phone UI already uses.

**What shipped**:
- `com.apple.developer.carplay-audio` entitlement added to both the Debug
  and Release entitlements files.
- `UISceneConfigurations` → `CPTemplateApplicationSceneSessionRoleApplication`
  scene declaration added (both `project.yml`'s `info.properties` and the
  raw `Sources/App/Info.plist`, since it wasn't obvious ahead of time which
  one XcodeGen's merge favors — redundant, harmless, belt-and-suspenders).
- `CarPlaySceneDelegate` (`CPTemplateApplicationSceneDelegate`): connects/
  disconnects, sets the root template.
- `CarPlayRootBuilder`: a `CPTabBarTemplate` with four tabs (CarPlay caps a
  tab bar at 5, so this doesn't try to mirror the full phone My Music scope
  bar) — Playlists, Artists, Recently Played, Favorites — each a
  `CPListTemplate` reading from `LibraryStore.shared` (an actor; every list
  starts empty and fills in via `updateSections` once its async read
  completes, since CarPlay needs a template synchronously and there's no
  blocking-read escape hatch from an actor). Selecting a playlist/artist
  pushes a leaf track list; selecting a track calls
  `AudioPlayer.shared.play(tracks:startAt:source:)` — the exact same call
  the phone UI's row-tap handlers use.

**Real, disclosed risk**: the Release configuration signs with
`CODE_SIGN_STYLE: Manual` and a named `PROVISIONING_PROFILE_SPECIFIER:
"Platterhead Profile"` (`project.yml`). Adding the entitlement key to the
app's own entitlements file is necessary but not sufficient — the
provisioning profile itself must be regenerated on Apple's side to include
the CarPlay capability, or the TestFlight archive/signing step in CI will
fail. This can only be confirmed by watching the actual CI run after this
lands; if it fails on the archive/export step with an entitlement mismatch,
that's the profile, not the code.

**Not done / explicitly deferred**:
- No CarPlay simulator visual verification was done — Xcode's CarPlay
  Simulator (Simulator app → I/O → External Displays → CarPlay) exists but
  driving it interactively from here wasn't attempted given the session's
  existing headless-GUI limitation (documented earlier this session:
  AppleScript/System Events GUI scripting found zero windows in this
  environment). The build compiles and the template logic was written
  against the confirmed real API (verified by iterating actual compiler
  errors against the CarPlay.swiftmodule in this Xcode install, not
  guessed), but a real device or an interactively-driven CarPlay Simulator
  session is the only way to confirm the visual/interaction result.
- No search, no queue/up-next browsing, no "Now Playing" custom button rail
  beyond what the system template provides by default.

## 2. Playlist pinning (descoped from "folders")

The competitor-research note called this "playlist folders/pinning."
**Descoped to pinning only** — true nested folders is a real data-model
change (a `parentPlaylistId` column, recursive UI, migration) disproportionate
to the request; pinning is a simple, additive, low-risk win that gets most
of the organizational value (surfacing the playlists you actually use) at a
fraction of the cost. Folders remain a documented follow-up if wanted later.

**Design**: a persisted `Set<Int64>` of pinned playlist IDs (new small table
or a settings-style key), pinned playlists sort first in `PlaylistsView`,
with a pin/unpin action in the row's context menu and the detail view's
overflow menu.

## 3. Lyrics translation — descoped after discovering the prerequisite doesn't exist

Checked before building: `SyncedLyrics`/`LRCParser` (`Sources/Domain/
Lyrics.swift`) and `LyricsLookupPolicy` exist and are unit-tested, but have
**zero consumers anywhere in the app** — no network client, no Settings
toggle, no view. The Settings Privacy screen nonetheless claimed lyrics
lookup was a real, working, opt-in feature ("Lyrics lookup and scrobbling
stay off until you enable them; then Platterhead talks only to LRCLIB,
Last.fm, or ListenBrainz for those features") — checked scrobbling too
(`ScrobblePolicy.swift`) and found the identical pattern: policy logic with
no network client and no toggle either.

Adding *translation* on top of a lyrics feature that doesn't actually exist
isn't a small addition — it's "build the whole feature first." That's
bigger than this pass's scope (real network client + caching + a synced-
scroll display view + Settings wiring, on top of the translation piece
itself), and building it now, blind, alongside everything else in this
session risks the same kind of rushed-feature quality this session has
otherwise been careful to avoid.

**What shipped instead**: fixed the Privacy screen's false claim — removed
the sentence describing lyrics lookup and scrobbling as real, reachable
features, since neither actually talks to any network service today. A
privacy disclosure describing aspirational features as current behavior is
a correctness bug in its own right, independent of whether the mood-based-
listening work (a separate, newer research thread) ends up wanting a real
lyrics feature later.

**Follow-up, not done here**: build the actual lyrics feature (LRCLIB
fetch + cache + synced display in Now Playing) if wanted, then add
on-device translation (Apple's `Translation` framework, iOS 17.4+ — no new
network dependency, fits the privacy stance) on top of it.

## 4. AutoMix-style automatic Transition Lab mode — explicitly NOT built this pass

This is the same "live practice loop" the Transition Lab session already
declined to build blind: arming `SmartFader` on a `HeadlessDJEngine` for
real-time automatic mixing has no compile-time safety net for correctness
(buffer underruns, timing drift, crossfade quality) — it needs a real
device to verify, and shipping it unverified risks audibly broken
transitions during actual playback, which is worse than not having the
feature. Kept as a documented follow-up (already tracked in the README's
own Roadmap: "a live Transition Lab practice loop").

## Audit plan

After 1–3 are implemented: full `swift test` + `xcodebuild build` (already
the running verification loop this session), plus a specific re-check that
CarPlay's `LibraryStore` actor calls don't introduce any thread-safety
issue the compiler wouldn't catch on its own (e.g., a `CPListItem` handler
capturing stale state), and that playlist pinning doesn't break any
existing `PlaylistsView` UI test identifier.
