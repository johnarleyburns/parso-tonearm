#!/usr/bin/env python3
"""Validate completed starter shards and deterministically assemble ONE starter v4 database.

  assemble_starter.py --catalog Config/starter-batches/manifest-v1.json \
      --shard-allowlist Config/starter-batches/assemble-allowlist.json \
      --output "$RUNNER_TEMP/starter.sqlite" --report "$RUNNER_TEMP/REPORT.md" [--validate-only]

This is the only component that creates the final starter database. It works offline: each
allowlist entry names a shard asset (looked up in --shard-dir, default the allowlist's directory)
whose SHA-256 is verified before the file is opened. Nothing is downloaded, published or scanned for
"latest" here; the workflow fetches the allowlisted assets and uploads the outputs.

Outputs (written next to --output, REPORT.md at --report): starter.sqlite, starter.manifest.json,
SHA256SUMS.txt, REPORT.md. Everything is validated before any final file appears; an existing
output path is refused unless --overwrite is passed.
"""
import argparse, collections, json, math, os, sqlite3, struct, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S

FORMAT_VERSION = '4'
ALLOWLIST_SCHEMA = 'starter-assemble-allowlist-v1'
ALLOWLIST_FIELDS = ('batchID', 'batchManifestSHA256', 'assetName', 'assetURL', 'assetSHA256')
OUTPUT_NAMES = ('starter.sqlite', 'starter.manifest.json', 'SHA256SUMS.txt', 'REPORT.md')
SCHEMA_SQL = """
CREATE TABLE starter_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
CREATE TABLE starter_batch (
  batch_id TEXT PRIMARY KEY NOT NULL,
  batch_manifest_sha256 TEXT NOT NULL,
  shard_logical_digest TEXT NOT NULL,
  track_count INTEGER NOT NULL
);
CREATE TABLE starter_track (
  provider TEXT NOT NULL,
  provider_track_id TEXT NOT NULL,
  id TEXT NOT NULL UNIQUE,
  batch_id TEXT NOT NULL REFERENCES starter_batch(batch_id),
  source_revision TEXT NOT NULL,
  title TEXT NOT NULL, artist TEXT NOT NULL, genre TEXT NOT NULL, license TEXT NOT NULL,
  duration REAL NOT NULL, stream_url TEXT NOT NULL UNIQUE,
  bpm REAL, camelot TEXT, energy REAL,
  emb_dimensions INTEGER NOT NULL, emb_vector BLOB NOT NULL,
  transition_profile_json TEXT NOT NULL, payload_sha256 TEXT NOT NULL,
  PRIMARY KEY (provider, provider_track_id)
);
"""
TRACK_COLUMNS = ('provider, provider_track_id, id, batch_id, source_revision, title, artist, genre, '
                 'license, duration, stream_url, bpm, camelot, energy, emb_dimensions, emb_vector, '
                 'transition_profile_json, payload_sha256')


def load_allowlist(path):
    try:
        data = json.load(open(path, 'rb'))
    except (OSError, ValueError) as e:
        raise S.ShardError(f'allowlist unreadable: {e}')
    if data.get('schema') != ALLOWLIST_SCHEMA:
        raise S.ShardError(f'allowlist schema must be {ALLOWLIST_SCHEMA}')
    shards = data.get('shards')
    if not isinstance(shards, list) or not shards:
        raise S.ShardError('allowlist has no shards')
    for s in shards:
        absent = [k for k in ALLOWLIST_FIELDS if not isinstance(s.get(k), str) or not s[k]]
        if absent:
            raise S.ShardError(f'allowlist entry missing {absent}')
        if os.path.basename(s['assetName']) != s['assetName'] or s['assetName'] in ('.', '..'):
            raise S.ShardError('allowlist assetName must be a plain file name')
    ids = [s['batchID'] for s in shards]
    if len(ids) != len(set(ids)):
        raise S.ShardError('allowlist lists a batch ID twice')
    return sorted(shards, key=lambda s: s['batchID'])


