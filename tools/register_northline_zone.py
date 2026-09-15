#!/usr/bin/env python3
"""Add only the full-zone native entrypoints to the exact-output policy."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
path=ROOT/'config/first_playable_1080_gate.json'
manifest=json.loads(path.read_text())
visual='tests/presentation/northline_zone_contract.gd'
command='tests/tooling/run_northline_zone_gate.py'
for group,name,purpose in [('active_visual_entrypoints',visual,'full Northline native map, GUI and collision walkthrough'),('active_command_entrypoints',command,'exact-1080 full-zone capture and repeatability')]:
    manifest[group][name]={'purpose':purpose,'sha256':hashlib.sha256((ROOT/name).read_bytes()).hexdigest()}
manifest['sanctioned_capture_writers'][visual]={'physical_guard_call':'Exact1080CaptureGuard.accepts(root, root, image)','guard_anchors':['root.size = EXACT','const EXACT := Vector2i(1920,1080)']}
path.write_text(json.dumps(manifest,indent=2)+'\n')
test=ROOT/'tests/tooling/test_ui_first_playable_scope.py'
# Keep the inventory assertion in step with the manifest just written, rather
# than a hard-coded count that breaks whenever main adds an entrypoint.
source=test.read_text()
if visual not in manifest['active_visual_entrypoints']:raise RuntimeError('Review changed inventory baseline first')
updated=re.sub(r'self\.assertEqual\(\d+, len\(self\.manifest\["active_visual_entrypoints"\]\)\)','self.assertEqual(%d, len(self.manifest["active_visual_entrypoints"]))'%len(manifest['active_visual_entrypoints']),source)
if updated!=source:test.write_text(updated)
print('NORTHLINE_POLICY_REGISTERED: two new entrypoints, existing policy retained')
