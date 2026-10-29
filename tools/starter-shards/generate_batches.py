#!/usr/bin/env python3
"""Deterministically cut a canonical catalog manifest into immutable batches.

  generate_batches.py --catalog Config/starter-batches/manifest-v1.json \
      --out-dir Config/starter-batches [--size 100]

Tracks are sorted by (provider, providerTrackID); batch N holds sorted tracks
[(N-1)*size, N*size). Existing batch files are never rewritten or renumbered: when the catalog
grows, only batches that do not exist yet are created (a catalog must only be appended to in
a new manifest version, so earlier batches keep their manifest hash). An existing batch whose
catalogSHA256 or bytes differ from what this catalog would produce is an error.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalog', required=True)
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--size', type=int, default=100)
    a = ap.parse_args(argv)
    if a.size < 1:
        raise S.ShardError('--size must be >= 1')
    catalog, sha = S.load_canonical(a.catalog, 'catalog')
    S.validate_catalog(catalog)
    tracks = catalog['tracks']
    plan = []
    for n, start in enumerate(range(0, len(tracks), a.size), 1):
        batch = {'schema': 'starter-batch-v1', 'batchID': f'batch-{n:04d}', 'catalogSHA256': sha,
                 'tracks': tracks[start:start + a.size]}
        plan.append((os.path.join(a.out_dir, f'batch-{n:04d}.json'), S.canonical(batch) + b'\n'))
    for path, data in plan:  # verify everything before writing anything
        if os.path.exists(path):
            with open(path, 'rb') as f:
                if f.read() != data:
                    raise S.ShardError(f'{path}: existing batch differs from this catalog (immutable; '
                                       'new tracks need a new catalog version and later batch IDs)')
    os.makedirs(a.out_dir, exist_ok=True)
    for path, data in plan:
        if os.path.exists(path):
            continue
        with open(path, 'wb') as f:
            f.write(data)
        print('wrote', path)


if __name__ == '__main__':
    try:
        main()
    except S.ShardError as e:
        sys.exit(f'error: {e}')
