#!/usr/bin/env python3
"""The offline package of a release: zmanenu-offline.tar.zst.

A tar, compressed like the official library bundle (`zstd -19 -T0`, see
otzaria-<version>-library.tar.zst in the app's build-and-announce.yml), that
holds exactly three entries at its root, so the app can import and verify a
release without the network:

  manifest.json       exactly as published in the release
  manifest.json.sig   exactly as published in the release
  zmanenu.db          the full database, byte for byte (sha256 = manifest full.sha256)

The tar is deterministic: entries sorted by name, fixed mtime, owner 0, mode
0644, UTF-8 (PAX) names.

Up to 1992294400 bytes the archive is published as one file. A larger one is
split the way the official library splits it (tool/release/split_release_asset.sh
in the app): <archive>.part-000, -001 ... and <archive>.manifest.json.

  offline_bundle.py pack --db zmanenu.db --manifest manifest.json --out-dir DIR [--zstd zstd]
"""
import argparse
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile

ARCHIVE = 'zmanenu-offline.tar.zst'
ZSTD_ARGS = ['-19', '-T0']
# Same values as split_release_asset.sh.
PART_SIZE = 1992294400
GITHUB_LIMIT = 2147483648
TAR_MTIME = 1577836800  # 2020-01-01T00:00:00Z


def fail(message):
    print(f'::error::{message}', file=sys.stderr)
    sys.exit(1)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def tar_info(name, size):
    info = tarfile.TarInfo(name)
    info.size = size
    info.mtime = TAR_MTIME
    info.mode = 0o644
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.type = tarfile.REGTYPE
    return info


def write_tar(path, db, manifest_bytes, sig_bytes):
    entries = {
        os.path.basename(db): None,
        'manifest.json': manifest_bytes,
        'manifest.json.sig': sig_bytes,
    }
    with tarfile.open(path, 'w', format=tarfile.PAX_FORMAT, encoding='utf-8') as tar:
        for name in sorted(entries):
            data = entries[name]
            if data is None:
                with open(db, 'rb') as f:
                    tar.addfile(tar_info(name, os.path.getsize(db)), f)
            else:
                tar.addfile(tar_info(name, len(data)), io.BytesIO(data))


def check_archive(archive, zstd, db_name, full, manifest_bytes, sig_bytes):
    """Extracts the archive the way an importer would and checks every entry."""
    proc = subprocess.Popen([zstd, '-d', '-c', '-q', archive], stdout=subprocess.PIPE)
    seen = []
    with tarfile.open(fileobj=proc.stdout, mode='r|', encoding='utf-8') as tar:
        for member in tar:
            seen.append(member.name)
            if not member.isfile():
                fail(f'{member.name} in {archive} is not a regular file')
            f = tar.extractfile(member)
            if member.name == db_name:
                h = hashlib.sha256()
                size = 0
                for chunk in iter(lambda: f.read(1 << 20), b''):
                    h.update(chunk)
                    size += len(chunk)
                if h.hexdigest() != full['sha256'] or size != full['size']:
                    fail(f'{db_name} inside {archive} does not match full.sha256/full.size')
            elif member.name == 'manifest.json':
                if f.read() != manifest_bytes:
                    fail(f'manifest.json inside {archive} differs from the published one')
            elif member.name == 'manifest.json.sig':
                if f.read() != sig_bytes:
                    fail(f'manifest.json.sig inside {archive} differs from the published one')
    proc.stdout.close()
    if proc.wait() != 0:
        fail(f'zstd could not decompress {archive}')
    expected = sorted([db_name, 'manifest.json', 'manifest.json.sig'])
    if seen != expected:
        fail(f'unexpected entries in {archive}: {seen}')


def split(archive, out_dir):
    """Parts and manifest in the format of split_release_asset.sh."""
    base = os.path.basename(archive)
    parts = []
    with open(archive, 'rb') as src:
        index = 0
        while True:
            name = f'{base}.part-{index:03d}'
            path = os.path.join(out_dir, name)
            h = hashlib.sha256()
            size = 0
            with open(path, 'wb') as dst:
                while size < PART_SIZE:
                    chunk = src.read(min(1 << 20, PART_SIZE - size))
                    if not chunk:
                        break
                    dst.write(chunk)
                    h.update(chunk)
                    size += len(chunk)
            if size == 0:
                os.remove(path)
                break
            parts.append({'name': name, 'size': size, 'sha256': h.hexdigest()})
            index += 1
    manifest = {
        'schemaVersion': 1,
        'archive': base,
        'size': os.path.getsize(archive),
        'sha256': sha256_of(archive),
        'partSizeLimit': PART_SIZE,
        'githubAssetLimit': GITHUB_LIMIT,
        'parts': parts,
    }
    with open(os.path.join(out_dir, f'{base}.manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2)
        f.write('\n')
    os.remove(archive)
    return parts


def pack(db, manifest_path, out_dir, zstd):
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

    os.makedirs(out_dir, exist_ok=True)
    archive = os.path.join(out_dir, ARCHIVE)
    for name in os.listdir(out_dir):
        if name.startswith(ARCHIVE):
            os.remove(os.path.join(out_dir, name))
    with tempfile.TemporaryDirectory(dir=out_dir) as work:
        tar_path = os.path.join(work, 'zmanenu-offline.tar')
        write_tar(tar_path, db, manifest_bytes, sig_bytes)
        subprocess.run([zstd, *ZSTD_ARGS, '-q', '-f', tar_path, '-o', archive], check=True)
    check_archive(archive, zstd, os.path.basename(db), full, manifest_bytes, sig_bytes)

    size = os.path.getsize(archive)
    if size > PART_SIZE:
        parts = split(archive, out_dir)
        check_parts(out_dir)
        print(f'{ARCHIVE}: {size} bytes in {len(parts)} parts, see {ARCHIVE}.manifest.json')
    else:
        print(f'{archive}: {size} bytes, {os.path.basename(db)} sha256 {full["sha256"]}')


def check_parts(out_dir):
    """Reassembles the parts as assemble_split_asset.sh does and checks every sha256."""
    with open(os.path.join(out_dir, f'{ARCHIVE}.manifest.json'), encoding='utf-8') as f:
        manifest = json.load(f)
    whole = hashlib.sha256()
    total = 0
    for part in manifest['parts']:
        path = os.path.join(out_dir, part['name'])
        if sha256_of(path) != part['sha256'] or os.path.getsize(path) != part['size']:
            fail(f'{part["name"]} does not match {ARCHIVE}.manifest.json')
        if part['size'] >= GITHUB_LIMIT:
            fail(f'{part["name"]} is over the GitHub asset limit')
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                whole.update(chunk)
                total += len(chunk)
    if whole.hexdigest() != manifest['sha256'] or total != manifest['size']:
        fail(f'the parts do not add up to {ARCHIVE}')


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='command', required=True)
    k = sub.add_parser('pack')
    k.add_argument('--db', required=True)
    k.add_argument('--manifest', required=True)
    k.add_argument('--out-dir', required=True)
    k.add_argument('--zstd', default='zstd')
    a = ap.parse_args()
    pack(a.db, a.manifest, a.out_dir, a.zstd)


if __name__ == '__main__':
    main()