def shard_fingerprint(path):
    try:
        db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
        try:
            row = db.execute("SELECT value FROM shard_meta WHERE key = 'embedding_space_fingerprint'").fetchone()
        finally:
            db.close()
    except sqlite3.DatabaseError as e:
        raise S.ShardError(f'shard is not a readable SQLite database: {e}')
    if not row:
        raise S.ShardError('shard_meta missing embedding_space_fingerprint')
    return row[0]


def read_shard_rows(path):
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        return [(p, t, json.loads(bytes(b))) for p, t, b in db.execute(
            'SELECT provider, provider_track_id, payload_json FROM shard_track ORDER BY provider, provider_track_id')]
    finally:
        db.close()


def failure_ids(path):
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        return [tuple(r) for r in db.execute('SELECT provider, provider_track_id FROM shard_failure')]
    finally:
        db.close()


def check_profile(profile, what):
    bpm = profile.get('bpm')
    if bpm is not None and (isinstance(bpm, bool) or not isinstance(bpm, (int, float))
                            or not math.isfinite(bpm) or bpm <= 0):
        raise S.ShardError(f'{what}: invalid bpm')
    key = profile.get('key')
    if key is not None and not isinstance(key, str):
        raise S.ShardError(f'{what}: invalid key')
    energy = profile.get('energy')
    if energy is not None and (isinstance(energy, bool) or not isinstance(energy, (int, float))
                               or not math.isfinite(energy)):
        raise S.ShardError(f'{what}: invalid energy')


def collect(catalog_path, allowlist_path, shard_dir=None, expected_catalog_sha=None):
    """Validate every allowlisted shard against the catalog. Returns the assembly plan or raises."""
    catalog, catalog_sha = S.load_canonical(catalog_path, 'catalog')
    S.check_entries(catalog.get('tracks'), 'catalog')
    if expected_catalog_sha and expected_catalog_sha.lower() != catalog_sha:
        raise S.ShardError('catalog SHA-256 does not match the requested catalog_manifest')
    entries = {S.identity(e): e for e in catalog['tracks']}
    shard_dir = shard_dir or os.path.dirname(os.path.abspath(allowlist_path))
    allow = load_allowlist(allowlist_path)

    problems, batches, successes, seen = [], [], {}, collections.Counter()
    fingerprint = model_sha = generator_version = None
    for a in allow:
        path = os.path.join(shard_dir, a['assetName'])
        if not os.path.isfile(path):
            raise S.ShardError(f"{a['batchID']}: shard asset {a['assetName']} not found")
        if S.sha256_file(path) != a['assetSHA256']:
            raise S.ShardError(f"{a['batchID']}: asset SHA-256 does not match the allowlist")
        fp = shard_fingerprint(path)
        if fingerprint is None:
            fingerprint = fp
        if fp != fingerprint:
            raise S.ShardError(f"{a['batchID']}: mixed embedding-space fingerprints")
        meta = S.validate_shard(path, fingerprint, None, a['batchManifestSHA256'], catalog_sha)
        if meta['batch_id'] != a['batchID']:
            raise S.ShardError(f"{a['batchID']}: shard batch_id {meta['batch_id']} differs from the allowlist")
        if model_sha is None:
            model_sha, generator_version = meta['model_archive_sha256'], meta['generator_version']
        if meta['model_archive_sha256'] != model_sha:
            raise S.ShardError(f"{a['batchID']}: mixed model archive checksums")
        if meta['generator_version'] != generator_version:
            raise S.ShardError(f"{a['batchID']}: incompatible generator version")
        failed = failure_ids(path)
        if meta['status'] != S.STATUS_COMPLETE or failed:
            problems.append(f"{a['batchID']}: shard is {meta['status']} with {len(failed)} failed track(s)")
        rows = read_shard_rows(path)
        for p, t, payload in rows:
            seen[(p, t)] += 1
            successes[(p, t)] = (a['batchID'], payload)
        for ident in failed:
            seen[ident] += 1
        batches.append({'batchID': a['batchID'], 'batchManifestSHA256': a['batchManifestSHA256'],
                        'shardLogicalDigest': S.logical_digest(path), 'trackCount': len(rows) + len(failed),
                        'successCount': len(rows), 'failureCount': len(failed)})

    duplicate = sorted(i for i, n in seen.items() if n > 1)
    unknown = sorted(i for i in seen if i not in entries)
    missing = sorted(i for i in entries if i not in seen)
    counts = {'catalogExpected': len(entries),
              'successful': sum(b['successCount'] for b in batches),
              'failed': sum(b['failureCount'] for b in batches),
              'duplicate': len(duplicate), 'unknown': len(unknown), 'missing': len(missing)}
    if duplicate:
        problems.append(f'duplicate identities: {duplicate[:5]}')
    if unknown:
        problems.append(f'unknown identities: {unknown[:5]}')
    if missing:
        problems.append(f'missing identities: {len(missing)} (first {missing[:5]})')
    if problems:
        raise S.ShardError('; '.join(problems) + f' [counts {json.dumps(counts, sort_keys=True)}]')

    tracks = []
    for ident in sorted(successes):
        batch_id, payload = successes[ident]
        entry = entries[ident]
        for k in S.ENTRY_FIELDS:
            if payload.get(k) != entry[k]:
                raise S.ShardError(f'{ident}: payload {k} differs from the catalog manifest')
        check_profile(payload['transitionProfile'], str(ident))
        tracks.append((batch_id, entry, payload))
    counts['assembled'] = len(tracks)
    return {'catalog_sha': catalog_sha, 'model_sha': model_sha, 'fingerprint': fingerprint,
            'batches': batches, 'tracks': tracks, 'counts': counts}


