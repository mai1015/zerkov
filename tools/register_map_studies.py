#!/usr/bin/env python3
"""Register only this review's exact-1080 entrypoints; preserve prior policy.
Used once during integration. It never modifies the policy checker or retires tests.
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
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
test=ROOT/'tests/tooling/test_ui_first_playable_scope.py'
source=test.read_text();old='self.assertEqual(26, len(self.manifest["active_visual_entrypoints"]))';new='self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))'
if old in source:test.write_text(source.replace(old,new))
elif new not in source:raise RuntimeError('review expected entrypoint count before updating another baseline')
print('MAP_STUDY_POLICY_REGISTERED: new native and command entrypoints; prior policy retained')
