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
