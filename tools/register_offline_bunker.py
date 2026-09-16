#!/usr/bin/env python3
"""Register the reviewed offline flow's native capture and command entrypoint."""
import hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=ROOT/'config/first_playable_1080_gate.json'
m=json.loads(p.read_text())
for group,path in [('active_visual_entrypoints','tests/presentation/offline_bunker_flow.gd'),('active_command_entrypoints','tests/tooling/run_offline_bunker_gate.py')]:
    m[group][path]={'purpose':'offline default normal-input bunker and native inventory persistence','sha256':hashlib.sha256((ROOT/path).read_bytes()).hexdigest()}
m['sanctioned_capture_writers']['tests/presentation/offline_bunker_flow.gd']={'physical_guard_call':'Exact1080CaptureGuard.accepts(root, root, image)','guard_anchors':['root.size = EXACT','const EXACT := Vector2i(1920, 1080)']}
p.write_text(json.dumps(m,indent=2)+'\n')
p=ROOT/'tests/tooling/test_ui_first_playable_scope.py'
s=p.read_text()
s=re.sub(r'self.assertEqual\(\d+, len\(self.manifest\["active_visual_entrypoints"\]\)\)',f'self.assertEqual({len(m["active_visual_entrypoints"])}, len(self.manifest["active_visual_entrypoints"]))',s)
# Both independent inventories grow by exactly this one new guarded writer.
s=s.replace('self.assertEqual(13, len(self.manifest["sanctioned_capture_writers"]))',
            'self.assertEqual(14, len(self.manifest["sanctioned_capture_writers"]))')
p.write_text(s)
