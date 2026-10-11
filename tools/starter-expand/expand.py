#!/usr/bin/env python3
"""Expand the Mood Starter source index (data/mood-starter/source-index.json) by a factor.

The starter is each genre's most popular Jamendo tracks (popularity_total, the order the app's
genre libraries use). Expanding keeps every existing track and each genre's share: genre g gets
`factor x its current count` tracks, as far as Jamendo has them.

  expand.py list     [--factor 10]   list candidates per genre from the Jamendo API
  expand.py process  [--batch 200]   download each new track once, embed (BuiltInEmbedder) and
                                     analyse (BuiltInAnalyzer) it, delete the audio; resumable
  expand.py assemble OUT.json        write the expanded source index for `build-starter`
  expand.py status                   progress so far

Work files live in ~/Library/Caches/tonearm-starter-expand (EXPAND_WORK to override). The
Jamendo client ID is read from .test-credentials ([jamendo] client_id) and never written out.
Build the release tools first: swift build -c release --product BuiltInEmbedder --product BuiltInAnalyzer
"""
import argparse, collections, concurrent.futures, json, os, re, shutil
import subprocess, sys, time, urllib.parse, urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SOURCE = os.path.join(REPO, 'data/mood-starter/source-index.json')
TREE = os.path.join(REPO, 'Sources/Remote/Providers/JamendoGenreProvider.swift')
WORK = os.environ.get('EXPAND_WORK', os.path.expanduser('~/Library/Caches/tonearm-starter-expand'))
CANDIDATES = os.path.join(WORK, 'candidates.json')
DONE = os.path.join(WORK, 'done.jsonl')          # one processed track per line (resumable)
AUDIO = os.path.join(WORK, 'audio')
BIN = os.path.join(REPO, '.build/release')


def say(*a):
    print(*a, flush=True)


def client_id():
    # Read by hand: other sections of the file repeat keys, which configparser rejects.
    section, cid = None, ''
    for line in open(os.path.join(REPO, '.test-credentials')):
        line = line.strip()
        if line.startswith('['):
            section = line.strip('[]')
        elif section == 'jamendo' and line.split('=')[0].strip() == 'client_id':
            cid = line.split('=', 1)[1].strip()
    if not cid:
        sys.exit('no [jamendo] client_id in .test-credentials')
    return cid


def genre_nodes():
    """(name, tag) for every node of the app's Jamendo genre tree."""
    src = open(TREE).read()
    return [(n, p.split('/')[-1]) for n, p in
            re.findall(r'name: String\(localized: "([^"]*)", bundle: \.module\), path: "([^"]*)"', src)]


def api(params, cid):
    q = dict(params, client_id=cid, format='json')
    url = 'https://api.jamendo.com/v3.0/tracks/?' + urllib.parse.urlencode(q)
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = json.load(r)
            if data.get('headers', {}).get('status') == 'success':
                return data['results']
            say('  api:', data.get('headers', {}).get('error_message'))
        except Exception as e:  # network, 5xx, 429
            say(f'  api retry {attempt + 1}: {e}')
        time.sleep(min(60, 2 ** attempt * 3))
    raise RuntimeError('Jamendo API unavailable')


def cmd_list(args):
    os.makedirs(WORK, exist_ok=True)
    cid = client_id()
    existing = json.load(open(SOURCE))
    counts = collections.Counter(t['genre'] for t in existing)
    have = {t['id'] for t in existing}
    candidates = json.load(open(CANDIDATES)) if os.path.exists(CANDIDATES) else {}
    for name, tag in genre_nodes():
        target = counts.get(name, 0) * args.factor
        if target == 0 or name in candidates:
            continue
        rows, seen, offset = [], set(), 0
        # Headroom: a track listed under an earlier genre is assigned there.
        while len(rows) < target * 1.5 and offset < 5000:
            params = {'tags': tag, 'order': 'popularity_total', 'limit': 200, 'offset': offset,
                      'include': 'musicinfo', 'audioformat': 'mp32', 'audiodlformat': 'mp32'}
            # Jamendo's search intermittently returns an empty or short page for a query that
            # has results (the app's JamendoAPI retries for the same reason): retry before
            # taking a short page as the end of the genre.
            page = api(params, cid)
            for _ in range(4):
                if len(page) == 200:
                    break
                time.sleep(2)
                retry = api(params, cid)
                if len(retry) > len(page):
                    page = retry
            for t in page:
                tid = f"jamendo-{t['id']}"
                if tid in seen or not t.get('audio') or (t.get('duration') or 0) < 30:
                    continue
                seen.add(tid)
                rows.append({'id': tid, 'title': t['name'], 'artist': t.get('artist_name') or '',
                             'genre': name, 'license': t.get('license_ccurl') or '', 'licenseURL': None,
                             'durationSec': float(t['duration']), 'streamURL': t['audio'],
                             'artworkURL': t.get('album_image') or None})
            if len(page) < 200:
                break
            offset += 200
            time.sleep(0.5)
        candidates[name] = {'target': target, 'tracks': rows}
        json.dump(candidates, open(CANDIDATES, 'w'))
        say(f'{name}: {len(rows)} candidates for {target} ({len(have & {r["id"] for r in rows})} already in)')


def selection():
    """The new tracks to add, genre by genre, in tree order (first genre to list a track keeps it)."""
    existing = json.load(open(SOURCE))
    counts = collections.Counter(t['genre'] for t in existing)
    taken = {t['id'] for t in existing}
    candidates = json.load(open(CANDIDATES))
    picked = []
    for name, _ in genre_nodes():
        entry = candidates.get(name)
        if not entry:
            continue
        need = entry['target'] - counts.get(name, 0)
        for t in entry['tracks']:
            if need <= 0:
                break
            if t['id'] in taken:
                continue
            taken.add(t['id'])
            picked.append(t)
            need -= 1
    return picked


