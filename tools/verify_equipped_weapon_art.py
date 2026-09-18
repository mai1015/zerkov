#!/usr/bin/env python3
"""Verify the exact original weapon/arm/FX source selection; no writes or imports."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path('game/content/art/weapon_art/source_manifest.json')

def verify(root: Path = ROOT) -> int:
    value = json.loads((root / MANIFEST).read_text(encoding='utf-8'))
    if value.get('schema_version') != 1 or value.get('distribution_status') != 'blocked_pending_provenance':
        raise ValueError('invalid provenance/distribution state')
    rows = value.get('sources', [])
    if not 1 <= len(rows) <= 64:
        raise ValueError('source budget exceeded')
    seen: set[str] = set()
    for row in rows:
        path = row['path']
        member = row['member']
        if not path.startswith('assets/original/') or PurePosixPath(path).is_absolute() or '..' in PurePosixPath(path).parts:
            raise ValueError('invalid original path')
        if member != 'zerkov/' + path.removeprefix('assets/original/') or 'do not use' in member.casefold():
            raise ValueError('forbidden or mismatched archive source')
        if path in seen:
            raise ValueError('duplicate source')
        seen.add(path)
        source = root / path
        if source.is_symlink() or not source.is_file():
            raise ValueError('missing or linked original: ' + path)
        raw = source.read_bytes()
        if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
            raise ValueError('changed original: ' + path)
        if raw[:8] != b'\x89PNG\r\n\x1a\n' or [int.from_bytes(raw[16:20], 'big'), int.from_bytes(raw[20:24], 'big')] != row['size']:
            raise ValueError('changed PNG dimensions: ' + path)
    return len(rows)

if __name__ == '__main__':
    try:
        print(f'WEAPON_ART_SOURCES_RESULT sources={verify()} failures=0 original_bytes=true')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise SystemExit('WEAPON_ART_SOURCES_FAILED: ' + str(exc))
