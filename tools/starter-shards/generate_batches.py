#!/usr/bin/env python3
"""Deterministically cut a canonical catalog manifest into immutable batches.

  generate_batches.py --catalog Config/starter-batches/manifest-v1.json \
      --out-dir Config/starter-batches [--size 100]

Tracks are sorted by (provider, providerTrackID); batch N holds sorted tracks
[(N-1)*size, N*size). Existing batch files are never rewritten or renumbered: when the catalog
grows, only batches that do not exist yet are created (a catalog must only be appended to in
a new manifest version, so earlier batches keep their manifest hash).
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalog', required=True)
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--size', type=int, default=100)
    a = ap.parse_args()
    catalog, sha = S.load_canonical(a.catalog, 'catalog')
    S.check_entries(catalog['tracks'], 'catalog')
    tracks = catalog['tracks']
    for n, start in enumerate(range(0, len(tracks), a.size), 1):
        path = os.path.join(a.out_dir, f'batch-{n:04d}.json')
        if os.path.exists(path):
            continue
        batch = {'schema': 'starter-batch-v1', 'batchID': f'batch-{n:04d}', 'catalogSHA256': sha,
                 'tracks': tracks[start:start + a.size]}
        with open(path, 'wb') as f:
            f.write(S.canonical(batch) + b'\n')
        print('wrote', path)


if __name__ == '__main__':
    main()
