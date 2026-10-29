import json, os, random, re, subprocess, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
sys.path.insert(0, TOOL)
sys.path.insert(0, os.path.join(TOOL, '..', 'starter-shards'))
import build_top10_cohort as B
import shardlib as S

FX = os.path.join(HERE, '..', '..', '..', 'Tests', 'Fixtures', 'starter-catalog')
TAX = os.path.join(FX, 'taxonomy.json')
RESP = os.path.join(FX, 'responses.json')


def run(top=10, responses=None, out=None):
    out = out or tempfile.mkdtemp()
    fx = RESP
    if responses is not None:
        fx = os.path.join(out, 'fx.json')
        with open(fx, 'w', encoding='utf-8') as f:
            json.dump({'responses': responses}, f)
    paths = [os.path.join(out, n) for n in ('sel.json', 'rep.json', 'cat.json')]
    B.main(['--taxonomy', TAX, '--selection-out', paths[0], '--report-out', paths[1],
            '--catalog-out', paths[2], '--top-per-node', str(top), '--fixture', fx])
    decoded, raw = [], []
    for path in paths:
        with open(path, encoding='utf-8') as f:
            decoded.append(json.load(f))
        with open(path, 'rb') as f:
            raw.append(f.read())
    return decoded, raw


class CohortTests(unittest.TestCase):
    def test_dedup_and_provenance(self):
        (sel, rep, cat), _ = run()
        ids = [t['providerTrackID'] for t in sel['tracks']]
        self.assertEqual(ids, ['10', '20', '30', '40', '50'])
        t20 = next(t for t in sel['tracks'] if t['providerTrackID'] == '20')
        self.assertEqual(t20['genreNodeIDs'], ['genre:ambient', 'subgenre:electronic:ambient'])
        self.assertEqual(rep['rawSelectionsBeforeDedupe'], 4 + 3 + 0)
        self.assertEqual(rep['uniqueSelectedTracks'], 5)
        self.assertEqual(rep['duplicateCollapseCount'], 2)
        self.assertEqual(rep['taxonomyNodeCount'], 2)

    def test_ranking_popularity_desc_then_id_asc(self):
        (sel, _, _), _ = run()
        node = next(n for n in sel['nodes'] if n['nodeID'] == 'genre:ambient')
        self.assertEqual([s['providerTrackID'] for s in node['rankedSelections']], ['20', '10', '30', '40'])
        self.assertEqual([s['rank'] for s in node['rankedSelections']], [1, 2, 3, 4])

    def test_exclusions(self):
        (_, rep, _), _ = run()
        ex = rep['excludedByReason']
        self.assertEqual(ex, {'not_downloadable': 1, 'license': 1, 'missing_metadata': 1,
                              'invalid_duration': 2, 'filter_mismatch': 1})

    def test_limit_and_no_padding(self):
        (sel, rep, _), _ = run(top=2)
        for n in sel['nodes']:
            self.assertLessEqual(len(n['rankedSelections']), 2)
        (sel, rep, _), _ = run(top=10)
        self.assertEqual(rep['nodesWithFewerThanTop'], ['genre:ambient', 'subgenre:electronic:ambient'])
        self.assertIn('shortfallReason', rep['nodes'][0])
        self.assertEqual(rep['recommendedBatchCount'], 1)
        self.assertEqual(rep['recommendedExecutionIssueCount'], 1)

    def test_deterministic_across_reordering(self):
        with open(RESP, encoding='utf-8') as f:
            base = json.load(f)['responses']
        _, first = run(responses=base)
        for seed in range(3):
            shuffled = {k: random.Random(seed).sample(v, len(v)) for k, v in reversed(list(base.items()))}
            _, again = run(responses=shuffled)
            self.assertEqual(first[0], again[0])
            self.assertEqual(first[2], again[2])

    def test_catalog_valid_and_sorted(self):
        (_, rep, cat), raw = run()
        S.validate_catalog(cat)
        self.assertEqual(cat['embeddingSpace'], 'clap-int4-128-v1')
        self.assertEqual(cat['metadata']['selectedCount'], 5)
        self.assertEqual(cat['metadata']['nodeCount'], 2)
        self.assertEqual(cat['metadata']['selectionManifestSHA256'], rep['selectionSHA256'])
        self.assertEqual(S.sha256_hex(raw[2]), rep['catalogSHA256'])
        self.assertEqual(S.sha256_hex(raw[0]), rep['selectionSHA256'])

    def test_no_secrets_or_signed_urls_in_outputs(self):
        _, raw = run()
        for data in raw:
            text = data.decode()
            self.assertNotRegex(text, r'https?://[^"]*[?&]')
            self.assertNotIn('client_id', text)
            self.assertNotIn('example.invalid/audio', text)
        for name in os.listdir(FX):
            self.assertTrue(name.endswith('.json'))
            with open(os.path.join(FX, name), encoding='utf-8') as f:
                self.assertNotRegex(f.read(), r'https?://[^"]*[?&]|client_id')

    def test_live_mode_requires_env_credential(self):
        env = {k: v for k, v in os.environ.items() if k != 'JAMENDO_CLIENT_ID'}
        d = tempfile.mkdtemp()
        p = subprocess.run([sys.executable, '-I', os.path.join(TOOL, 'build_top10_cohort.py'),
                            '--taxonomy', TAX, '--selection-out', d + '/a', '--report-out', d + '/b',
                            '--catalog-out', d + '/c'], env=env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('JAMENDO_CLIENT_ID', p.stderr)

    def test_real_taxonomy_is_well_formed(self):
        tax, sha = B.load_taxonomy(os.path.join(TOOL, 'jamendo_taxonomy_v1.json'))
        self.assertGreater(len(tax['nodes']), 0)
        self.assertEqual(len(sha), 64)


if __name__ == '__main__':
    unittest.main()
