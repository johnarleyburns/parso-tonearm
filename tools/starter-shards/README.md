# Starter shards

Deterministic, independently runnable producer of one immutable starter shard per batch.

- `generate_batches.py` cuts the canonical catalog (`Config/starter-batches/manifest-v1.json`, sorted by
  `(provider, providerTrackID)`) into `batch-NNNN.json` of 100 sorted tracks. Existing batch files are never
  rewritten or renumbered. Batch identity = batch ID + SHA-256 of its canonical JSON.
- `build_shard.py` downloads each source to a temp dir, analyses it, deletes the audio in `finally`, and writes
  the shard plus `.manifest.json`, `.report.json`, `.SHA256SUMS`. Failures become `shard_failure` rows and the
  shard status is `incomplete`. `--validate-only` checks a shard offline; `--dry-run` checks inputs only.
- Never touches `done.jsonl`, a shared DB, releases or branches.

Tests (no network, no model): `python3 -I -m unittest discover -s tools/starter-shards/tests`.
The real analysis path needs `BuiltInEmbedder`/`BuiltInAnalyzer` in `.build/release` (or `STARTER_SHARD_BIN`).

## Assembly

`assemble_starter.py` is the only producer of the final starter v4 database. It verifies each allowlisted
shard's asset SHA-256, requires one catalog/model/fingerprint/generator version, reconciles every catalog
identity exactly once (expected = successful + failed − duplicates; unknown/missing/incomplete fail), builds a
new DB serially in one transaction (`starter_meta`, `starter_batch`, `starter_track` with native 128-D float32
vectors), runs FK/integrity/order checks, VACUUM, a read-only round trip, then writes `starter.sqlite`,
`starter.manifest.json`, `SHA256SUMS.txt`, `REPORT.md`. Existing outputs are refused unless `--overwrite`.
`--validate-only` runs every check and leaves only the report. Allowlist format
(`schema: starter-assemble-allowlist-v1`, `shards: [{batchID, batchManifestSHA256, assetName, assetURL, assetSHA256}]`).
`assemble-starter-pack.workflow.yml` is the proposed dispatch-only workflow (copy to `.github/workflows/`);
`Config/starter.lock` adoption stays a separate PR.
