# Platterhead Watch — redesign spec

Status: implemented 2026-10-01 (see §8 for the two deviations and the one blocked item). Mockups: [`mockups/index.html`](mockups/index.html), which are normative for
hierarchy, sizes, copy and states (not pixel-exact). This spec sits on top of
[`../watch-rearchitecture/`](../watch-rearchitecture/): the sync/protocol architecture there stands, and this replaces
its watch UI layer (W1–W12 screens).

The same **Watch Listening Kit** (§3) is specified in Voxglass at `parso-voxglass/docs/plans/watch-redesign/DESIGN.md`. Only the
accent colour and the domain screens differ, so build fixes and polish in one app port straight to the other.

## 1. What's wrong today (from code review + owner device report, 2026-09-30)

| # | Problem | Where |
|---|---|---|
| 1 | Watch playback is silent with AirPods connected. Fixes in `980b90f` surface the stall code; root cause still open | `AVPlayerOutput.swift` |
| 2 | Music started on the iPhone doesn't show on the watch unless the watch started it (target only flips on a watch-initiated play) | `WatchRootView.swift` `WatchNowPlayingChip.current`, `WatchAppAssembly.playOnPhone` |
| 3 | The same tap plays on the watch in one list and on the iPhone in another, with nothing saying which | `WatchSearchView.activate`, `WatchPhoneCollectionView`, `WatchPlaylistDetailView` |
| 4 | Now Playing is a scrolling sheet with "Close"; the Crown both scrolls and sets volume; transport is 26 pt bare glyphs; debug text on top in DEBUG | `WatchNowPlayingView.swift` |
| 5 | "No results" for every search; connected/offline scope and phone timeouts aren't distinguished in copy | `WatchSearchPresenter`, `WatchSearchView` |
| 6 | "Your iPhone isn't reachable" while the phone is nearby: `chrome.banner`, search mode and `model.phoneReachable` come from different signals and can disagree | `WatchConnectivityObservers.swift` (`WatchChromeObserver.didNegotiate` sets search `.connected` without touching `phoneReachable`) |
| 7 | Carousel list style everywhere (watchOS 6 look, a11y-tree problems); no artwork in lists; Downloads → Playlists/Albums/Tracks/Storage maze | all list views |
| 8 | No volume or artwork for iPhone playback | `WatchNowPlayingView.remoteBody` uses `artwork(nil)` |

## 2. Principles

