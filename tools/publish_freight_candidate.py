#!/usr/bin/env python3
"""Publish exactly the locally tested freight-polish candidate, once.

Transport only: this script and its three parts are removed by the successful
validation commit. No arbitrary extraction, source packs, fonts or engine.
"""
from pathlib import Path
import hashlib
import io
import json
import tarfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = '''assets/world/northline_zone/review_outfit.json
assets/world/northline_zone/review_outfit.webp
assets/world/northline_zone/review_outfit.webp.import
docs/qa/freight_polish/ANIMATION_AUDIT.md
docs/qa/freight_polish/README.md
docs/spec/changes/polish-northline-freight-2026-09-15/design.md
docs/spec/changes/polish-northline-freight-2026-09-15/proposal.md
docs/spec/changes/polish-northline-freight-2026-09-15/specs/freight-presentation/spec.md
docs/spec/changes/polish-northline-freight-2026-09-15/tasks.md
game/presentation/northline_zone/northline_zone.gd
game/presentation/northline_zone/polish/anchored_wind.gdshader
game/presentation/northline_zone/polish/freight_polish.gd
game/presentation/northline_zone/review_locomotion_pose.gd
game/presentation/northline_zone/review_walker.gd
game/presentation/northline_zone/zone_world.gd
tests/presentation/freight_polish_contract.gd
tests/presentation/northline_zone_contract.gd
tests/tooling/run_northline_zone_gate.py
tests/tooling/test_freight_polish.py
tools/import_northline_review_outfit.py'''.splitlines()
parts = [ROOT / 'tools/freight-transfer' / ('%02d.part' % i) for i in range(3)]
if set((ROOT / 'tools/freight-transfer').iterdir()) != set(parts):
    raise RuntimeError('unexpected source transfer inventory')
raw = b''.join(p.read_bytes() for p in parts)
if len(raw) != 25480 or hashlib.sha256(raw).hexdigest() != '29a078f87c4ccd686e0a9fc0385c6911244a2e8819ec60051a14012d89b59d82':
    raise RuntimeError('candidate checksum mismatch')
plan = {}
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:xz') as archive:
    members = archive.getmembers()
    allowed = set(EXPECTED) | {'MANIFEST.json'}
    if len(members) != len(allowed) or {m.name for m in members} != allowed:
        raise RuntimeError('candidate member inventory mismatch')
    for member in members:
        if not member.isfile() or member.size > 200_000:
            raise RuntimeError('invalid member type/size')
    manifest = json.loads(archive.extractfile('MANIFEST.json').read())
    if manifest['base_commit'] != 'e9720bbafed702aa372dfea971098fc839c21792' or set(manifest['files']) != set(EXPECTED):
        raise RuntimeError('wrong candidate baseline or file inventory')
    for name in EXPECTED:
        target = ROOT / name
        if target.is_symlink() or any(p.is_symlink() for p in target.parents):
            raise RuntimeError('symlink destination')
        record = manifest['files'][name]
        data = archive.extractfile(name).read()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise RuntimeError('source digest mismatch: ' + name)
        if record['old_sha256'] is None:
            if target.exists():
                raise RuntimeError('new path already exists: ' + name)
        elif not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != record['old_sha256']:
            raise RuntimeError('preimage changed: ' + name)
        plan[target] = data
# Preflight all file identities before any materialization.
for target, data in plan.items():
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
print('FREIGHT_SOURCE_CANDIDATE files=20 sha256=verified preimages=verified')
