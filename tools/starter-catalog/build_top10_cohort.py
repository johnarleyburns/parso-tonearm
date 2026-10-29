#!/usr/bin/env python3
"""Build the frozen top-N-per-taxonomy-node Jamendo cohort (selection metadata only).

  build_top10_cohort.py --taxonomy T.json --selection-out S.json --report-out R.json \
      --catalog-out Config/starter-batches/manifest-v1.json --top-per-node 10 [--fixture F.json]

Live mode reads the API key from the JAMENDO_CLIENT_ID environment variable only. --fixture injects
recorded responses ({"retrievedAt": "...", "responses": {nodeID: [rows]}}) and never touches the
network. Nothing here downloads audio, reads embeddings or reads any starter database; signed audio
URLs from the API are used only as a truthiness check and are never persisted or logged.
"""
import argparse, hashlib, json, math, os, re, sys, time, urllib.error, urllib.parse, urllib.request

API_ENDPOINT = 'https://api.jamendo.com/v3.0/tracks/'
API_VERSION = 'v3.0'
METHOD = 'top-10-per-node-v1'
EMBEDDING_SPACE = 'clap-int4-128-v1'
BATCH_SIZE, EXECUTION_BATCHES = 100, 4
# Live catalog freezing is a one-off curation task, so deliberately pace API
# calls instead of bursting the full taxonomy at Jamendo.
MIN_REQUEST_INTERVAL_SECONDS = 5.0
REASONS = ('not_downloadable', 'license', 'missing_metadata', 'invalid_duration', 'filter_mismatch')
CC_URL = re.compile(r'^https?://(?:www\.)?creativecommons\.org/(?:licenses/([a-z-]+)/([0-9.]+)|publicdomain/zero/([0-9.]+))/?')


class CohortError(Exception):
    pass


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def license_info(row):
    """(license id, url) for a permitted Creative Commons license, else None."""
    url = row.get('license_ccurl')
    m = CC_URL.match(url) if isinstance(url, str) else None
    if not m:
        return None
    if m.group(1):
        return f'cc-{m.group(1)}-{m.group(2)}', url
    return f'cc0-{m.group(3)}', url


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


def matches_exact_node_filter(row, node):
    return {str(t).lower() for t in node['sourceFilter']['tags']} <= row_tags(row)


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


def classify(row, node):
    """Return (None, normalized) when eligible, else (reason, None)."""
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
    pop = popularity(row)
    if not all(isinstance(s, str) and s.strip() for s in (title, artist)):
        return 'missing_metadata', None
    try:
        dur = float(row.get('duration'))
    except (TypeError, ValueError):
        return 'invalid_duration', None
    if not math.isfinite(dur) or dur <= 0:
        return 'invalid_duration', None
    lic = license_info(row)
    if lic is None:
        return 'license', None
    if not matches_exact_node_filter(row, node):
        return 'filter_mismatch', None
    return None, {'providerTrackID': tid, 'title': title.strip(), 'artist': artist.strip(),
                  'durationSec': dur, 'license': lic[0], 'licenseURL': lic[1], 'popularityTotal': pop}


def select_for_node(node, rows, top):
    excluded = {r: 0 for r in REASONS}
    good, seen = [], set()
    for source_order, row in enumerate(rows):
        reason, norm = classify(row, node)
        if reason:
            excluded[reason] += 1
        elif norm['providerTrackID'] not in seen:
            seen.add(norm['providerTrackID'])
            # Jamendo applies the requested popularity_total_desc ordering but
            # does not consistently return a numeric popularity_total field.
            # Preserve its response order in that case instead of rejecting a
            # valid candidate for metadata the API did not expose.
            norm['sourceOrder'] = source_order
            good.append(norm)
    if all(t['popularityTotal'] is not None for t in good):
        good.sort(key=lambda t: (-t['popularityTotal'], int(t['providerTrackID'])))
    else:
        good.sort(key=lambda t: t['sourceOrder'])
    return good[:top], len(good), excluded