def pack_vector(embedding):
    return struct.pack(f'<{S.DIMENSIONS}f', *embedding)


def track_row(batch_id, entry, payload):
    profile = payload['transitionProfile']
    blob = S.canonical(payload)
    return (entry['provider'], entry['providerTrackID'], f"{entry['provider']}-{entry['providerTrackID']}",
            batch_id, entry['sourceRevision'], entry['title'], entry['artist'], entry.get('genre', ''),
            entry['license'], float(entry['durationSec']), entry['streamURL'],
            profile.get('bpm'), profile.get('key'), profile.get('energy'), S.DIMENSIONS,
            pack_vector(payload['embedding']), S.canonical(profile).decode('utf-8'), S.sha256_hex(blob))


def logical_hash(plan, rows):
    import hashlib
    h = hashlib.sha256()
    for key, value in (('format_version', FORMAT_VERSION), ('catalog_manifest_sha256', plan['catalog_sha']),
                       ('model_sha256', plan['model_sha']), ('embedding_space_fingerprint', plan['fingerprint'])):
        h.update(S.canonical(['meta', key, value]))
    for r in rows:
        h.update(S.canonical(['track', *[x.hex() if isinstance(x, bytes) else x for x in r]]))
    return h.hexdigest()


def build_db(path, plan, generator_sha):
    rows = [track_row(*t) for t in plan['tracks']]
    digest = logical_hash(plan, rows)
    meta = {
        'format_version': FORMAT_VERSION, 'content_version': f'starter-v4-{digest[:12]}',
        'embedding_space_fingerprint': plan['fingerprint'], 'catalog_manifest_sha256': plan['catalog_sha'],
        'model_sha256': plan['model_sha'], 'generator_git_sha': generator_sha,
        'batches': S.canonical([{'batchID': b['batchID'], 'batchManifestSHA256': b['batchManifestSHA256'],
                                 'shardLogicalDigest': b['shardLogicalDigest']}
                                for b in plan['batches']]).decode('utf-8'),
        'track_count': str(len(rows)), 'logical_content_sha256': digest,
    }
    db = sqlite3.connect(path, isolation_level=None)
    try:
        db.execute('PRAGMA foreign_keys = ON')
        db.executescript(SCHEMA_SQL)
        db.execute('BEGIN')
        try:
            db.executemany('INSERT INTO starter_meta (key, value) VALUES (?, ?)', sorted(meta.items()))
            db.executemany('INSERT INTO starter_batch VALUES (?, ?, ?, ?)',
                           [(b['batchID'], b['batchManifestSHA256'], b['shardLogicalDigest'], b['trackCount'])
                            for b in plan['batches']])
            db.executemany(f'INSERT INTO starter_track ({TRACK_COLUMNS}) VALUES ({",".join("?" * 18)})', rows)
            db.execute('COMMIT')
        except BaseException:
            db.execute('ROLLBACK')
            raise
        verify_db(db, plan, rows)
        db.execute('VACUUM')
    finally:
        db.close()
    return meta, rows


