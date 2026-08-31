# Watch artwork and Now Playing contract

This contract records the behavior shipped by the watch pipeline. The phone is the only artwork
author; the watch stores and displays opaque, content-addressed derivatives.

## Artwork

- Phone variants are JPEG derivatives with a longest edge of at most 300 px.
- `artworkID` is the SHA-256 of the exact derivative sent to the watch.
- Track bindings are optional `coverArtworkID` and `customArtworkID` fields.
- Display precedence is custom, cover, embedded audio art, then the existing placeholder.
- The watch deduplicates by content address, reports installed artwork IDs in its manifest, adopts
  hash-valid orphan files after recovery, and garbage-collects assets with no track references.
- Custom-art assignment is phone-only; there is no watch authoring affordance.

## Now Playing and route behavior

`WatchNowPlayingView` is the canonical in-app surface. The persistent root chip, local play-start,
remote play-start, restored playback, and app-intent playback all open the same sheet. The system
Now Playing surface remains enabled for background transport and Crown volume; it is intentionally
not suppressed, and receives the same duration and resolved artwork data.

On first local play, an empty audio route parks playback before activation and presents the app-owned
`Choose an Audio Output` card. `watch.now.chooseRoute` deliberately requests the system route picker;
successful activation resumes the pending play. Route loss parks playback and preserves the queue.

## Accessibility identifiers

Stable identifiers are product/test contract, not implementation details:

| Surface | Identifier |
|---|---|
| Root | `watch.root`, `watch.nowPlaying`, `watch.search`, `watch.playlists`, `watch.albums`, `watch.songs` |
| Now Playing | `watch.now.artwork`, `watch.now.title`, `watch.now.elapsed`, `watch.now.remaining` |
| Transport | `watch.now.previous`, `watch.now.playPause`, `watch.now.next`, `watch.now.upNext` |
| Target/download | `watch.now.target`, `watch.now.download`, `watch.now.continue` |
| Route/failure | `watch.now.chooseRoute`, `watch.now.routeHint`, `watch.now.debugRate` (debug only) |

The artwork and downloaded states carry VoiceOver labels; no state relies on color alone. The watch
simulator cannot verify physical audio output, route picker presentation, or hardware VoiceOver
traversal; those remain owner device checks.
