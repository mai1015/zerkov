#!/usr/bin/env python3
"""Register only the approved native freight review and capture boundary.
Preserve unrelated current entries; do not loosen historical display rules.
"""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
path=ROOT/'config/first_playable_1080_gate.json'
text=path.read_text();data=json.loads(text)
visual='tests/presentation/northline_native_contract.gd'
command='tests/tooling/run_northline_native_gate.py'
headless='tools/migrate_northline_freight.gd'
def add(group,key,value):
    global text,data
    if key in data[group]:
        if data[group][key]!=value:raise RuntimeError('registered source drift: '+key)
        return
    anchor='"'+group+'": {'
    if text.count(anchor)!=1:raise RuntimeError('ambiguous group '+group)
    text=text.replace(anchor,anchor+'\n    '+json.dumps(key)+': '+json.dumps(value)+',',1)
    data=json.loads(text)
for group,name,purpose in [('active_visual_entrypoints',visual,'original-PNG native TileMapLayer freight slice and guarded 1080 capture'),('active_command_entrypoints',command,'native 1080 freight scene and third-process edit reopening')]:
    add(group,name,{'purpose':purpose,'sha256':hashlib.sha256((ROOT/name).read_bytes()).hexdigest()})
add('sanctioned_capture_writers',visual,{'physical_guard_call':'Exact1080CaptureGuard.accepts(root,root,image)','guard_anchors':['root.size=EXACT','const EXACT := Vector2i(1920,1080)']})
if headless not in data['active_headless_entrypoints']:
    anchor='"active_headless_entrypoints": ['
    if text.count(anchor)!=1:raise RuntimeError('ambiguous headless inventory')
    text=text.replace(anchor,anchor+'\n    '+json.dumps(headless)+',',1)
    data=json.loads(text)
path.write_text(text)
test=ROOT/'tests/tooling/test_ui_first_playable_scope.py';source=test.read_text()
for group in ['active_visual_entrypoints','active_headless_entrypoints','sanctioned_capture_writers']:
    source=re.sub(r'self\.assertEqual\(\d+, len\(self\.manifest\["'+group+r'"\]\)\)', 'self.assertEqual(%d, len(self.manifest["%s"]))'%(len(data[group]),group),source)
test.write_text(source)
print('NATIVE_FREIGHT_REGISTRATION_COMPLETE')