def fetch_live(node, client_id, limit, last_request_at=None):
    if last_request_at is not None:
        wait = MIN_REQUEST_INTERVAL_SECONDS - (time.monotonic() - last_request_at[0])
        if wait > 0:
            time.sleep(wait)
    params = {'client_id': client_id, 'format': 'json', 'limit': limit, 'audiodownload_allowed': 'true',
              'order': 'popularity_total_desc', 'tags': '+'.join(node['sourceFilter']['tags']),
              'include': 'musicinfo+licenses+stats'}
    url = API_ENDPOINT + '?' + urllib.parse.urlencode(params, safe='+')
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            body = json.load(r)
    except (urllib.error.URLError, ValueError, OSError) as e:
        raise CohortError(f'Jamendo request failed for {node["id"]}: {type(e).__name__}')
    results = body.get('results') if isinstance(body, dict) else None
    if not isinstance(results, list):
        raise CohortError(f'Jamendo response for {node["id"]} had no results list')
    if last_request_at is not None:
        last_request_at[0] = time.monotonic()
    return results


def load_taxonomy(path):
    with open(path, 'rb') as f:
        raw = f.read()
    tax = json.loads(raw)
    if tax.get('schema') != 'jamendo-taxonomy-v1' or not isinstance(tax.get('nodes'), list):
        raise CohortError('taxonomy: schema must be jamendo-taxonomy-v1 with a nodes list')
    ids = [n.get('id') for n in tax['nodes']]
    if len(set(ids)) != len(ids):
        raise CohortError('taxonomy: duplicate node ids')
    for n in tax['nodes']:
        tags = (n.get('sourceFilter') or {}).get('tags')
        if not n.get('id') or n.get('kind') not in ('genre', 'subgenre') or not tags or \
                not all(isinstance(t, str) and t for t in tags):
            raise CohortError(f'taxonomy: malformed node {n.get("id")!r}')
    return tax, sha256_hex(raw)


