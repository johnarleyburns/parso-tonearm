#!/usr/bin/env python3
"""Build one immutable starter shard (SQLite) from a frozen batch manifest.

  build_shard.py --batch B --catalog C --model-dir M --embedding-space-fingerprint F --output O
  build_shard.py --validate-only --output O --embedding-space-fingerprint F [--batch B --catalog C]

Each source is downloaded to a runner-local temp file, analysed, and the audio deleted in a
finally block. The shard is the only artifact: no shared DB, release, branch or cache is touched.
Per-track failures become shard_failure rows and mark the shard `incomplete`; nothing is dropped.
"""
import argparse, datetime, json, os, re, shutil, sqlite3, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S
import pilot_metrics as M

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
JAMENDO_FILE_ENDPOINT = 'https://api.jamendo.com/v3.0/tracks/file/'
JAMENDO_MIN_REQUEST_INTERVAL_SECONDS = 5.0


class TrackFailure(Exception):
    def __init__(self, stage, code, detail):
        super().__init__(detail)
        self.stage, self.code, self.detail = stage, code, detail


def safe_subprocess_detail(error):
    """Bounded stderr diagnostic with URLs, query strings and paths removed."""
    raw = (getattr(error, 'stderr', '') or '').replace('\n', ' ')
    raw = re.sub(r'https?://\S+|\S*[?&](?:token|sig|client_id)=[^\s]+', '[redacted-url]', raw)
    raw = re.sub(r'/(?:[^\s/]+/){2,}[^\s]*', '[redacted-path]', raw)
    raw = re.sub(r'\s+', ' ', raw).strip()
    return raw[:240] or type(error).__name__


class JamendoTrackDownloader:
    """Resolve one durable `jamendo://track/<id>` locator only at download time.

    The request URL contains the client id and redirects to a short-lived CDN URL;
    neither URL is logged or persisted.  One builder is serial, with five seconds
    between request starts, to avoid burdening Jamendo.
    """
    def __init__(self, client_id=None, opener=urllib.request.urlopen, clock=time.monotonic,
                 sleep=time.sleep):
        self.client_id = client_id if client_id is not None else os.environ.get('JAMENDO_CLIENT_ID', '')
        self.opener, self.clock, self.sleep = opener, clock, sleep
        self.last_request_at = None

    def __call__(self, entry, dest):
        tid = str(entry.get('providerTrackID', ''))
        if entry.get('provider') != 'jamendo' or entry.get('streamURL') != f'jamendo://track/{tid}' or not tid.isdigit():
            raise TrackFailure('resolve', 'invalid_locator', 'durable Jamendo locator required')
        if not self.client_id:
            raise TrackFailure('resolve', 'missing_client_id', 'JAMENDO_CLIENT_ID is not set')
        if self.last_request_at is not None:
            wait = JAMENDO_MIN_REQUEST_INTERVAL_SECONDS - (self.clock() - self.last_request_at)
            if wait > 0:
                self.sleep(wait)
        query = urllib.parse.urlencode({'client_id': self.client_id, 'id': tid,
                                        'action': 'download', 'audioformat': 'mp32'})
        request = urllib.request.Request(JAMENDO_FILE_ENDPOINT + '?' + query)
        self.last_request_at = self.clock()
        try:
            with self.opener(request, timeout=120) as r, open(dest, 'wb') as out:
                shutil.copyfileobj(r, out)
        except urllib.error.HTTPError as e:
            raise TrackFailure('resolve', 'jamendo_http_error', f'HTTP {e.code}')
        except Exception as e:
            raise TrackFailure('resolve', 'jamendo_resolve_failed', type(e).__name__)
        if os.path.getsize(dest) < 10_000:
            raise TrackFailure('download', 'too_small', 'downloaded file is implausibly small')


def download_audio(entry, dest):
    """Legacy HTTP fixture downloader; production builds use JamendoTrackDownloader."""
    try:
        with urllib.request.urlopen(entry['streamURL'], timeout=120) as r, open(dest, 'wb') as out:
            shutil.copyfileobj(r, out)
    except Exception as e:
        raise TrackFailure('download', 'download_failed', type(e).__name__)
    if os.path.getsize(dest) < 10_000:
        raise TrackFailure('download', 'too_small', 'downloaded file is implausibly small')


