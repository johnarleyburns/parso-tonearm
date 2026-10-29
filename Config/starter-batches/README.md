# Starter batches

Immutable 100-track input manifests for the from-scratch int4/128-D (`clap-int4-128-v1`) Jamendo
starter catalog. Identity is `(provider, providerTrackID)` with provider exactly `jamendo`; stream
URLs are never identity. No v3/512-D vector or `starter.sqlite` row is an input.

- `manifest-v1.json` — canonical catalog (`starter-catalog-v1`), tracks sorted by identity. It is the
  frozen input and must be supplied from the Jamendo catalog export; it is not generated here.
- `batch-NNNN.json` — `starter-batch-v1`, 1..100 tracks, `catalogSHA256` = hash of the catalog.
- `MANIFEST.sha256` — `shasum -a 256` of `manifest-v1.json`.

Generate (existing batches are verified byte-for-byte and never rewritten; a mismatch fails):

    python3 -I tools/starter-shards/generate_batches.py \
      --catalog Config/starter-batches/manifest-v1.json --out-dir Config/starter-batches --size 100
    shasum -a 256 Config/starter-batches/manifest-v1.json > Config/starter-batches/MANIFEST.sha256

The manifest file must be the canonical bytes without a trailing newline so `shasum` equals
`catalogSHA256`. Published batches are immutable: new tracks go into a new catalog version and later
batch IDs; never rebalance or renumber.
