# Custom Track Artwork Plan

## Problem

Tracks without embedded artwork or iTunes matches show nothing but a gradient
in Now Playing and on source tiles. The user wants to attach their own image
from Photos, persisted permanently (not cache-evicted), deleted only when the
track or source is explicitly removed.

## Design Decisions

- **Image source**: local Photos only (no URL paste). Uses `PhotosPicker`.
- **Storage**: `ApplicationSupport/Tonearm/Artwork/<uuid>.jpg` via existing
  `ArtworkStore` actor. Separate from the 7-day-TTL ephemeral cache at
  `Documents/Tonearm/artwork_cache/`.
- **Persistence**: SQLite `custom_artwork` table, keyed by `trackId` with
  `ON DELETE CASCADE` so source deletion automatically removes the DB row.
- **Show on source tiles**: yes. The artwork resolution chain (Step 0 below)
  applies universally, so `SourceArtworkView` and `NowPlayingView` both pick
  it up.
- **Settings**: custom artwork size shown separately from music cache. Custom
  artwork is *never* auto-evicted. Clearing it requires an explicit
  confirmation with a warning that uploaded artwork will be permanently lost.

---

## Files Changed

| # | File | What |
|---|------|------|
| 1 | `Sources/Data/Schema.swift` | v5 migration: `custom_artwork` table |
| 2 | `Sources/Data/LibraryStore.swift` | CRUD queries; pre-delete file cleanup in `deleteSource(id:)` |
| 3 | `Sources/Data/ArtworkStore.swift` | `delete(id:)` method for file removal |
| 4 | `Sources/Data/ArtworkService.swift` | Step 0 in resolution chain: check custom artwork first |
| 5 | `Sources/Features/NowPlaying/NowPlayingView.swift` | "No Image" overlay + `PhotosPicker` |
| 6 | `Sources/App/AppState.swift` | `deleteSource`: pre-delete custom artwork files |
| 7 | `Sources/Features/Settings/SettingsView.swift` | Custom art size row; clear-with-warning dialog |

---

## 1. Schema v5 — `Sources/Data/Schema.swift`

Register migration "v5":

```swift
migrator.registerMigration("v5") { db in
    try db.create(table: "custom_artwork") { t in
        t.column("trackId", .integer).notNull().unique()
            .references("track", onDelete: .cascade)
        t.column("artworkId", .text).notNull()
    }
}
```

- `trackId` is `UNIQUE` — one custom artwork per track.
- `ON DELETE CASCADE` — deleting a source (which cascades to tracks) removes
  the custom artwork row automatically. No manual DB cleanup needed.
- The `artworkId` is the UUID string from `ArtworkStore.store(_:)`.

---

## 2. Database queries — `Sources/Data/LibraryStore.swift`

Add three methods and modify `deleteSource(id:)`:

```swift
// ── Custom Artwork Queries ──────────────────────────────────────────

func customArtworkId(for trackId: Int64) throws -> String? {
    try dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork WHERE trackId = ?",
                         arguments: [trackId])?["artworkId"]
    }
}

func setCustomArtwork(trackId: Int64, artworkId: String) throws {
    try dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO custom_artwork (trackId, artworkId) VALUES (?, ?)
            ON CONFLICT(trackId) DO UPDATE SET artworkId = excluded.artworkId
            """, arguments: [trackId, artworkId])
    }
}

func deleteCustomArtwork(trackId: Int64) throws {
    try dbQueue.write { db in
        try db.execute(sql: "DELETE FROM custom_artwork WHERE trackId = ?",
                       arguments: [trackId])
    }
}

/// All custom artwork IDs for a source (used to delete files before the
/// source cascade removes the DB rows).
func customArtworkIds(forSource sourceId: Int64) throws -> [String] {
    try dbQueue.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT ca.artworkId FROM custom_artwork ca
            JOIN track t ON t.id = ca.trackId
            WHERE t.sourceId = ?
            """, arguments: [sourceId])
        return rows.compactMap { $0["artworkId"] }
    }
}
```

Modify `deleteSource(id:)` to clean up files before the cascade delete:

```swift
func deleteSource(id: Int64) throws {
    // Delete custom artwork files from disk before the cascade removes
    // the DB rows (after which we can't find the artworkIds).
    if let ids = try? customArtworkIds(forSource: id) {
        for aid in ids {
            await ArtworkStore.shared.delete(id: aid)
        }
    }
    _ = try dbQueue.write { db in
        try Source.deleteOne(db, key: id)
    }
}
```

---

## 3. File cleanup — `Sources/Data/ArtworkStore.swift`

Add a `delete(id:)` method to the existing actor:

```swift
func delete(id: String) {
    memory.removeObject(forKey: id as NSString)
    let url = dir.appendingPathComponent("\(id).jpg")
    try? FileManager.default.removeItem(at: url)
}
```

