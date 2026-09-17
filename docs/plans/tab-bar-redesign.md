# Tab bar redesign: 6 tabs → 5, plus a real "Your Queue" home module

## Context (read once, don't re-derive)

The owner asked for a tab-bar/home-screen study of Apple Music, Spotify, etc.,
given Platterhead/Tonearm is a **private collection app**, not a streaming
catalog app. The resulting recommendation (mockup published earlier at
`https://claude.ai/artifact/BiqBPK4yH3sG55WEqppU7m`, not needed to implement
this — everything actionable is below) was:

- **5 tabs**: Listen, Find, Library, DJ, Settings (down from the current 6:
  Listen, Playlists, Library, Sources, Settings, DJ).
  - **Listen** — landing tab, unchanged in spirit, gains a "Your Queue" module
    (see Part 3).
  - **Find** — was a search-only sheet; becomes a real tab. Defaults to
    browsing the whole library (already implemented — see "Already done"
    below), search filters on top.
  - **Library** — absorbs **Playlists** as an in-tab destination, not a
    separate tab (there's only one kind of content: the user's own music).
  - **DJ** — unchanged, stays its own tab.
  - **Settings** — absorbs **Sources** ("Libraries" — remote/local connections)
    as an in-tab destination, since it's configured rarely.
- Explicitly **do not** add: a Charts/New Releases/editorial Browse tab, a
  black-box "For You" section, or catalog-first search. Every personalized
  module must say what it's built from.

This plan is meant to be handed to a Sonnet-class coding agent with **no
further research or design input needed** — it should be fully actionable as
written. If something below turns out to be wrong about the current code
(e.g. a file moved), fix the plan's description to match reality and proceed;
don't stop and ask.

### Already done (do not redo)

`Sources/Features/Discovery/DiscoverySearchView.swift`'s idle (no-query) state
already shows the full library via a new `libraryBrowseList` (backed by
`appState.allTracks`, `TrackRowView`, `LazyVStack`) instead of a blank hint.
This is the "Find defaults to browsing your library" behavior — it does not
need to change. What's missing is promoting this screen from a
sheet-only presentation to an actual tab (Part 2 below).

## Part 1 — `AppTab` enum and persistence

`Sources/App/AppState.swift`:

```swift
enum AppTab: Int, CaseIterable {
    case listen, playlists, library, sources, settings, dj
}
```

Change to:

```swift
enum AppTab: Int, CaseIterable {
    case listen, find, library, dj, settings
}
```

(Order here only controls `CaseIterable` iteration, which nothing depends on
today — grep to confirm before assuming — but keep it in tab-bar left-to-right
order for readability.)

**Persistence migration is required, not optional.** The current code persists
`tab.rawValue` (an `Int`) under `UserDefaults` key `"lastActiveTab.v1"` and
restores via `AppTab(rawValue: saved)`. Because raw values are now assigned to
different cases (e.g. old `.sources` was `3`, new `.dj` is `3`), a stale
integer from before this change would silently restore the *wrong* tab after
the app updates — e.g. a user who last had Sources open (rawValue 3) would
silently land on DJ. Fix this by bumping the storage key:

```swift
private static let lastTabKey = "lastActiveTab.v2"
```

Leave the restore logic (`if let saved = ... as? Int, let restored = AppTab(rawValue: saved) { tab = restored }`)
and the `didSet` write otherwise unchanged — just the key string changes. The
old `"lastActiveTab.v1"` value is simply orphaned in `UserDefaults`; no
migration/cleanup of the old key is needed.

## Part 2 — Wire the 5 tabs

### 2a. `Sources/Features/RootView.swift`

Update the `switch appState.tab` in `body`:

```swift
switch appState.tab {
case .listen: ListenView()
case .find: DiscoverySearchView(isTab: true)
case .library: LibraryView()
case .dj: DJHomeView()
case .settings: SettingsView()
}
```

Also update `backgroundLayer`'s switch (currently keys off `.sources` to pick
`Palette.sourcesBackground`). Since Sources is no longer a tab, decide the
background by whichever screen now shows source-management UI. Simplest
correct fix: remove the `.sources` case entirely and always use
`Palette.libraryBackground` for every tab — the "Libraries" screen will now be
a *pushed* destination inside Settings (Part 2d), not a full tab, so it no
longer needs to own the root background:

```swift
private var backgroundLayer: some View {
    Palette.libraryBackground
}
```

(If `Palette.sourcesBackground` becomes unused after this, that's fine — leave
the token defined, don't delete it, in case another screen wants it later.)

### 2b. `Sources/Features/Chrome/GlassDock.swift` — `TabBar`

Replace the `items` array:

```swift
private let items: [(AppTab, String, String)] = [
    (.listen, "play.circle.fill", "Listen"),
    (.find, "magnifyingglass", "Find"),
    (.library, "square.grid.2x2.fill", "Library"),
    (.dj, "slider.horizontal.3", "DJ"),
    (.settings, "gearshape.fill", "Settings")
]
```

(Icon choices: `magnifyingglass` for Find matches the mockup's search-first
framing and is a standard SF Symbol already used elsewhere in the codebase —
grep for `"magnifyingglass"` to confirm no visual collision with an existing
control before finalizing. Everything else keeps its current icon/label.)

No other changes needed in `GlassDock.swift` — `TabBar` only reads `AppTab`
cases generically via the tuple array.

### 2c. Promote `DiscoverySearchView` to a tab

`Sources/Features/Discovery/DiscoverySearchView.swift` is currently only used
as a **sheet** (`appState.showSoundSearch`, presented from `RootView` and from
`LibraryView`'s "sound search" button, and from Now Playing's "More like
this"). As a sheet it shows a "Done" button (`.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }`)
that doesn't make sense as a persistent tab.

Add an `isTab: Bool = false` parameter:

```swift
struct DiscoverySearchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    var isTab: Bool = false

    @State private var model: DiscoverySearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    DiscoverySearchContent(model: model)
                } else {
                    ProgressView("Preparing search…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Find Music")
            .navigationBarTitleDisplayMode(.inline)
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

Every existing call site (`DiscoverySearchView()` used in `.sheet(...)` in
`RootView.swift`, and anywhere else — grep `DiscoverySearchView(` to find all
of them) keeps working unchanged since `isTab` defaults to `false`. Only the
new `RootView` tab-switch call passes `isTab: true`.

One more thing to check: `DiscoverySearchView` wraps itself in its own
`NavigationStack`. Since it's now a top-level tab (siblings: `ListenView`,
`LibraryView`, etc. — none of which wrap themselves in `NavigationStack`
except `LibraryView` via its own `ownsNavigationStack` flag), this is fine and
matches the existing pattern of "each tab root owns its own stack unless it
needs to nest under DJ."

### 2d. Fold Sources into Settings

Goal: remove `.sources` as a tab, but keep `SourcesView` and everything it
already does (Jamendo entry, personal libraries list, `NavigationLink`s to
`SourceDetailView` / `JamendoBrowseView`) — just reachable as a pushed
destination from Settings instead of a tab.

1. In `Sources/Features/Settings/SettingsView.swift`, find the top-level
   `List`/`ScrollView` section structure (read the file — it's 601 lines, so
   locate the existing section grouping first) and add a new row, e.g. inside
   whatever section groups configuration/connections:

   ```swift
   NavigationLink {
       SourcesView()
   } label: {
       Label("Libraries", systemImage: "cloud.fill")
   }
   .accessibilityIdentifier("Settings Libraries")
   ```

   Adjust to match whatever row style `SettingsView` already uses for its
   other rows (don't introduce a new row-styling pattern — copy an existing
   row's exact modifiers/spacing).

2. `SourcesView.swift` currently wraps itself in its own `NavigationStack`:

   ```swift
   var body: some View {
       NavigationStack {
           ScrollView { ... }
           .navigationDestination(for: Source.self) { ... }
           .navigationDestination(for: LibraryService.self) { ... }
           .toolbar(.hidden, for: .navigationBar)
       }
   }
   ```

   Pushed onto `SettingsView`'s own `NavigationStack` (check whether
   `SettingsView` owns one — if it does, a nested `NavigationStack` inside a
   pushed destination breaks the push/pop chain, same issue already solved for
   `LibraryView` via `ownsNavigationStack`). Apply the same fix: add an
   `ownsNavigationStack: Bool = true` parameter to `SourcesView`, matching
   `LibraryView`'s existing pattern exactly:

   ```swift
   struct SourcesView: View {
       @EnvironmentObject var appState: AppState
       private let ownsNavigationStack: Bool

       init(ownsNavigationStack: Bool = true) {
           self.ownsNavigationStack = ownsNavigationStack
       }

       var body: some View {
           Group {
               if ownsNavigationStack {
                   NavigationStack { content }
               } else {
                   content
               }
           }
       }

       @ViewBuilder
       private var content: some View {
           ScrollView { /* existing body, minus the .toolbar(.hidden, for: .navigationBar) — see below */ }
           .background(Palette.sourcesBackground.ignoresSafeArea())
           .foregroundStyle(Palette.ink)
           .navigationDestination(for: Source.self) { source in
               SourceDetailView(source: source)
           }
           .navigationDestination(for: LibraryService.self) { service in
               switch service {
               case .jamendo: JamendoBrowseView()
               }
           }
       }
   }
   ```

   From the `Settings` call site, use `SourcesView(ownsNavigationStack: false)`
   since it's being pushed into `SettingsView`'s existing stack (adjust based
   on what you find `SettingsView` actually does — if `SettingsView` has no
   `NavigationStack` of its own, wrap the whole `SettingsView` body in one, or
   push via `.sheet`/`NavigationLink` as appropriate; read the file first).

   Also reconsider `.toolbar(.hidden, for: .navigationBar)` — that was correct
   when `SourcesView` was a full-screen tab with its own custom
   `ScreenHeader(title: "Libraries")` replacing the nav bar. Pushed inside
   Settings, you likely want the *opposite*: a normal visible nav bar with a
   back button and the title "Libraries" via `.navigationTitle`, and you
   should remove or conditionalize the in-body `ScreenHeader(title: "Libraries")`
   to avoid a doubled header. Use judgment matching how other pushed detail
   screens in this codebase look (e.g. `SourceDetailView` itself, or
   `JamendoBrowseView`) — grep for `.navigationTitle` usage in
   `Sources/Features/` for the established pattern.

### 2e. Fold Playlists into Library

Goal: `PlaylistsView` (currently its own tab, `.playlists`) becomes reachable
from `LibraryView` instead.

1. `Sources/Features/Library/LibraryView.swift` uses a segmented `Picker`
   bound to `LibraryBrowseMode` (`.artists`, `.albums`, `.songs`, `.genres`) to
   switch what's shown below a search field. Playlists are a *different kind
   of object* (`Playlist`, not `TrackRow` sections), so don't try to force
   them into that segmented-picker/`LibraryBrowse.sections` machinery — that
   would require reshaping `LibraryBrowse.swift`'s section model for no
   benefit.

   Instead, add a simple navigation entry point above or below the picker,
   e.g. right after the `SearchField`:

   ```swift
   NavigationLink {
       PlaylistsView(ownsNavigationStack: false)
   } label: {
       HStack(spacing: 8) {
           Image(systemName: "music.note.list")
           Text("Playlists")
           Spacer()
           Text("\(appState.playlists.count)")
               .foregroundStyle(Palette.ink3)
           Image(systemName: "chevron.right")
               .font(.system(size: 13))
               .foregroundStyle(Palette.ink3)
       }
   }
   .buttonStyle(.plain)
   .accessibilityIdentifier("Library Playlists")
   .padding(.vertical, 9)
   ```

   (Match existing row padding/spacing conventions found elsewhere in
   `LibraryView.swift` rather than inventing new numbers — read the
   surrounding rows first.)

2. Give `PlaylistsView` the same `ownsNavigationStack` treatment as
   `SourcesView` above (check whether it already has one — if
   `PlaylistsView.swift`'s `body` starts with `NavigationStack { ... }`,
   parametrize it exactly like `LibraryView`'s existing pattern). Since
   `LibraryView` already conditionally owns its own stack (`ownsNavigationStack`
   param, `true` by default when used as the standalone Library tab), pushing
   `PlaylistsView(ownsNavigationStack: false)` from inside it reuses that
   existing stack correctly.

3. Double-check `CreatePlaylistSheet` / `appState.showCreatePlaylist` (used
   elsewhere to add a playlist) still works from wherever it's currently
   triggered — it's presented as a `.sheet` from `RootView`, independent of
   which tab is active, so it should need no change. Just confirm nothing in
   `PlaylistsView` assumed it was a root-level tab (e.g. a custom
   `ScreenHeader` that should become a `.navigationTitle` instead, same
   consideration as `SourcesView` above).

## Part 3 — "Your Queue" on the Listen home screen (and Now Playing)

The owner specifically likes the existing "Keep Playing" auto-queue-fill
feature (`Sources/Audio/AudioPlayer.swift` — `keepPlayingEnabled`,
`keepPlayingAutoAddedTrackIDs`, `keepPlayingFallbackReason`, similarity-based
extension) and wants it surfaced as a visible module: **"Your Queue"**, not a
vague "recommendation" — consistent with the research's "every personalized
section says what it's built from" principle.

Two places to add it:

### 3a. `AudioPlayer.upNextTracks` already exists and is unused elsewhere

```swift
public var upNextTracks: [TrackRow] {
    if isAmbient { return [] }
    guard index < queue.count - 1 else { return [] }
    return Array(queue.dropFirst(index + 1))
}
```

This is exactly "what's coming up next in the queue" — use it as-is, don't
duplicate its logic.

### 3b. Now Playing screen

`Sources/Features/NowPlaying/NowPlayingView.swift` currently has **no** queue
list at all (confirmed by grep — no `queue`/`Queue` reference in that file).
Add a "Your Queue" section:

- Show `player.upNextTracks` (empty state: hide the whole section, or show a
  brief "Nothing queued yet" — match whatever empty-state convention
  `NowPlayingView` already uses elsewhere in the file for consistency).
- Per-row: title/artist (reuse `TrackRowView` or whatever row component
  `NowPlayingView` already uses for consistency — check the file first, don't
  introduce a third row style alongside `TrackRowView`/`RecentCard`).
- For rows whose track id is in `player.keepPlayingAutoAddedTrackIDs`, add a
  small "From your queue" / "Extended by Keep Playing" caption or icon — the
  point (per CLAUDE.md "no silent/magic background work" and the research's
  "say what it's built from" principle) is that auto-added tracks are visibly
  distinguished from ones the user explicitly queued/chose.
- Tapping a row should jump playback to that track: find the track's actual
  index in `player.queue` (not just its position in the `upNextTracks` slice)
  and call whatever existing "jump to index" method `AudioPlayer` exposes —
  grep `AudioPlayer.swift` for how `next()`/track-jumping is currently done
  (e.g. there may already be a `jump(to:)` or similar; do not reimplement
  queue-seeking logic if one exists).
- Respect `keepPlayingLastExtensionWasFallback` /
  `keepPlayingFallbackReason` if there's a natural place to surface it (e.g. a
  small caption "shuffled — sound index unavailable" when the last extension
  fell back) — optional polish, not required for this feature to be usable.

### 3c. Listen home screen

`Sources/Features/Listen/ListenView.swift` — add a "Your Queue" card, styled
like the existing `cardRow`/`statsCard` sections (`SectionHeader`, horizontal
scroll of `RecentCard`s is the established pattern for track collections on
this screen — reuse it):

```swift
if player.currentTrack != nil, !player.upNextTracks.isEmpty {
    cardRow(title: "Your Queue", rows: Array(player.upNextTracks.prefix(10)))
}
```

Placement: put it near the top, likely right after (or replacing the spot
where) "Jump Back In" sits, since it's now the more actionable, most-live
section — use judgment on exact ordering, but do not place it below
"Listening Stats" (queue relevance decays fast; stats don't need to be seen
first). `ListenView` already has `@EnvironmentObject var player: AudioPlayer`
— no new dependency needed.

If `cardRow`'s current tap behavior (`player.play(tracks: rows, startAt: idx, ...)`)
doesn't fit for an already-playing queue (it would restart playback from that
position rather than "jump" without disturbing what's already playing),
consider whether tapping a "Your Queue" card should instead jump to that
track's real index in `player.queue` (same consideration as 3b above) rather
than calling `play(tracks:startAt:)` with just the sliced `upNextTracks`
array — reusing the general `cardRow` helper as-is would technically work
(it would just re-set the queue to only the visible upcoming tracks starting
at the tapped one) but silently drops everything currently *behind* the
tapped track in the real queue. Prefer a dedicated tap handler that finds the
tapped row's real index in `player.queue` and jumps there without truncating
the rest of the queue.

## Part 4 — Tests and other call sites to update

Run these searches before considering the work done — this list is likely not
exhaustive against the exact code at implementation time, so re-grep rather
than trusting only this list:

1. `grep -rn "AppTab\." Sources/ Tests/` — confirm every remaining reference
   compiles against the new 5-case enum (this plan's grep at write-time found
   none in `Tests/`, only in `Sources/App/AppState.swift`,
   `Sources/Features/RootView.swift`, and `Sources/Features/Chrome/GlassDock.swift`,
   all covered above — but re-check, since other code may have been added
   since).
2. **UI regression tests** (`UIRegressionTests/`, not run in CI — run by hand,
   per `CLAUDE.md` — but must still be kept correct):
   - `UIRegressionTests/NowPlayingRegressionUITests.swift:100` and
     `UIRegressionTests/PlaylistRegressionUITests.swift:72` —
     `app.buttons["Playlists"].tap()` — the "Playlists" tab button no longer
     exists. Update to navigate via Library → the new "Playlists" row
     (`accessibilityIdentifier("Library Playlists")` from Part 2e) instead:
     tap the "Library" tab button, then tap the Playlists row.
   - `UIRegressionTests/DJLiveMixRegressionUITests.swift:81,109` and
     `UIRegressionTests/DJMixRegressionUITests.swift:77` —
     `app.buttons["Libraries"].firstMatch.tap()` — the "Libraries" tab button
     no longer exists. Update to navigate via Settings → the new "Libraries"
     row (`accessibilityIdentifier("Settings Libraries")` from Part 2d)
     instead: tap the "Settings" tab button, then tap the Libraries row.
   - `UIRegressionTests/DJMixRegressionUITests.swift:51-52` —
     `app.staticTexts["Playlists"].waitForExistence(...)` after "DJ → Playlists
     should present the modal playlist browser" — this looks like a *different*
     playlist browser (a DJ-specific modal, not the tab), so it probably
     doesn't need to change — confirm by reading the surrounding test before
     touching it; don't blindly edit every "Playlists" string match.
   - After editing, these tests are not runnable without Docker + simulator +
     demo servers per `CLAUDE.md` — do not attempt to run them in this
     environment; a careful read-through of the edited steps against the new
     navigation is the available substitute for actually running them, and
     say so plainly rather than claiming they were verified by execution.
3. Any other `.sheet`/call site constructing `PlaylistsView()` or
   `SourcesView()` directly (grep `PlaylistsView(` and `SourcesView(` across
   `Sources/`) — confirm each either still wants the default
   `ownsNavigationStack: true` (i.e., still presented as a standalone
   full-screen sheet/cover somewhere) or needs updating to `false` if it's now
   nested. Don't assume the two calls this plan describes (Settings, Library)
   are the only call sites without checking.
4. `Sources/Features/Ingest/AddFolderSheet.swift` and any other file matched
   by the earlier `grep -rln "appState.tab"` search — re-run that grep and
   confirm every `appState.tab = .something` assignment still compiles (e.g.
   `appState.tab = .library` after a folder import — already valid under the
   new enum, but check for any `= .sources` or `= .playlists` assignment that
   needs redirecting, e.g. to `.library` or `.settings` respectively).
5. Build and run the full test suite: `swift test` (see `CLAUDE.md` — this
   also runs via the pre-commit hook, budget 5+ minutes) and a plain
   `xcodebuild build` for the iOS app target to catch anything `swift test`
   doesn't compile (UI code paths not exercised by unit tests).

## Part 5 — Commit

Follow repo convention (`CLAUDE.md`): commit directly to `main`, one task per
commit — this whole tab-bar redesign is reasonably one commit since it's a
single coherent, interdependent change (splitting the enum change from its
call-site updates would leave intermediate commits that don't build). Do
**not** use `--no-verify` unless the owner explicitly asks for that specific
commit — let the pre-commit hook run the full suite. Do **not** `git push`
without asking the owner first, even if you believe this plan already implies
approval to push — push is a separate, explicit approval gate per
`CLAUDE.md` and the owner's standing preference.