def build(tax, tax_sha, fetch, top, retrieved_at):
    nodes = sorted(tax['nodes'], key=lambda n: n['id'])
    ranked, report_nodes, excluded_total = [], [], {r: 0 for r in REASONS}
    tracks = {}
    for node in nodes:
        sel, eligible, excluded = select_for_node(node, fetch(node), top)
        for r, c in excluded.items():
            excluded_total[r] += c
        ranked.append({'nodeID': node['id'], 'rankedSelections': [
            {'providerTrackID': t['providerTrackID'], 'rank': i, 'popularityTotal': t['popularityTotal']}
            for i, t in enumerate(sel, 1)]})
        entry = {'nodeID': node['id'], 'kind': node['kind'], 'eligibleCount': eligible,
                 'selectedCount': len(sel), 'excluded': excluded}
        if len(sel) < top:
            entry['shortfallReason'] = (f'only {eligible} eligible candidates after filtering' if eligible
                                        else 'no eligible candidates returned for the exact node filter')
        report_nodes.append(entry)
        for i, t in enumerate(sel, 1):
            cur = tracks.setdefault(t['providerTrackID'], {'meta': t, 'nodes': {}})
            cur['nodes'][node['id']] = i
    out_tracks = []
    for tid in sorted(tracks, key=int):
        t, nmap = tracks[tid]['meta'], tracks[tid]['nodes']
        best = min(nmap.values())
        out_tracks.append({
            'provider': 'jamendo', 'providerTrackID': tid, 'title': t['title'], 'artist': t['artist'],
            'genreNodeIDs': sorted(nmap),
            'selection': {'method': METHOD, 'bestRank': best,
                          'selectedByNodeIDs': sorted(n for n, r in nmap.items() if r == best)},
            'audiodownloadAllowed': True, 'durationSec': t['durationSec'],
            'license': t['license'], 'licenseURL': t['licenseURL']})
    out_tracks.sort(key=lambda t: ('jamendo', t['providerTrackID']))
    selection = {'schema': 'top10-per-node-selection-v1', 'method': METHOD, 'topPerNode': top,
                 'embeddingSpace': EMBEDDING_SPACE, 'taxonomySHA256': tax_sha,
                 'nodes': ranked, 'tracks': out_tracks}
    sel_bytes = canonical(selection)
    sel_sha = sha256_hex(sel_bytes)
    cat_tracks = []
    for t in out_tracks:
        rev = sha256_hex(canonical({k: t[k] for k in ('providerTrackID', 'title', 'artist', 'durationSec',
                                                       'licenseURL')}))[:16]
        cat_tracks.append({'provider': 'jamendo', 'providerTrackID': t['providerTrackID'],
                           'streamURL': f'jamendo://track/{t["providerTrackID"]}', 'sourceRevision': rev,
                           'title': t['title'], 'artist': t['artist'], 'license': t['license'],
                           'licenseURL': t['licenseURL'], 'durationSec': t['durationSec'],
                           'genre': t['genreNodeIDs'][0]})
    catalog = {'schema': 'starter-catalog-v1', 'embeddingSpace': EMBEDDING_SPACE, 'tracks': cat_tracks,
               'metadata': {'selectionManifestSHA256': sel_sha, 'taxonomySHA256': tax_sha,
                            'selectedCount': len(cat_tracks), 'nodeCount': len(nodes),
                            'method': METHOD}}
    cat_bytes = canonical(catalog)
    raw = sum(len(n['rankedSelections']) for n in ranked)
    uniq = len(cat_tracks)
    dist = {}
    for n in report_nodes:
        dist.setdefault(n['kind'], {})[n['nodeID']] = n['selectedCount']
    report = {
        'schema': 'top10-per-node-report-v1', 'method': METHOD,
        'api': {'endpoint': API_ENDPOINT, 'version': API_VERSION,
                'order': 'popularity_total_desc', 'tieBreak': 'numeric track id ascending',
                'include': 'musicinfo+licenses+stats', 'retrievedAt': retrieved_at},
        'taxonomyNodeCount': len(nodes), 'topPerNode': top, 'nodes': report_nodes,
        'nodesWithFewerThanTop': [n['nodeID'] for n in report_nodes if n['selectedCount'] < top],
        'rawSelectionsBeforeDedupe': raw, 'uniqueSelectedTracks': uniq,
        'duplicateCollapseCount': raw - uniq, 'distributionByKind': dist,
        'excludedByReason': excluded_total,
        'taxonomySHA256': tax_sha, 'selectionSHA256': sel_sha, 'catalogSHA256': sha256_hex(cat_bytes),
        'recommendedBatchCount': -(-uniq // BATCH_SIZE),
        'recommendedExecutionIssueCount': -(-uniq // (BATCH_SIZE * EXECUTION_BATCHES))}
    return sel_bytes, canonical(report), cat_bytes, report


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--taxonomy', required=True)
    ap.add_argument('--selection-out', required=True)
    ap.add_argument('--report-out', required=True)
    ap.add_argument('--catalog-out', required=True)
    ap.add_argument('--top-per-node', type=int, default=10)
    ap.add_argument('--fixture')
    ap.add_argument('--candidate-limit', type=int, default=200)
    a = ap.parse_args(argv)
    if a.top_per_node < 1:
        raise CohortError('--top-per-node must be >= 1')
    tax, tax_sha = load_taxonomy(a.taxonomy)
    if a.fixture:
        with open(a.fixture, encoding='utf-8') as f:
            fx = json.load(f)
        responses, when = fx['responses'], fx.get('retrievedAt', 'fixture')
        fetch = lambda node: responses.get(node['id'], [])
    else:
        cid = os.environ.get('JAMENDO_CLIENT_ID')
        if not cid:
            raise CohortError('JAMENDO_CLIENT_ID is not set (use --fixture for recorded responses)')
        when = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        last_request_at = [float('-inf')]
        fetch = lambda node: fetch_live(node, cid, a.candidate_limit, last_request_at)
    sel, rep, cat, report = build(tax, tax_sha, fetch, a.top_per_node, when)
    for path, data in ((a.selection_out, sel), (a.report_out, rep), (a.catalog_out, cat)):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
    print(f'nodes={report["taxonomyNodeCount"]} raw={report["rawSelectionsBeforeDedupe"]} '
          f'unique={report["uniqueSelectedTracks"]} batches={report["recommendedBatchCount"]} '
          f'issues={report["recommendedExecutionIssueCount"]}')
    print(f'selectionSHA256={report["selectionSHA256"]} catalogSHA256={report["catalogSHA256"]}')


if __name__ == '__main__':
    try:
        main()
    except CohortError as e:
        sys.exit(f'error: {e}')
