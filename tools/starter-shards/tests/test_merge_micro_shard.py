import datetime, os, shutil, sqlite3, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import assemble_starter as A
import build_shard as B
import merge_micro_shard as M
import shardlib as S

FP = 'clap-int4-128-v1:128:a:b:c:1:1'


def entry(i):
    return {'provider': 'jamendo', 'providerTrackID': str(i), 'streamURL': f'https://example.invalid/{i}.mp3',
            'sourceRevision': f'rev{i}', 'title': f'T{i}', 'artist': 'A', 'license': 'cc-by', 'durationSec': 100.5}


class MergeMicroShardTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.model = os.path.join(self.dir, 'model')
        os.makedirs(self.model)
        open(os.path.join(self.model, 'w.bin'), 'wb').write(b'weights')

    def write(self, name, obj):
        p = os.path.join(self.dir, name)
        open(p, 'wb').write(S.canonical(obj) + b'\n')
        return p

    def download(self, e, dest):
        open(dest, 'wb').write(b'x' * 20000)

    def analyze(self, e, path):
        n = int(e['providerTrackID'])
        return {'embedding': [n / 100.0] * 128, 'transitionProfile': {'bpm': 100.0 + n, 'key': '8A'}}

    def base_db(self, tracks):
        """A normally-assembled starter.sqlite with one batch of `tracks`."""
        cat = {'schema': 'starter-catalog-v1', 'tracks': tracks}
        cpath = self.write('base-catalog.json', cat)
        bpath = self.write('base-batch.json', {'schema': 'starter-batch-v1', 'batchID': 'batch-0001',
                           'catalogSHA256': S.sha256_hex(S.canonical(cat)), 'tracks': tracks})
        shard_out = os.path.join(self.dir, 'base-batch.sqlite')
        B.build(bpath, cpath, self.model, FP, shard_out, download=self.download, analyze=self.analyze,
               git_sha='gen', tmp_root=self.dir, now=datetime.datetime(2026, 1, 1))
        _, batch_sha, _ = S.load_batch(bpath, cpath)
        allow = self.write('base-allow.json', {'schema': A.ALLOWLIST_SCHEMA, 'shards': [
            {'batchID': 'batch-0001', 'batchManifestSHA256': batch_sha, 'assetName': 'base-batch.sqlite',
             'assetURL': 'https://example.invalid/base-batch.sqlite', 'assetSHA256': S.sha256_file(shard_out)}]})
        out = os.path.join(self.dir, 'base.sqlite')
        A.assemble(cpath, allow, out, os.path.join(self.dir, 'base-report.md'), shard_dir=self.dir,
                  generator_sha='gen')
        return out

    def micro_shard(self, tracks, batch_id='batch-micro', fp=FP):
        """A standalone catalog+shard pair, independent of the base's own catalog."""
        cat = {'schema': 'starter-catalog-v1', 'tracks': tracks}
        cpath = self.write(f'{batch_id}-catalog.json', cat)
        bpath = self.write(f'{batch_id}-batch.json', {'schema': 'starter-batch-v1', 'batchID': batch_id,
                           'catalogSHA256': S.sha256_hex(S.canonical(cat)), 'tracks': tracks})
        out = os.path.join(self.dir, f'{batch_id}.sqlite')
        B.build(bpath, cpath, self.model, fp, out, download=self.download, analyze=self.analyze,
               git_sha='gen', tmp_root=self.dir, now=datetime.datetime(2026, 1, 1))
        return out, cpath

    def test_mergesSixTracksIntoABaseOfFourWithoutTouchingOriginalRows(self):
        base = self.base_db([entry(1), entry(2), entry(3), entry(4)])
        shard, cpath = self.micro_shard([entry(5), entry(6)])
        out = os.path.join(self.dir, 'merged.sqlite')
        added, total, version = M.merge(base, shard, cpath, 'batch-micro', out)
        self.assertEqual((added, total), (2, 6))
        self.assertTrue(version.startswith('starter-v4-'))

        old_rows = {(r[0], r[1]): r for r in sqlite3.connect(base).execute(
            f'SELECT {A.TRACK_COLUMNS} FROM starter_track')}
        new_rows = {(r[0], r[1]): r for r in sqlite3.connect(out).execute(
            f'SELECT {A.TRACK_COLUMNS} FROM starter_track')}
        self.assertEqual(len(new_rows), 6)
        for k, v in old_rows.items():
            self.assertEqual(new_rows[k], v, k)
        self.assertEqual({k[1] for k in new_rows} - {k[1] for k in old_rows}, {'5', '6'})

        db = sqlite3.connect(out)
        self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
        self.assertEqual(db.execute('PRAGMA integrity_check').fetchall(), [('ok',)])
        self.assertEqual(db.execute("SELECT genre FROM starter_track WHERE provider_track_id='5'").fetchone()[0],
                         entry(5).get('genre', ''))

    def test_rejectsADuplicateBatchIDAlreadyInTheBase(self):
        base = self.base_db([entry(1), entry(2)])
        shard, cpath = self.micro_shard([entry(3)], batch_id='batch-0001')  # collides with the base's own batch
        with self.assertRaisesRegex(S.ShardError, 'already present'):
            M.merge(base, shard, cpath, 'batch-0001', os.path.join(self.dir, 'merged.sqlite'))

    def test_rejectsATrackIdentityAlreadyInTheBase(self):
        base = self.base_db([entry(1), entry(2)])
        shard, cpath = self.micro_shard([entry(2), entry(3)])  # track 2 collides
        with self.assertRaisesRegex(S.ShardError, 'already present'):
            M.merge(base, shard, cpath, 'batch-micro', os.path.join(self.dir, 'merged.sqlite'))

    def test_rejectsAShardBuiltAgainstADifferentCatalogThanTheOnePassed(self):
        base = self.base_db([entry(1), entry(2)])
        shard, _ = self.micro_shard([entry(3)])
        wrong_catalog = self.write('wrong-catalog.json', {'schema': 'starter-catalog-v1', 'tracks': [entry(4)]})
        with self.assertRaisesRegex(S.ShardError, 'input_catalog_sha256'):
            M.merge(base, shard, wrong_catalog, 'batch-micro', os.path.join(self.dir, 'merged.sqlite'))

    def test_rejectsAnIncompleteShard(self):
        base = self.base_db([entry(1)])
        cat = {'schema': 'starter-catalog-v1', 'tracks': [entry(2)]}
        cpath = self.write('incomplete-catalog.json', cat)
        bpath = self.write('incomplete-batch.json', {'schema': 'starter-batch-v1', 'batchID': 'batch-micro',
                           'catalogSHA256': S.sha256_hex(S.canonical(cat)), 'tracks': [entry(2)]})
        out = os.path.join(self.dir, 'incomplete.sqlite')

        def fail_analyze(e, path):
            raise RuntimeError('boom')
        B.build(bpath, cpath, self.model, FP, out, download=self.download, analyze=fail_analyze,
               git_sha='gen', tmp_root=self.dir, now=datetime.datetime(2026, 1, 1))
        with self.assertRaisesRegex(S.ShardError, 'not complete'):
            M.merge(base, out, cpath, 'batch-micro', os.path.join(self.dir, 'merged.sqlite'))


if __name__ == '__main__':
    unittest.main()
