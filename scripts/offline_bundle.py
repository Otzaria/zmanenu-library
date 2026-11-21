#!/usr/bin/env python3
"""The offline package of a release: zmanenu-offline.zip.

The zip holds exactly three entries at its root, so the app can import and
verify a release without the network:

  zmanenu.db          the full database, byte for byte (sha256 = manifest full.sha256)
  manifest.json       exactly as published in the release
  manifest.json.sig   exactly as published in the release

  offline_bundle.py check-size --db zmanenu.db
  offline_bundle.py pack --db zmanenu.db --manifest manifest.json --out zmanenu-offline.zip

`check-size` fails early, before signing, when the package cannot be published:
GitHub release assets must be smaller than 2 GiB.
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

# GitHub rejects release assets of 2 GiB and more.
MAX_ASSET_BYTES = 2 * 1024 ** 3 - 1
# Fixed timestamp: the same files give the same zip.
ZIP_TIME = (2020, 1, 1, 0, 0, 0)


def fail(message):
    print(f'::error::{message}', file=sys.stderr)
    sys.exit(1)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def check_size(db):
    size = os.path.getsize(db)
    if size > MAX_ASSET_BYTES:
        fail(f'{os.path.basename(db)} is {size} bytes. The offline package would pass the '
             f'2 GiB limit of a GitHub release asset; see docs/release.md before releasing.')
    return size


def entry(name):
    info = zipfile.ZipInfo(name, ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    return info


def pack(db, manifest_path, out):
    check_size(db)
    sig_path = manifest_path + '.sig'
    for path in (db, manifest_path, sig_path):
        if not os.path.isfile(path):
            fail(f'missing {path}')
    with open(manifest_path, 'rb') as f:
        manifest_bytes = f.read()
    with open(sig_path, 'rb') as f:
        sig_bytes = f.read()
    full = json.loads(manifest_bytes.decode('utf-8'))['full']
    if sha256_of(db) != full['sha256'] or os.path.getsize(db) != full['size']:
        fail(f'{db} does not match full.sha256/full.size of the manifest')

    db_name = os.path.basename(db)
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, 'w', allowZip64=True) as z:
        with open(db, 'rb') as src, z.open(entry(db_name), 'w', force_zip64=True) as dst:
            for chunk in iter(lambda: src.read(1 << 20), b''):
                dst.write(chunk)
        z.writestr(entry('manifest.json'), manifest_bytes)
        z.writestr(entry('manifest.json.sig'), sig_bytes)

    # Read it back the way an importer would.
    with zipfile.ZipFile(out) as z:
        names = sorted(z.namelist())
        if names != sorted([db_name, 'manifest.json', 'manifest.json.sig']):
            fail(f'unexpected entries in {out}: {names}')
        h = hashlib.sha256()
        with z.open(db_name) as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        if h.hexdigest() != full['sha256']:
            fail(f'{db_name} inside {out} does not match full.sha256')
        if z.read('manifest.json') != manifest_bytes or z.read('manifest.json.sig') != sig_bytes:
            fail(f'the manifest inside {out} differs from the published one')
    size = os.path.getsize(out)
    if size > MAX_ASSET_BYTES:
        os.remove(out)
        fail(f'{out} is {size} bytes, over the 2 GiB limit of a GitHub release asset')
    print(f'{out}: {size} bytes, {db_name} sha256 {full["sha256"]}')


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='command', required=True)
    c = sub.add_parser('check-size')
    c.add_argument('--db', required=True)
    k = sub.add_parser('pack')
    k.add_argument('--db', required=True)
    k.add_argument('--manifest', required=True)
    k.add_argument('--out', required=True)
    a = ap.parse_args()
    if a.command == 'check-size':
        print(f'{a.db}: {check_size(a.db)} bytes')
    else:
        pack(a.db, a.manifest, a.out)


if __name__ == '__main__':
    main()
