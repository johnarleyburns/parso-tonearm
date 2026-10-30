# Native int4/128-D starter-pack rollout

## Goal

Replace the legacy projected/512-D Mood Starter database with one immutable,
bundled starter v4 database generated from the frozen Jamendo cohort.  There is
no compatibility path for the old starter embeddings: an upgrade removes only
the previous `Mood Starter` source and seeds the v4 pack again. User-imported
local and remote-library sources are never touched.

## Completed evidence

- The frozen catalog contains 886 Jamendo tracks, split into eight 100-track
  batches and one 86-track batch.
- GitHub Actions pilot `40991507207` processed ten real tracks successfully:
  zero failures, 10.166 s p90, 9.55 MB peak temporary disk, and a recommended
  maximum of 100 tracks per macOS runner.
- The runner now extracts the native 128-D Core ML output and decodes the
  production int8/base64 tool result before validating shard payloads.

## Delivery order

1. Make the iOS runtime read native starter v4 rows: 128 little-endian
   float32 values plus transition profile JSON are converted to the app's
   in-memory quantized embedding form. Reject malformed rows.
2. On detecting a different starter content version, remove only the old Mood
   Starter source, clear its merge version, and reseed the bundled v4 source.
3. Dispatch `starter-shard-build.yml` once per immutable batch. It publishes
   only a complete, zero-failure shard to a unique prerelease tag.
4. Commit an explicit allowlist of the nine published asset URLs and SHA-256
   values. The assembler must never discover “latest” assets.
5. Dispatch `assemble-starter-pack.yml`. It re-verifies every asset, reconciles
   all 886 identities exactly once, emits `starter.sqlite`, and publishes an
   immutable starter-pack prerelease.
6. Update `Config/starter.lock` to that exact release asset and SHA-256, fetch
   it into `Resources/Starter/`, then run the iOS archive/test validation.

## Exit criteria

- The app accepts only starter database format 4 and seeds native 128-D rows.
- Nine complete shard assets cover all 886 catalog identities exactly once.
- The assembled pack passes SQLite integrity, checksum, and count reconciliation.
- `starter.lock` pins the published pack; a clean app build bundles it.
