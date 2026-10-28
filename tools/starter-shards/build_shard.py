#!/usr/bin/env python3
"""Build one immutable starter shard (SQLite) from a frozen batch manifest.

  build_shard.py --batch B --catalog C --model-dir M --embedding-space-fingerprint F --output O
  build_shard.py --validate-only --output O --embedding-space-fingerprint F [--batch B --catalog C]

Each source is downloaded to a runner-local temp file, analysed, and the audio deleted in a
finally block. The shard is the only artifact: no shared DB, release, branch or cache is touched.
Per-track failures become shard_failure rows and mark the shard `incomplete`; nothing is dropped.
"""
import argparse, datetime, os, shutil, sqlite3, subprocess, sys, tempfile, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))


class TrackFailure(Exception):
    def __init__(self, stage, code, detail):
        super().__init__(detail)
        self.stage, self.code, self.detail = stage, code, detail


def download_audio(entry, dest):
    """Fetch the source to `dest`. Never echoes the URL (it may carry credentials)."""
    try:
        with urllib.request.urlopen(entry['streamURL'], timeout=120) as r, open(dest, 'wb') as out:
            shutil.copyfileobj(r, out)
    except Exception as e:
        raise TrackFailure('download', 'download_failed', type(e).__name__)
    if os.path.getsize(dest) < 10_000:
        raise TrackFailure('download', 'too_small', 'downloaded file is implausibly small')


