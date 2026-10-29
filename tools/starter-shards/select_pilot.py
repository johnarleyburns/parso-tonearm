#!/usr/bin/env python3
"""Deterministically select the frozen 10-track capacity pilot from a canonical catalog.

  select_pilot.py --catalog Config/starter-batches/manifest-v1.json --pilot-id pilot-0001 \
      --out Config/starter-batches/pilots/pilot-0001.json

Percentile algorithm (nearest rank): durations sorted ascending, P(p) = d[ceil(p/100*n)-1].
Buckets, taken in this order, never reusing a track:
  low    2 tracks with duration <= P(20)   nearest to P(20)
  median 3 tracks                          nearest to P(50)
  p80    3 tracks                          nearest to P(80)
  high   2 tracks with duration >= P(95)   nearest to P(95)
Ties break by (provider, providerTrackID). The output is a starter-batch-v1 manifest (entries copied
verbatim, sorted canonically) that records the algorithm and catalog SHA-256. No random choice, no
hand-picking.
"""
import argparse, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S

BUCKETS = (('low', 20, 2, 'le'), ('median', 50, 3, None), ('p80', 80, 3, None), ('high', 95, 2, 'ge'))
ALGORITHM = ('nearest-rank percentile P(p)=d[ceil(p/100*n)-1]; low: 2 nearest P20 with d<=P20; median: 3 nearest P50; '
             'p80: 3 nearest P80; high: 2 nearest P95 with d>=P95; ties by (provider, providerTrackID)')


def percentile(durations, p):
    d = sorted(durations)
    return d[max(1, math.ceil(p / 100 * len(d))) - 1]


def select(tracks):
    if len(tracks) < 10:
        raise S.ShardError('catalog needs at least 10 tracks for a pilot')
    durs = [t['durationSec'] for t in tracks]
    chosen, used, detail = [], set(), {}
    for name, p, count, bound in BUCKETS:
        target = percentile(durs, p)
        pool = [t for t in tracks if S.identity(t) not in used
                and (bound is None or (t['durationSec'] <= target if bound == 'le' else t['durationSec'] >= target))]
        pool.sort(key=lambda t: (abs(t['durationSec'] - target), S.identity(t)))
        if len(pool) < count:
            raise S.ShardError(f'not enough eligible tracks for bucket {name}')
        for t in pool[:count]:
            used.add(S.identity(t))
            chosen.append(t)
        detail[name] = {'percentile': p, 'targetDurationSec': target}
    return sorted(chosen, key=S.identity), detail


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalog', required=True)
    ap.add_argument('--pilot-id', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    try:
        catalog, sha = S.load_canonical(a.catalog, 'catalog')
        S.validate_catalog(catalog)
        tracks, detail = select(catalog['tracks'])
        if os.path.exists(a.out):
            raise S.ShardError('refusing to overwrite an existing pilot manifest (pilots are immutable)')
        pilot = {'schema': 'starter-batch-v1', 'batchID': a.pilot_id, 'catalogSHA256': sha, 'tracks': tracks,
                 'selection': {'algorithm': ALGORITHM, 'buckets': detail, 'catalogSHA256': sha}}
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, 'wb') as f:
            f.write(S.canonical(pilot) + b'\n')
        return 0
    except S.ShardError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
