#!/usr/bin/env python3
"""Merge a standalone micro-shard's tracks into a copy of an already-assembled starter.sqlite.

  merge_micro_shard.py --base starter.sqlite --shard micro.sqlite --catalog micro-catalog.json \
      --batch-id batch-foo-micro --out starter-merged.sqlite

For a small, source-controlled addition that doesn't belong in the frozen manifest-v1.json cohort
(e.g. a new genre with zero existing candidates in it) — see build-starter-micro-shard.yml. The
base database and its original rows are never modified in place; everything is written to --out.
Reuses assemble_starter.py's own track_row()/logical_hash()/check_profile(), not a reimplementation,
so a merged row is identical in shape to one produced by a normal assemble run. The 881-track main
cohort this was first used for (Berlin Club, starter-v4-128c7155029a) stayed byte-for-byte identical
except for starter_meta/starter_batch, verified by a full row-by-row diff before publishing.

Does not touch Config/starter.lock, create a release, or download anything — purely a local
database transform. Review --out, then publish and re-pin by hand.
"""
import argparse, json, os, shutil, sqlite3, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S
import assemble_starter as A


def merge(base_path, shard_path, catalog_path, batch_id, out_path):
    catalog, catalog_sha = S.load_canonical(catalog_path, 'catalog')
    S.check_entries(catalog.get('tracks'), 'catalog')
    entries = {S.identity(e): e for e in catalog['tracks']}

    meta = dict(sqlite3.connect(f'file:{shard_path}?mode=ro', uri=True).execute(
        'SELECT key, value FROM shard_meta'))
    if meta.get('status') != S.STATUS_COMPLETE:
        raise S.ShardError(f'shard is not complete: {meta}')
    if meta.get('batch_id') != batch_id:
        raise S.ShardError(f"shard batch_id {meta.get('batch_id')!r} != --batch-id {batch_id!r}")
    if meta.get('input_catalog_sha256') != catalog_sha:
        raise S.ShardError('shard was not built against --catalog (input_catalog_sha256 mismatch)')

    rows_raw = A.read_shard_rows(shard_path)
    if not rows_raw:
        raise S.ShardError('shard has no successful tracks')
    new_rows = []
    for provider, tid, payload in rows_raw:
        entry = entries.get((provider, tid))
        if entry is None:
            raise S.ShardError(f'{provider}/{tid}: not in catalog')
        for k in S.ENTRY_FIELDS:
            if payload.get(k) != entry[k]:
                raise S.ShardError(f'{provider}/{tid}: payload {k} differs from the catalog manifest')
        A.check_profile(payload['transitionProfile'], f'{provider}/{tid}')
        new_rows.append(A.track_row(batch_id, entry, payload))
    new_rows.sort(key=lambda r: (r[0], r[1]))
    shard_digest = S.logical_digest(shard_path)

    shutil.copyfile(base_path, out_path)
    db = sqlite3.connect(out_path, isolation_level=None)
    db.execute('PRAGMA foreign_keys = ON')
    try:
        if db.execute("SELECT 1 FROM starter_batch WHERE batch_id = ?", (batch_id,)).fetchone():
            raise S.ShardError(f'{batch_id}: already present in the base database')
        old_meta = dict(db.execute('SELECT key, value FROM starter_meta'))
        old_batches = json.loads(old_meta['batches'])
        old_track_count = int(old_meta['track_count'])
        existing = db.execute(f'SELECT {A.TRACK_COLUMNS} FROM starter_track').fetchall()
        if len(existing) != old_track_count:
            raise S.ShardError('base database track_count does not match its own row count')
        for row in new_rows:
            if any(row[0] == e[0] and row[1] == e[1] for e in existing):
                raise S.ShardError(f'{row[0]}/{row[1]}: already present in the base database')

        all_rows = sorted(existing + new_rows, key=lambda r: (r[0], r[1]))
        plan = {'catalog_sha': old_meta['catalog_manifest_sha256'], 'model_sha': old_meta['model_sha256'],
                'fingerprint': old_meta['embedding_space_fingerprint']}
        digest = A.logical_hash(plan, all_rows)
        new_meta = dict(old_meta)
        new_meta['track_count'] = str(len(all_rows))
        new_meta['logical_content_sha256'] = digest
        new_meta['content_version'] = f'starter-v4-{digest[:12]}'
        new_meta['batches'] = S.canonical(old_batches + [
            {'batchID': batch_id, 'batchManifestSHA256': catalog_sha, 'shardLogicalDigest': shard_digest}
        ]).decode('utf-8')
        # catalog_manifest_sha256 keeps pointing at the base database's own primary cohort —
        # a micro-batch's catalog is a different lineage entirely, recorded per-batch above
        # (and, for the newest one, here) rather than forced into that single-catalog field.
        new_meta['micro_catalog_sha256'] = catalog_sha

        db.execute('BEGIN')
        try:
            for k, v in new_meta.items():
                cur = db.execute('UPDATE starter_meta SET value = ? WHERE key = ?', (v, k))
                if cur.rowcount == 0:
                    db.execute('INSERT INTO starter_meta (key, value) VALUES (?, ?)', (k, v))
            db.execute('INSERT INTO starter_batch VALUES (?, ?, ?, ?)',
                      (batch_id, catalog_sha, shard_digest, len(new_rows)))
            db.executemany(f'INSERT INTO starter_track ({A.TRACK_COLUMNS}) VALUES ({",".join("?" * 18)})', new_rows)
            db.execute('COMMIT')
        except BaseException:
            db.execute('ROLLBACK')
            raise

        if db.execute('PRAGMA foreign_key_check').fetchall():
            raise S.ShardError('foreign_key_check failed')
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise S.ShardError('integrity_check failed')
        count = db.execute('SELECT count(*) FROM starter_track').fetchone()[0]
        if count != old_track_count + len(new_rows):
            raise S.ShardError('unexpected track count after merge')
        ids = db.execute('SELECT provider, provider_track_id FROM starter_track').fetchall()
        if len(set(ids)) != count:
            raise S.ShardError('duplicate track identity after merge')
        db.execute('VACUUM')
    finally:
        db.close()
    return len(new_rows), count, new_meta['content_version']


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True, help='existing assembled starter.sqlite')
    ap.add_argument('--shard', required=True, help='the micro-shard .sqlite to merge in')
    ap.add_argument('--catalog', required=True, help='the standalone catalog the shard was built against')
    ap.add_argument('--batch-id', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    added, total, content_version = merge(a.base, a.shard, a.catalog, a.batch_id, a.out)
    print(f'merged {added} track(s) -> {total} total; new content_version {content_version}')


if __name__ == '__main__':
    try:
        main()
    except S.ShardError as e:
        sys.exit(f'error: {e}')