def analyze_audio(entry, path):
    """Real analysis via the BuiltInEmbedder/BuiltInAnalyzer release tools (dev-only binaries)."""
    bin_dir = os.environ.get('STARTER_SHARD_BIN', os.path.join(REPO, '.build/release'))
    folder = os.path.dirname(path)
    tid = os.path.splitext(os.path.basename(path))[0]
    t0 = time.monotonic()
    embed_seconds = None
    try:
        emb_path = os.path.join(folder, 'embeddings.json')
        subprocess.run([os.path.join(bin_dir, 'BuiltInEmbedder'), folder, emb_path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        emb = {e['id']: e for e in json.load(open(emb_path))}[tid]
        embed_seconds = time.monotonic() - t0
        t1 = time.monotonic()
        idx_path = os.path.join(folder, 'index.json')
        json.dump([{'id': tid, 'streamURL': 'local', 'durationSec': entry['durationSec']}],
                  open(idx_path, 'w'))
        subprocess.run([os.path.join(bin_dir, 'BuiltInAnalyzer'), idx_path, '1'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                       env=dict(os.environ, BUILTIN_ANALYZER_AUDIO_DIR=folder))
        with open(idx_path, encoding='utf-8') as f:
            ana = json.load(f)[0]
    except subprocess.CalledProcessError as e:
        raise TrackFailure('analyze', 'tool_failed', safe_subprocess_detail(e))
    except Exception as e:
        raise TrackFailure('analyze', 'analyze_failed', type(e).__name__)
    profile = {k: v for k, v in ana.items() if k not in ('id', 'streamURL', 'durationSec')}
    return {'embedding': emb.get('embedding') or emb.get('vector'), 'transitionProfile': profile,
            'embedSeconds': embed_seconds, 'analysisSeconds': time.monotonic() - t1}


def _dir_bytes(path):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs
               if os.path.exists(os.path.join(r, f)))


def process_track(entry, fingerprint, download, analyze, tmp_root, metrics=None):
    """Returns the payload dict; raises TrackFailure. Temp audio never outlives this call.

    When `metrics` is a list, exactly one safe row is appended per attempt (success, failure or
    cancellation) from the finally block."""
    work = tempfile.mkdtemp(prefix='shard-', dir=tmp_root)
    started = time.monotonic()
    t = {'dl': None, 'an': None, 'embed': None, 'ana': None, 'bytes': None, 'disk': None}
    outcome, stage, code = 'cancelled', None, None
    try:
        path = os.path.join(work, f"{entry['providerTrackID']}.mp3")
        mark = time.monotonic()
        try:
            download(entry, path)
        finally:
            t['dl'] = time.monotonic() - mark
            t['bytes'] = os.path.getsize(path) if os.path.exists(path) else None
        mark = time.monotonic()
        try:
            result = analyze(entry, path)
        finally:
            t['an'] = time.monotonic() - mark
            t['disk'] = _dir_bytes(work)
        t['embed'], t['ana'] = result.get('embedSeconds'), result.get('analysisSeconds')
        outcome = 'success'
    except TrackFailure as f:
        outcome, stage, code = 'failure', f.stage, f.code
        raise
    except Exception as e:
        outcome, stage, code = 'failure', 'analyze', 'analyze_failed'
        raise TrackFailure('analyze', 'analyze_failed', type(e).__name__)
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if metrics is not None:
            metrics.append(M.make_row(
                entry.get('providerTrackID', ''), entry.get('durationSec'), outcome,
                t['dl'], t['bytes'], t['embed'], t['ana'] if t['ana'] is not None else t['an'],
                time.monotonic() - started, stage, code, t['disk']))
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
          download=None, analyze=analyze_audio, now=None, git_sha=None, tmp_root=None,
          metrics_out=None, env=None):
    batch, batch_sha, catalog_sha = S.load_batch(batch_path, catalog_path)
    download = download or JamendoTrackDownloader()
    model_sha = S.sha256_dir(model_dir)
    if expected_model_sha and expected_model_sha != model_sha:
        raise S.ShardError('model archive checksum does not match the pinned value')
    successes, failures, rows = [], [], []
    run_env = env or M.environment(git_sha or os.environ.get('GITHUB_SHA', 'unknown'), model_sha, fingerprint)
    try:
        for entry in batch['tracks']:
            try:
                successes.append((entry, process_track(entry, fingerprint, download, analyze, tmp_root, rows)))
            except TrackFailure as f:
                failures.append((entry, f))
    finally:
        if metrics_out:  # also on cancellation, so attempted tracks are never lost
            write_metrics(metrics_out, rows, output, run_env)
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
    if metrics_out:  # refresh now that the shard size is known
        write_metrics(metrics_out, rows, output, run_env)
    return meta


def write_metrics(path, rows, output, env):
    shard_bytes = os.path.getsize(output) if os.path.exists(output) else None
    with open(path, 'wb') as f:
        f.write(S.canonical(M.build_document(rows, env, shard_bytes)) + b'\n')


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
    ap.add_argument('--metrics-out', help='opt-in safe per-track timing metrics (JSON)')
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
                     a.expected_model_sha256, metrics_out=a.metrics_out)
        print(f"built {meta['batch_id']}: {meta['status']} "
              f"{meta['success_count']} ok, {meta['failure_count']} failed")
        return 0
    except S.ShardError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