1. **Now Playing is the app.** Home leads with it, and it's one fixed, glanceable screen.
2. **Always say where the audio is.** Every play control and the Now Playing chip name the destination: *iPhone* or
   *Apple Watch · <output name>*. Switching is a named, deliberate action (owner's §7.1 rule, kept).
3. **Honest states only.** A pause icon appears only after audio is confirmed (`timeControlStatus == .playing` and a
   moving clock, per `980b90f`). Any failure becomes a Problem Card: what failed, what to do, one button, and the code.
4. **Three taps to music** from a wrist raise: Home → list → song.
5. **One layout, two scopes.** With the phone away, the same four doors show what's on the watch. The user never
   learns a second app.
6. **Crown = volume on Now Playing, scroll everywhere else.** Never both on one screen.

## 3. Watch Listening Kit (shared with Voxglass)

SwiftUI components. Put them in `WatchApp/Views/Kit/`, one file each, in the app's existing style.

| Component | Spec |
|---|---|
| `NowPlayingScaffold` | Full-screen, non-scrolling `VStack`: `TargetChip`, title (`.headline`, 1 line, 2 at AX sizes), subtitle (`.footnote`, secondary), `ProgressHairline`, times, transport, `.toolbar(.bottomBar)` with 3 `ToolButton`s. Background is a `RadialGradient` from two artwork colours (falling back to the accent), cross-fading over 0.35 s. `.digitalCrownRotation` → volume, with the system volume indicator. `.handGestureShortcut(.primaryAction)` on play/pause. |
| `TransportButton` | Circle. Play/pause 58 pt, filled `.primary`, black glyph. Side buttons 44 pt on `white.opacity(0.08)`. States: normal, busy (`ProgressView` in place of the glyph, never a pause icon), disabled (35 % opacity). Haptic `.click`. |
| `TargetChip` | 20 pt capsule: SF Symbol (`iphone` / `applewatch`) + "iPhone" or "Apple Watch · AirPods Pro" (route name from `AVAudioSession.currentRoute.outputs.first?.portName`). Variants: neutral, `.warn` (target unreachable), `.bad`. |
| `ProgressHairline` | 3 pt capsule track; read-only (no scrubbing on watch); times underneath, `.monospacedDigit()`. |
| `ProblemCard` | Replaces the transport *in place*, keeping title and progress. SF Symbol, title (`.headline`), one sentence, 1–2 `ActionPill`s, the code in `.caption2.monospaced()` secondary. Haptic `.failure` once on appear. a11y id `watch.now.problem`, code id `watch.now.errorCode`. |
| `ActionPill` | 40 pt capsule (34 pt small). `.primary` uses the accent background with dark text; secondary uses `surface2`. Never an unstyled list row pretending to be a button. |
| `StatusChip` | Connection or scope state in words with a dot: `iPhone connected` (good), `iPhone not nearby` (warn), `Update Platterhead on iPhone` (bad). Shown at the end of the Home list, or at the top only while it changes scope. |
| `ArtTile` | Rounded-rect artwork thumbnail, 28/32/38 pt, gradient placeholder from the accent. |
| `TransferRing` | 22 pt conic ring with real byte fraction, or an indeterminate spinner before the first byte. |
| `HomeHero` | Mini-player card: `ArtTile` 38, title/artist, `TargetChip` (compact), hairline, 32 pt play/pause. Whole card → Now Playing. |

**Tokens.** Platterhead accent `#E3A44B` (brass) on pure black. Surfaces `#1C1F24` and `#2A2E35`. Success `#4CD471`,
warn `#FFCC5C`, bad `#FF6B5E`. Use semantic `Font` styles only (keep `WatchTypography`, extend it); no fixed point
sizes except artwork and the button diameters above.

## 4. Information architecture

```
Home (NavigationStack root, inset-grouped List, no carousel)
├─ HomeHero  ── shown while anything plays on either target ──▶ Now Playing (pushed page)
├─ Search                ▶ dictation-first search (Q1/Q2)
├─ Playlists             ▶ list ▶ collection (T1 header + B2 songs)
├─ Albums                ▶ grid-ish list ▶ collection
├─ On This Watch         ▶ downloads + active transfers + storage + diagnostics (D1/D2)
└─ StatusChip
Now Playing ── toolbar: Output (system route picker) · Up Next · More (target switch, download, shuffle/repeat, go to album)
```

- **Now Playing becomes a pushed `navigationDestination`**, not a `.sheet`. Keep `WatchPlayer.isShowingNowPlaying` as
  the trigger, but drive a `NavigationPath` append on the root stack. The old comment says external path mutation
  was unreliable; verify on watchOS 26 first, and if it's still unreliable keep the sheet but make it full-screen with
  no Close button (`.toolbar(.hidden)`, swipe-down to dismiss).
- **The hero follows playback on either device.** Compute it from "is anything playing": prefer the local engine if
  `player.isPlaying`, else the remote snapshot if the phone `isPlaying`, else the most recent of the two. *Don't*
  switch `coordinator.target` silently: the hero shows the phone's playback, and its transport addresses the phone,
  because that's the engine that's playing. That fixes problem 2 without breaking the "target only changes by user
  action" rule.

## 5. Screens

IDs match the mockup sections. Existing accessibility identifiers are kept wherever a screen keeps its role
(`watch.root`, `watch.search`, `watch.playlists`, `watch.downloads`, `watch.nowPlaying`, `watch.now.*`,
`watch.collection.playPhone`, `watch.collection.playLocal`, `watch.track.<id>`). New ones are listed per screen.

- **H1–H4 Home.** Four doors in fixed order. H4 empty state ends in an action. New: `watch.home.hero`, `watch.status`.
- **N1/N2 Now Playing.** Same scaffold for both targets. N2 needs: remote volume (§6.1) and artwork colours (§6.2).
  Remove the `#if DEBUG` debug block from the visible layout; move it behind a `WATCH_DEBUG_OVERLAY` launch argument,
  so the UI smoke tests that read `watch.now.debug*` still pass.
- **N3 More.** Rows: *Play on iPhone / Play on Apple Watch* (the other target, with the reason if impossible),
  *Download to Watch* (with `TransferRing`), Shuffle and Repeat as two `ActionPill`s, *Go to Album*.
- **N4 Up Next.** Section header "Playing from <collection> · on <target>". iPhone-only rows stay visible with a
  note.
- **T1 Collection header.** Primary `ActionPill` = remembered target ("Play on iPhone" or "Play"). Secondary pills:
  Shuffle, and the other target with its availability ("18 of 32 on watch"). Replaces the three list-row buttons.
- **T2 Target choice.** First play of an item that both targets can play, with no stored preference. Persist in
  `WatchPlaybackTargetStore`.
- **T3 Hand-off.** Tapping play pushes Now Playing immediately in a "Starting on iPhone…" state until the reply or
  snapshot. `980b90f` already routes failures to S4.
- **S1–S5 Problem Cards.** S1 only for `activationRejected`; Choose Output calls `requestRoute()` and shows busy
  until it returns. S2 for `stalled-*`, `itemReadinessTimeout` and `item-*`. S3 is the busy transport plus a step
  label from `playbackPhase` (`activating`, `loading`, `ready`). S4 is the final form of the "iPhone Didn't Start"
  card from `980b90f`, adding the "play N downloaded songs here" alternative when `locallyAvailableTrackIDs` isn't
  empty. S5 restyles the existing continue-on-watch card.
- **B1–B3 Browse.** Inset-grouped, `ArtTile` per row, one location glyph. Swipe (see §8) on a song:
  Play on iPhone / Play on Watch / Download to Watch / Go to Album. This replaces the "Manage on iPhone" alert in
  `WatchPhoneCollectionView`; the existing `requestDownloadToThisWatch` already covers single tracks.
- **Q1/Q2 Search.** The field opens dictation on appear (`.searchable`, or `TextField` with
  `.textInputSuggestions`). Group results by `WatchResultKind`. The field hint and the empty-state copy name the
  scope and the reason (`.unreachable` → "Your iPhone isn't reachable, so only the N downloaded songs were
  searched." plus *Try iPhone Again*).
- **D1/D2 On This Watch.** Active transfers first, with a specific waiting reason (needs the phone's existing
  download status; add a `waitingReason` field if the snapshot lacks it), plus Pause and Stop on the same surface.
  Then downloaded collections, storage bar, diagnostics summary, Remove All.
- **A1 Always On.** `@Environment(\.isLuminanceReduced)`: hide transport and toolbar, freeze the hairline, elapsed via
  `TimelineView(.everyMinute)`.
- **A2 Smart Stack.** New watch widget extension target (`project.yml` + `make project`), `.accessoryRectangular`, and
  a `Button(intent:)` using the existing `WatchPlaybackIntents`.
- **A3 Accessibility.** At `dynamicTypeSize >= .accessibility1`: hide subtitle and times, title gets 2 lines,
  transport keeps its minimum sizes. VoiceOver label for the chip: "Playing on Apple Watch through AirPods Pro".

## 6. Data and protocol needs

1. **Remote volume.** Add `WatchPlayCommand` action `.setVolume(Float)`. An iOS app can't set the system
   volume programmatically, so the phone sets its player's volume, and N2 shows *app* volume. **Open question for the owner:** is app-level volume acceptable on the iPhone target? If not, drop
   Crown volume on N2 and show "Use iPhone volume buttons" once.
2. **Artwork colours for remote playback.** Add two optional hex colours (`artPrimary`, `artSecondary`) to
   `WatchPhonePlaybackSnapshot`, computed on the phone from the artwork the iPhone already has. That's cheaper than
   sending images. Local playback computes them from `player.artwork`.
3. **Output name.** Local only: `AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName`, refreshed on
   `routeChangeNotification`.
4. **One reachability truth.** `WatchChromeObserver` and `WatchReachabilityObserver` must derive `phoneReachable`, the
   banner and the search mode from the same `WatchConnectivityState`. `didNegotiate` must set `phoneReachable = true`
   too. Add a host test in `TonearmWatchCore` that every observer callback leaves the three in agreement.

## 7. Build order (one commit each, on `main`)

0. **Find the audio root cause first.** With `980b90f` installed, the owner reads the `stalled-…` / `activation…`
   code off the watch. Fix that before any visual work; a beautiful silent player is still broken.
1. Reachability single source (§6.4) and the hero following either engine (§4). Mostly logic; host tests.
2. Kit components (§3) with SwiftUI previews; no screen changes yet.
3. Now Playing on the scaffold (N1, N2 local parts, S1–S3, A1, A3); pushed instead of a sheet; debug overlay
   behind a flag.
4. Problem Cards S4/S5 and the hand-off state T3.
5. Home (H1–H4) and the list restyle (B1, B2), carousel removed.
6. Target model in the UI (T1, T2, N3) and context menus (B3).
7. Search (Q1, Q2).
8. On This Watch (D1, D2).
9. Protocol additions (§6.1, §6.2) and N2 remote volume and colours, with protocol tests on both sides.
10. Smart Stack widget (A2).

Each commit: `swift test` (the hook), then build `TonearmWatch` with
`-destination 'generic/platform=watchOS Simulator'` and `Tonearm` with
`-destination 'generic/platform=iOS Simulator'`, sequentially, per CLAUDE.md. The watch UI smoke test
(`TonearmWatchUITests`) must stay green; update it when a screen's structure changes, without dropping assertions.

## 8. Implementation notes (2026-10-01)

- **B3 is a swipe, not a long-press.** `contextMenu` is deprecated on watchOS (and this repo is
  warning-free), so per-song actions (Play on Watch / Download to Watch / Play on iPhone / Go to
  Album) are trailing `swipeActions` on each row.
- **Output (⇄) opens the system `NowPlayingView`.** watchOS has no route-picker view (AVKit's is
  unavailable); the system Now Playing's AirPlay button switches output for whichever device plays.
  When no route exists at all, S1's *Choose Output* re-activates the session, which presents the
  system picker.
- **A2 Smart Stack widget is blocked on signing, not code.** Every extension here ships with a
  manual App Store profile and a CI secret. A watch widget extension needs a new App ID
  (`guru.parso.tonearm.watchkitapp.widgets`), an App Store provisioning profile named e.g.
  "Platterhead Watch Widgets Profile", and a `WATCH_WIDGETS_PROVISIONING_PROFILE_BASE64` secret
  before the target can be added without breaking the TestFlight job. Until then the system Smart
  Stack's Now Playing widget (fed by `MPNowPlayingInfoCenter`, which the watch already publishes)
  provides wrist-down control.
- **Audio root cause candidate.** `AVPlayerOutput` now sets `automaticallyWaitsToMinimizeStalling =
  false`: every watch item is a local file, and the waiting behaviour matches the on-device
  `stalled-*` symptom. Confirm on device with the Problem Card code.
- **Remote volume** is the phone player's own level (`AudioPlayer.outputLevel`, which crossfades
  respect); iOS has no public system-volume setter.

## 9. Acceptance (owner checks on device)

- From a wrist raise, a downloaded playlist starts playing through AirPods in ≤ 3 taps, and you hear it.
- Music started on the iPhone appears in the Home hero within 2 s of opening the watch app, and pause works.
- Every play control names its destination; nothing ever plays on a device you didn't expect.
- Pulling AirPods out, or walking away from the phone, produces a Problem Card with an action, never a frozen
  pause icon.
- Search with the phone away says it searched the watch only; with the phone nearby it finds iPhone songs.
- VoiceOver can operate Home → playlist → play → pause → Up Next without sighted help.
