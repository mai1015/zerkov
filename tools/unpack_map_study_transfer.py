#!/usr/bin/env python3
"""One-time exact-content publication for locally tested map sources.

Only the nineteen explicitly listed new files are accepted. No extraction of
arbitrary archives, links, repository config, fonts, engines or original packs.
This script and its transfer parts are removed after validated publication.
"""
import hashlib
import io
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = '''assets/world/map_studies/atlas.json
assets/world/map_studies/atlas.webp
assets/world/map_studies/atlas.webp.import
docs/qa/map_studies/README.md
docs/qa/map_studies/capture.json
docs/spec/changes/add-extraction-map-studies-2026-09-15/design.md
docs/spec/changes/add-extraction-map-studies-2026-09-15/proposal.md
docs/spec/changes/add-extraction-map-studies-2026-09-15/specs/map-studies/spec.md
docs/spec/changes/add-extraction-map-studies-2026-09-15/tasks.md
game/presentation/map_studies/README.md
game/presentation/map_studies/map_studies.gd
game/presentation/map_studies/map_studies.tscn
game/presentation/map_studies/map_study_world.gd
game/presentation/map_studies/maps.json
tests/presentation/map_studies_contract.gd
tests/tooling/run_map_studies_gate.py
tests/tooling/test_map_studies.py
tools/import_map_study_assets.py
tools/register_map_studies.py'''.splitlines()
parts = [ROOT / 'tools/map-study-transfer' / ('%02d.part' % i) for i in range(5)]
if not any(p.exists() for p in parts):
    raise SystemExit('Map sources already published; no transfer to decode.')
if set((ROOT / 'tools/map-study-transfer').iterdir()) != set(parts):
    raise RuntimeError('unexpected transfer part inventory')
raw = b''.join(p.read_bytes() for p in parts)
if len(raw) != 58620 or hashlib.sha256(raw).hexdigest() != 'cbcedc8526b4a072b971e6809219cc710a918adf8d784469bac5ae7e49618689':
    raise RuntimeError('map source transfer checksum mismatch')
plan = {}
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:xz') as archive:
    members = archive.getmembers()
    if len(members) != len(EXPECTED) or {m.name for m in members} != set(EXPECTED):
        raise RuntimeError('unexpected archive file inventory')
    for member in members:
        if not member.isfile() or member.size > 1_000_000:
            raise RuntimeError('invalid archive member type/size')
        target = ROOT / member.name
        if target.is_symlink() or any(p.is_symlink() for p in target.parents):
            raise RuntimeError('symlink destination')
        data = archive.extractfile(member).read()
        if target.exists() and target.read_bytes() != data:
            raise RuntimeError('refusing to overwrite an independently changed file')
        plan[target] = data
for target, data in plan.items():
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
for part in parts:
    part.unlink()
print('MAP_SOURCE_TRANSFER_RESULT files=19 sha256=verified')
