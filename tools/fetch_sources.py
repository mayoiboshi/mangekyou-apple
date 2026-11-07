#!/usr/bin/env python3
"""Fetch only pinned, allowlisted source text; never archives or sample assets."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def fetch(item, destination):
    repo, commit = item['repository'], item['commit']
    def one(entry):
        name = PurePosixPath(entry['path'])
        if name.is_absolute() or '..' in name.parts:
            raise ValueError('unsafe manifest path')
        if name.suffix not in {'.py', '.rs', '.c', '.cpp', '.toml', '.lock', '.md'} and name.name not in {'LICENSE', 'COPYING'}:
            raise ValueError('non-source download refused: ' + str(name))
        path = destination / repo.split('/')[1] / name
        if path.is_symlink() or any(p.is_symlink() for p in path.parents):
            raise ValueError('symlink destination refused')
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']:
            return
        request = urllib.request.Request(
            'https://raw.githubusercontent.com/' + repo + '/' + commit + '/' + str(name),
            headers={'User-Agent': 'Mangekyou-P0-source-audit'})
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('source digest mismatch: ' + str(name))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(one,item['files']))
    return repo + ' ' + commit


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--destination', type=Path, default=ROOT / '.research/upstream')
    args = ap.parse_args()
    manifest = json.loads((ROOT / 'docs/upstream-lock.json').read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(fetch, item, args.destination) for item in manifest['upstreams']]
        for future in futures:
            print(future.result())


if __name__ == '__main__':
    main()
