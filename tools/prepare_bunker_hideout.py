#!/usr/bin/env python3
"""Idempotent integration of this bounded visual request into the existing host.

Only the Bunker scene's script binding and exact-output runner inventory change.
Refuse unexpected existing bindings; never replace the old controller or gates.
"""
import hashlib
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def prepare():
    scene=ROOT/'ui/screens/bunker/bunker.tscn'
    old='path="res://ui/screens/bunker/bunker.gd" id="1_bunker_screen"'
    new='path="res://ui/screens/bunker/bunker_hideout_screen.gd" id="1_bunker_screen"'
    text=scene.read_text()
    if old in text:
        if text.count(old)!=1:raise RuntimeError('Ambiguous bunker binding')
        scene.write_text(text.replace(old,new))
    elif new not in text:raise RuntimeError('Unexpected bunker scene script binding')
    path=ROOT/'config/first_playable_1080_gate.json';data=json.loads(path.read_text())
    gd='tests/presentation/bunker_hideout_contract.gd'
    driver='tests/tooling/run_bunker_hideout_gate.py'
    for group,name,purpose in [('active_visual_entrypoints',gd,'Native bunker production-view rendering and actual mouse input'),('active_command_entrypoints',driver,'Exact-1080 graphical bunker capture gate')]:
        data[group][name]={'purpose':purpose,'sha256':hashlib.sha256((ROOT/name).read_bytes()).hexdigest()}
    data['sanctioned_capture_writers'][gd]={'physical_guard_call':'Guard.accepts(root, root, image)','guard_anchors':['root.size = Vector2i(1920, 1080)','image.get_size() == Vector2i(1920, 1080)']}
    path.write_text(json.dumps(data,indent=2)+'\n')
    tests=ROOT/'tests/tooling/test_ui_first_playable_scope.py';text=tests.read_text()
    text=text.replace('self.assertEqual(26, len(self.manifest["active_visual_entrypoints"]))','self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))')
    tests.write_text(text)
    print('BUNKER_HOST_INTEGRATION_OK')

if __name__=='__main__':prepare()
