import json, math, os, re, shutil, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import build_shard as B
import pilot_metrics as M
import pilot_report as R
import select_pilot as P
import shardlib as S
from test_build_shard import FP, entry

SECRET = 'https://cdn.example.invalid/a.mp3?token=SECRET123&sig=abc'
ENV = {'macOS': '15', 'xcode': 'x', 'python': '3', 'generatorGitSHA': 'abc', 'modelArchiveSHA256': 'm',
       'embeddingSpaceFingerprint': FP}


class PilotBase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.model = os.path.join(self.dir, 'model')
        os.makedirs(self.model)
        open(os.path.join(self.model, 'w.bin'), 'wb').write(b'w')
        self.mode = {}

    def write(self, name, obj):
        p = os.path.join(self.dir, name)
        open(p, 'wb').write(S.canonical(obj) + b'\n')
        return p

    def download(self, e, dest):
        open(dest, 'wb').write(b'x' * 20000)
        m = self.mode.get(e['providerTrackID'])
        if m == 'dl':
            raise B.TrackFailure('download', 'download_failed', SECRET)
        if m == 'cancel':
            raise KeyboardInterrupt()

    def analyze(self, e, path):
        if self.mode.get(e['providerTrackID']) == 'an':
            raise RuntimeError(SECRET)
        return {'embedding': [0.1] * 128, 'transitionProfile': {'bpm': 1.0}, 'embedSeconds': 2.0,
                'analysisSeconds': 3.0}

    def run_build(self, n=4):
        tracks = [entry(i) for i in range(1, n + 1)]
        cat = {'schema': 'starter-catalog-v1', 'tracks': tracks}
        cp = self.write('c.json', cat)
        bp = self.write('b.json', {'schema': 'starter-batch-v1', 'batchID': 'p', 'tracks': tracks,
                                   'catalogSHA256': S.sha256_hex(S.canonical(cat))})
        mo = os.path.join(self.dir, 'm.json')
        out = os.path.join(self.dir, 's.sqlite')
        try:
            B.build(bp, cp, self.model, FP, out, download=self.download, analyze=self.analyze, git_sha='abc',
                    tmp_root=self.dir, metrics_out=mo, env=ENV)
        finally:
            pass
        return mo


class MetricsTests(PilotBase):
    def test_rows_success_and_failures_redacted(self):
        self.mode = {'2': 'dl', '3': 'an'}
        mo = self.run_build()
        raw = open(mo).read()
        doc = json.loads(raw)
        self.assertNotIn('SECRET123', raw)
        self.assertNotIn('http', raw)
        self.assertFalse(M.contains_url(raw))
        rows = {r['providerTrackID']: r for r in doc['tracks']}
        self.assertEqual([rows[k]['outcome'] for k in '1234'], ['success', 'failure', 'failure', 'success'])
        self.assertEqual((rows['2']['stage'], rows['2']['errorCode']), ('download', 'download_failed'))
        self.assertEqual((rows['3']['stage'], rows['3']['errorCode']), ('analyze', 'analyze_failed'))
        self.assertEqual((rows['1']['embedSeconds'], rows['1']['analysisSeconds']), (2.0, 3.0))
        self.assertEqual(rows['1']['downloadBytes'], 20000)
        self.assertGreaterEqual(rows['1']['tempDiskBytes'], 20000)
        self.assertEqual(doc['summary']['failureCount'], 2)
        self.assertEqual(doc['generatedShardBytes'], os.path.getsize(os.path.join(self.dir, 's.sqlite')))
        self.assertEqual(doc['environment']['embeddingSpaceFingerprint'], FP)
        self.assertEqual([d for d in os.listdir(self.dir) if d.startswith('shard-')], [])

    def test_cancellation_recorded_and_cleaned(self):
        self.mode = {'2': 'cancel'}
        with self.assertRaises(KeyboardInterrupt):
            self.run_build()
        doc = json.load(open(os.path.join(self.dir, 'm.json')))
        self.assertEqual([r['outcome'] for r in doc['tracks']], ['success', 'cancelled'])
        self.assertEqual([d for d in os.listdir(self.dir) if d.startswith('shard-')], [])

    def test_malformed_timings_safe(self):
        row = M.make_row('9?x=1', float('nan'), 'success', -1, True, 'abc', math.inf, None)
        self.assertIsNone(row['downloadSeconds'])
        self.assertIsNone(row['downloadBytes'])
        self.assertIsNone(row['embedSeconds'])
        self.assertIsNone(row['analysisSeconds'])
        self.assertEqual(row['providerTrackID'], '9_x_1')
        json.dumps(M.build_document([row], ENV, None), allow_nan=False)
        s = M.summarize([row])
        self.assertIsNone(s['totalSeconds']['p90'])
        self.assertEqual(M.recommend(None, 0), 25)

    def test_exact_percentiles(self):
        rows = [M.make_row(str(i), 1, 'success', total_seconds=i) for i in range(1, 11)]
        t = M.summarize(rows)['totalSeconds']
        self.assertEqual((t['p50'], t['p90'], t['max']), (5.0, 9.0, 10.0))

    def test_recommendation_boundaries(self):
        self.assertEqual(M.recommend(60, 0), 100)
        self.assertEqual(M.recommend(60.001, 0), 50)
        self.assertEqual(M.recommend(60, 0.01), 50)
        self.assertEqual(M.recommend(120, 0.02), 50)
        self.assertEqual(M.recommend(120.001, 0.02), 25)
        self.assertEqual(M.recommend(120, 0.0201), 25)
        self.assertEqual(M.recommend(10, 0.05), 25)

    def test_gates(self):
        rows = [M.make_row('1', 1, 'success', total_seconds=10, temp_bytes=1)]
        doc = M.build_document(rows, ENV, 1)
        self.assertEqual(M.evaluate(doc, FP)[1], [])
        big = M.build_document([M.make_row('1', 1, 'success', total_seconds=1, temp_bytes=26 * 10 ** 9)], ENV, 1)
        self.assertEqual(len(M.evaluate(big, FP, 151 * 60, ['x'], True)[1]), 4 + 0)
        self.assertEqual(len(M.evaluate(doc, 'other')[1]), 1)
        leaky = json.loads(json.dumps(doc))
        leaky['environment']['xcode'] = SECRET
        self.assertIn('metrics contain a stream URL or query string', M.evaluate(leaky, FP)[1])

    def test_report_cli(self):
        self.mode = {'2': 'dl'}
        mo = self.run_build()
        out = os.path.join(self.dir, 'r.json')
        self.assertEqual(R.main(['--metrics', mo, '--expected-fingerprint', FP, '--temp-root', self.dir,
                                 '--out', out, '--markdown', out + '.md']), 0)
        rep = json.load(open(out))
        self.assertEqual(rep['recommendedMaxTracksPerRunner'], 25)
        self.assertNotIn('SECRET', open(out).read() + open(out + '.md').read())
        os.makedirs(os.path.join(self.dir, 'shard-left'))
        self.assertEqual(R.main(['--metrics', mo, '--expected-fingerprint', FP, '--temp-root', self.dir,
                                 '--out', out]), 1)


