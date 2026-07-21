# Watch App "Tap Does Nothing" Fix Plan

## Problem

On the watch app (Platterhead), albums and songs are visible, but clicking them
or tapping "Play All" does nothing — no visible feedback, no navigation, no
fetch indicator.

## Root Causes (4 interrelated bugs)

### Bug 1 — No auto-navigation to Now Playing on play

When a user taps a song or "Play All" and the file IS already on the watch,
`WatchPlayer.play()` calls `handleCommand(.play)` which starts AVPlayer playback.
However, the user stays on the album/song detail screen with no indication that
anything happened. They must manually navigate back to root → tap "Now Playing".

### Bug 2 — Fetch overlay invisible (only shown inside NowPlayingView)

When the file is NOT yet on the watch, `resolveURL(for:)` returns `nil` →
`showFetchFor(row)` sets `showFetchOverlay = true` and sends a fetch request to
the iPhone. But `WatchFetchOverlay` is only rendered inside
`WatchNowPlayingView`, so the user (still on album/songs detail) sees nothing.

### Bug 3 — No navigation after fetch completes

When the audio arrives from the iPhone and `WatchSyncHandler.handleAudio()`
calls `WatchPlayer.shared.cancelFetch()`, playback starts but there is still no
navigation to Now Playing.

### Bug 4 — No error feedback when iPhone is unreachable

`WatchSessionAdapter.sendFetchRequest()` silently returns if
`session.isReachable` is false. The user gets zero feedback.

## Solution

### Step 1 — Programmatic navigation via NavigationPath

1. In `PlatterheadWatchApp.swift`, replace the plain `NavigationStack` with a
   bound variant using `NavigationPath`:
   ```swift
   @State private var path = NavigationPath()
   NavigationStack(path: $path) { ... }
   ```

2. Add a `@Published var navigationPath = NavigationPath()` to
   `WatchPlayer`. Bind the app's `$path` to `$player.navigationPath`.

3. Add a `navigateToNowPlaying()` method on `WatchPlayer` that appends
   `WatchNav.nowPlaying` to the path.

4. Call `navigateToNowPlaying()` in `play()` — both when the file resolves
   (playback starts) AND when the file needs fetching (overlay appears).

### Step 2 — Navigate to Now Playing on play action

In `WatchAlbumDetailView`, `WatchSongsView`, and `WatchPlaylistDetailView`,
after calling `WatchPlayer.shared.play(...)`, also call
`WatchPlayer.shared.navigateToNowPlaying()`.

OR: have `WatchPlayer.play()` itself trigger navigation (cleaner — single
responsibility, one place to change).

### Step 3 — iPhone-unreachable feedback

When `sendFetchRequest` fails because the iPhone isn't reachable, show a
"Connecting…" state in the Now Playing view rather than silently doing nothing.
This can be done by:
- Still navigating to Now Playing
- Setting a flag like `@Published var connectionState: WatchConnectionState`
  that the Now Playing view can check to show "Waiting for iPhone…"

### Step 4 — Auto-dismiss navigation after close

When the user taps "Close" in the Now Playing toolbar, also clear the
now-playing navigation from the path (pop the navigation stack entry).

## Files to Change

| File | Change |
|------|--------|
| `WatchApp/WatchPlayer.swift` | Add `navigationPath` + `navigateToNowPlaying()`, call from `play()`, add connection state |
| `WatchApp/PlatterheadWatchApp.swift` | Use `NavigationStack(path:)` bound to `WatchPlayer.navigationPath` |
| `WatchApp/Views/WatchNowPlayingView.swift` | Show "Connecting…" state when waiting for iPhone, handle close to clear navigation |
| `WatchApp/WatchSessionAdapter.swift` | Return success/failure from `sendFetchRequest` so caller can react |

## Verification

1. Tap "Play All" on an album → should navigate to Now Playing and show either
   playback or fetch overlay.
2. Tap a single song → same.
3. When iPhone is unreachable → should navigate to Now Playing and show
   "Connecting…" with a Cancel button.
4. Tap "Close" in Now Playing → should pop back to the previous screen.
