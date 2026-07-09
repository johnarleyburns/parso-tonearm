# Plan: Cache & display artwork for all source types with per-type fallback icons

## Problem
`AppState.firstArtworkId(for:)` only resolves **IA identifiers**. Local sources always
have `artworkId == nil` (`IngestService.swift`), so they never show embedded art — only
a seed gradient. There's no fallback icon anywhere, and no way to tell a "Local Files"
source from a folder import (both are `SourceKind.local`).

## Requirements (from user)
1. Local Files source: pick the first added file's artwork; remember it (cached) and use
   it in Sources view and other views.
2. Local Folder source: pick the first artwork from the first album added; use it in
   Sources view and other views.
3. If no artwork for a local source: use a local file-list icon (Local Files) or a local
   folder icon (Local Folder). The folder icon must differ from the files icon.
4. IA lists/collections/favorites where no artwork resolves: use a music-collection icon
   (different from local files icon and local folder icon).
5. IA item: art if available, otherwise an icon over the gradient (never bare gradient).
6. Apply going forward AND retroactively on app update (migration + lazy backfill).

## Icon mapping
- `.local`, files (localIsFolder == false) -> `music.note.list`
- `.local`, folder (localIsFolder == true) -> `folder.fill`
- `.iaList` / `.iaCollection` / `.iaFavorites` -> `square.stack.fill`
- `.iaItem` -> `music.note`

## Implementation steps

### 1. Schema (`Entities.swift`, `Schema.swift`) — additive, non-breaking
- Add to `Source` struct at the END with defaults:
  - `var localIsFolder: Bool = false`
  - `var artworkTrackId: Int64? = nil` (remembers the representative track's embedded art)
- Migration `v4`: `ALTER TABLE source ADD COLUMN localIsFolder`, `artworkTrackId`.
  Backfill legacy `.local` rows: `localIsFolder = (title != 'Local Files')`.

### 2. Per-kind fallback icon (`Entities.swift`)
- Add `Source.fallbackIcon: String` computed per the mapping above.

### 3. `ArtworkView` (`ArtworkView.swift`)
- Add `var fallbackIcon: String? = nil`. When no image resolves and `fallbackIcon != nil`,
  render the SF Symbol centered over the existing gradient. Default nil keeps all other
  call sites unchanged.

### 4. Artwork resolution for local sources (`AppState.swift`, `LibraryStore.swift`)
- `LibraryStore.setSourceArtworkTrack(id:trackId:)` + `firstTrackRow(forSource:)`.
- `AppState.resolvedArtwork(for:) async -> ResolvedSourceArtwork` returning
  `{ identifier: String?, trackRow: TrackRow?, fallbackIcon: String }`:
  - IA sources: `identifier = firstAvailableIdentifier(...)`, `trackRow = nil`.
  - Local sources: representative `TrackRow` — prefer stored `artworkTrackId`; else scan
    tracks in order, pick first whose embedded art extracts (via
    `ArtworkService.artwork(forTrackRow:)`, already disk-cached as `local-<trackId>`), then
    persist that track id back to the source (remembered).
  - `fallbackIcon` always set from `source.fallbackIcon`.

### 5. Wire the tiles
- New `SourceArtworkView(source:cornerRadius:)` wrapper holding `@State` resolution result,
  rendering `ArtworkView` with identifier/trackRow + fallbackIcon.
- Replace inline `ArtworkView(identifier:seed:)` + `.task { firstArtworkId }` in
  `SourcesView.swift`, `LibraryView.swift` (AlbumCell), `SourceDetailView.swift` (hero).

### 6. Ingest sets the flag going forward (`IngestService.swift`)
- `addFolder` -> `localIsFolder: true`. `addFiles` -> keep default false.

### 7. Apply-on-update
- Migration v4 backfills `localIsFolder`. Local art resolves lazily on first tile render
  (covers pre-existing sources) and is persisted via `artworkTrackId`. Bounded background
  warm pass in `bootstrap()` for local sources missing `artworkTrackId`.

### 8. Tests & verification
- Unit test for `Source.fallbackIcon` across all kinds/flags.
- `xcodebuild -scheme Tonearm build`; run `TonearmTests`.

## Notes / tradeoffs
- New `Source` fields use trailing defaults so existing initializers and tests compile
  unchanged; no new `SourceKind` case.
- `eraseDatabaseOnSchemaChange` is DEBUG-only; migration v4 handles real app-update installs.
