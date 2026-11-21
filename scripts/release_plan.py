#!/usr/bin/env python3
"""Plans a release: next db_version and the previous databases to diff against.

Reads the published releases (tags vN) with the gh CLI, downloads the full
artifact of the newest `--deltas` releases (always at least the latest one,
whose book ids the new build must keep), checks each against the sha256 in its
manifest, and writes to $GITHUB_OUTPUT:

  db_version   the version to build
  previous_db  the latest published database ('' before the first release)
  delta_from   space-separated databases for `pack --delta-from`

  release_plan.py --repo OWNER/REPO --out DIR --deltas N [--db-version N]
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys


def gh(*args):
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout


def published_versions(repo):
    rows = gh('api', '--paginate', f'repos/{repo}/releases?per_page=100',
              '--jq', '.[] | [.tag_name, (.draft | tostring)] | @tsv')
    versions = []
    for row in rows.splitlines():
        tag, draft = row.split('\t')
        m = re.fullmatch(r'v(\d+)', tag)
        if m and draft == 'false':
            versions.append(int(m.group(1)))
    return sorted(set(versions), reverse=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def fetch_db(repo, version, out):
    work = os.path.join(out, f'v{version}')
    os.makedirs(work, exist_ok=True)
    tag = f'v{version}'
    gh('release', 'download', tag, '--repo', repo, '--pattern', 'manifest.json', '--dir', work, '--clobber')
    with open(os.path.join(work, 'manifest.json'), encoding='utf-8') as f:
        manifest = json.load(f)
    if manifest.get('db_version') != version:
        sys.exit(f'{tag}: manifest db_version is {manifest.get("db_version")}, not {version}')
    full = manifest['full']
    names = [p['url'].rsplit('/', 1)[1] for p in full['parts']]
    for name in names:
        gh('release', 'download', tag, '--repo', repo, '--pattern', name, '--dir', work, '--clobber')
    payload = os.path.join(work, 'payload')
    with open(payload, 'wb') as dst:
        for name, part in zip(names, full['parts']):
            path = os.path.join(work, name)
            if sha256(path) != part['sha256']:
                sys.exit(f'{tag}: part {name} does not match its sha256')
            with open(path, 'rb') as src:
                shutil.copyfileobj(src, dst)
    db = os.path.join(out, f'v{version}.db')
    if full['compression'] == 'zstd':
        subprocess.run(['zstd', '-q', '-d', '-f', '--long=31', payload, '-o', db], check=True)
    else:
        shutil.move(payload, db)
    if sha256(db) != full['sha256'] or os.path.getsize(db) != full['size']:
        sys.exit(f'{tag}: the rebuilt database does not match the manifest')
    shutil.rmtree(work)
    return db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--deltas', type=int, default=3)
    ap.add_argument('--db-version', default='')
    a = ap.parse_args()
    if not 0 <= a.deltas <= 4:
        sys.exit('--deltas must be between 0 and 4 (the limit of pack --delta-from)')
    os.makedirs(a.out, exist_ok=True)

    versions = published_versions(a.repo)
    latest = versions[0] if versions else 0
    version = int(a.db_version) if a.db_version.strip() else latest + 1
    if version <= latest:
        sys.exit(f'db_version {version} must be greater than the latest release ({latest})')

    wanted = versions[:max(a.deltas, 1)]
    dbs = {v: fetch_db(a.repo, v, a.out) for v in wanted}
    previous = dbs[latest] if latest else ''
    deltas = [dbs[v] for v in versions[:a.deltas]]

    print(f'db_version={version} latest={latest} deltas={[f"v{v}" for v in versions[:a.deltas]]}')
    out = os.environ.get('GITHUB_OUTPUT')
    lines = [f'db_version={version}', f'previous_db={previous}', f'delta_from={" ".join(deltas)}']
    if out:
        with open(out, 'a', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
    else:
        print('\n'.join(lines))


if __name__ == '__main__':
    main()
