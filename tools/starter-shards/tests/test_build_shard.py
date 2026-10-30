import base64, datetime, io, json, os, shutil, sqlite3, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import build_shard as B
import shardlib as S

FP = 'clap-int4-128-v1:128:a:b:c:1:1'


def entry(i):
    return {'provider': 'jamendo', 'providerTrackID': str(i), 'streamURL': f'https://example.invalid/{i}.mp3',
            'sourceRevision': f'rev{i}', 'title': f'T{i}', 'artist': 'A', 'license': 'cc-by', 'durationSec': 100.5}


class ShardTests(unittest.TestCase):
    fail_download = None
    fail_analyze = None

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.model = os.path.join(self.dir, 'model')
        os.makedirs(self.model)
        open(os.path.join(self.model, 'w.bin'), 'wb').write(b'weights')
        self.seen_paths = []
        self.analyze = self.default_analyze

    def write(self, name, obj):
        p = os.path.join(self.dir, name)
        open(p, 'wb').write(S.canonical(obj) + b'\n')
        return p

    def make(self, tracks=None):
        tracks = tracks if tracks is not None else [entry(1), entry(2), entry(3)]
        cat = {'schema': 'starter-catalog-v1', 'tracks': tracks}
        cpath = self.write('catalog.json', cat)
        sha = S.sha256_hex(S.canonical(cat))
        bpath = self.write('batch.json', {'schema': 'starter-batch-v1', 'batchID': 'batch-0001',
                                          'catalogSHA256': sha, 'tracks': tracks})
        return bpath, cpath

    def download(self, e, dest):
        open(dest, 'wb').write(b'x' * 20000)
        self.seen_paths.append(dest)
        if e['providerTrackID'] == self.fail_download:
            raise B.TrackFailure('download', 'download_failed', 'HTTPError')

    def default_analyze(self, e, path):
        if e['providerTrackID'] == self.fail_analyze:
            raise RuntimeError('boom')
        return {'embedding': [0.1] * 128, 'transitionProfile': {'bpm': 120.0, 'key': '8A'}}

    def build(self, name='s.sqlite', paths=None, **kw):
        bpath, cpath = paths or self.make()
        out = os.path.join(self.dir, name)
        meta = B.build(bpath, cpath, self.model, FP, out, download=self.download, analyze=self.analyze,
                       git_sha='abc', tmp_root=self.dir, **kw)
        return out, meta, (bpath, cpath)

    def rows(self, out):
        return sqlite3.connect(out).execute('SELECT * FROM shard_track ORDER BY 1,2').fetchall()

    def test_deterministic(self):
        a, _, p = self.build('a.sqlite', now=datetime.datetime(2026, 1, 1))
        b, _, _ = self.build('b.sqlite', paths=p, now=datetime.datetime(2027, 1, 1))
        self.assertEqual(self.rows(a), self.rows(b))
        self.assertEqual(S.logical_digest(a), S.logical_digest(b))
        S.validate_shard(a, FP)

    def test_cli_validate_only(self):
        out, _, (bp, cp) = self.build()
        self.assertEqual(B.main(['--validate-only', '--output', out, '--embedding-space-fingerprint', FP,
                                 '--batch', bp, '--catalog', cp]), 0)
        self.assertEqual(B.main(['--validate-only', '--output', out, '--embedding-space-fingerprint', 'x']), 1)

    def test_reordered_rejected(self):
        with self.assertRaises(S.ShardError):
            S.load_batch(*self.make([entry(2), entry(1)]))

    def test_duplicate_rejected(self):
        with self.assertRaises(S.ShardError):
            S.load_batch(*self.make([entry(1), entry(1)]))

    def test_bad_checksum_and_catalog_mismatch(self):
        out, _, _ = self.build()
        db = sqlite3.connect(out)
        db.execute("UPDATE shard_track SET payload_sha256 = 'bad' WHERE provider_track_id = '1'")
        db.commit()
        db.close()
        with self.assertRaisesRegex(S.ShardError, 'checksum'):
            S.validate_shard(out, FP)
        bpath, cpath = self.make()
        b = json.load(open(bpath))
        b['catalogSHA256'] = '0' * 64
        with self.assertRaises(S.ShardError):
            S.load_batch(self.write('bad.json', b), cpath)

    def test_wrong_fingerprint(self):
        out, _, _ = self.build()
        with self.assertRaisesRegex(S.ShardError, 'fingerprint'):
            S.validate_shard(out, 'other')

    def test_127d_and_oversized_profile(self):
        p = B.process_track(entry(1), FP, self.download, self.analyze, self.dir)
        p['embedding'] = p['embedding'][:127]
        with self.assertRaisesRegex(S.ShardError, '128'):
            S.validate_payload(p, FP)
        p['embedding'] = [0.0] * 128
        p['transitionProfile'] = {'blob': 'x' * 5000}
        with self.assertRaisesRegex(S.ShardError, 'Profile'):
            S.validate_payload(p, FP)
        self.analyze = lambda e, path: {'embedding': [0.0] * 127, 'transitionProfile': {}}
        _, meta, _ = self.build()
        self.assertEqual(meta['status'], 'incomplete')

    def test_failures_recorded_incomplete(self):
        self.fail_download, self.fail_analyze = '1', '2'
        out, meta, _ = self.build()
        fails = sqlite3.connect(out).execute(
            'SELECT provider_track_id, stage, error_code FROM shard_failure ORDER BY 1').fetchall()
        self.assertEqual(fails, [('1', 'download', 'download_failed'), ('2', 'analyze', 'analyze_failed')])
        self.assertEqual((meta['status'], meta['success_count'], meta['failure_count']), ('incomplete', '1', '2'))
        S.validate_shard(out, FP)
        self.assertEqual(json.load(open(out[:-7] + '.report.json'))['failure_count'], 2)

    def test_temp_audio_removed(self):
        self.fail_download, self.fail_analyze = '1', '2'
        self.build()
        self.assertEqual(len(self.seen_paths), 3)
        for p in self.seen_paths:
            self.assertFalse(os.path.exists(p))
            self.assertFalse(os.path.exists(os.path.dirname(p)))

    def test_model_checksum_pin(self):
        with self.assertRaisesRegex(S.ShardError, 'model'):
            self.build(expected_model_sha='0' * 64)

    def test_durable_jamendo_locator_is_resolved_without_persisting_urls(self):
        seen, now, sleeps = [], [10.0], []
        class Response(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
        def opener(request, timeout):
            seen.append(request.full_url)
            return Response(b'x' * 10001)
        downloader = B.JamendoTrackDownloader('secret-client-id', opener=opener,
                                               clock=lambda: now[0], sleep=sleeps.append)
        first = dict(entry(7), streamURL='jamendo://track/7')
        first_path = os.path.join(self.dir, 'first.mp3')
        downloader(first, first_path)
        now[0] = 12.0
        second_path = os.path.join(self.dir, 'second.mp3')
        downloader(first, second_path)
        self.assertEqual(sleeps, [3.0])
        self.assertEqual(len(seen), 2)
        self.assertTrue(all('/tracks/file/?' in url and 'id=7' in url for url in seen))
        self.assertFalse(os.path.exists(first_path + '.url'))
        self.assertFalse(os.path.exists(second_path + '.url'))

    def test_jamendo_resolver_requires_matching_durable_locator(self):
        downloader = B.JamendoTrackDownloader('client')
        with self.assertRaisesRegex(B.TrackFailure, 'durable Jamendo locator'):
            downloader(entry(1), os.path.join(self.dir, 'x.mp3'))

    def test_tool_diagnostic_redacts_urls_and_paths(self):
        error = __import__('subprocess').CalledProcessError(1, ['tool'], stderr='https://x/?token=nope /tmp/secret/file')
        detail = B.safe_subprocess_detail(error)
        self.assertNotIn('token=', detail)
        self.assertNotIn('/tmp/secret', detail)

    def test_embedder_quantized_output_is_decoded_at_128_dimensions(self):
        raw = bytes([0, 127, 128] + [1] * 125)
        vector = B.embedding_from_tool_result({
            'dimensions': 128,
            'scale': 0.25,
            'quantizedVectorBase64': base64.b64encode(raw).decode('ascii'),
        })
        self.assertEqual(len(vector), 128)
        self.assertEqual(vector[:3], [0.0, 31.75, -32.0])
        with self.assertRaisesRegex(ValueError, 'length'):
            B.embedding_from_tool_result({
                'dimensions': 128, 'scale': 0.25,
                'quantizedVectorBase64': base64.b64encode(raw[:-1]).decode('ascii'),
            })


if __name__ == '__main__':
    unittest.main()
