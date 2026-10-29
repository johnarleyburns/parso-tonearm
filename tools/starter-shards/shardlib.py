"""Shared canonical-JSON, identity and validation helpers for starter shards."""
import hashlib, json, math, os, re, sqlite3

SCHEMA_VERSION = 1
GENERATOR_VERSION = '1'
DIMENSIONS = 128
MAX_PROFILE_BYTES = 4096
MAX_PROFILE_KEYS = 64
STATUS_COMPLETE, STATUS_INCOMPLETE = 'complete', 'incomplete'
ENTRY_FIELDS = ('provider', 'providerTrackID', 'streamURL', 'sourceRevision', 'title', 'artist',
                'license', 'durationSec')
SCHEMA_SQL = """
CREATE TABLE shard_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
CREATE TABLE shard_track (
  provider TEXT NOT NULL,
  provider_track_id TEXT NOT NULL,
  source_revision TEXT NOT NULL,
  payload_json BLOB NOT NULL,
  payload_sha256 TEXT NOT NULL,
  PRIMARY KEY (provider, provider_track_id)
);
CREATE TABLE shard_failure (
  provider TEXT NOT NULL,
  provider_track_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  error_code TEXT NOT NULL,
  detail TEXT NOT NULL,
  PRIMARY KEY (provider, provider_track_id)
);
"""
REQUIRED_META = ('schema_version', 'generator_git_sha', 'generator_version', 'batch_id',
                 'batch_manifest_sha256', 'input_catalog_sha256', 'model_archive_sha256',
                 'embedding_space_fingerprint', 'track_count', 'success_count', 'failure_count',
                 'status', 'created_at')


class ShardError(Exception):
    pass


