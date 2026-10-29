#!/usr/bin/env python3
"""Evaluate pilot metrics: percentile summary, batch-size recommendation and failure gates.

  pilot_report.py --metrics M --expected-fingerprint F [--elapsed-seconds N] [--temp-root DIR]
                  [--artifact-dir DIR] --out report.json [--markdown report.md]

Exit 1 when any gate fails. Reads only the metrics file; it never touches the network.
"""
import argparse, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_metrics as M

ALLOWED_ARTIFACT_SUFFIXES = ('.json', '.md', '.SHA256SUMS', '.sqlite')


def publication_attempted(artifact_dir):
    if not artifact_dir:
        return False
    names = [os.path.basename(p) for p in glob.glob(os.path.join(artifact_dir, '**'), recursive=True)
             if os.path.isfile(p)]
    return any(n == 'starter.lock' or not n.endswith(ALLOWED_ARTIFACT_SUFFIXES) for n in names)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--metrics', required=True)
    ap.add_argument('--expected-fingerprint', required=True)
    ap.add_argument('--elapsed-seconds', type=float)
    ap.add_argument('--temp-root')
    ap.add_argument('--artifact-dir')
    ap.add_argument('--out', required=True)
    ap.add_argument('--markdown')
    a = ap.parse_args(argv)
    doc = json.load(open(a.metrics))
    leftovers = glob.glob(os.path.join(a.temp_root, 'shard-*')) if a.temp_root else []
    report, violations = M.evaluate(doc, a.expected_fingerprint, a.elapsed_seconds, leftovers,
                                    publication_attempted(a.artifact_dir))
    text = json.dumps(report, indent=2, sort_keys=True)
    open(a.out, 'w').write(text + '\n')
    if a.markdown:
        lines = ['# Starter shard pilot report', '',
                 f"- Status: **{report['status']}**",
                 f"- Recommended maximum tracks per runner: **{report['recommendedMaxTracksPerRunner']}**",
                 f"- p50 / p90 total seconds: {report['p50TotalSeconds']} / {report['p90TotalSeconds']}",
                 f"- Failure rate: {report['failureRate']}", f"- Peak temp disk bytes: {report['peakTempDiskBytes']}",
                 '', report['note']] + [f'- VIOLATION: {v}' for v in violations]
        open(a.markdown, 'w').write('\n'.join(lines) + '\n')
    if M.contains_url(text):
        print('error: report contains a URL', file=sys.stderr)
        return 1
    print(text)
    return 1 if violations else 0


if __name__ == '__main__':
    sys.exit(main())
