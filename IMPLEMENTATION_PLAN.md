# Implementation Plan: Download & Watch Status Icons + Queue Tap-to-Play

## Overview

Add download-to-phone AND watch status visibility across the app, with actionable tap/hold controls, plus fix queue tap-to-play.

---

## 1. New Dependencies / Infrastructure

### 1.1 `TrackLocation` enum (new file: `Sources/WatchSync/TrackLocation.swift`)

```swift
public enum PhoneDownloadState: Equatable {
    case notDownloaded      // not on phone
    case downloaded         // pinned to phone (remote) or local file exists
    case downloading(Double?) // downloading from remote (progress 0-1)
}

public enum TrackLocation: Equatable {
    case onPhone(PhoneDownloadState)
    case onWatch(WatchGlyphState)
}
```

Used to convey "where is this track?" as a pair of states that UI can consume.

### 1.2 New methods in `AppState` (add to `Sources/App/AppState.swift`)

```swift
// Resolves whether a TrackRow is "downloaded to phone":
// - Local tracks (bookmark/relPath) → .downloaded
// - Remote tracks with pinned cache entry → .downloaded  
// - Remote tracks with partial cache → .downloading(progress)
// - Remote tracks with no cache → .notDownloaded
func phoneDownloadState(for row: TrackRow) -> PhoneDownloadState

// Unpin a single track's cache (remove from phone but keep remote reference)
func removeDownloadFromPhone(rows: [TrackRow]) async

// Convenience: combined state
func trackLocation(for row: TrackRow) -> (phone: PhoneDownloadState, watch: WatchGlyphState) {
    (phoneDownloadState(for: row), watchGlyphState(for: row))
}
```

### 1.3 New icons (modify existing `CacheGlyph` + create `PhoneDownloadGlyph`)

#### `CacheGlyph` already exists at `Sources/DesignSystem/CacheGlyph.swift`
- `.none` = unfilled circle (border only)
- `.filling` = donut progress
- `.cached` = filled brass dot

#### New `PhoneDownloadGlyph` view (add to `Sources/DesignSystem/CacheGlyph.swift` or new file)
- Accepts `PhoneDownloadState` and `compact: Bool`
- `compact: true` (row usage): shows filled dot ONLY when `.downloaded`, shows nothing for `.notDownloaded` or `.downloading`
- `compact: false` (Now Playing): shows unfilled border for `.notDownloaded`, progress donut for `.downloading`, filled for `.downloaded`

Actually, this IS `CacheGlyph` — the existing view already maps perfectly:
- `.none` = unfilled circle → "not on phone"
- `.filling` = progress → "downloading"
- `.cached` = filled dot → "on phone"

So we just need to expose the right state. The `CacheGlyph` already has the right visuals.

#### `WatchGlyphView` already exists at `Sources/DesignSystem/WatchGlyph.swift`
- Need to add `compact: Bool` parameter:
  - `compact: true`: only show for `.onWatch`, `.transferring`, `.failed` (hide `.notOnWatch`)
  - `compact: false`: show all states including `.notOnWatch` (unfilled/gray)

---

## 2. Now Playing View Changes

**File:** `Sources/Features/NowPlaying/NowPlayingView.swift`

### 2.1 Add download/watch icons to toolbar (line ~256)

Insert into the toolbar `HStack` between the EQ button and the spacer:

```swift
// Phone download status
Button {
    // action depends on state
} label: {
    let phoneState = phoneDownloadState()
    CacheGlyph(state: mapToCacheGlyphState(phoneState))
}
.buttonStyle(.plain)

// Watch status  
Button {
    // action depends on state
} label: {
    let watchState = appState.watchGlyphState(forKey: currentKey)
    WatchGlyphView(state: watchState)  // with compact: false
}
.buttonStyle(.plain)
```

### 2.2 Interaction rules for NP icons

For the **phone download icon**:
| Current State | Tap Action |
|---|---|
| `.notDownloaded` | Call `appState.download(rows: [currentRow])` — download + pin |
| `.downloading` | No action (or cancel download if we add that) |
| `.downloaded` | Call `appState.removeDownloadFromPhone(rows: [currentRow])` — unpin |

