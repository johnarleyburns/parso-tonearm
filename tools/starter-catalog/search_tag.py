#!/usr/bin/env python3
"""Ad-hoc Jamendo tag search for curating a new Starter Blend (metadata only, no audio).

  search_tag.py --tag progressivehouse --limit 40 --out candidates.json

Reads the API key from the JAMENDO_CLIENT_ID environment variable only (no --fixture mode: this is
a one-off lookup tool, not the frozen-cohort builder). Prints/saves eligible candidates
(audiodownload_allowed, exact tag match, valid title/artist/duration) ordered by popularity —
the same eligibility rules as build_top10_cohort.py's `classify`, trimmed to a single tag. Does not
download audio or write to any database or release.
"""
import argparse, json, math, os, sys, time, urllib.error, urllib.parse, urllib.request

API_ENDPOINT = 'https://api.jamendo.com/v3.0/tracks/'


def row_tags(row):
    tags = set()
    info = row.get('musicinfo')
    t = info.get('tags') if isinstance(info, dict) else None
    if isinstance(t, dict):
        for key in ('genres', 'instruments', 'vartags'):
            vals = t.get(key)
            if isinstance(vals, list):
                tags.update(str(v).strip().lower() for v in vals)
    return tags


def popularity(row):
    v = row.get('popularity_total')
    if v is None and isinstance(row.get('stats'), dict):
        v = row['stats'].get('popularity_total')
    if isinstance(v, bool):
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def classify(row, tag):
    if not isinstance(row, dict):
        return 'missing_metadata', None
    tid = str(row.get('id') or '')
    if not tid.isdigit() or int(tid) <= 0:
        return 'missing_metadata', None
    if row.get('audiodownload_allowed') is not True:
        return 'not_downloadable', None
    if not row.get('audio'):
        return 'missing_metadata', None
    title, artist = row.get('name'), row.get('artist_name')
    if not all(isinstance(s, str) and s.strip() for s in (title, artist)):
        return 'missing_metadata', None
    try:
        dur = float(row.get('duration'))
    except (TypeError, ValueError):
        return 'invalid_duration', None
    if not math.isfinite(dur) or dur <= 0:
        return 'invalid_duration', None
    if tag.lower() not in row_tags(row):
        return 'filter_mismatch', None
    license_url = row.get('license_ccurl')
    if not isinstance(license_url, str) or not license_url.strip():
        license_url = None
    return None, {'providerTrackID': tid, 'title': title.strip(), 'artist': artist.strip(),
                  'durationSec': dur, 'license': license_url or 'jamendo-approved',
                  'licenseURL': license_url, 'popularityTotal': popularity(row)}


def fetch(tag, client_id, limit):
    params = {'client_id': client_id, 'format': 'json', 'limit': limit, 'audiodownload_allowed': 'true',
              'order': 'popularity_total_desc', 'tags': tag, 'include': 'musicinfo+licenses+stats'}
    url = API_ENDPOINT + '?' + urllib.parse.urlencode(params, safe='+')
    with urllib.request.urlopen(url, timeout=60) as r:
        body = json.load(r)
    results = body.get('results') if isinstance(body, dict) else None
    if not isinstance(results, list):
        raise SystemExit(f'Jamendo response had no results list: {body!r}')
    return results


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--tag', required=True)
    ap.add_argument('--limit', type=int, default=40)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    cid = os.environ.get('JAMENDO_CLIENT_ID')
    if not cid:
        raise SystemExit('JAMENDO_CLIENT_ID is not set')
    rows = fetch(a.tag, cid, a.limit)
    excluded = {}
    good, seen = [], set()
    for row in rows:
        reason, norm = classify(row, a.tag)
        if reason:
            excluded[reason] = excluded.get(reason, 0) + 1
        elif norm['providerTrackID'] not in seen:
            seen.add(norm['providerTrackID'])
            good.append(norm)
    if all(t['popularityTotal'] is not None for t in good):
        good.sort(key=lambda t: (-t['popularityTotal'], int(t['providerTrackID'])))
    out = {'tag': a.tag, 'retrievedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
           'candidateCount': len(good), 'excludedByReason': excluded, 'candidates': good}
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(out, f, indent=2)
    print(f'{len(good)} eligible candidates for tag {a.tag!r} written to {a.out}')
    for t in good:
        print(f"  {t['providerTrackID']}: {t['artist']} - {t['title']} ({t['durationSec']:.0f}s)")


if __name__ == '__main__':
    main()
