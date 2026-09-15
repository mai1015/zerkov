#!/usr/bin/env python3
"""Register only this review's exact-1080 entrypoints; preserve prior policy.
Used once during integration. It never modifies the policy checker or retires tests.
The explicitly reviewed full-zone extension adds one visual entrypoint after this
study; an idempotent run must preserve that later count rather than undo it.
"""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
manifest_path=ROOT/'config/first_playable_1080_gate.json'
manifest=json.loads(manifest_path.read_text())
visual='tests/presentation/map_studies_contract.gd'
command='tests/tooling/run_map_studies_gate.py'
for group,path,purpose in [('active_visual_entrypoints',visual,'two original map studies; guarded native screenshots and input'),('active_command_entrypoints',command,'isolated exact-1080 map scene capture and repeatability')]:
    manifest[group][path]={'purpose':purpose,'sha256':hashlib.sha256((ROOT/path).read_bytes()).hexdigest()}
manifest['sanctioned_capture_writers'][visual]={'physical_guard_call':'Exact1080CaptureGuard.accepts(root, root, image)','guard_anchors':['root.size=EXACT','const EXACT := Vector2i(1920,1080)']}
test=ROOT/'tests/tooling/test_ui_first_playable_scope.py'
source=test.read_text()
old='self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))'
new='self.assertEqual(28, len(self.manifest["active_visual_entrypoints"]))'
expanded='self.assertEqual(29, len(self.manifest["active_visual_entrypoints"]))'
if old in source:
    source=source.replace(old,new)
elif new not in source:
    if (expanded not in source or len(manifest['active_visual_entrypoints']) != 29
            or 'tests/presentation/northline_zone_contract.gd' not in manifest['active_visual_entrypoints']
            or 'tests/tooling/run_northline_zone_gate.py' not in manifest['active_command_entrypoints']
            or 'tests/presentation/northline_zone_contract.gd' not in manifest['sanctioned_capture_writers']):
        raise RuntimeError('review expected entrypoint count before updating another baseline')
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
if source != test.read_text():
    test.write_text(source)
print('MAP_STUDY_POLICY_REGISTERED: map entrypoints current; later reviewed full-zone inventory retained')