For the **watch icon**:
| Current State | Tap Action |
|---|---|
| `.notOnWatch` | Call `appState.downloadToWatch(rows: [currentRow])` |
| `.transferring` | No action |
| `.onWatch` | Call `appState.removeFromWatch(rows: [currentRow])` |
| `.failed` | Call `appState.downloadToWatch(rows: [currentRow])` (retry) |

### 2.3 Visual design for NP

- Use same icon style as existing toolbar (36x36 circles with `.ultraThinMaterial` background)
- Position: between the EQ button and the Spacer
- Both icons should always show (never hidden):
  - Watch icon: gray unfilled for not on watch, brass filled for on watch, progress overlay for transferring
  - Phone icon: unfilled circle for not downloaded, brass filled for downloaded

---

## 3. Track Row Changes (Playlists, Library, Sources)

**File:** `Sources/Features/Components.swift` — `TrackRowView` (lines 146-207)

### 3.1 Change watch glyph visibility logic

Current behavior (line 173-176):
```swift
let watchState = appState.watchGlyphState(for: row)
if watchState != .notOnWatch { watchGlyph }  // hidden when not on watch
```

This is already the correct `compact` behavior for rows. Keep it as-is. Only show filled states.

### 3.2 Add phone download glyph to rows

Current behavior (lines 177-179):
```swift
if showCacheGlyph, row.asset?.kind == .remote {
    cacheGlyph  // shows .none for non-current tracks (effectively hidden)
}
```

**Problem**: For non-current tracks, `player.cacheState` is `.none` so the glyph always shows an empty circle (or nothing useful). For local tracks it's hidden entirely.

**Fix**: Add a dedicated phone download glyph that queries the real pinned/cached state:

```swift
// Replace the existing cacheGlyph block with:
if showCacheGlyph {
    let phoneState = appState.phoneDownloadState(for: row)
    if phoneState == .downloaded {
        phoneDownloadGlyph  // filled brass dot only when downloaded
    }
}
```

- Only show the filled dot when the track IS downloaded to phone
- Local tracks (bookmark/relPath) → always show as downloaded
- Remote tracks not pinned → show nothing (blank)
- This matches the user requirement: "ONLY show a filled download icon and never the unfilled (just leave blank)"

### 3.3 Layout order in row

Current order: title · subtitle | Spacer | heart | watch | cache

Keep same order, replace `cacheGlyph` with `phoneDownloadGlyph`. The closing order should be:

```
title · subtitle | Spacer | heart | watch (filled only) | phone (filled only)
```

---

## 4. Context Menu Changes (Long Press)

**File:** `Sources/Features/Components.swift` — `TrackContextMenu` (lines 223-286)

### 4.1 Add "Download to Phone" / "Remove from Phone" menu items

Add after the "Change Artwork" button and before the Favorites button:

```swift
// --- Phone Download ---
let phoneState = appState.phoneDownloadState(for: row)
switch phoneState {
case .notDownloaded:
    Button {
        Task { await appState.download(rows: [row]) }
    } label: {
        Label("Download to Phone", systemImage: "arrow.down.circle")
    }
case .downloaded:
    Button {
        Task { await appState.removeDownloadFromPhone(rows: [row]) }
    } label: {
        Label("Remove from Phone", systemImage: "arrow.down.circle.fill")
    }
case .downloading:
    EmptyView()
}
Divider()
```

### 4.2 Existing watch menu items (already working, lines 254-279)

These are already correct — they show:
- "Download to Watch" when `.notOnWatch`
- "Remove from Watch" when `.onWatch`
- "Retry Download to Watch" when `.failed`

No changes needed to the watch menu items.

### 4.3 Full context menu order (after changes)

```
1. Play
2. Play Next
3. Add to Queue
   ─── Divider ───
4. Change Artwork
5. Download to Phone / Remove from Phone  ← NEW
   ─── Divider ───
6. Add to Favorites / Remove from Favorites
7. Download to Watch / Remove from Watch / Retry
```

---

## 5. Queue Tap-to-Play Fix

