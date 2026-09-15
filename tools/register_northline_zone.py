#!/usr/bin/env python3
"""Add only the full-zone native entrypoints to the exact-output policy."""
from pathlib import Path
import hashlib,json
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
source=test.read_text();old='self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))';new='self.assertEqual(28, len(self.manifest["active_visual_entrypoints"]))'
if old in source:test.write_text(source.replace(old,new))
elif new not in source:raise RuntimeError('Review changed inventory baseline first')
print('NORTHLINE_POLICY_REGISTERED: two new entrypoints, existing policy retained')