def done_ids():
    if not os.path.exists(DONE):
        return {}
    out = {}
    for line in open(DONE):
        t = json.loads(line)
        out[t['id']] = t
    return out


def download(t, folder):
    path = os.path.join(folder, t['id'] + '.mp3')
    for attempt in range(3):
        r = subprocess.run(['curl', '-sfL', '--max-time', '120', '-o', path, t['streamURL']])
        if r.returncode == 0 and os.path.getsize(path) > 10_000:
            return True
        time.sleep(2)
    if os.path.exists(path):
        os.remove(path)
    return False


def cmd_process(args):
    for tool in ('BuiltInEmbedder', 'BuiltInAnalyzer'):
        if not os.path.exists(os.path.join(BIN, tool)):
            sys.exit(f'missing {BIN}/{tool}: swift build -c release --product {tool}')
    picked = selection()
    done = done_ids()
    pending = [t for t in picked if t['id'] not in done]
    say(f'{len(picked)} tracks to add, {len(done)} processed, {len(pending)} to go')
    start = time.time()
    batches = [pending[b:b + args.batch] for b in range(0, len(pending), args.batch)]
    folders = [AUDIO + '-a', AUDIO + '-b']

    def fetch(batch, folder):
        shutil.rmtree(folder, ignore_errors=True)
        os.makedirs(folder)
        with concurrent.futures.ThreadPoolExecutor(12) as pool:
            return list(pool.map(lambda t: download(t, folder), batch))

    # The network is the bottleneck: the next batch downloads while this one is processed.
    prefetch = concurrent.futures.ThreadPoolExecutor(1)
    upcoming = prefetch.submit(fetch, batches[0], folders[0]) if batches else None
    processed = 0
    for k, batch in enumerate(batches):
        folder = folders[k % 2]
        ok = upcoming.result()
        if k + 1 < len(batches):
            upcoming = prefetch.submit(fetch, batches[k + 1], folders[(k + 1) % 2])
        fetched = [t for t, good in zip(batch, ok) if good]
        emb_path = os.path.join(WORK, 'batch-embeddings.json')
        subprocess.run([os.path.join(BIN, 'BuiltInEmbedder'), folder, emb_path],
                       check=True, stdout=subprocess.DEVNULL)
        embeddings = {e['id']: e for e in json.load(open(emb_path))}
        index_path = os.path.join(WORK, 'batch-index.json')
        json.dump([{'id': t['id'], 'streamURL': t['streamURL'], 'durationSec': t['durationSec']}
                   for t in fetched], open(index_path, 'w'))
        subprocess.run([os.path.join(BIN, 'BuiltInAnalyzer'), index_path, '4'], check=True,
                       stdout=subprocess.DEVNULL, env=dict(os.environ, BUILTIN_ANALYZER_AUDIO_DIR=folder))
        analysis = {e['id']: e for e in json.load(open(index_path))}
        with open(DONE, 'a') as out:
            for t, good in zip(batch, ok):
                row = dict(t)
                e, a = embeddings.get(t['id']), analysis.get(t['id'], {})
                if not good or not e:
                    row['failed'] = 'download' if not good else 'embedding'
                else:
                    row.update(dimensions=e['dimensions'], scale=e['scale'],
                               quantizedVectorBase64=e['quantizedVectorBase64'],
                               bpm=a.get('bpm'), key=a.get('key'), energy=a.get('energy'),
                               analysisScopeSeconds=a.get('analysisScopeSeconds'))
                out.write(json.dumps(row) + '\n')
        shutil.rmtree(folder, ignore_errors=True)
        processed += len(batch)
        rate = processed / max(1, time.time() - start)
        say(f'[{processed}/{len(pending)}] batch done: {len(fetched)}/{len(batch)} downloaded, '
            f'{len(embeddings)} embedded; {rate * 3600:.0f} tracks/h, '
            f'~{(len(pending) - processed) / max(rate, 1e-9) / 3600:.1f} h left')
    prefetch.shutdown()


def cmd_assemble(args):
    existing = json.load(open(SOURCE))
    added = [t for t in done_ids().values() if 'failed' not in t and t.get('quantizedVectorBase64')]
    keys = ['id', 'title', 'artist', 'genre', 'license', 'licenseURL', 'durationSec', 'streamURL',
            'artworkURL', 'dimensions', 'scale', 'quantizedVectorBase64', 'bpm', 'key', 'energy',
            'analysisScopeSeconds']
    out = existing + [{k: t.get(k) for k in keys} for t in sorted(added, key=lambda t: t['id'])]
    json.dump(out, open(args.out, 'w'), ensure_ascii=False)
    say(f'{len(existing)} existing + {len(added)} added = {len(out)} tracks -> {args.out}')


def cmd_status(args):
    picked = selection() if os.path.exists(CANDIDATES) else []
    done = done_ids()
    failed = collections.Counter(t.get('failed') for t in done.values() if t.get('failed'))
    say(f'{len(picked)} selected, {len(done)} processed, failures {dict(failed)}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    l = sub.add_parser('list'); l.add_argument('--factor', type=int, default=10)
    pr = sub.add_parser('process'); pr.add_argument('--batch', type=int, default=200)
    a = sub.add_parser('assemble'); a.add_argument('out')
    sub.add_parser('status')
    args = p.parse_args()
    {'list': cmd_list, 'process': cmd_process, 'assemble': cmd_assemble, 'status': cmd_status}[args.cmd](args)


if __name__ == '__main__':
    main()
