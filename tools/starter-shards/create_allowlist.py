#!/usr/bin/env python3
"""Create a canonical, explicit assembly allowlist from one immutable shard release.

Usage:
  create_allowlist.py --repo OWNER/REPO --release-tag TAG --batch-dir Config/starter-batches \
      --out Config/starter-batches/assemble-allowlist.json

The release tag is an input, never inferred. Every expected batch must have exactly one
SQLite asset and checksum listed in that release's matching `.SHA256SUMS` asset.
"""
import argparse, json, os, subprocess, sys, tempfile, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shardlib as S

SCHEMA = 'starter-assemble-allowlist-v1'


def batches(batch_dir):
    files = sorted(name for name in os.listdir(batch_dir)
                   if name.startswith('batch-') and name.endswith('.json'))
    if not files:
        raise S.ShardError('no frozen batch manifests found')
    result = []
    for name in files:
        batch, digest = S.load_canonical(os.path.join(batch_dir, name), name)
        result.append((batch['batchID'], digest))
    return result


def release_assets(repo, tag):
    raw = subprocess.check_output(['gh', 'api', f'repos/{repo}/releases/tags/{tag}'], text=True)
    assets = json.loads(raw).get('assets', [])
    return {a['name']: a for a in assets if isinstance(a.get('name'), str)}


def checksum_assets(repo, tag, assets):
    sums = {}
    for name, asset in assets.items():
        if not name.endswith('.SHA256SUMS'):
            continue
        content = subprocess.check_output(['gh', 'api', asset['url'], '-H', 'Accept: application/octet-stream'])
        for line in content.decode('utf-8').splitlines():
            digest, filename = line.split(None, 1)
            sums[filename.strip()] = digest
    return sums


def make_allowlist(repo, tag, batch_dir):
    assets = release_assets(repo, tag)
    checksums = checksum_assets(repo, tag, assets)
    entries = []
    for batch_id, manifest_sha in batches(batch_dir):
        asset_name = f'{batch_id}.sqlite'
        if asset_name not in assets:
            raise S.ShardError(f'{batch_id}: missing release asset {asset_name}')
        digest = checksums.get(asset_name)
        if not digest or len(digest) != 64:
            raise S.ShardError(f'{batch_id}: missing SHA-256 for {asset_name}')
        entries.append({
            'batchID': batch_id,
            'batchManifestSHA256': manifest_sha,
            'assetName': asset_name,
            'assetURL': f'https://github.com/{repo}/releases/download/{urllib.parse.quote(tag, safe="")}/{urllib.parse.quote(asset_name)}',
            'assetSHA256': digest,
        })
    return {'schema': SCHEMA, 'shards': entries}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--release-tag', required=True)
    parser.add_argument('--batch-dir', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args(argv)
    try:
        result = make_allowlist(args.repo, args.release_tag, args.batch_dir)
        data = S.canonical(result) + b'\n'
        if os.path.exists(args.out) and open(args.out, 'rb').read() != data:
            raise S.ShardError(f'{args.out}: refuses to rewrite an existing immutable allowlist')
        with open(args.out, 'wb') as f:
            f.write(data)
    except (S.ShardError, subprocess.CalledProcessError, ValueError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
