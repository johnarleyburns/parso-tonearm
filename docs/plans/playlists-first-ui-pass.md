# Playlists-first UI pass — splash, DJ home, playlists, remote libraries, the mixer

**Status:** implemented and locally verified on 2026-08-18. **Landed commits:** T1
`680ea59`, T2–T3 `ec9a426`, T4–T11 `c806b99`. **Branch policy:** commit to `main`, ask
before `git push` (CLAUDE.md). **Toolchain:** Swift 6 language mode, complete strict
concurrency, no suppression, no `--no-verify`.

This plan is written to be executed **without further research or design decisions**. Every
change names the file, the current code, the replacement, and the test that proves it. Line
numbers are as of `1d42747`; if they have drifted, the quoted code is the anchor.

---

## 0 · How to run this

Read `docs/plans/tonearm-mvp-ios/HANDOFF.md` §0 first (session model). Then:

- **One commit per task below (T1…T11).** A task is a session's worth of work.
- `git commit` runs the full local hook suite (Swift tests + simulator UI smoke). **Allow
  300 s.** Never `--no-verify`.
- Adding or deleting a Swift file means `make project` (`scripts/generate-project.sh`) —
  never hand-edit `Tonearm.xcodeproj/project.pbxproj` — and the regenerated project is part
  of the same commit.
- `make ci-guards` before each commit (under a second). Note guard (b): **no user-visible
  "Tonearm" string literals** in `Sources/Features`, `Sources/App`, `Sources/DesignSystem`.
  New copy says **Platterhead**.
- `make test-swift` runs the SPM suites. **Only `Sources/{Art,Audio,Data,Domain,IA,Intents,
  Pro,Remote,Share,Snapshot,Sync,WatchPlayback,WatchSync}` (TonearmCore) and `Sources/DJ`
  (TonearmDJ) are in the SPM package.** `Sources/App`, `Sources/Features`,
  `Sources/DesignSystem` are **not** unit-testable — so every behaviour worth a test in this
  plan is placed in Core or DJ deliberately, and the view layer stays thin.
- `make test-ui-regression` is **hand-run only** (needs Docker + a simulator). Never wire it
  into CI or a hook. T11 updates it; run the named lanes once at the end.

---

## 1 · Ground truth (verified, do not re-derive)

| Fact | Evidence |
|---|---|
| Splash tile is `PeriodicTileView`, subtitle is a sibling `Text` | `Sources/Features/Onboarding/AnimatedSplashView.swift:43` |
| Tile corners are `cornerRadius: 34` in three places (fill, clip, stroke) | same file `:121`, `:129`, `:133` |
| `waveform.badge.record` **is not an SF Symbol** — the Recorded Mixes row renders a blank glyph | `plutil -p /System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_order.plist` lists `waveform.badge.{plus,minus,exclamationmark,checkmark,xmark,magnifyingglass,microphone}` and `recordingtape{,.circle,.circle.fill}` — no `.record` |
| DJ home sections are ordered Purchase → Perform → Library → Hardware | `Sources/Features/DJ/DJHomeView.swift:52-75` |
| Playlist detail puts `+` on the **left** and hides the back button | `Sources/Features/Playlists/PlaylistsView.swift:118-166`, `.navigationBarBackButtonHidden()` at `:196` |
| `LibraryStore.addToPlaylist` appends unconditionally — no dedup | `Sources/Data/LibraryStore.swift:612-620` |
| `IngestService.addFolder` **always** inserts a new `source` + `playlist` — importing the same folder twice yields two of each | `Sources/Domain/IngestService.swift:88-125` |
| Migration v13 already merges folder playlists **per `sourceId`**, and deliberately keeps same-named folders distinct (regression D-7) | `Sources/Data/Schema.swift:376-443` |
| `AppState.download(rows:)` writes the whole file and calls `setContentLength` + `setPinned` but **never `recordWrite`** — so `meta.rangeMap` stays empty, `cachedBytes == 0`, `complete == false` | `Sources/App/AppState.swift:638-661`; `CacheStore.recordWrite` at `Sources/Audio/CacheStore.swift:141` is the only writer of `rangeMap` |
| `AudioPlayer.refreshCacheState()` reports 0 % when `asset.transientRemoteSupportsByteRanges` is false, and only ever raises the percentage from the range map | `Sources/Audio/AudioPlayer.swift:1069-1096` |
| `transientRemoteSupportsByteRanges` is **runtime-only** (`Sources/Domain/Entities.swift:229`), so any row re-read from the DB has the initialiser default `true`; a browsed row that never went through the loader has an empty range map |  |
| Now Playing's download button's tappable area is its label — a **9 × 9 pt** circle (`CacheGlyph` `.none`/`.cached`); the `.frame(width: 44, height: 44)` is applied to the `Button`, outside the label | `Sources/Features/NowPlaying/NowPlayingView.swift:316-338`, `Sources/DesignSystem/CacheGlyph.swift:8-31` |
| `AppState.phoneDownloadState(for:)` reads the filesystem and publishes nothing, so the glyph never refreshes after a download | `Sources/App/AppState.swift:664-686` |
| "Send to DJ library" is `GenreCrateImporter` → `DJLibraryStore.saveCrate`, shown only for `.jamendoGenre` | `Sources/Features/Sources/SourceDetailView.swift:192,270-308`; `Sources/Features/Sources/GenreCrateImporter.swift` |
| Browsed remote rows carry **synthetic negative track ids** (`-Int64(index + 1)`) and are never persisted | `Sources/Remote/RemoteTrackRowFactory.swift:11` |
| Remote credentials never reach the DB: headers are `transient` by design | `Sources/Domain/Entities.swift:226-231` |
| The "Transitions" pill is `TransitionCoachAccessory.entryButton`, top-centre, on all three surfaces | `Sources/DJ/Features/Coach/TransitionCoachAccessory.swift:45-63` |
| `MidiCatchIndicator` occupies `.topTrailing` with `.padding(12)` on three surfaces | `SoloDeckView.swift:62-66`, `TwinDeckView.swift:65-69`, `WorkspaceView.swift:69-74` |
| `CueButton`'s label is `.frame(height: 32)`; the compact bar's siblings are `minHeight: 44` (REC) and a fixed `44` (Echo) | `Sources/DJ/Features/Workspace/CueControls.swift:23`, `SoloDeckView.swift:198-243`, `EchoControls.swift:68` |
| The crate sheet exists only on the portrait compact surface and defaults to the `.allTracks` queue | `SoloDeckView.swift:105-107`, `:824-949`; `WorkspaceModel.queueA/queueB` default `.allTracks` at `:469-472` |
| `DeckQueueSource.playlist(id:)` is a **`DJPlaylist`** id in `DJLibraryStore`, not an app `Playlist` | `Sources/DJ/Features/Workspace/DeckLoader.swift:180-192, 257-268` |
| `TonearmDJ` depends on `TonearmCore`, so DJ code **may** read the app's `LibraryStore` | `Package.swift:90-96` |
| `DJLibraryStore.importDownloadedTracks` bookmarks files **in place** (no copy) and dedups by content hash; `saveCrate` replaces a same-titled crate | `Sources/DJ/Domain/DJLibraryStore.swift:663-733, 740-770` |
| `LibraryStore(inMemory: true)` exists for tests; `CacheStore(rootDirectory:limitBytes:)` exists for tests | `Sources/Data/LibraryStore.swift:41`, `Sources/Audio/CacheStore.swift:66` |

