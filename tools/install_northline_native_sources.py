#!/usr/bin/env python3
"""Copy the selected full original PNGs, byte for byte. No image transformation.

Normal game/editor startup never invokes this installer. It requires the two
user-supplied ZIPs only on a checkout where original art is not already installed.
Existing differing files and symlinks are rejected; --verify is read-only.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'assets/world/northline_native/source_manifest.json'
PREFIX = 'assets/world/northline_native/sources/'

class SourceError(ValueError):
    pass

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def clean_path(name: str) -> str:
    if not isinstance(name, str) or not name or '\\' in name or ':' in name:
        raise SourceError('non-portable path')
    if any(p in ('', '.', '..') for p in name.split('/')) or PurePosixPath(name).is_absolute():
        raise SourceError('unsafe relative path')
    if 'do not use' in name.casefold() or any(ord(c)<32 for c in name):
        raise SourceError('forbidden path')
    return name

def destination(root: Path, name: str) -> Path:
    clean_path(name)
    if not name.startswith(PREFIX) or not name.endswith('.png'):
        raise SourceError('output is not an allowlisted PNG location')
    relative = Path(name)
    for parent in (root / relative).parents:
        if parent == root.parent: break
        if parent.is_symlink(): raise SourceError('symlink output ancestor')
    target=root/relative
    if target.is_symlink(): raise SourceError('symlink output file')
    return target

def manifest_at(path: Path = MANIFEST) -> dict:
    value=json.loads(path.read_text())
    if value.get('schema_version')!=1 or not isinstance(value.get('sources'),list):
        raise SourceError('unsupported manifest')
    paths=set()
    total=0
    for row in value['sources']:
        clean_path(row['member']);clean_path(row['archive']);clean_path(row['path'])
        if row['path'] in paths or not row['path'].startswith(PREFIX):
            raise SourceError('duplicate or unexpected output')
        paths.add(row['path'])
        if type(row['bytes']) is not int or not 0<row['bytes']<=16*1024*1024:
            raise SourceError('invalid byte budget')
        total+=row['bytes']
        if row['archive'] not in value['archives']:
            raise SourceError('unknown archive')
    if not paths or len(paths)>32 or total>32*1024*1024:
        raise SourceError('selection budget exceeded')
    return value

def verify(root: Path, manifest: dict) -> None:
    missing=[]
    for row in manifest['sources']:
        p=destination(root,row['path'])
        if not p.is_file():missing.append(row['path']);continue
        if p.stat().st_size!=row['bytes'] or sha(p.read_bytes())!=row['sha256']:
            raise SourceError('source bytes differ: '+row['path'])
    if missing:raise SourceError('original art is not installed: '+', '.join(missing))

def install(root: Path, source_dir: Path, manifest: dict) -> None:
    # Preflight ALL bytes and outputs before writing any file.
    plan=[]
    for name, expected in manifest['archives'].items():
        p=source_dir/clean_path(name)
        if not p.is_file() or p.is_symlink() or p.stat().st_size>256*1024*1024:
            raise SourceError('missing/unsafe source archive: '+name)
        with p.open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=expected:
                raise SourceError('archive hash mismatch: '+name)
    for row in manifest['sources']:
        p=destination(root,row['path'])
        if p.exists() and (not p.is_file() or sha(p.read_bytes())!=row['sha256']):
            raise SourceError('refusing to overwrite different source: '+row['path'])
        with zipfile.ZipFile(source_dir/row['archive']) as z:
            if len(z.infolist())>10000:raise SourceError('archive entry budget')
            selected=[i for i in z.infolist() if i.filename==row['member']]
            if len(selected)!=1:raise SourceError('missing/duplicate selected member')
            item=selected[0]
            if item.is_dir() or stat.S_ISLNK(item.external_attr>>16) or item.flag_bits&1:
                raise SourceError('selected source is directory/link/encrypted')
            if item.file_size!=row['bytes']:raise SourceError('source length differs')
            raw=z.read(item)
        if sha(raw)!=row['sha256']:raise SourceError('source hash differs')
        if not p.exists():plan.append((p,raw))
    for p,raw in plan:
        p.parent.mkdir(parents=True,exist_ok=True)
        # Recheck the name after potentially creating its parent. Fail closed
        # against another writer; link publishes without replacing an existing file.
        destination(root,p.relative_to(root).as_posix())
        fd,name=tempfile.mkstemp(prefix='.original-',dir=p.parent)
        try:
            with os.fdopen(fd,'wb') as stream:
                stream.write(raw);stream.flush();os.fsync(stream.fileno())
            os.link(name,p)
        finally:
            Path(name).unlink(missing_ok=True)
    verify(root,manifest)

def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-dir',type=Path)
    p.add_argument('--verify',action='store_true')
    args=p.parse_args()
    try:
        data=manifest_at()
        if args.verify:verify(ROOT,data)
        elif args.source_dir:install(ROOT,args.source_dir,data)
        else:p.error('provide --source-dir or --verify')
        print('NATIVE_SOURCE_RESULT sheets=%d failures=0 unchanged_original_bytes=true'%len(data['sources']))
        return 0
    except (OSError,ValueError,zipfile.BadZipFile) as exc:
        print('NATIVE_SOURCES_BLOCKED:',exc)
        return 2
if __name__=='__main__':raise SystemExit(main())
