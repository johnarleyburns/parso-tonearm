import datetime, json, os, shutil, sqlite3, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import assemble_starter as A
import build_shard as B
import shardlib as S

FP = 'clap-int4-128-v1:128:a:b:c:1:1'


def entry(i):
    return {'provider': 'jamendo', 'providerTrackID': str(i), 'streamURL': f'https://example.invalid/{i}.mp3',
            'sourceRevision': f'rev{i}', 'title': f'T{i}', 'artist': 'A', 'license': 'cc-by', 'durationSec': 100.5}


class AssembleTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.model = os.path.join(self.dir, 'model')
        os.makedirs(self.model)
        open(os.path.join(self.model, 'w.bin'), 'wb').write(b'weights')
        self.fail_ids = set()
        self.tracks = [entry(i) for i in range(1, 5)]
        self.catalog_path = self.write('catalog.json', {'schema': 'starter-catalog-v1', 'tracks': self.tracks})
        self.catalog_sha = S.sha256_hex(S.canonical({'schema': 'starter-catalog-v1', 'tracks': self.tracks}))

    def write(self, name, obj):
        p = os.path.join(self.dir, name)
        open(p, 'wb').write(S.canonical(obj) + b'\n')
        return p

    def shard(self, batch_id, tracks, model=None, fp=FP, catalog_tracks=None):
        cat_tracks = catalog_tracks or self.tracks
        cat = {'schema': 'starter-catalog-v1', 'tracks': cat_tracks}
        cpath = self.write(f'cat-{batch_id}.json', cat)
        bpath = self.write(f'{batch_id}.json', {'schema': 'starter-batch-v1', 'batchID': batch_id,
                           'catalogSHA256': S.sha256_hex(S.canonical(cat)), 'tracks': tracks})
        out = os.path.join(self.dir, f'{batch_id}.sqlite')

        def download(e, dest):
            open(dest, 'wb').write(b'x' * 20000)

        def analyze(e, path):
            if e['providerTrackID'] in self.fail_ids:
                raise RuntimeError('boom')
            n = int(e['providerTrackID'])
            return {'embedding': [n / 100.0] * 128, 'transitionProfile': {'bpm': 100.0 + n, 'key': '8A'}}
        B.build(bpath, cpath, model or self.model, fp, out, download=download, analyze=analyze, git_sha='abc',
                tmp_root=self.dir, now=datetime.datetime(2026, 1, 1))
        _, batch_sha, _ = S.load_batch(bpath, cpath)
        return {'batchID': batch_id, 'batchManifestSHA256': batch_sha, 'assetName': f'{batch_id}.sqlite',
                'assetURL': f'https://example.invalid/{batch_id}.sqlite', 'assetSHA256': S.sha256_file(out)}

    def allowlist(self, entries, name='allow.json'):
        return self.write(name, {'schema': A.ALLOWLIST_SCHEMA, 'shards': entries})

    def two(self):
        return [self.shard('batch-0001', self.tracks[:2]), self.shard('batch-0002', self.tracks[2:])]

    def run_assemble(self, entries, out='out', **kw):
        d = os.path.join(self.dir, out)
        os.makedirs(d, exist_ok=True)
        return A.assemble(self.catalog_path, self.allowlist(entries), os.path.join(d, 'starter.sqlite'),
                          os.path.join(d, 'REPORT.md'), shard_dir=self.dir, generator_sha='gen', **kw), d

    def assertFails(self, entries, pattern, **kw):
        with self.assertRaisesRegex(S.ShardError, pattern):
            self.run_assemble(entries, out='fail', **kw)
        d = os.path.join(self.dir, 'fail')
        self.assertEqual([n for n in os.listdir(d)], [] if os.path.isdir(d) else [])

    def test_deterministic_independent_of_order(self):
        e = self.two()
        (plan_a, meta_a), da = self.run_assemble(e, 'a')
        (plan_b, meta_b), db = self.run_assemble(list(reversed(e)), 'b')
        self.assertEqual(meta_a['logical_content_sha256'], meta_b['logical_content_sha256'])
        self.assertEqual(A.read_back(os.path.join(da, 'starter.sqlite')), A.read_back(os.path.join(db, 'starter.sqlite')))
        self.assertEqual(open(os.path.join(da, 'REPORT.md')).read(), open(os.path.join(db, 'REPORT.md')).read())
        self.assertEqual(sorted(os.listdir(da)), sorted(A.OUTPUT_NAMES))
        self.assertEqual(plan_a['counts'], {'catalogExpected': 4, 'successful': 4, 'failed': 0, 'duplicate': 0,
                                            'unknown': 0, 'missing': 0, 'assembled': 4})

    def test_reader_round_trip_native_128d(self):
        _, d = self.run_assemble(self.two())
        meta, rows = A.read_back(os.path.join(d, 'starter.sqlite'))
        self.assertEqual(meta['format_version'], '4')
        self.assertEqual(meta['catalog_manifest_sha256'], self.catalog_sha)
        self.assertEqual(meta['embedding_space_fingerprint'], FP)
        self.assertEqual([(r[0], r[1]) for r in rows], [('jamendo', str(i)) for i in range(1, 5)])
        self.assertTrue(all(r[14] == 128 and len(r[15]) == 512 for r in rows))
        sums = open(os.path.join(d, 'SHA256SUMS.txt')).read()
        self.assertIn(S.sha256_file(os.path.join(d, 'starter.sqlite')), sums)

    def test_missing_batch(self):
        self.assertFails(self.two()[:1], 'missing identities')

    def test_duplicate_identity(self):
        dup = [self.shard('batch-0001', self.tracks[:2]), self.shard('batch-0002', self.tracks[1:])]
        self.assertFails(dup, 'duplicate identities')

    def test_unknown_identity(self):
        extra = self.tracks + [entry(9)]
        e = [self.shard('batch-0001', self.tracks[:2], catalog_tracks=extra),
             self.shard('batch-0002', self.tracks[2:] + [entry(9)], catalog_tracks=extra)]
        self.assertFails(e, 'catalog|unknown')

    def test_incomplete_shard(self):
        self.fail_ids = {'3'}
        self.assertFails(self.two(), 'incomplete')

    def test_wrong_model_and_fingerprint(self):
        other = os.path.join(self.dir, 'model2')
        os.makedirs(other)
        open(os.path.join(other, 'w.bin'), 'wb').write(b'other')
        self.assertFails([self.shard('batch-0001', self.tracks[:2]),
                          self.shard('batch-0002', self.tracks[2:], model=other)], 'model')
        self.assertFails([self.shard('batch-0001', self.tracks[:2]),
                          self.shard('batch-0002', self.tracks[2:], fp='other-fp')], 'fingerprint')

    def test_wrong_catalog(self):
        self.assertFails(self.two(), 'catalog SHA', expected_catalog_sha='0' * 64)
        changed = self.tracks[:3] + [dict(entry(4), title='changed')]
        e = [self.shard('batch-0001', self.tracks[:2], catalog_tracks=changed),
             self.shard('batch-0002', changed[2:], catalog_tracks=changed)]
        self.assertFails(e, 'input_catalog_sha256')

    def test_asset_checksum_and_payload_checksum(self):
        e = self.two()
        e[0] = dict(e[0], assetSHA256='0' * 64)
        self.assertFails(e, 'asset SHA-256')
        e = self.two()
        path = os.path.join(self.dir, 'batch-0001.sqlite')
        db = sqlite3.connect(path)
        db.execute("UPDATE shard_track SET payload_sha256 = 'bad' WHERE provider_track_id = '1'")
        db.commit()
        db.close()
        e[0] = dict(e[0], assetSHA256=S.sha256_file(path))
        self.assertFails(e, 'checksum')

    def test_invalid_vector_and_profile(self):
        e = self.two()
        path = os.path.join(self.dir, 'batch-0001.sqlite')
        db = sqlite3.connect(path)
        payload = json.loads(db.execute("SELECT payload_json FROM shard_track WHERE provider_track_id='1'").fetchone()[0])
        payload['embedding'] = payload['embedding'][:127]
        blob = S.canonical(payload)
        db.execute("UPDATE shard_track SET payload_json=?, payload_sha256=? WHERE provider_track_id='1'",
                   (blob, S.sha256_hex(blob)))
        db.commit()
        db.close()
        e[0] = dict(e[0], assetSHA256=S.sha256_file(path))
        self.assertFails(e, '128')

    def test_refuses_existing_output_unless_overwrite(self):
        e = self.two()
        _, d = self.run_assemble(e)
        with self.assertRaisesRegex(S.ShardError, 'overwrite'):
            self.run_assemble(e)
        self.run_assemble(e, overwrite=True)

    def test_validate_only_leaves_no_database(self):
        d = os.path.join(self.dir, 'v')
        allow = self.allowlist(self.two())
        rc = A.main(['--catalog', self.catalog_path, '--shard-allowlist', allow, '--output',
                     os.path.join(d, 'starter.sqlite'), '--report', os.path.join(d, 'REPORT.md'),
                     '--validate-only', '--shard-dir', self.dir])
        self.assertEqual(rc, 0)
        self.assertEqual(os.listdir(d), ['REPORT.md'])
        self.assertEqual(A.main(['--catalog', self.catalog_path, '--shard-allowlist', allow, '--output',
                                 os.path.join(d, 'x.sqlite'), '--report', os.path.join(d, 'R2.md'),
                                 '--catalog-sha256', '0' * 64, '--shard-dir', self.dir, '--validate-only']), 1)
        self.assertFalse(os.path.exists(os.path.join(d, 'R2.md')))


if __name__ == '__main__':
    unittest.main()