def verify_db(db, plan, rows):
    if db.execute('PRAGMA foreign_key_check').fetchall():
        raise S.ShardError('foreign_key_check failed')
    if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
        raise S.ShardError('integrity_check failed')
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if tables != {'starter_meta', 'starter_batch', 'starter_track'}:
        raise S.ShardError(f'unexpected output tables {sorted(tables)}')
    ids = db.execute('SELECT provider, provider_track_id FROM starter_track ORDER BY rowid').fetchall()
    if ids != sorted(ids) or len(ids) != len(plan['tracks']):
        raise S.ShardError('output rows are not in canonical order or count')
    for ident, blob, dims in db.execute('SELECT provider || "/" || provider_track_id, emb_vector, emb_dimensions '
                                        'FROM starter_track'):
        if dims != S.DIMENSIONS or len(blob) != 4 * S.DIMENSIONS:
            raise S.ShardError(f'{ident}: embedding is not native {S.DIMENSIONS}-D')
        if not all(math.isfinite(x) for x in struct.unpack(f'<{S.DIMENSIONS}f', blob)):
            raise S.ShardError(f'{ident}: non-finite embedding')


def read_back(path):
    """Independent read-only reopen: returns (meta, ordered rows) for the round-trip check."""
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        meta = dict(db.execute('SELECT key, value FROM starter_meta'))
        rows = db.execute(f'SELECT {TRACK_COLUMNS} FROM starter_track ORDER BY rowid').fetchall()
        return meta, rows
    finally:
        db.close()


def round_trip(path, plan, meta):
    got_meta, got_rows = read_back(path)
    if got_meta != meta:
        raise S.ShardError('round-trip: starter_meta differs')
    if len(got_rows) != plan['counts']['assembled']:
        raise S.ShardError('round-trip: row count differs')
    if logical_hash(plan, got_rows) != meta['logical_content_sha256']:
        raise S.ShardError('round-trip: logical content hash differs')
    for row, (_, entry, payload) in zip(got_rows, plan['tracks']):
        if (row[0], row[1]) != S.identity(entry):
            raise S.ShardError(f'round-trip: identity differs for {S.identity(entry)}')
        if list(struct.unpack(f'<{S.DIMENSIONS}f', row[15])) != list(struct.unpack(
                f'<{S.DIMENSIONS}f', pack_vector(payload['embedding']))):
            raise S.ShardError(f'round-trip: embedding differs for {S.identity(entry)}')


def render_report(plan, meta):
    c = plan['counts']
    lines = ['# Starter pack assembly report', '',
             f"- content_version: `{meta['content_version']}`",
             f"- logical_content_sha256: `{meta['logical_content_sha256']}`",
             f"- catalog_manifest_sha256: `{plan['catalog_sha']}`",
             f"- model_sha256: `{plan['model_sha']}`",
             f"- embedding_space_fingerprint: `{plan['fingerprint']}`", '', '## Count reconciliation', '']
    for label, key in (('Catalog expected', 'catalogExpected'), ('Successful', 'successful'),
                       ('Failed', 'failed'), ('Duplicate', 'duplicate'), ('Unknown', 'unknown'),
                       ('Missing', 'missing'), ('Assembled', 'assembled')):
        lines.append(f'- {label}: {c[key]}')
    lines += ['', '## Batches', '', '| Batch | Tracks | Manifest SHA-256 |', '| --- | ---: | --- |']
    lines += [f"| {b['batchID']} | {b['trackCount']} | `{b['batchManifestSHA256']}` |" for b in plan['batches']]
    return '\n'.join(lines) + '\n'


