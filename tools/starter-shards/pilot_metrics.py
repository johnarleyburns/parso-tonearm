"""Safe per-track timing metrics, summaries and the batch-size gate for the capacity pilot.

Rows carry only a sanitized track ID, durations, byte counts, outcome and (for failures) the stage and
error code. Stream URLs, query strings, tokens and audio bytes are never accepted into a row.
"""
import math, os, platform, re, subprocess, sys

SCHEMA = 'starter-pilot-metrics-v1'
MAX_TEMP_DISK_BYTES = 25 * 10 ** 9
MAX_RUNNER_SECONDS = 150 * 60
_SAFE_ID = re.compile(r'[^A-Za-z0-9_.-]')
_URLISH = re.compile(r'(?i)(https?://|[a-z][a-z0-9+.-]*://|[?&][a-z0-9_.-]+=|\bsignature=|\btoken=)')


def clean_seconds(v):
    """A finite, non-negative number or None (malformed timings never poison a summary)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
        return None
    return round(float(v), 3)


def clean_bytes(v):
    return int(v) if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def clean_code(v):
    s = _SAFE_ID.sub('_', str(v))[:64]
    return '_' if _URLISH.search(str(v)) else s


def make_row(track_id, duration_sec, outcome, download_seconds=None, download_bytes=None,
             embed_seconds=None, analysis_seconds=None, total_seconds=None, stage=None, error_code=None,
             temp_bytes=None):
    row = {'providerTrackID': _SAFE_ID.sub('_', str(track_id))[:64], 'durationSec': clean_seconds(duration_sec),
           'downloadSeconds': clean_seconds(download_seconds), 'downloadBytes': clean_bytes(download_bytes),
           'embedSeconds': clean_seconds(embed_seconds), 'analysisSeconds': clean_seconds(analysis_seconds),
           'totalSeconds': clean_seconds(total_seconds), 'tempDiskBytes': clean_bytes(temp_bytes),
           'outcome': outcome if outcome in ('success', 'failure', 'cancelled') else 'failure'}
    if outcome != 'success':
        row['stage'] = clean_code(stage or 'unknown')
        row['errorCode'] = clean_code(error_code or 'unknown')
    return row


def percentile(values, p):
    """Nearest-rank percentile: sorted ascending, rank = ceil(p/100*n), value[rank-1]. None if empty."""
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    return vals[max(1, math.ceil(p / 100 * len(vals))) - 1]


def _stats(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    return {'p50': percentile(vals, 50), 'p90': percentile(vals, 90), 'max': max(vals) if vals else None}


def summarize(rows):
    ok = sum(1 for r in rows if r['outcome'] == 'success')
    return {'attempted': len(rows), 'successCount': ok, 'failureCount': len(rows) - ok,
            'failureRate': (len(rows) - ok) / len(rows) if rows else 1.0,
            'peakTempDiskBytes': max([r['tempDiskBytes'] or 0 for r in rows] or [0]),
            **{k: _stats(rows, k) for k in ('downloadSeconds', 'embedSeconds', 'analysisSeconds', 'totalSeconds')}}


def recommend(p90_total, failure_rate):
    """Maximum safe tracks per runner. Boundaries are inclusive; unknown p90 is the most conservative."""
    if p90_total is None:
        return 25
    if p90_total <= 60 and failure_rate == 0:
        return 100
    if p90_total <= 120 and failure_rate <= 0.02:
        return 50
    return 25


def environment(git_sha, model_sha, fingerprint):
    def run(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip().replace('\n', '; ')
        except Exception:
            return 'unavailable'
    return {'macOS': platform.mac_ver()[0] or platform.platform(), 'xcode': run(['xcodebuild', '-version']),
            'python': sys.version.split()[0], 'generatorGitSHA': git_sha, 'modelArchiveSHA256': model_sha,
            'embeddingSpaceFingerprint': fingerprint}


def build_document(rows, env, shard_bytes):
    return {'schema': SCHEMA, 'environment': env, 'generatedShardBytes': shard_bytes,
            'summary': summarize(rows), 'tracks': rows}


def contains_url(text):
    return bool(_URLISH.search(text))


def evaluate(doc, expected_fingerprint, elapsed_seconds=None, leftover_temp_dirs=(), publication_attempted=False):
    """Returns (report dict, list of violations). Any violation fails the pilot."""
    import json
    s = doc['summary']
    violations = []
    if s['peakTempDiskBytes'] > MAX_TEMP_DISK_BYTES:
        violations.append('peak temporary disk exceeds 25 GB')
    if leftover_temp_dirs:
        violations.append(f'{len(leftover_temp_dirs)} audio temporary directory(ies) survived')
    if doc['environment'].get('embeddingSpaceFingerprint') != expected_fingerprint:
        violations.append('model/fingerprint differs from the pinned value')
    if contains_url(json.dumps(doc)):
        violations.append('metrics contain a stream URL or query string')
    if elapsed_seconds is not None and elapsed_seconds > MAX_RUNNER_SECONDS:
        violations.append('runner exceeded 150 minutes')
    if publication_attempted:
        violations.append('artifact/release publication was attempted')
    rec = recommend(s['totalSeconds']['p90'], s['failureRate'])
    report = {'recommendedMaxTracksPerRunner': rec, 'p50TotalSeconds': s['totalSeconds']['p50'],
              'p90TotalSeconds': s['totalSeconds']['p90'], 'failureRate': s['failureRate'],
              'peakTempDiskBytes': s['peakTempDiskBytes'], 'violations': violations,
              'status': 'fail' if violations else 'pass',
              'note': 'Maximum safety recommendation only; a human approves any later batch execution issue.'}
    return report, violations