---

## 4. Artwork resolution — `Sources/Data/ArtworkService.swift`

In `trackArtwork(forTrackRow:)`, insert **Step 0** before Step 1 (IA identifier):

```swift
func trackArtwork(forTrackRow row: TrackRow) async -> (image: UIImage, persistable: Bool)? {
    let trackId = row.track.id ?? -1

    // 0. Custom user-attached artwork (highest priority, persistable).
    if let customId = try? await LibraryStore.shared.customArtworkId(for: trackId),
       !customId.isEmpty,
       let image = await ArtworkStore.shared.image(id: customId) {
        return (image, true)
    }

    // 1. IA identifier cover (strong).
    if let id = row.album?.artworkId, !id.isEmpty {
        // ... existing code ...
```

Note: `ArtworkService` currently imports `Foundation`, `UIKit`, and
`AVFoundation`. It doesn't import `LibraryStore` — that's a separate
actor. Both are singletons (`ArtworkService.shared`, `LibraryStore.shared`)
and can be called from any `async` context.

---

## 5. Now Playing UI — `Sources/Features/NowPlaying/NowPlayingView.swift`

### New imports

```swift
import PhotosUI
```

### New `@State` properties

```swift
@State private var showPhotoPicker = false
@State private var selectedPhotoItem: PhotosPickerItem?
```

### Replace artwork area (lines 21–37)

Extract the artwork into a dedicated view that either shows the current
art (with gradient fallback) or, when `npArtwork` is nil and no custom
artwork is pending, a "No Image" tappable overlay:

```swift
private var artworkArea: some View {
    ZStack {
        ArtworkView(
            image: npArtwork,
            trackRow: player.currentTrack,
            seed: player.currentTrack?.album?.title ?? "np",
            cornerRadius: 16
        )
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)

        // "No Image" overlay — only when no artwork resolved at all.
        if npArtwork == nil {
            noImageOverlay
        }

        // Ambient video overlay (existing)
        if player.isAmbient, let channelId = player.ambientChannelId,
           let videoURL = BuiltInContentProvider.bundledVideoURL(forChannelId: channelId) {
            LoopingVideoView(url: videoURL, isPlaying: player.isPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)
        }
    }
    .onTapGesture {
        guard npArtwork == nil, player.currentTrack != nil else { return }
        showPhotoPicker = true
    }
}
```

### "No Image" overlay

```swift
private var noImageOverlay: some View {
    VStack(spacing: 8) {
        Image(systemName: "photo.badge.plus")
            .font(.system(size: 28, weight: .light))
        Text("No Image")
            .font(.system(size: 13, weight: .medium))
        Text("Add Artwork")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
    .foregroundStyle(.white.opacity(0.55))
}
```

### Photos picker modifier