def canonical(obj):
    """Canonical JSON bytes: sorted keys, no whitespace, no NaN/Infinity, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path):
    """Deterministic digest of a model directory (relative names + file digests, sorted)."""
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, path).replace(os.sep, '/').encode() + b'\0')
            h.update(sha256_file(full).encode() + b'\n')
    return h.hexdigest()


def identity(entry):
    return (entry['provider'], entry['providerTrackID'])


def load_canonical(path, what):
    """Read a JSON file that must already be in canonical byte form; returns (obj, sha256)."""
    raw = open(path, 'rb').read()
    try:
        obj = json.loads(raw)
    except ValueError as e:
        raise ShardError(f'{what}: not valid JSON ({e})')
    try:
        canon = canonical(obj)
    except ValueError as e:
        raise ShardError(f'{what}: not canonical-serializable (NaN/Infinity/invalid Unicode: {e})')
    if raw != canon and raw != canon + b'\n':
        raise ShardError(f'{what}: not in canonical form (sorted keys, compact separators)')
    return obj, sha256_hex(canonical(obj))


def check_entries(entries, what):
    if not isinstance(entries, list):
        raise ShardError(f'{what}: tracks must be a list')
    seen = set()
    for e in entries:
        missing = [k for k in ENTRY_FIELDS if k not in e]
        if missing:
            raise ShardError(f'{what}: entry missing {missing}')
        if identity(e) in seen:
            raise ShardError(f'{what}: duplicate provider identity {identity(e)}')
        seen.add(identity(e))
    if entries != sorted(entries, key=identity):
        raise ShardError(f'{what}: tracks are not sorted by (provider, providerTrackID)')


REQUIRED_NONEMPTY = ('provider', 'providerTrackID', 'streamURL', 'sourceRevision', 'title', 'artist', 'license')
CATALOG_SCHEMA = 'starter-catalog-v1'
CATALOG_EMBEDDING_SPACE = 'clap-int4-128-v1'
CATALOG_PROVIDER = 'jamendo'


def _clean_text(value):
    if not isinstance(value, str):
        return False
    try:
        value.encode('utf-8')
    except UnicodeEncodeError:
        return False
    return not any(ord(c) < 0x20 or 0x7f <= ord(c) < 0xa0 for c in value)


def validate_catalog(catalog):
    """Strict frozen-catalog validation (Jamendo-only, int4/128-D, identity = provider+id)."""
    if not isinstance(catalog, dict):
        raise ShardError('catalog: must be a JSON object')
    if catalog.get('schema') != CATALOG_SCHEMA:
        raise ShardError(f'catalog: schema must be {CATALOG_SCHEMA}')
    if catalog.get('embeddingSpace') != CATALOG_EMBEDDING_SPACE:
        raise ShardError(f'catalog: embeddingSpace must be exactly {CATALOG_EMBEDDING_SPACE}')
    tracks = catalog.get('tracks')
    if not isinstance(tracks, list):
        raise ShardError('catalog: tracks must be a list')
    for e in tracks:
        if not isinstance(e, dict):
            raise ShardError('catalog: track must be an object')
        for k in REQUIRED_NONEMPTY:
            v = e.get(k)
            if not isinstance(v, str) or not v.strip():
                raise ShardError(f'catalog: track {e.get("providerTrackID")!r} missing nonempty {k}')
        for k in ('genre', 'licenseURL'):
            if k in e and e[k] is not None and not isinstance(e[k], str):
                raise ShardError(f'catalog: track {e.get("providerTrackID")!r} {k} must be a string')
        for k, v in e.items():
            if isinstance(v, str) and not _clean_text(v):
                raise ShardError(f'catalog: track {e["providerTrackID"]!r} {k} has invalid Unicode/control characters')
        if e['provider'] != CATALOG_PROVIDER:
            raise ShardError(f'catalog: provider must be exactly {CATALOG_PROVIDER}, got {e["provider"]!r}')
        d = e.get('durationSec')
        if isinstance(d, bool) or not isinstance(d, (int, float)) or not math.isfinite(d) or d <= 0:
            raise ShardError(f'catalog: track {e["providerTrackID"]!r} durationSec must be finite and positive')
    check_entries(tracks, 'catalog')


def load_batch(batch_path, catalog_path):
    catalog, catalog_sha = load_canonical(catalog_path, 'catalog')
    batch, batch_sha = load_canonical(batch_path, 'batch')
    check_entries(catalog.get('tracks'), 'catalog')
    check_entries(batch.get('tracks'), 'batch')
    if batch.get('catalogSHA256') != catalog_sha:
        raise ShardError('batch catalogSHA256 does not match the catalog manifest')
    by_id = {identity(e): e for e in catalog['tracks']}
    for e in batch['tracks']:
        if by_id.get(identity(e)) != e:
            raise ShardError(f'batch entry {identity(e)} differs from the catalog manifest')
    return batch, batch_sha, catalog_sha


def validate_payload(payload, fingerprint):
    """Raises ShardError describing the first violation."""
    emb = payload.get('embedding')
    if not isinstance(emb, list) or len(emb) != DIMENSIONS:
        raise ShardError(f'embedding must be {DIMENSIONS}-D, got {len(emb) if isinstance(emb, list) else type(emb).__name__}')
    if not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in emb):
        raise ShardError('embedding contains a non-finite or non-numeric value')
    if payload.get('embeddingSpaceFingerprint') != fingerprint:
        raise ShardError('embedding-space fingerprint mismatch')
    profile = payload.get('transitionProfile')
    if not isinstance(profile, dict):
        raise ShardError('transitionProfile must be an object')
    if len(profile) > MAX_PROFILE_KEYS or len(canonical(profile)) > MAX_PROFILE_BYTES:
        raise ShardError('transitionProfile exceeds size limits')


def validate_shard(path, fingerprint, batch=None, batch_sha=None, catalog_sha=None, model_sha=None):
    """Offline structural validation of a shard. Returns the meta dict."""
    if not os.path.exists(path):
        raise ShardError('shard file missing')
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables != {'shard_meta', 'shard_track', 'shard_failure'}:
            raise ShardError(f'unexpected tables {sorted(tables)}')
        meta = dict(db.execute('SELECT key, value FROM shard_meta'))
        absent = [k for k in REQUIRED_META if k not in meta]
        if absent:
            raise ShardError(f'shard_meta missing {absent}')
        if meta['schema_version'] != str(SCHEMA_VERSION):
            raise ShardError('unsupported shard schema version')
        if meta['embedding_space_fingerprint'] != fingerprint:
            raise ShardError('embedding-space fingerprint mismatch')
        for key, want in (('batch_manifest_sha256', batch_sha), ('input_catalog_sha256', catalog_sha),
                          ('model_archive_sha256', model_sha)):
            if want is not None and meta[key] != want:
                raise ShardError(f'{key} mismatch')
        rows = db.execute('SELECT provider, provider_track_id, source_revision, payload_json, '
                          'payload_sha256 FROM shard_track ORDER BY provider, provider_track_id').fetchall()
        failures = db.execute('SELECT provider, provider_track_id FROM shard_failure').fetchall()
        for provider, tid, revision, blob, digest in rows:
            blob = bytes(blob)
            if sha256_hex(blob) != digest:
                raise ShardError(f'payload checksum mismatch for {provider}/{tid}')
            payload = json.loads(blob)
            if blob != canonical(payload):
                raise ShardError(f'payload for {provider}/{tid} is not canonical JSON')
            if (payload.get('provider'), payload.get('providerTrackID'), payload.get('sourceRevision')) != (provider, tid, revision):
                raise ShardError(f'payload identity mismatch for {provider}/{tid}')
            try:
                validate_payload(payload, fingerprint)
            except ShardError as e:
                raise ShardError(f'{provider}/{tid}: {e}')
        ids = [(r[0], r[1]) for r in rows] + [tuple(f) for f in failures]
        if len(ids) != len(set(ids)):
            raise ShardError('a track is recorded as both success and failure')
        if (int(meta['success_count']), int(meta['failure_count']), int(meta['track_count'])) != (
                len(rows), len(failures), len(ids)):
            raise ShardError('shard_meta counts disagree with rows')
        if meta['status'] != (STATUS_INCOMPLETE if failures else STATUS_COMPLETE):
            raise ShardError('shard status disagrees with failure rows')
        if batch is not None:
            if meta['batch_id'] != batch.get('batchID'):
                raise ShardError('batch_id mismatch')
            if sorted(ids) != [identity(e) for e in batch['tracks']]:
                raise ShardError('shard tracks do not cover exactly the batch manifest')
        return meta
    finally:
        db.close()


def logical_digest(path):
    """Digest of the shard's logical content; excludes the creation timestamp."""
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        h = hashlib.sha256()
        for key, value in db.execute("SELECT key, value FROM shard_meta WHERE key != 'created_at' ORDER BY key"):
            h.update(canonical(['meta', key, value]))
        for row in db.execute('SELECT provider, provider_track_id, source_revision, payload_sha256 '
                              'FROM shard_track ORDER BY provider, provider_track_id'):
            h.update(canonical(['track', *row]))
        for row in db.execute('SELECT * FROM shard_failure ORDER BY provider, provider_track_id'):
            h.update(canonical(['failure', *row]))
        return h.hexdigest()
    finally:
        db.close()


def artifact_name(batch_id, batch_sha, fingerprint):
    return f'starter-shard-{batch_id}-{batch_sha[:12]}-{sha256_hex(fingerprint.encode())[:12]}-g{GENERATOR_VERSION}'
