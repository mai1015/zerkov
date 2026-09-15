#!/usr/bin/env python3
"""One-time publication of the reviewed Northline source candidate.

Exactly 22 known paths, sealed by SHA-256. The large authored zone is generated
separately and checked against its reviewed hash. No engines, fonts or source
archives are transported. This helper and its parts are removed after validation.
"""
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '8046c19593501353c6584992136e99bf47d33215'
REPLACEMENT = 'tools/check_map_study_scope.py'
EXPECTED = '''assets/world/northline_zone/review_walker.json
assets/world/northline_zone/review_walker.png
assets/world/northline_zone/review_walker.png.import
docs/qa/northline_zone/README.md
docs/spec/changes/expand-northline-zone-2026-09-15/design.md
docs/spec/changes/expand-northline-zone-2026-09-15/proposal.md
docs/spec/changes/expand-northline-zone-2026-09-15/specs/northline-zone/spec.md
docs/spec/changes/expand-northline-zone-2026-09-15/tasks.md
game/presentation/northline_zone/README.md
game/presentation/northline_zone/northline_zone.gd
game/presentation/northline_zone/northline_zone.tscn
game/presentation/northline_zone/review_walker.gd
game/presentation/northline_zone/zone_overlay.gd
game/presentation/northline_zone/zone_world.gd
tests/presentation/northline_zone_contract.gd
tests/tooling/run_northline_zone_gate.py
tests/tooling/test_northline_zone.py
tools/author_northline_zone.py
tools/check_map_study_scope.py
tools/import_northline_walker.py
tools/register_northline_zone.py
tools/review_northline_routes.py'''.splitlines()
folder = ROOT / 'tools/northline-transfer'
parts = [folder / ('%02d.part' % i) for i in range(4)]
if set(folder.iterdir()) != set(parts):
    raise RuntimeError('unexpected transfer inventory')
raw = b''.join(p.read_bytes() for p in parts)
if len(raw) != 30312 or hashlib.sha256(raw).hexdigest() != 'fcc0447e899f9546d390401eb6d9f13bd046b1da139bfdf1583cb8462179dfe3':
    raise RuntimeError('source checksum mismatch')
old = subprocess.run(['git', 'show', BASE + ':' + REPLACEMENT], cwd=ROOT, check=True, capture_output=True).stdout
plan = {}
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:xz') as archive:
    members = archive.getmembers()
    if len(members) != len(EXPECTED) or {m.name for m in members} != set(EXPECTED):
        raise RuntimeError('unexpected source file inventory')
    for member in members:
        if not member.isfile() or not 0 < member.size <= 100_000:
            raise RuntimeError('invalid source type/size')
        target = ROOT / member.name
        if target.is_symlink() or any(p.is_symlink() for p in target.parents):
            raise RuntimeError('symlink destination')
        data = archive.extractfile(member).read()
        if target.exists() and target.read_bytes() != data:
            if member.name != REPLACEMENT or target.read_bytes() != old:
                raise RuntimeError('independently changed destination: ' + member.name)
        plan[target] = data
for target, data in plan.items():
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
print('NORTHLINE_SOURCE_RESULT files=22 checksum=verified')
