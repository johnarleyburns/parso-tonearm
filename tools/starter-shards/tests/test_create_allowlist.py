import json, os, shutil, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import create_allowlist as A
import shardlib as S


class AllowlistTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        for number in (1, 2):
            batch = {'schema': 'starter-batch-v1', 'batchID': f'batch-{number:04d}',
                     'catalogSHA256': 'a' * 64, 'tracks': []}
            with open(os.path.join(self.dir, f'batch-{number:04d}.json'), 'wb') as f:
                f.write(S.canonical(batch) + b'\n')

    def test_allowlist_uses_only_expected_assets_and_checksums(self):
        original_assets, original_sums = A.release_assets, A.checksum_assets
        self.addCleanup(setattr, A, 'release_assets', original_assets)
        self.addCleanup(setattr, A, 'checksum_assets', original_sums)
        assets = {f'batch-{n:04d}.sqlite': {'name': f'batch-{n:04d}.sqlite'} for n in (1, 2)}
        A.release_assets = lambda repo, tag: assets
        A.checksum_assets = lambda repo, tag, received: {name: str(n) * 64 for n, name in enumerate(assets, 1)}
        result = A.make_allowlist('owner/repo', 'tag', self.dir)
        self.assertEqual(result['schema'], A.SCHEMA)
        self.assertEqual([s['batchID'] for s in result['shards']], ['batch-0001', 'batch-0002'])
        self.assertTrue(result['shards'][0]['assetURL'].endswith('/tag/batch-0001.sqlite'))

    def test_missing_asset_is_rejected(self):
        original_assets, original_sums = A.release_assets, A.checksum_assets
        self.addCleanup(setattr, A, 'release_assets', original_assets)
        self.addCleanup(setattr, A, 'checksum_assets', original_sums)
        A.release_assets = lambda repo, tag: {'batch-0001.sqlite': {'name': 'batch-0001.sqlite'}}
        A.checksum_assets = lambda repo, tag, assets: {'batch-0001.sqlite': 'a' * 64}
        with self.assertRaisesRegex(S.ShardError, 'batch-0002'):
            A.make_allowlist('owner/repo', 'tag', self.dir)


if __name__ == '__main__':
    unittest.main()