---

## 2 · Decisions taken up front (do not re-open)

1. **Playlists are the one crate concept.** "Send to DJ library" is deleted outright.
   Everything that used to reach the decks through a DJ-only crate now goes: remote library →
   **app playlist** → (mixer) **Import playlist** → DJ crate. The DJ↔app bridge is one new
   type, `PlaylistCrateImporter` (T10).
2. **Adding remote tracks to a playlist persists them, then pins them.** A browsed remote row
   has a negative id and cannot be a `playlist_item` (FK). The flow inserts real `track` +
   `asset` rows against the remote `source`, then downloads each into the pinned stream cache.
   Downloading is not optional decoration: persisted rows lose their auth headers by design,
   and a complete pinned cache file is what makes them replayable without headers. Progress is
   shown and cancellable.
3. **Folder identity is the canonical folder path**, stored in a new `source.folderPath`
   column. Title is *not* an identity (regression D-7 requires two folders both named `Music`
   to stay distinct). Existing duplicates are merged by resolving each folder playlist's
   bookmark at launch — bookmarks cannot be resolved in SQL, so this is a one-time Swift
   repair, not a migration.
4. **Track-level dedup is "first occurrence wins", within one playlist.** Adding a track that
   is already in the playlist is a **no-op, not an error**. A one-time repair strips existing
   duplicates and re-numbers positions.
5. **The DJ route table loses `.library`.** DJ → Playlists is a sheet, not a push, so a
   pushed `.library` destination would be unreachable — dead code under §49.3a. The enum case
   and its `navigationDestination` are removed and `DJEntryTests` updated.
6. **The crate sheet is per-deck and starts empty.** `WorkspaceModel` gains
   `importedCrateA/B: DeckQueueSource?`. The iPad `WorkspaceView` picker and `availableQueues`
   are untouched.
7. **The coach "?" owns the top-right corner**; `MidiCatchIndicator` moves down by 44 pt on
   all three surfaces so they never overlap.
8. **No new user-facing dependency on `Tonearm` copy.** All new strings say Platterhead or are
   generic.

---

## 3 · Commit sequence

Each task lists **files**, **change**, **tests**, **verify**. The commit message convention is
`fix(area): …` / `feat(area): … (plan playlists-first-ui-pass)`.

---

### T1 — Splash: no subtitle, square tile, translucent field

**Files:** `Sources/Features/Onboarding/AnimatedSplashView.swift`

1. Delete the subtitle `Text` (`:43-47`) and the now-unused `@State private var scale`
   (`:16`) plus its `withAnimation` assignment (`:55`). Keep `tileScale`.
2. The `VStack(spacing: 22)` now wraps a single child — replace it with the
   `PeriodicTileView` directly, keeping `.accessibilityElement(children: .ignore)` and
   changing the label to `"Platterhead"`.
3. `PeriodicTileView`: replace all three `RoundedRectangle(cornerRadius: 34, style:
   .continuous)` (`:121`, `:129`, `:133`) with `Rectangle()`. For the clip use
   `.clipShape(Rectangle())`.
4. Make the tile field partially transparent so the splash artwork reads through:
   in the `.background` fill, change the gradient to
   `LinearGradient(colors: [Color(hex: 0x12141A).opacity(0.55), Color(hex: 0x0A0B0D).opacity(0.55)], startPoint: .top, endPoint: .bottom)`.
   Leave the brass radial overlay, the shadow and the 1 pt brass border as they are — the
   border is what keeps a transparent tile legible.

**Tests:** none (view-only, outside the SPM package). **Verify:** run the app; the splash
shows the Pt tile with square corners and visible artwork behind it, and no subtitle line.

---

### T2 — DJ home: order, naming, a real icon, Playlists as a sheet

**Files:** `Sources/Features/DJ/DJHomeView.swift`, `Sources/DJ/Features/Entry/DJEntryModel.swift`,
`Sources/Features/Playlists/PlaylistsView.swift`, `Tests/DJTests/DJEntryTests.swift`

1. **Order.** Move the `Section("Library")` block above `Section("Perform")`. Final order:
   Purchase → Library → Perform → Hardware.
2. **Rename.** `Label("Open the decks", systemImage: "slider.horizontal.3")` →
   `Label("Open DJ Mixer", systemImage: "slider.horizontal.3")`. Identifier `dj.decks`
   unchanged.
3. **Icon.** `Label("Recorded Mixes", systemImage: "waveform.badge.record")` →
   `systemImage: "recordingtape.circle.fill"` (a real symbol; the old one rendered blank).
4. **Playlists sheet.** Replace the `NavigationLink(value: DJDestination.library)` row with:

   ```swift
   Button { showPlaylists = true } label: {
       Label("Playlists", systemImage: "music.note.list")
   }
   .accessibilityIdentifier("dj.playlists")
   ```

   backed by `@State private var showPlaylists = false` and, on the `List`:

   ```swift
   .sheet(isPresented: $showPlaylists) {
       PlaylistsView(presentsCreateSheetLocally: true)
   }
   ```

