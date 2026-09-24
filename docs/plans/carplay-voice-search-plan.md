# CarPlay voice search — plan

## Why this exists

`CPSearchTemplate` was removed (`e3ae1a5`) after three real TestFlight crashes: Apple's own
CarPlay App Programming Guide (the per-category template-support matrix) confirms Search is not
in the supported-template set for the Audio app category at all — a hard platform restriction,
not a bug. The real report behind all of this was: *"it's hard to scroll through everything in
the car — I need voice search."* This plan replaces the impossible on-screen search UI with the
approach Apple actually documents for audio apps: **Siri**, via the CarPlay assistant cell and
`INPlayMediaIntent`-class App Intents — not `CPSearchTemplate`.

## What's already there (verified by reading the real code, not assumed)

`Sources/Intents/TonearmAppIntents.swift` + `IntentResolver.swift` already implement real,
working Siri Shortcuts: `TonearmPlayPlaylistIntent`, `TonearmPlayArtistIntent`,
`TonearmResumeIntent`, `TonearmSleepTimerIntent`, `TonearmAddSourceIntent`, registered via
`TonearmShortcutsProvider: AppShortcutsProvider` with real phrases ("Play a playlist in
Platterhead"). `IntentResolver` is pure, tested, reusable matching logic (exact → contains →
fuzzy via `StringSimilarity`, with proper ambiguity/no-match failures) — `Tests/
IntentResolverTests.swift` already covers it.

Two real gaps against that existing infrastructure:

1. **No song-level intent at all.** Only playlist and artist can be voice-triggered — the most
   natural request ("play Hotel California") has no path.
2. **Every existing playback intent sets `openAppWhenRun = true`.** Confirmed via a real Apple
   Developer Forums thread (`developer.apple.com/forums/thread/709496`): a custom App Intent that
   tries to bring the app to the foreground (`.continueInApp` / `openAppWhenRun = true`) is
   **blocked entirely while CarPlay is active** — Siri answers "Sorry, I can't do that while
   you're driving" and the intent never runs. This almost certainly means none of the five
   existing intents work over Siri while connected to CarPlay today, independent of anything in
   this plan — a real, pre-existing bug this plan also fixes.

## What does NOT apply here

- **`AssistantSchemas`/`AudioSearch`/`IntentValueQuery` audio entities** (the "modern" approach
  ChatGPT's advice centered on) — verified directly against Apple's own docs
  (`developer.apple.com/documentation/MediaIntents/AudioSearch`): **introduced in iOS 27**, which
  does not exist on any real device yet (the crash logs this session are all iOS 18.7.1). Not
  usable now; worth revisiting once iOS 27 has real adoption, not part of this plan.
- **A separate Intents App Extension** — not needed. `TonearmAppIntents.swift` already lives in
  the main app target (confirmed: no Intents extension target in `project.yml`), which is
  correct for the modern `AppIntents` framework — these run in-process, with live access to
  `AudioPlayer.shared`, not in a sandboxed satellite process the way legacy `Intents.framework`
  extensions did.

## Design

### 1. `TonearmPlaySongIntent` (new)

Mirrors `TonearmPlayArtistIntent`'s shape exactly:

```swift
public struct TonearmPlaySongIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play Song"
    public static let openAppWhenRun = false   // see §2

    @Parameter(title: "Song")
    public var songTitle: String
    @Parameter(title: "Artist", default: nil)
    public var artistName: String?

    public func perform() async throws -> some IntentResult & ProvidesDialog { ... }
}
```

`IntentResolver.resolveSong(title:artist:tracks:)` reuses the existing `match()` machinery:
filter candidates to the given artist first when one was spoken (narrows ambiguity — "play
Yesterday by the Beatles" vs. just "play Yesterday"), then run the same exact → contains → fuzzy
pipeline already proven for playlist/artist. New `TargetKind.song` case, new `Command.playSong`
case, new candidate struct carrying `trackId`/`title`/`artist` (enough to build a `TrackRow`
queue of one via `LibraryStore.shared.trackRow(id:)`).

Registered in `TonearmShortcutsProvider` with real phrases: "Play \(.applicationName)",
`\(\.$songTitle)` interpolated per Apple's `AppShortcut` phrase grammar — "Play
\(\.$songTitle) in \(.applicationName)".

### 2. Make every playback-triggering intent driving-safe

`TonearmPlayPlaylistIntent`, `TonearmPlayArtistIntent`, `TonearmPlaySongIntent`,
`TonearmResumeIntent` all change `openAppWhenRun` to `false` and conform their result to
`ProvidesDialog`, returning a spoken confirmation ("Playing Hotel California by the Eagles") —
the intent starts playback directly against the live `AudioPlayer.shared` singleton without ever
needing the phone screen, which is both the fix for the driving-mode block above and simply
better UX at rest too (Music.app/Spotify's own Siri integration doesn't bounce you to the app
either). `TonearmSleepTimerIntent`/`TonearmAddSourceIntent` are left as `openAppWhenRun = true` —
setting up a new remote source by voice while driving isn't a real scenario worth chasing, and
`addSource` needs the on-screen preview/confirmation flow already built for it.

### 3. `CPAssistantCellConfiguration` in the CarPlay tab templates

Real, current, Apple-documented API for exactly this (`CPListTemplate.h`, iOS 15+, "only
supported by CarPlay Audio and Communication apps" — our exact category). Adds a real "Ask Siri"
row at the top of the Playlists/Library/More list templates
(`CPAssistantCellPosition.top`, `.always` visibility, `CPAssistantCellActionType.playMedia`) — an
on-screen affordance alongside the always-available physical "Hey Siri"/voice button, matching
what Apple's own guide shows as the audio-app-supported alternative to Search.

## Non-goals

- Free-text on-screen search — categorically impossible for this app category (already the
  reason `CPSearchTemplate` was removed).
- "Play more like this" / mood queries by voice — real feature, real scope, not part of this
  pass; the intents above cover the concrete "play song/artist/playlist X" requests from the
  original report.

## Testing

- `IntentResolverTests`: new cases mirroring the existing playlist/artist coverage —
  exact/contains/fuzzy match, empty-library, no-match, ambiguous, and the artist-narrows-ambiguity
  case specific to song resolution.
- Real `xcodebuild` for the `Tonearm` (iOS) scheme — `AppIntents`/`CarPlay` symbols aren't part of
  the SwiftPM `TonearmCore` target, so `swift test` alone won't catch a build break here.
- Full `swift test` for the resolver logic itself (host-testable, no device needed).

## Audit checklist (run after implementation, before commit)

- [ ] `TonearmPlaySongIntent` exists, registered in `TonearmShortcutsProvider` with a real phrase.
- [ ] `IntentResolver.resolveSong` has real test coverage matching the playlist/artist pattern.
- [ ] Every playback-starting intent (playlist/artist/song/resume) has `openAppWhenRun = false`
      and a spoken `ProvidesDialog` confirmation.
- [ ] `CPAssistantCellConfiguration` is wired into all three CarPlay tab templates
      (Playlists/Library/More), not just one.
- [ ] `swift test` passes in full.
- [ ] Real `xcodebuild` for `Tonearm` (iOS) succeeds.
- [ ] No leftover references to the removed `CPSearchTemplate`/`CarPlaySearchDelegate`.