class SelectionTests(PilotBase):
    def catalog(self, n=100):
        tracks = [dict(entry(1000 + i), durationSec=float(60 + i)) for i in range(n)]
        return self.write('cat.json', {'schema': 'starter-catalog-v1', 'embeddingSpace': 'clap-int4-128-v1',
                                       'tracks': tracks})

    def test_selection_deterministic_and_stratified(self):
        tracks = [dict(entry(1000 + i), durationSec=float(60 + i)) for i in range(100)]
        a, detail = P.select(tracks)
        b, _ = P.select(list(reversed(tracks)))
        self.assertEqual(a, sorted(b, key=S.identity))
        d = sorted(t['durationSec'] for t in a)
        self.assertEqual(len(a), 10)
        self.assertEqual(len({S.identity(t) for t in a}), 10)
        self.assertEqual(a, sorted(a, key=S.identity))
        self.assertEqual(d, [78.0, 79.0, 108.0, 109.0, 110.0, 138.0, 139.0, 140.0, 154.0, 155.0])
        self.assertEqual(detail['low']['targetDurationSec'], 79.0)

    def test_too_small_rejected(self):
        with self.assertRaises(S.ShardError):
            P.select([entry(i) for i in range(1, 6)])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = open(os.path.join(os.path.dirname(HERE), 'starter-shard-pilot.workflow.yml')).read()
        self.code = '\n'.join(l for l in self.text.splitlines() if not l.lstrip().startswith('#'))

    def test_dispatch_only_macos_no_publication(self):
        self.assertEqual(re.findall(r'^on:\n((?:  .*\n)+)', self.code, re.M)[0].split(':')[0].strip(), 'workflow_dispatch')
        self.assertEqual(len(re.findall(r'^  (?:push|pull_request|schedule|workflow_call):', self.code, re.M)), 0)
        self.assertIn('runs-on: macos-latest', self.code)
        self.assertRegex(self.code, r'default: false')
        self.assertIn('[ "$PUBLISH" = "false" ]', self.code)
        self.assertNotIn('contents: write', self.code)
        for bad in ('gh release', 'upload-release', 'git push', 'starter.lock', 'sqlite3 ', 'create-release'):
            self.assertNotIn(bad, self.code)
        self.assertIn('retention-days:', self.code)
        self.assertIn('Config/starter-batches/pilots/', self.code)
        self.assertIn('--metrics-out', self.code)


if __name__ == '__main__':
    unittest.main()