Attached to the `ZStack` body (or to the view's outermost `ZStack`):

```swift
.photosPicker(
    isPresented: $showPhotoPicker,
    selection: $selectedPhotoItem,
    matching: .images
)
.onChange(of: selectedPhotoItem) { _, item in
    guard let item else { return }
    Task {
        guard let data = try? await item.loadTransferable(type: Data.self),
              await ArtworkStore.shared.store(data) != nil,
              let trackId = player.currentTrack?.track.id else { return }
        // Re-read the artworkId from store? Or we can return it from store.
        // Better: have ArtworkStore.store return the UUID, then save.
    }
}
```

**Issue**: `ArtworkStore.store(_:)` returns `String?` (the UUID). We need it.
After storing, call `LibraryStore.shared.setCustomArtwork(trackId:, artworkId:)`,
then refresh `npArtwork` by re-fetching via `ArtworkService.shared.artwork(forTrackRow:)`.

Refined `.onChange`:

```swift
.onChange(of: selectedPhotoItem) { _, item in
    guard let item else { return }
    Task {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let artworkId = await ArtworkStore.shared.store(data),
              let trackId = player.currentTrack?.track.id else { return }
        try? await LibraryStore.shared.setCustomArtwork(trackId: trackId, artworkId: artworkId)
        // Trigger re-fetch — Step 0 of ArtworkService will pick up the custom art.
        npArtwork = await ArtworkService.shared.artwork(forTrackRow: player.currentTrack!)
    }
}
```

---

## 6. Source deletion cleanup — `Sources/App/AppState.swift`

Modify `deleteSource(_:)` to clean up custom artwork files *before* the
SQLite cascade removes the rows:

```swift
func deleteSource(_ source: Source) async {
    guard let id = source.id else { return }
    // Delete custom artwork files from disk before cascade removes DB rows.
    if let artworkIds = try? await store.customArtworkIds(forSource: id) {
        for aid in artworkIds { await ArtworkStore.shared.delete(id: aid) }
    }
    try? await store.deleteSource(id: id)
    await reload()
}
```

---

## 7. Settings storage breakdown — `Sources/Features/Settings/SettingsView.swift`

### New `@State` property

```swift
@State private var customArtworkBytes: Int64 = 0
```

### New helper: compute custom artwork size

```swift
private func customArtworkSize() -> Int64 {
    let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask, appropriateFor: nil, create: false))
        .flatMap { $0.appendingPathComponent("Tonearm/Artwork") }
    guard let dir, let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return contents.reduce(0) { total, url in
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        return total + size
    }
}
```

### Refresh

Update `refresh()` to include custom artwork size:

```swift
private func refresh() async {
    cacheUsed = await CacheStore.shared.totalCachedBytes()
    cacheLimit = await CacheStore.shared.currentLimit()
    cachedCount = await CacheStore.shared.cachedTrackCount()
    customArtworkBytes = customArtworkSize()
}
```

### New state for clear confirmation

```swift
@State private var showClearCustomConfirm = false
```

### New card: Custom Artwork (placed after `clearCard`)

```swift
private var customArtworkCard: some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack {
            Text("Custom Artwork").font(.system(size: 13, weight: .bold))
            Spacer()
            Text(TimeFmt.megabytes(customArtworkBytes))
                .font(.system(size: 11)).foregroundStyle(Palette.ink3)
        }
        .padding(.bottom, 8)

        Button {
            showClearCustomConfirm = true
        } label: {
            Text("Clear Custom Artwork")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity)
        }
        .disabled(customArtworkBytes == 0)
    }
    .padding(15)
    .glassSurface(cornerRadius: 18)
}
```

### Alert for custom artwork deletion

Attach to the view:

```swift
.alert("Delete all custom artwork?", isPresented: $showClearCustomConfirm) {
    Button("Cancel", role: .cancel) {}
    Button("Delete All", role: .destructive) {
        Task {
            // Delete all custom artwork rows' files
            if let ids = try? await appState.store.allCustomArtworkIds() {
                for aid in ids { await ArtworkStore.shared.delete(id: aid) }
            }
            try? await appState.store.clearAllCustomArtwork()
            await refresh()
        }
    }
} message: {
    Text("Custom artwork you've uploaded will be permanently lost. This cannot be undone.")
}
```

The `alert` (as opposed to `confirmationDialog`) is more prominent and
forces the user to read the warning before acting.

### Additional LibraryStore methods needed

```swift
func allCustomArtworkIds() throws -> [String] {
    try dbQueue.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT artworkId FROM custom_artwork")
        return rows.compactMap { $0["artworkId"] }
    }
}

func clearAllCustomArtwork() throws {
    try dbQueue.write { db in
        try db.execute(sql: "DELETE FROM custom_artwork")
    }
}
```

---

## Storage Layout

After implementation, the app has **three** distinct artwork/cache stores:

| Store | Location | Eviction | TTL |
|-------|----------|----------|-----|
| Music cache | `Caches/Tonearm/StreamCache/` | LRU, limit-based | Manual or under limit |
| Ephemeral art cache | `Documents/Tonearm/artwork_cache/` | 7-day TTL + manual | 7 days |
| Custom artwork | `ApplicationSupport/Tonearm/Artwork/` | Never (manual only) | Forever |

Custom artwork uses UUID filenames (`.jpg` via `ArtworkStore`) and is
*never* touched by `CacheStore` eviction, `ArtworkService.clearAll()`,
or the "Clear Cache" button. It can only be removed by:
1. Deleting the source (which cascade-deletes the `custom_artwork` row
   and triggers file cleanup in `deleteSource`).
2. Explicitly tapping "Clear Custom Artwork" in Settings (with a
   confirmation alert).

---

## Test Plan

### Unit tests

1. **Schema v5 migration** — verify `custom_artwork` table exists with
   correct columns and foreign key.

2. **LibraryStore custom artwork CRUD**:
   - `customArtworkId(for:)` returns nil when no custom art set
   - `setCustomArtwork(trackId:artworkId:)` inserts; calling again with
     same trackId updates (upsert)
   - `customArtworkIds(forSource:)` returns all artwork IDs for a source
   - `deleteCustomArtwork(trackId:)` removes the row
   - `clearAllCustomArtwork()` removes all rows
   - Deleting a source removes associated custom artwork rows (cascade)

3. **ArtworkService resolution** — when custom artwork exists for a track,
   `trackArtwork(forTrackRow:)` returns it (strong/persistable match)
   before trying IA/embedded/iTunes.

4. **FilenameQueryParser** — existing tests pass; added tests for
   "Solomun Boiler Room DJ Set" and "Stephan Bodzin Boiler Room Berlin
   Live" from earlier fixes.

5. **Confidence gate** — existing rejection tests still pass; new
   "Stephan Bodzin Berlin" partial match test passes.