5. **Route table.** Delete `case library` from `DJDestination`, delete `.library` from
   `DJEntryModel.reachableDestinations`, and delete the `case .library:` arm of
   `navigationDestination` in `DJHomeView` (the `LibraryView(ownsNavigationStack:)` call goes
   with it — keep the `ownsNavigationStack` parameter on `LibraryView`, it is still used by
   the Music tab's default `true`).
6. **`PlaylistsView` gains a sheet-safe create path.** `RootView` owns
   `.sheet(isPresented: $appState.showCreatePlaylist)`; presenting from inside another sheet
   via that flag fails. Add:

   ```swift
   struct PlaylistsView: View {
       private let presentsCreateSheetLocally: Bool
       @State private var showLocalCreate = false
       init(presentsCreateSheetLocally: Bool = false) { … }
   ```

   The header's add action becomes
   `{ if presentsCreateSheetLocally { showLocalCreate = true } else { appState.showCreatePlaylist = true } }`,
   and the view gets `.sheet(isPresented: $showLocalCreate) { CreatePlaylistSheet() }`.
7. `AppState.createPlaylist(title:trackIds:)` currently ends with `tab = .playlists`
   (`Sources/App/AppState.swift:925`). Guard it so a create started from a sheet does not
   yank the root tab: change the body to take a `switchesTab: Bool = true` parameter and only
   assign `tab` when true; `CreatePlaylistSheet` passes `switchesTab: !isEmbedded`, where
   `CreatePlaylistSheet` gains `var isEmbedded = false` and `PlaylistsView` passes
   `CreatePlaylistSheet(isEmbedded: true)` from its local sheet.

**Tests:** update `Tests/DJTests/DJEntryTests.swift:34` to
`XCTAssertEqual(DJEntryModel.reachableDestinations, [.decks, .mixes, .midi])`, and
`testEntryModelPresentsAPushedDestination` to push `.mixes` instead of `.library`.

**Verify:** `make test-swift`; DJ tab shows Library above Perform, "Playlists" opens a modal
Playlists screen with a working `+`, and Recorded Mixes has a visible tape glyph.

---

### T3 — Playlist detail header: Back on the left, `+` beside the overflow

**Files:** `Sources/Features/Playlists/PlaylistsView.swift` (`PlaylistDetailView`, `:118-166`)

Rebuild the header `HStack` in this order:

```
[ chevron.left "Back" ]  ——— Spacer ———  [ EditButton ] [ + ] [ ellipsis.circle ]
```

- **Back button** (new, leading):

  ```swift
  Button { dismiss() } label: {
      Image(systemName: "chevron.left")
          .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.brass)
          .frame(width: 44, height: 44).glassSurface(cornerRadius: 22)
  }
  .accessibilityLabel("Back")
  .accessibilityIdentifier("playlist.back")
  ```

  `@Environment(\.dismiss)` is already declared on the view (`:106`).
  `.navigationBarBackButtonHidden()` stays — this is the replacement, and the same
  chevron-in-a-glass-pill pattern already used by `SourceDetailView.navRow` and
  `LibraryGroupDetailView.navRow`.
- **`+`** keeps identifier `playlist.add` and moves to the position immediately **left** of
  the overflow menu, right of `EditButton`. Its `Menu { … }` body is replaced in T5 by a
  sheet presentation; in this task only the position changes.
- `EditButton` (`playlist.edit`) and the overflow `Menu` (`playlist.overflow`) keep their
  identifiers and contents.

**Tests:** none in SPM. **Verify:** entering any playlist shows `< ` top-left and `+` directly
left of `…`; tapping `<` returns to the playlist list (both from the Playlists tab and from
the DJ sheet).

---

### T4 — Deduplicate playlists: on add, and the ones already there

Two distinct duplicates, both fixed here.

**(a) Track duplicated inside one playlist.**

*New file* `Sources/Domain/PlaylistDedup.swift` (TonearmCore, pure, `Sendable`):

```swift
public enum PlaylistDedup {
    /// First occurrence of each trackId wins; returns the ids of the later
    /// duplicates, in the order they should be deleted.
    public static func duplicateItemIDs(in items: [PlaylistItem]) -> [Int64]
    /// The survivors, renumbered 0..<n in their original relative order.
    public static func deduplicated(_ items: [PlaylistItem]) -> [PlaylistItem]
}
```

`Sources/Data/LibraryStore.swift`:

- `addToPlaylist(playlistId:trackId:sectionTitle:)` (`:612`) becomes a no-op when the pair
  already exists:

  ```swift
  let exists = try PlaylistItem
      .filter(Column("playlistId") == playlistId && Column("trackId") == trackId)
      .fetchCount(db) > 0
  guard !exists else { return }
  ```

- `createManualPlaylist(title:trackIds:)` (`:669`) inserts
  `trackIds.reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }`.
- New `public func removeDuplicatePlaylistItems() throws -> Int` — for every playlist, apply
  `PlaylistDedup` and persist through the existing `persistPlaylistItems(original:edited:db:)`
  helper. Returns the number of rows removed.

**(b) The same local folder imported twice → two sources + two playlists.**

- *Migration* `Sources/Data/Schema.swift`: append `"v14"` to `migrationOrder` (`:5-7`) and
  register:

  ```swift
  migrator.registerMigration("v14") { db in
      try db.alter(table: "source") { $0.add(column: "folderPath", .text) }
      try db.create(indexOn: "source", columns: ["folderPath"])
  }
  ```

- `Sources/Domain/Entities.swift`: add `public var folderPath: String? = nil` to `Source`
  (after `localIsFolder`), with a defaulted initialiser parameter so no call site breaks.
  Add it to `Source`'s coding keys/column list wherever the record's columns are enumerated
  (check `Sources/Data/Records.swift` for an explicit `CodingKeys`; if the record relies on
  synthesised keys, nothing else is needed).
- *New file* `Sources/Domain/FolderImportIdentity.swift`:

  ```swift
  public enum FolderImportIdentity {
      /// The stable identity of an imported folder: the resolved, standardised
      /// file path without a trailing slash. Case is preserved (iOS volumes may
      /// be case-sensitive); percent-encoding is resolved away.
      public static func key(for url: URL) -> String
  }
  ```

  Implementation: `url.standardizedFileURL.resolvingSymlinksInPath().path` with any trailing
  `/` trimmed.
- `Sources/Data/LibraryStore.swift`: new
  `public func folderSource(path: String) throws -> Source?` filtering
  `kind == 'local' AND folderPath == ?`.
- `Sources/Domain/IngestService.swift` `addFolder` (`:88`): before inserting, compute
  `let key = FolderImportIdentity.key(for: folderURL)`; if
  `try await store.folderSource(path: key)` returns a source **and** that source has a folder
  playlist, do **not** create a second source/album/playlist — instead call the existing
  `addFiles(_:toSourceId:into:)` path for files whose bookmarked URL is not already an asset
  of that source, then return. Otherwise insert as today, with `folderPath: key` set on the
  new `Source`.
- New `public func mergeDuplicateFolderPlaylists() throws -> Int` on `LibraryStore`:
  resolve every folder playlist's `folderBookmark` (via `BookmarkVault.resolve`) to a
  `FolderImportIdentity.key`; falling back to its source's `folderPath`. Group by key; for
  each group of more than one, keep the **lowest playlist id**, back-fill the keeper's
  source's `folderPath`, move any items whose `trackId` the keeper does not already hold
  (appending positions), then `DELETE FROM source WHERE id = <duplicate playlist's sourceId>`
  — the v1 cascades (`album`, `track`, `asset`, `playlist_item`, `playlist`) remove the whole
  redundant import. A duplicate playlist with no `sourceId` is deleted directly after its
  items are moved. Returns the number of playlists merged away.
- `Sources/App/AppState.swift` `bootstrap()` (`:89`): after `fixLegacySourceTitles()`, add a
  once-only repair guarded by `@AppStorage`-style `UserDefaults` key
  `"repair.playlistDedup.v1"`:

  ```swift
  private func repairDuplicatePlaylistsOnce() async {
      let key = "repair.playlistDedup.v1"
      guard !UserDefaults.standard.bool(forKey: key) else { return }
      _ = try? await store.mergeDuplicateFolderPlaylists()
      _ = try? await store.removeDuplicatePlaylistItems()
      UserDefaults.standard.set(true, forKey: key)
  }
  ```

**Tests** — *new* `Tests/PlaylistDedupTests.swift`:

1. `PlaylistDedup.duplicateItemIDs` keeps the first occurrence and reports the rest.
2. `PlaylistDedup.deduplicated` renumbers positions `0..<n` contiguously.
3. `LibraryStore(inMemory: true)`: adding the same track twice leaves one item.
4. `createManualPlaylist(title:trackIds: [1,2,1])` produces two items.
5. `removeDuplicatePlaylistItems()` on a hand-seeded playlist with duplicates returns the
   right count and leaves contiguous positions.
6. `FolderImportIdentity.key` is equal for `/a/b`, `/a/b/`, `/a/./b`.
7. `mergeDuplicateFolderPlaylists()` on two sources sharing a `folderPath` keeps one playlist,
   preserves both playlists' distinct tracks in the survivor, and deletes the duplicate source.
8. *New* `Tests/MigrationV14Tests.swift` — `Schema.migrator(upTo: "v13")` then full migrate;
   assert `folderPath` exists and existing rows survive (mirror `FolderPlaylistMigrationTests`).

**Verify:** `make test-swift`. Existing `FolderPlaylistMigrationTests`, `RecordMappingTests`,
`SyncMigrationTests`, `SchemaMigrationV8Tests`, `MigrationV12Tests` must stay green — v14 only
adds a nullable column.

---

### T5 — The playlist `+` opens the Music picker

**Files:** *new* `Sources/Features/Playlists/AddTracksToPlaylistSheet.swift`;
`Sources/Features/Playlists/PlaylistsView.swift`

Replace `PlaylistDetailView`'s `+` `Menu` (which listed `appState.allTracks` in a menu — a
menu is unusable at library scale, which is the reported bug) with:

```swift
Button { showAddTracks = true } label: { /* the same glass "+" pill */ }
    .accessibilityIdentifier("playlist.add")
…
.sheet(isPresented: $showAddTracks) {
    AddTracksToPlaylistSheet(playlist: currentPlaylist) { await loadTracks() }
}
```

`AddTracksToPlaylistSheet` — a full-height sheet that is the Music tab's list in picker form.
Model it on `CreatePlaylistSheet` (`Sources/Features/Playlists/CreatePlaylistSheet.swift`),
which already has exactly this shape:

- Grabber capsule, title `Text("Add to \(playlist.title)")`.
- `SearchField(text: $filter, placeholder: "Search all your music…")` filtering
  `appState.allTracks` on title / album / artist (reuse `CreatePlaylistSheet.filteredTracks`
  verbatim — copy it, do not try to share state with the tab's `appState.searchText`, which
  drives the Music tab's own results).
- A `List` of every filtered row with a `checkmark.circle.fill` / `circle` toggle, identical
  to `CreatePlaylistSheet`'s row. Identifier `playlist.add.row.<trackId>`.
- A footer count `"\(selected.count) selected"` and a brass capsule button
  `Text(selected.isEmpty ? "Add tracks" : "Add \(selected.count) tracks")`, disabled while
  empty, identifier `playlist.add.confirm`. It loops
  `await appState.addToPlaylist(row, playlist: playlist)` in `appState.allTracks` order
  (dedup is now in the store, T4), calls the `onFinished` closure, then `dismiss()`.
- `.presentationDetents([.large])`, `.presentationBackground(.ultraThinMaterial)`,
  `.foregroundStyle(Palette.ink)` — matching the existing sheets.

**Tests:** none in SPM. **Verify:** open a playlist → `+` → the full library with a working
search box; select several, Add; the rows appear once each even if already present.

---

### T6 — Now Playing: a download button that is reachable and honest, and a real add-to-playlist dialog

**Files:** `Sources/Features/NowPlaying/NowPlayingView.swift`, `Sources/App/AppState.swift`,
*new* `Sources/Features/Playlists/AddToPlaylistDialog.swift`

**(a) The download button "does nothing" because it is 9 pt wide.**
In `phoneDownloadButton(for:)` (`:316`) and `watchButton(for:)` (`:340`), move the sizing
**inside** the label:

```swift
} label: {
    CacheGlyph(state: cacheGlyphState(from: state))
        .frame(width: 44, height: 44)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
}
.buttonStyle(.plain)
.accessibilityIdentifier("np.download")
```

(dropping the now-duplicated `.frame`/`.background` that sat on the `Button`). Do the same for
`WatchGlyphView`.

**(b) The glyph never refreshes.** `AppState`:

- add `@Published private(set) var downloadRevision = 0` and
  `@Published private(set) var activePhoneDownloads: Set<Int64> = []`;
- `download(rows:)` inserts each `row.id` into `activePhoneDownloads` before its fetch and
  removes it after, and bumps `downloadRevision += 1` at the end;
- `removeDownloadFromPhone(rows:)` bumps `downloadRevision` too;
- `phoneDownloadState(for:)` returns `.downloading(nil)` when
  `activePhoneDownloads.contains(row.id)`, before any filesystem check.

In `phoneDownloadButton`, read the revision so SwiftUI re-renders:
`let _ = appState.downloadRevision` at the top of the `@ViewBuilder` body (assign it to
`state` via a computed helper if the compiler objects — e.g. make the helper take
`revision: Int` and pass `appState.downloadRevision`).

**(c) `+=` becomes a dialog.** Replace the `Menu` at `:255-268` with a button that presents
the new shared dialog:

*New file* `Sources/Features/Playlists/AddToPlaylistDialog.swift`:

```swift
/// "Add to playlist": pick an existing playlist or create a new one by name,
/// then confirm. Shared by Now Playing and the remote-library "+" flow.
struct AddToPlaylistDialog: View {
    enum Target: Equatable { case existing(Playlist), create(String) }
    let title: String                      // e.g. "Add to playlist"
    let subtitle: String?                  // e.g. "Add 12 tracks to playlist"
    let confirm: (Target) async -> Void
    …
}
```

- A `Picker` (`.menu` style) over `appState.playlists` plus a trailing
  `"Create a new playlist…"` entry; identifier `addToPlaylist.picker`.
- When "create" is selected, a `TextField("Playlist name", …)` appears; identifier
  `addToPlaylist.name`.
- `Cancel` (dismisses) and `Add` (identifier `addToPlaylist.confirm`), the latter disabled
  when creating with a blank name.
- Presented as `.sheet` with `.presentationDetents([.height(280)])`.

`AppState` gains, so the dialog need not switch tabs:

```swift
@discardableResult
func makePlaylist(title: String) async -> Playlist? {
    let name = title.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    let created = try? await store.createManualPlaylist(title: name, trackIds: [])
    await reload()
    return created
}
```

Now Playing's handler: resolve the target to a `Playlist` (creating if needed), then
`await appState.addToPlaylist(row, playlist:)`. **If `player.currentTrack` has a negative
`track.id`** (an unpersisted browsed remote row — `RemoteTrackRowFactory`), first persist it
with `RemotePlaylistIngest` from T7 and add the persisted id instead.

**Tests:** none in SPM for the views. Add `Tests/…` coverage only if T7's ingest helper is
touched here (it is not). **Verify:** with a library track playing, the disc glyph is a
44 pt target, tapping it fills then turns brass, and tapping again clears it; `+=` opens the
dialog and adding to a brand-new playlist works.

---

### T7 — Cache truth: a downloaded track reports 100 %

**Files:** `Sources/Audio/CacheStore.swift`, `Sources/Audio/AudioPlayer.swift`,
`Sources/App/AppState.swift`

1. `CacheStore` — new actor method:

   ```swift
   /// Adopt a file written whole (not through the range loader) as a complete
   /// cache entry: total size, a full range map, complete, pinned. Without this
   /// the meta says 0 bytes cached for a file that is entirely on disk.
   public func adoptCompleteFile(byteCount: Int64, for key: String, pinned: Bool = true) async
   ```

   It sets `totalBytes`, inserts `0..<byteCount` into the range map (so `cachedBytes` and
   `complete` follow the existing `recordWrite` logic), sets `pinned`, persists, and calls
   `evictToFit(protecting: key)`.
2. `AppState.download(rows:)` (`:638`) and the `makeOffline` loop (`:600-625`): replace the
   `setContentLength` + `setPinned` pair with
   `await CacheStore.shared.adoptCompleteFile(byteCount: Int64(data.count), for: cacheKey)`.
   For a file that already exists on disk (the `FileManager.fileExists` branch) call it with
   the file's size from `FileManager.attributesOfItem` so a pre-existing file is repaired too.
3. `AudioPlayer.refreshCacheState()` (`:1069`): two fixes.
   - Drop `asset.transientRemoteSupportsByteRanges` from the guard. The flag is runtime-only
     and defaults to `true` for any row read back from the DB, so gating the *readout* on it
     reports 0 % for tracks that are fully on disk.
   - After reading `state`, trust it: when `state == .cached`, set `cachePercent = 100` and
     `cachedFraction = 1` regardless of what the range map arithmetic says; otherwise use the
     `map.totalBytes() / total` ratio as today, and when `total == 0` leave the previous
     values alone rather than reporting a false zero.

**Tests** — *new* `Tests/CacheAdoptionTests.swift`, using `CacheStore(rootDirectory:)` in a
temp dir:

1. `adoptCompleteFile(byteCount: 1000, for: "k")` → `state(for: "k") == .cached`,
   `rangeMap(for: "k").totalBytes() == 1000`, `totalBytes(for: "k") == 1000`,
   `isPinned("k") == true`.
2. The old sequence (`setContentLength` only) yields `.filling(0)` — the regression this
   fixes; assert it explicitly so the difference is documented.
3. Adopting twice is idempotent (still `.cached`, still 1000 bytes).

**Verify:** `make test-swift`; on device, download a Jamendo track from Now Playing and watch
the quality chip go to `● 100% CACHED`.

---

### T8 — Remote libraries: no "Send to DJ library", a `+` that adds N tracks to a playlist

**Files:** delete `Sources/Features/Sources/GenreCrateImporter.swift`;
`Sources/Features/Sources/SourceDetailView.swift`; *new*
`Sources/Remote/RemotePlaylistIngest.swift`; *new*
`Sources/Features/Sources/AddRemoteTracksSheet.swift`

1. **Delete the crate button.** Remove `genreCrateSection` (`:266-308`), its call site
   (`:192-194`), the `@StateObject private var crateImporter` and the custom `init`
   (`:23-28`), the `import TonearmDJ` if nothing else in the file needs it, and the
   `GenreCrateImporter.swift` file. Run `make project`.
2. **New `+` in the header.** In `navRow` (`:133`), insert between the `Spacer()` and the
   overflow `Menu`:

   ```swift
   Button { showAddToPlaylist = true } label: {
       Image(systemName: "plus")
           .font(.system(size: 15)).foregroundStyle(Palette.brass)
           .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
   }
   .accessibilityLabel("Add tracks to playlist")
   .accessibilityIdentifier("source.addToPlaylist")
   ```

   Show it whenever `isRemoteLibrary` is true. `.sheet(isPresented: $showAddToPlaylist) {
   AddRemoteTracksSheet(source: source, nodes: audioNodesInScope, scopeTitle: scopeTitle) }`
   where `audioNodesInScope = remoteNodes.filter { $0.kind == .audio }` (for a browseable
   server that is the current directory/genre — exactly "the library genre if I'm in a
   subgenre") and, for a non-browseable archive source, the already-loaded `tracks`.
3. **`AddRemoteTracksSheet`** — the dialog the request describes:
   - Title `Text("Add tracks to playlist")`, subtitle `Text(scopeTitle)`.
   - **Count selector:** `Stepper(value: $count, in: 1...max(1, available))` **plus** a
     `Slider` for large libraries, showing `Text("Add \(count) of \(available) tracks")`.
     `count` defaults to `1`. Identifier `remoteAdd.count`.
   - **Playlist selector:** the same control as `AddToPlaylistDialog` — a `.menu` `Picker`
     over `appState.playlists` plus `"Create a new playlist…"`, with a name `TextField` when
     creating. Identifier `remoteAdd.playlist`.
   - **Cancel / Add** (`remoteAdd.confirm`).
   - On confirm: resolve/create the playlist, then run the ingest (below) over
     `nodes.prefix(count)` with a determinate `ProgressView("Adding \(done) of \(count)…")`
     and a **Cancel** that sets a flag the loop checks each iteration. Failures are counted
     and reported inline (`"\(ok) added · \(failed) unavailable"`) — never a silent success.
4. **`RemotePlaylistIngest`** (TonearmCore, `Sources/Remote/`), the persistence seam:

   ```swift
   public struct RemotePlaylistIngest: Sendable {
       public struct Result: Sendable, Equatable {
           public let trackIDs: [Int64]     // in node order, persisted
           public let skipped: Int
       }
       /// Persist browsed remote nodes as real `track` + `asset` rows against
       /// `source`, deduplicating by `asset.remoteURL` within that source, and
       /// return the ids. Headers are deliberately **not** persisted (they are
       /// credentials); the caller pins the bytes so playback never needs them.
       public static func persist(nodes: [RemoteNode],
                                  resolve: (RemoteNode) async throws -> ResolvedAsset,
                                  source: Source,
                                  store: LibraryStore) async -> Result
   }
   ```

   Implementation mirrors `RemoteTrackRowFactory` for metadata, then
   `store.insertTrack(_:)` + `store.insertAsset(_:)` with `kind: .remote`,
   `remoteURL: resolved.url.absoluteString`, `sizeBytes: resolved.sizeBytes`. It first asks
   the store for existing remote URLs of that source (new
   `public func remoteURLs(forSource:) throws -> Set<String>` on `LibraryStore`) and reuses
   the existing track id when a URL is already persisted.
   An `album` row for the source is found-or-created via the existing
   `firstAlbum(sourceId:title:)` / `insertAlbum` pair so the tracks browse sanely.
5. **Then pin.** After persisting, the sheet calls `await appState.download(rows:)` for the
   new rows (T7 makes that mark them complete and pinned), keeping the transient headers of
   the *browsed* rows so authenticated providers can still fetch the bytes. This is what makes
   a persisted row playable later, when its headers are gone.
6. Finally `await appState.reload()` so the Playlists and Music tabs see the new rows.

**Tests** — *new* `Tests/RemotePlaylistIngestTests.swift` (`LibraryStore(inMemory: true)`, a
stub `resolve` closure, no network):

1. Three nodes → three `track` rows and three `.remote` assets under the given source, ids
   returned in node order.
2. Re-running with the same nodes returns the **same** ids and inserts nothing
   (dedup by `remoteURL`).
3. A node whose `resolve` throws is skipped and counted in `skipped`, and the others still
   land.
4. Persisted assets have empty `transientRemoteHeaders` when re-read from the store (the
   credential-safety property, stated as a test).

**Verify:** `make test-swift`. On device: open a Jamendo genre → `+` → "Add 5 tracks to
playlist" → pick "Create a new playlist" → name it → the five tracks appear in the playlist,
download, and play.

---

### T9 — Mixer chrome: "?" instead of a Transitions pill, and a Cue button that matches its row

**Files:** `Sources/DJ/Features/Coach/TransitionCoachAccessory.swift`,
`Sources/DJ/Features/Workspace/{SoloDeckView,TwinDeckView,WorkspaceView}.swift`,
`Sources/DJ/Features/Workspace/CueControls.swift`

1. **The pill becomes a "?" in the top-right.** In `TransitionCoachAccessory`:
   - `ZStack(alignment: .top)` → `ZStack(alignment: .topTrailing)`.
   - `entryButton`'s label becomes

     ```swift
     Image(systemName: "questionmark.circle")
         .font(.system(size: 18, weight: .semibold))
         .frame(width: 44, height: 44)
         .background(.ultraThinMaterial, in: Circle())
         .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
         .contentShape(Circle())
     ```

     with `.accessibilityLabel("Transitions")` added (the identifier `dj.coach` **stays** —
     the regression suite and VoiceOver both find it there) and
     `.padding(.top, 6).padding(.trailing, 10)` replacing `.padding(.top, 6)`.
   - The presented panel is unchanged: it is still `TransitionCoachView`, so "?" displays
     exactly what Transitions displayed.
2. **Move the MIDI catch indicator out of the corner.** In all three hosts change
   `MidiCatchIndicator(model: model).padding(12)` to
   `.padding(.top, 56).padding(.trailing, 12)`.
3. **Cue height.** `CueButton` gains `var height: CGFloat = 32`; its label uses
   `.frame(maxWidth: .infinity).frame(height: height)` and
   `RoundedRectangle(cornerRadius: 8)` (matching REC). In `SoloDeckView.crossfaderBar`
   (`:225-226`) pass `CueButton(model:, deck:, height: 44)` and **delete** the outer
   `.frame(minHeight: 44)` — an outer frame around a 32 pt label is exactly what made the
   button look short next to REC/ECHO/CRATE. Leave `TwinDeckView` and `WorkspaceView` on the
   default 32.

**Tests:** none (view-only). **Verify:** the mixer's top-right shows a "?" that opens the
transitions panel, no "Transitions" pill remains, and REC · ECHO · CUE · CRATE are all 44 pt
tall with matching corners.

---

### T10 — Crate: two decks, "Import playlist", real tracks

The largest task. Split the work as: model + bridge first (testable), view second.

**Files:** *new* `Sources/DJ/Domain/PlaylistCrateImporter.swift`; *new*
`Sources/DJ/Features/Workspace/CrateSheetView.swift` (moved out of `SoloDeckView.swift`);
`Sources/DJ/Features/Workspace/WorkspaceModel.swift`; `Sources/DJ/Features/Workspace/SoloDeckView.swift`

**(a) The app-playlist → DJ-crate bridge.**

```swift
/// The one seam between the app's Playlists and the decks. A deck's crate is an
/// app playlist imported into the DJ library: every track whose audio is on this
/// device (a local file, or a complete pinned cache file) is bookmarked into
/// `DJLibraryStore` and saved as a crate named after the playlist. Tracks whose
/// audio is not on the device are reported, never silently dropped (FR-LIB-8).
public protocol PlaylistCrateImporting: Sendable {
    func availablePlaylists() async -> [CratePlaylistSummary]
    func tracks(in playlistID: Int64) async -> [CrateTrackSummary]
    func importCrate(playlistID: Int64, title: String) async throws -> CrateImportResult
}

public struct CratePlaylistSummary: Identifiable, Equatable, Sendable {
    public let id: Int64; public let title: String; public let trackCount: Int
}
public struct CrateTrackSummary: Identifiable, Equatable, Sendable {
    public let id: Int64; public let title: String; public let artist: String
    public let isOnDevice: Bool
}
public struct CrateImportResult: Equatable, Sendable {
    public let source: DeckQueueSource     // .playlist(id:title:) — the DJ crate
    public let imported: Int
    public let skipped: Int
}

public struct PlaylistCrateImporter: PlaylistCrateImporting { … }
```

Live implementation:

- `availablePlaylists()` → `LibraryStore.shared.allPlaylists()` mapped, with counts from
  `playlistTrackRows(playlistId:)`.
- `tracks(in:)` → `playlistTrackRows`, `isOnDevice` decided by the resolver below.
- `localURL(for row: TrackRow) -> URL?` — the single resolver, mirroring
  `AudioPlayer.buildItem` (`:465-491`): `asset.bookmark` via `BookmarkVault.resolve`, else
  `asset.relPath` under the managed-copy directory, else — for `.remote` — the pinned
  complete cache file (`CacheStore.completeCacheExists(for:)` then
  `CacheStore.fileURL(for: CacheKeyGenerator.key(for:))`), else `nil`.
- `importCrate` builds `[DJLibraryStore.DownloadedTrackItem]` from the resolvable rows,
  calls `importDownloadedTracks`, then `saveCrate(title:trackIDs:)`, returning
  `.playlist(id: crateID, title: title)`. Change the `DJImportEvent` detail string in
  `DJLibraryStore.importDownloadedTracks` (`:719`) from `"genre crate"` to `"playlist crate"`.

**(b) `WorkspaceModel`.**

- New injected dependency: `crateImporter: any PlaylistCrateImporting = PlaylistCrateImporter()`
  as a defaulted `init` parameter (same pattern as `library:`), stored in a `let`.
- New published state:

  ```swift
  @Published public private(set) var importedCrateA: DeckQueueSource?
  @Published public private(set) var importedCrateB: DeckQueueSource?
  @Published public private(set) var crateImportError: String?
  @Published public private(set) var isImportingCrate = false
  public func importedCrate(for deck: PerformanceEngine.Deck) -> DeckQueueSource?
  public func availableCratePlaylists() async -> [CratePlaylistSummary]
  public func cratePlaylistTracks(_ id: Int64) async -> [CrateTrackSummary]
  public func importCrate(playlistID: Int64, title: String,
                          into deck: PerformanceEngine.Deck) async
  ```

  `importCrate` sets `isImportingCrate`, calls the importer, on success stores the returned
  source in `importedCrateA/B` **and** calls the existing
  `selectQueue(_:for:)` so `queueA/queueB` fills with real `DeckQueueRow`s (all the existing
  load/readiness plumbing then works unchanged); on failure sets `crateImportError`.
  `raiseCrateSheet()` keeps its `refreshDeckQueues()` call.

**(c) `CrateSheetView` — the popup the request describes.**

Move the type into its own file and rewrite it as a vertical split:

```
┌──────────────────────────────── grabber ─────────── [ ✕ dj.crate.close ] ┐
│ DECK A — <playlist name or nothing>                                       │  upper half
│   [ Import playlist ]  (when nothing imported)                            │
│   …scrollable DeckQueueRow list (when imported)…                          │
├───────────────────────────────────────────────────────────────────────────┤
│ DECK B — <playlist name or nothing>                                       │  lower half
│   [ Import playlist ] / …list…                                            │
└───────────────────────────────────────────────────────────────────────────┘
```

- The container is a `VStack(spacing: 0)` of two halves, each
  `.frame(maxHeight: .infinity)`, separated by a `Divider()`. The sheet keeps
  `.frame(maxHeight: WorkspaceModel.crateSheetMaxHeight(containerHeight:))` and still renders
  **behind** `crossfaderBar` — §42.7 is not negotiable.
- Half header: `Text("DECK A" + (importedCrate(for: .a).map { " — \($0.title)" } ?? ""))`,
  identifier `dj.crate.deck.a.title` (and `.b`).
- Empty state: one button `Label("Import playlist", systemImage: "square.and.arrow.down")`,
  identifier `dj.crate.import.a` / `.b`.
- Populated state: the **existing** `rowView(_:)` list over `model.queue(for: deck).rows`,
  scrollable, with the existing `dj.queue.row.<title>` identifiers and one-tap
  `loadAndPlay`. Keep the existing readiness/`status(for:)` rendering.
- Replacing an imported crate: the deck header carries a small `Change` button (identifier
  `dj.crate.change.a`) that re-opens the picker.
- The `QueueSourcePicker` type stays where it is — the iPad `WorkspaceView` still uses it.
- **The picker sheet** (`CratePlaylistPickerView`, in the same new file): presented from
  either half via `.sheet(item: $pickingDeck)`. It lists
  `await model.availableCratePlaylists()` as `DisclosureGroup`s — the row shows the title and
  `"\(trackCount) tracks"`, and expanding it lists `cratePlaylistTracks(id)` with each
  track's title, artist and a dimmed "not on this device" tag when `isOnDevice == false`.
  Identifiers: `dj.crate.picker.row.<title>`, `dj.crate.picker.expand.<title>`. Selecting a
  row arms it; `Cancel` / `Import` (`dj.crate.picker.confirm`) at the bottom. `Import` calls
  `model.importCrate(playlistID:title:into:)`, shows a `ProgressView` while
  `isImportingCrate`, and dismisses on success. `crateImportError` renders inline in the
  deck's half — an import that found nothing on the device says so.

**Tests** — *new* `Tests/DJTests/CrateImportTests.swift` with a fake `PlaylistCrateImporting`:

1. A fresh `WorkspaceModel` has `importedCrateA == nil` and `importedCrateB == nil` — the
   sheet starts empty on both decks.
2. `importCrate(playlistID: 1, title: "Set", into: .a)` sets `importedCrateA` to
   `.playlist(id:title: "Set")`, fills `queueA.rows` from the fake library, and leaves
   `importedCrateB` and `queueB` untouched (FR-ENG-13: the decks stay independent).
3. Importing into `.b` afterwards leaves `.a`'s crate as it was.
4. A throwing importer sets `crateImportError` and leaves `importedCrateA == nil`.
5. `isImportingCrate` is false again after both the success and the failure path.

*New* `Tests/DJTests/PlaylistCrateImporterTests.swift`:

6. With a `LibraryStore(inMemory: true)` playlist of two local fixture files and one remote
   row with no cache file, `importCrate` returns `imported == 2`, `skipped == 1`, and the
   named crate exists in a temp `DJLibraryStore` holding two items in playlist order.
7. Re-importing the same playlist replaces rather than stacks (the `saveCrate` contract).

**Verify:** `make test-swift`; on device, mixer → CRATE → two halves, Import playlist on each,
expand a playlist to see its songs, confirm, and the deck header reads
`DECK A — <name>` with the tracks listed and loadable.

---

### T11 — Regression suite and docs catch-up

**Files:** `UIRegressionTests/DJMixRegressionUITests.swift`,
`UIRegressionTests/DJLiveMixRegressionUITests.swift`,
`UIRegressionTests/PlaylistRegressionUITests.swift`,
`UIRegressionTests/NowPlayingRegressionUITests.swift`,
`UIRegressionTests/DJPerformanceDriver.swift`, `current_status.md`

1. `DJMixRegressionUITests.testAT_DJ_EntryMusicAndCrateAreReachable` (`:47-58`): `dj.library`
   no longer exists. Tap `dj.playlists` and assert the modal Playlists screen appears
   (`app.staticTexts["Playlists"]`), then dismiss it. The Crate half of the test now asserts
   `dj.crate.sheet` **and** both `dj.crate.import.a` / `dj.crate.import.b`.
2. `DJMixRegressionUITests.testAT_MIX_01_GenrePickerBuildsTwoCrates` (`:96-97`) and
   `DJLiveMixRegressionUITests` (`:86,124-126`): `genre.sendToDJ` is gone. Replace each
   "send to DJ" step with the new flow — `source.addToPlaylist` → set the count → create a
   playlist named after the genre → `remoteAdd.confirm` — and then, in the decks,
   `dj.crate.import.a` → `dj.crate.picker.row.<Genre>` → `dj.crate.picker.confirm`. The
   existing `assertQueues` assertion is unchanged: the crate is still a `DeckQueueSource`
   holding that genre's tracks.
3. `PlaylistRegressionUITests.testPlaylistDetailToolbarLayout`: add
   `XCTAssertTrue(app.waitFor("playlist.back").isHittable)` and assert the `+`'s `frame.minX`
   is greater than the `EditButton`'s — the "far right" requirement as an executable check.
4. `PlaylistRegressionUITests.testAddTracksToPlaylistFromDetailView`: the `+` now opens a
   sheet, so assert `playlist.add.confirm` exists instead of the old
   `"No tracks available"` menu text.
5. `NowPlayingRegressionUITests`: add `np.download` and `np.watchDownload` to
   `testControlsMeetMinimumHitTarget`'s identifier list — the 9 pt hit target is the bug T6
   fixes, and this is the check that keeps it fixed.
6. `DJPerformanceDriver.openDJDecks()` (`:268`) still taps `dj.decks` — unchanged. Add
   `func importCrate(_ playlist: String, into deck: String)` helper for step 2.
7. Update `current_status.md`: move this plan from "next" to landed, listing the commits.

**Verify (hand-run, once, at the end):**

```
make test-ui-regression LANES=playlists
make test-ui-regression LANES=nowplaying
make test-ui-regression LANES=djmix
```

Lanes whose prerequisites are missing skip rather than fail; a skip is an acceptable result,
a failure is not.

---

## 4 · File manifest

**New**

| File | Target | Why |
|---|---|---|
| `Sources/Domain/PlaylistDedup.swift` | Core | pure dedup policy (T4) |
| `Sources/Domain/FolderImportIdentity.swift` | Core | canonical folder key (T4) |
| `Sources/Remote/RemotePlaylistIngest.swift` | Core | persist browsed remote nodes (T8) |
| `Sources/Features/Playlists/AddTracksToPlaylistSheet.swift` | app | the Music picker popup (T5) |
| `Sources/Features/Playlists/AddToPlaylistDialog.swift` | app | shared add-to-playlist dialog (T6) |
| `Sources/Features/Sources/AddRemoteTracksSheet.swift` | app | "Add N tracks to playlist" (T8) |
| `Sources/DJ/Domain/PlaylistCrateImporter.swift` | DJ | app playlist → DJ crate bridge (T10) |
| `Sources/DJ/Features/Workspace/CrateSheetView.swift` | DJ | the two-deck crate popup (T10) |
| `Tests/PlaylistDedupTests.swift`, `Tests/MigrationV14Tests.swift`, `Tests/CacheAdoptionTests.swift`, `Tests/RemotePlaylistIngestTests.swift` | CoreTests | |
| `Tests/DJTests/PlaylistCrateImporterTests.swift` | DJTests | |
| *(as landed)* the planned `Tests/DJTests/CrateImportTests.swift` cases live in `Tests/DJTests/WorkspaceModelTests.swift` | DJTests | all five assertions, beside the other `WorkspaceModel` tests |

**Deleted:** `Sources/Features/Sources/GenreCrateImporter.swift` (T8).

**Modified:** `AnimatedSplashView`, `DJHomeView`, `DJEntryModel`, `PlaylistsView`,
`CreatePlaylistSheet`, `NowPlayingView`, `SourceDetailView`, `AppState`, `LibraryStore`,
`Schema`, `Entities`, `IngestService`, `CacheStore`, `AudioPlayer`, `CacheGlyph` call sites,
`TransitionCoachAccessory`, `CueControls`, `SoloDeckView`, `TwinDeckView`, `WorkspaceView`,
`WorkspaceModel`, `DJLibraryStore` (one string), plus the five regression files and
`Tonearm.xcodeproj` (regenerated).

---

## 5 · Risks, ranked

1. **Deleting a duplicate folder source deletes its tracks** (T4b). That is the intent — the
   folder was imported twice — but it is destructive. Mitigations, all required: the repair
   runs **once** behind a `UserDefaults` flag; it only ever deletes a source whose resolved
   folder path exactly equals a surviving source's; it moves every item the survivor lacks
   **before** deleting; test 7 asserts no membership is lost. If a bookmark cannot be
   resolved, the group is **skipped**, never guessed.
2. **Persisted remote rows losing their headers** (T8). Covered by pinning the bytes at add
   time. A track whose download fails stays in the playlist but will not play offline — the
   sheet reports the failure count rather than claiming success.
3. **Removing `DJDestination.library`** takes the DJ tab's only route to the whole Music list.
   That is the requested trade (Playlists is the DJ-side entry). The Music tab is unaffected.
4. **Crate import cost** (T10): `DJLibraryStore.importDownloadedTracks` SHA-256s every file.
   A large playlist takes seconds. The import runs off the main actor (it already does — the
   store is an actor-isolated pool) and the sheet shows `isImportingCrate`; do not add a
   progress bar with fake fractions.
5. **The crate sheet must never cover the crossfader** (§42.7). The two-half rewrite keeps
   `crateSheetMaxHeight` and the render order; re-check by hand on a small iPhone.
6. **`refreshCacheState` change** (T7) touches the playback hot path. It only widens which
   assets get a truthful readout; it does not change what is fetched.

---

## 6 · Definition of done

- All eleven tasks are implemented on `main`; the landed commit groups are recorded above,
  and the final implementation commit passed the full hook suite.
- `make ci-guards` and `make test-swift` pass at every commit.
- The eleven behaviours in the request are demonstrable on device: splash without a subtitle
  and with a square translucent tile; DJ home ordered Library-then-Perform with "Open DJ
  Mixer", a visible Recorded Mixes glyph and a Playlists popup; playlist detail with Back
  left and `+` beside the overflow; no duplicate playlists on add or on file; a searchable
  Music picker behind the playlist `+`; a Now Playing download button that works and an
  add-to-playlist dialog that can create a playlist; no "Send to DJ Library" anywhere and a
  remote `+` that adds N tracks to a chosen or new playlist; a downloaded track that reports
  its real cache percentage; a "?" in the mixer's top-right instead of a Transitions pill;
  a two-deck crate popup with Import playlist; and a CUE button the same height as its row.
- The named regression lanes have been hand-run once and are green or honestly skipped.
- `current_status.md` records the landed commits.
