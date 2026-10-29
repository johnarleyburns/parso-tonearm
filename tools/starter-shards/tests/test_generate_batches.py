import json, os, shutil, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import generate_batches as G
import shardlib as S

FIXTURE = os.path.join(HERE, '..', '..', '..', 'Tests', 'Fixtures', 'starter-batches', 'catalog-4.json')


class GenerateBatchesTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.catalog = json.load(open(FIXTURE))

    def write_catalog(self, obj, name='catalog.json'):
        p = os.path.join(self.dir, name)
        open(p, 'wb').write(json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                                       allow_nan=False).encode('utf-8', 'surrogatepass'))
        return p

    def run_gen(self, catalog_path, out, size=2):
        G.main(['--catalog', catalog_path, '--out-dir', out, '--size', str(size)])

    def read_all(self, out):
        return {n: open(os.path.join(out, n), 'rb').read() for n in sorted(os.listdir(out))}

    def test_deterministic_and_ranges(self):
        cat = self.write_catalog(self.catalog)
        a, b = os.path.join(self.dir, 'a'), os.path.join(self.dir, 'b')
        self.run_gen(cat, a)
        self.run_gen(cat, b)
        self.assertEqual(self.read_all(a), self.read_all(b))
        self.assertEqual(list(self.read_all(a)), ['batch-0001.json', 'batch-0002.json'])
        sha = S.sha256_hex(open(cat, 'rb').read())
        ids = []
        for n in ('batch-0001.json', 'batch-0002.json'):
            batch = json.load(open(os.path.join(a, n)))
            self.assertEqual(batch['catalogSHA256'], sha)
            self.assertEqual(batch['schema'], 'starter-batch-v1')
            ids.append([t['providerTrackID'] for t in batch['tracks']])
        self.assertEqual(ids, [['1', '2'], ['3', '4']])

    def test_existing_matching_is_noop_and_mismatch_fails(self):
        cat = self.write_catalog(self.catalog)
        out = os.path.join(self.dir, 'out')
        self.run_gen(cat, out)
        before = self.read_all(out)
        mtimes = {n: os.stat(os.path.join(out, n)).st_mtime_ns for n in before}
        self.run_gen(cat, out)
        self.assertEqual(before, self.read_all(out))
        self.assertEqual(mtimes, {n: os.stat(os.path.join(out, n)).st_mtime_ns for n in before})
        changed = json.loads(json.dumps(self.catalog))
        changed['tracks'][3]['sourceRevision'] = 'other'
        with self.assertRaises(S.ShardError):
            self.run_gen(self.write_catalog(changed, 'c2.json'), out)
        self.assertEqual(before, self.read_all(out))

    def assert_rejected(self, mutate):
        cat = json.loads(json.dumps(self.catalog))
        mutate(cat)
        with self.assertRaises(S.ShardError):
            self.run_gen(self.write_catalog(cat), os.path.join(self.dir, 'o'))

    def test_invalid_catalogs_fail(self):
        self.assert_rejected(lambda c: c['tracks'].__setitem__(1, dict(c['tracks'][0])))
        self.assert_rejected(lambda c: c['tracks'].reverse())
        self.assert_rejected(lambda c: c['tracks'][0].pop('sourceRevision'))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('sourceRevision', ''))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('provider', 'archive'))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('durationSec', 0))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('durationSec', -1))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('title', 'a\x00b'))
        self.assert_rejected(lambda c: c['tracks'][0].__setitem__('title', 'a\ud800b'))
        self.assert_rejected(lambda c: c.__setitem__('embeddingSpace', 'clap-v3-512'))
        self.assert_rejected(lambda c: c.pop('embeddingSpace'))

    def test_nan_duration_fails(self):
        cat = self.write_catalog(self.catalog)
        raw = open(cat).read().replace('"durationSec":100.5', '"durationSec":NaN', 1)
        open(cat, 'w').write(raw)
        with self.assertRaises(S.ShardError):
            self.run_gen(cat, os.path.join(self.dir, 'o'))


if __name__ == '__main__':
    unittest.main()