def assemble(catalog_path, allowlist_path, output, report, shard_dir=None, expected_catalog_sha=None,
             validate_only=False, overwrite=False, generator_sha='unknown'):
    out_dir = os.path.dirname(os.path.abspath(output))
    targets = [os.path.abspath(output), os.path.join(out_dir, 'starter.manifest.json'),
               os.path.join(out_dir, 'SHA256SUMS.txt'), os.path.abspath(report)]
    if not validate_only and not overwrite:
        existing = [t for t in targets if os.path.exists(t)]
        if existing:
            raise S.ShardError(f'refusing to overwrite existing output {existing[0]} (pass --overwrite)')
    plan = collect(catalog_path, allowlist_path, shard_dir, expected_catalog_sha)
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='assemble-', dir=out_dir) as tmp:
        built = os.path.join(tmp, 'starter.sqlite')
        meta, _ = build_db(built, plan, generator_sha)
        round_trip(built, plan, meta)
        report_text = render_report(plan, meta)
        if validate_only:
            with open(report, 'w') as f:
                f.write(report_text)
            return plan, meta
        manifest = S.canonical({'format_version': FORMAT_VERSION, 'meta': meta, 'counts': plan['counts'],
                                'batches': plan['batches'], 'files': {'starter.sqlite': S.sha256_file(built)}}) + b'\n'
        manifest_path = os.path.join(tmp, 'starter.manifest.json')
        report_tmp = os.path.join(tmp, 'REPORT.md')
        open(manifest_path, 'wb').write(manifest)
        open(report_tmp, 'w').write(report_text)
        sums = os.path.join(tmp, 'SHA256SUMS.txt')
        with open(sums, 'w') as f:
            for n, p in sorted(((os.path.basename(report), report_tmp), ('starter.manifest.json', manifest_path),
                                ('starter.sqlite', built))):
                f.write(f'{S.sha256_file(p)}  {n}\n')
        if not overwrite and any(os.path.exists(t) for t in targets):
            raise S.ShardError('output appeared during assembly; refusing to overwrite')
        for src, dst in ((built, targets[0]), (manifest_path, targets[1]), (sums, targets[2]),
                         (report_tmp, targets[3])):
            os.replace(src, dst)
    return plan, meta


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalog', required=True)
    ap.add_argument('--shard-allowlist', required=True)
    ap.add_argument('--shard-dir', help='directory holding the allowlisted assets (default: allowlist dir)')
    ap.add_argument('--catalog-sha256', help='require the catalog to hash to this value')
    ap.add_argument('--output', required=True)
    ap.add_argument('--report', required=True)
    ap.add_argument('--generator-git-sha', default=os.environ.get('GITHUB_SHA', 'unknown'))
    ap.add_argument('--validate-only', action='store_true',
                    help='run every check and write only the report; no output database is left behind')
    ap.add_argument('--overwrite', action='store_true', help='replace existing output files')
    a = ap.parse_args(argv)
    try:
        plan, meta = assemble(a.catalog, a.shard_allowlist, a.output, a.report, a.shard_dir, a.catalog_sha256,
                              a.validate_only, a.overwrite, a.generator_git_sha)
    except (S.ShardError, sqlite3.DatabaseError) as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    print(f"{'validated' if a.validate_only else 'assembled'}: {plan['counts']['assembled']} tracks, "
          f"logical_content_sha256={meta['logical_content_sha256']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
