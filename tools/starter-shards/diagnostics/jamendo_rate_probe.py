#!/usr/bin/env python3
"""One-off diagnostic (not production tooling): probe the real Jamendo /tracks/file/
endpoint at several different inter-request delays to find the real-world download rate
limit. Never logs the client_id, a full query string, or any signed URL -- only the HTTP
status, response size, and (when the body is Jamendo's own small JSON error envelope) the
generic, non-identifying `code`/`error_message` fields it already returns to any caller.

  JAMENDO_CLIENT_ID=... python3 jamendo_rate_probe.py --track-ids-file ids.json --out probe.json

`ids.json` is a flat JSON list of {"delaySeconds": N, "trackIDs": [...]} buckets.
"""
import argparse, json, re, sys, time, urllib.error, urllib.request

ENDPOINT = 'https://api.jamendo.com/v3.0/tracks/file/'
_URLISH = re.compile(r'https?://\S+')


def probe_one(client_id, track_id):
    url = f'{ENDPOINT}?client_id={client_id}&id={track_id}&action=download&audioformat=mp32'
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            status = r.status
            body = r.read(4096)
    except urllib.error.HTTPError as e:
        status = e.code
        body = e.read(4096) if e.fp else b''
    except Exception as e:
        return {'trackID': track_id, 'httpStatus': None, 'contentLength': None,
                'transportError': type(e).__name__}
    row = {'trackID': track_id, 'httpStatus': status, 'contentLength': len(body)}
    if len(body) < 2000:
        try:
            payload = json.loads(body)
            headers = payload.get('headers') if isinstance(payload, dict) else None
            if isinstance(headers, dict):
                row['jamendoStatus'] = headers.get('status')
                row['jamendoErrorCode'] = headers.get('code')
                row['jamendoErrorMessage'] = headers.get('error_message')
        except ValueError:
            row['bodyNotJSON'] = True
    return row


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--track-ids-file', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    client_id = __import__('os').environ.get('JAMENDO_CLIENT_ID', '')
    if not client_id:
        sys.exit('error: JAMENDO_CLIENT_ID is not set')
    buckets = json.load(open(a.track_ids_file, encoding='utf-8'))
    results = []
    for bucket in buckets:
        delay, ids = bucket['delaySeconds'], bucket['trackIDs']
        for i, tid in enumerate(ids):
            if i > 0:
                time.sleep(delay)
            row = probe_one(client_id, tid)
            row['delaySeconds'] = delay
            results.append(row)
            print(f"delay={delay}s track={tid} status={row.get('httpStatus')} "
                  f"len={row.get('contentLength')} jamendoCode={row.get('jamendoErrorCode')}")
    by_delay = {}
    for r in results:
        d = by_delay.setdefault(r['delaySeconds'], {'attempted': 0, 'ok': 0, 'failed': 0})
        d['attempted'] += 1
        # A real audio download is large; Jamendo's own error envelope is always small JSON.
        if r.get('contentLength') is not None and r['contentLength'] > 2000:
            d['ok'] += 1
        else:
            d['failed'] += 1
    text = json.dumps({'byDelaySeconds': by_delay, 'rows': results}, indent=2, sort_keys=True)
    assert not _URLISH.search(text), 'refusing to write a URL into the diagnostic output'
    open(a.out, 'w', encoding='utf-8').write(text + '\n')
    print(json.dumps(by_delay, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