**File:** `Sources/Features/NowPlaying/UpNextView.swift`

### 5.1 Add `skipToIndex` method to `AudioPlayer`

**File:** `Sources/Audio/AudioPlayer.swift`

```swift
/// Jump to a specific index in the queue and start playback immediately.
public func skipToIndex(_ newIndex: Int) {
    guard queue.indices.contains(newIndex), newIndex != index else { return }
    index = newIndex
    loadCurrent(autoplay: true)
}
```

Insert after the existing `next()` / `previous()` methods (around line 325).

### 5.2 Add tap gesture to `QueueRow`

**File:** `Sources/Features/NowPlaying/UpNextView.swift`, lines 84-127

Add `.onTapGesture` to the row content:

```swift
.onTapGesture {
    player.skipToIndex(idx)
}
```

Where `idx` is the position in the queue array (the `ForEach` index or enumerated index).

### 5.3 Visual feedback

Optionally add a highlight effect:
```swift
.contentShape(Rectangle())
.onTapGesture { ... }
```

The `.contentShape(Rectangle())` already exists at line 126 — it just needs the `.onTapGesture` added.

---

## 6. Implementation Order

### Phase A: Infrastructure (no UI changes)
1. Add `PhoneDownloadState` enum to `TrackLocation.swift` (new file)
2. Add `phoneDownloadState(for:)` to `AppState` — queries local bookmark/relPath or CacheStore.isPinned
3. Add `removeDownloadFromPhone(rows:)` to `AppState` — unpins cache keys
4. Add `skipToIndex(_:)` to `AudioPlayer`

### Phase B: Context menus (low risk, behind long-press)
5. Add phone download/remove to `TrackContextMenu` 
6. Add phone download items to the context menu

### Phase C: Row icons (visual only)
7. Update `TrackRowView` to show phone download glyph (filled only, replaces existing cacheGlyph)
8. No changes needed to watch glyph (already shows filled-only in rows)

### Phase D: Now Playing toolbar
9. Add phone download icon button to NP toolbar
10. Add watch icon button to NP toolbar
11. Wire up tap actions for both icons

### Phase E: Queue fix
12. Add `.onTapGesture` to `QueueRow` in `UpNextView`
13. Wire to `player.skipToIndex(idx)`

### Phase F: Verify
14. Build and test on simulator
15. Run `swift test` to verify no regressions

---

## 7. Files to Create/Modify

| File | Action | Summary |
|------|--------|---------|
| `Sources/WatchSync/TrackLocation.swift` | **CREATE** | `PhoneDownloadState` + `TrackLocation` types |
| `Sources/App/AppState.swift` | MODIFY | Add `phoneDownloadState(for:)`, `removeDownloadFromPhone(rows:)` |
| `Sources/Audio/AudioPlayer.swift` | MODIFY | Add `skipToIndex(_:)` method |
| `Sources/Features/Components.swift` | MODIFY | Update `TrackRowView` download glyph, update `TrackContextMenu` phone items |
| `Sources/Features/NowPlaying/NowPlayingView.swift` | MODIFY | Add phone/watch icon buttons to toolbar |
| `Sources/Features/NowPlaying/UpNextView.swift` | MODIFY | Add tap-to-play on QueueRow |

---

## 8. Key Design Decisions

1. **Phone download detection**: Local tracks (bookmark/relPath) are always `.downloaded`. Remote tracks check `CacheStore.shared.isPinned(cacheKey)` and `CacheStore.shared.state(for: cacheKey)`.

2. **Compact glyph behavior**: In rows, only show the FILLED state (`.downloaded` or `.onWatch`). Never show unfilled borders in rows — leave blank.

3. **Now Playing always shows both**: Both phone and watch icons are always visible with their current state (unfilled border = not present, filled = present).

4. **CacheGlyph reuse**: The existing `CacheGlyph` view already handles `.none` (unfilled), `.filling` (progress donut), `.cached` (filled dot) — we just need to feed it the correct state for each track (not just the current playing track).

5. **Context menu duplication OK**: Phone and watch download actions appear in BOTH the context menu AND as tappable icons in NP. This is intentional for discoverability.
