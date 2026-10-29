#!/usr/bin/env python3
"""Generate the starter cohort taxonomy from the app's authoritative Jamendo tree.

The app tree is the sole taxonomy authority.  Each selectable node is queried
by its own final, live-verified Jamendo tag: never by a parent-plus-child AND
query, which excludes valid tracks whose metadata carries only the leaf tag.
"""
import argparse
import json
import re
import sys


NODE = re.compile(
    r'name: String\(localized: "([^"]*)", bundle: \.module\), path: "([^"]*)"')


def build(tree_source):
    pairs = NODE.findall(tree_source)
    if not pairs:
        raise ValueError('no JamendoGenreNode declarations found')
    paths = [path for _, path in pairs]
    if len(paths) != len(set(paths)):
        raise ValueError('duplicate Jamendo genre-tree paths')
    nodes = []
    for name, path in pairs:
        parts = path.split('/')
        if len(parts) == 1:
            node_id, kind = f'genre:{parts[0]}', 'genre'
        elif len(parts) == 2:
            node_id, kind = f'subgenre:{parts[0]}:{parts[1]}', 'subgenre'
        else:
            raise ValueError(f'unsupported nested Jamendo path: {path}')
        nodes.append({'id': node_id, 'displayName': name, 'kind': kind,
                      'sourceFilter': {'tags': [parts[-1]]}})
    return {'schema': 'jamendo-taxonomy-v1',
            'apiEndpoint': 'https://api.jamendo.com/v3.0/tracks/',
            'filterField': 'tags (one live-verified final tag per node; verified per row against musicinfo.tags)',
            'nodes': nodes}


def encoded(taxonomy):
    return (json.dumps(taxonomy, indent=2, ensure_ascii=False) + '\n').encode('utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--tree', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args(argv)
    with open(args.tree, encoding='utf-8') as f:
        expected = encoded(build(f.read()))
    if args.check:
        try:
            with open(args.out, 'rb') as f:
                actual = f.read()
        except FileNotFoundError:
            actual = b''
        if actual != expected:
            raise SystemExit(f'{args.out} is stale; regenerate it with {sys.argv[0]}')
        return
    with open(args.out, 'wb') as f:
        f.write(expected)


if __name__ == '__main__':
    main()