def analyze_audio(entry, path):
    """Real analysis via the BuiltInEmbedder/BuiltInAnalyzer release tools (dev-only binaries)."""
    import json
    bin_dir = os.environ.get('STARTER_SHARD_BIN', os.path.join(REPO, '.build/release'))
    folder = os.path.dirname(path)
    tid = os.path.splitext(os.path.basename(path))[0]
    try:
        emb_path = os.path.join(folder, 'embeddings.json')
        subprocess.run([os.path.join(bin_dir, 'BuiltInEmbedder'), folder, emb_path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        emb = {e['id']: e for e in json.load(open(emb_path))}[tid]
        idx_path = os.path.join(folder, 'index.json')
        json.dump([{'id': tid, 'streamURL': 'local', 'durationSec': entry['durationSec']}],
                  open(idx_path, 'w'))
        subprocess.run([os.path.join(bin_dir, 'BuiltInAnalyzer'), idx_path, '1'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=dict(os.environ, BUILTIN_ANALYZER_AUDIO_DIR=folder))
        ana = json.load(open(idx_path))[0]
    except Exception as e:
        raise TrackFailure('analyze', 'analyze_failed', type(e).__name__)
    profile = {k: v for k, v in ana.items() if k not in ('id', 'streamURL', 'durationSec')}
    return {'embedding': emb.get('embedding') or emb.get('vector'), 'transitionProfile': profile}


def process_track(entry, fingerprint, download, analyze, tmp_root):
    """Returns the payload dict; raises TrackFailure. Temp audio never outlives this call."""
    work = tempfile.mkdtemp(prefix='shard-', dir=tmp_root)
    try:
        path = os.path.join(work, f"{entry['providerTrackID']}.mp3")
        download(entry, path)
        result = analyze(entry, path)
    except TrackFailure:
        raise
    except Exception as e:
        raise TrackFailure('analyze', 'analyze_failed', type(e).__name__)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    payload = {
        'schema': 'starter-v4', 'provider': entry['provider'],
        'providerTrackID': entry['providerTrackID'], 'sourceRevision': entry['sourceRevision'],
        'title': entry['title'], 'artist': entry['artist'], 'license': entry['license'],
        'durationSec': entry['durationSec'], 'streamURL': entry['streamURL'],
        'embeddingSpaceFingerprint': fingerprint,
        'embedding': [round(float(x), 6) for x in result['embedding']],
        'transitionProfile': result['transitionProfile'],
    }
    try:
        S.validate_payload(payload, fingerprint)
    except S.ShardError as e:
        raise TrackFailure('validate', 'invalid_payload', str(e))
    return payload


def build(batch_path, catalog_path, model_dir, fingerprint, output, expected_model_sha=None,
          download=download_audio, analyze=analyze_audio, now=None, git_sha=None, tmp_root=None):
    batch, batch_sha, catalog_sha = S.load_batch(batch_path, catalog_path)
    model_sha = S.sha256_dir(model_dir)
    if expected_model_sha and expected_model_sha != model_sha:
        raise S.ShardError('model archive checksum does not match the pinned value')
    successes, failures = [], []
    for entry in batch['tracks']:
        try:
            successes.append((entry, process_track(entry, fingerprint, download, analyze, tmp_root)))
        except TrackFailure as f:
            failures.append((entry, f))
    created = (now or datetime.datetime.now(datetime.timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')
    meta = {
        'schema_version': str(S.SCHEMA_VERSION), 'generator_git_sha': git_sha or os.environ.get('GITHUB_SHA', 'unknown'),
        'generator_version': S.GENERATOR_VERSION, 'batch_id': batch['batchID'],
        'batch_manifest_sha256': batch_sha, 'input_catalog_sha256': catalog_sha,
        'model_archive_sha256': model_sha, 'embedding_space_fingerprint': fingerprint,
        'track_count': str(len(batch['tracks'])), 'success_count': str(len(successes)),
        'failure_count': str(len(failures)),
        'status': S.STATUS_INCOMPLETE if failures else S.STATUS_COMPLETE, 'created_at': created,
    }
    tmp = output + '.partial'
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    try:
        db.executescript(S.SCHEMA_SQL)
        db.executemany('INSERT INTO shard_meta VALUES (?, ?)', sorted(meta.items()))
        for entry, payload in successes:
            blob = S.canonical(payload)
            db.execute('INSERT INTO shard_track VALUES (?, ?, ?, ?, ?)',
                       (entry['provider'], entry['providerTrackID'], entry['sourceRevision'],
                        blob, S.sha256_hex(blob)))
        for entry, f in failures:
            db.execute('INSERT INTO shard_failure VALUES (?, ?, ?, ?, ?)',
                       (entry['provider'], entry['providerTrackID'], f.stage, f.code, f.detail))
        db.commit()
    finally:
        db.close()
    os.replace(tmp, output)
    S.validate_shard(output, fingerprint, batch, batch_sha, catalog_sha, model_sha)
    write_reports(output, meta, failures, fingerprint)
    return meta


def write_reports(output, meta, failures, fingerprint):
    base = os.path.splitext(output)[0]
    digest = S.logical_digest(output)
    name = S.artifact_name(meta['batch_id'], meta['batch_manifest_sha256'], fingerprint)
    manifest = dict(meta, logical_digest=digest, shard_file=os.path.basename(output),
                    artifact_name=name)
    report = {'batch_id': meta['batch_id'], 'status': meta['status'],
              'success_count': int(meta['success_count']), 'failure_count': int(meta['failure_count']),
              'failures': [{'provider': e['provider'], 'providerTrackID': e['providerTrackID'],
                            'stage': f.stage, 'errorCode': f.code, 'detail': f.detail}
                           for e, f in failures]}
    files = {}
    for suffix, obj in (('.manifest.json', manifest), ('.report.json', report)):
        with open(base + suffix, 'wb') as f:
            f.write(S.canonical(obj) + b'\n')
    for p in (output, base + '.manifest.json', base + '.report.json'):
        files[os.path.basename(p)] = S.sha256_file(p)
    with open(base + '.SHA256SUMS', 'w') as f:
        for n in sorted(files):
            f.write(f'{files[n]}  {n}\n')
    print('artifact-name:', name)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--batch')
    ap.add_argument('--catalog')
    ap.add_argument('--model-dir')
    ap.add_argument('--embedding-space-fingerprint', required=True)
    ap.add_argument('--expected-model-sha256')
    ap.add_argument('--output', required=True)
    ap.add_argument('--validate-only', action='store_true')
    ap.add_argument('--dry-run', action='store_true', help='check batch, catalog and model only')
    a = ap.parse_args(argv)
    try:
        if a.validate_only:
            batch = batch_sha = catalog_sha = None
            if a.batch and a.catalog:
                batch, batch_sha, catalog_sha = S.load_batch(a.batch, a.catalog)
            meta = S.validate_shard(a.output, a.embedding_space_fingerprint, batch, batch_sha,
                                    catalog_sha, S.sha256_dir(a.model_dir) if a.model_dir else None)
            print(f"valid: {meta['batch_id']} {meta['status']} "
                  f"{meta['success_count']}/{meta['track_count']} tracks")
            return 0
        if not (a.batch and a.catalog and a.model_dir):
            ap.error('--batch, --catalog and --model-dir are required to build')
        if a.dry_run:
            batch, batch_sha, _ = S.load_batch(a.batch, a.catalog)
            model_sha = S.sha256_dir(a.model_dir)
            if a.expected_model_sha256 and a.expected_model_sha256 != model_sha:
                raise S.ShardError('model archive checksum does not match the pinned value')
            print('dry-run ok:', S.artifact_name(batch['batchID'], batch_sha, a.embedding_space_fingerprint))
            return 0
        meta = build(a.batch, a.catalog, a.model_dir, a.embedding_space_fingerprint, a.output,
                     a.expected_model_sha256)
        print(f"built {meta['batch_id']}: {meta['status']} "
              f"{meta['success_count']} ok, {meta['failure_count']} failed")
        return 0
    except S.ShardError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
