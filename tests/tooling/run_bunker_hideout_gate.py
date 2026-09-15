#!/usr/bin/env python3
"""Render the actual production bunker view using real Godot and software OpenGL.

The isolated project omits unrelated native add-ons; it substitutes no gameplay
or UI add-on. Both raw captures must pass the physical exact-output guard.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
PIN = '4.7.2.stable.official.ed1daf0bf'
PROJECT = '''config_version=5
[application]
config/name="Zerkov bunker presentation"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
window/vsync/vsync_mode=0
[rendering]
renderer/rendering_method="gl_compatibility"
'''

def run(command, cwd):
    print('RUN', ' '.join(map(str,command)),flush=True)
    p=subprocess.run(command,cwd=cwd,capture_output=True,text=True,timeout=180,
        env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1','LIBGL_ALWAYS_SOFTWARE':'1'})
    text=p.stdout+p.stderr
    print(text,flush=True)
    if p.returncode or re.search(r'(?:SCRIPT ERROR|ERROR|WARNING|Parse Error):|ObjectDB instances leaked',text):
        raise RuntimeError('Godot process/diagnostic failure: %s' % p.returncode)
    return text

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--godot',required=True);ap.add_argument('--output',type=Path,required=True);args=ap.parse_args()
    engine=shutil.which(args.godot)
    if not engine:raise RuntimeError('Godot executable not found')
    if run([engine,'--version'],ROOT).strip()!=PIN:raise RuntimeError('Incorrect Godot version')
    if args.output.exists():raise RuntimeError('Output directory must be new')
    args.output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='zerkov-bunker-') as tmp:
        project=Path(tmp)
        for directory in ['game/presentation/bunker','assets/world/bunker']:
            shutil.copytree(ROOT/directory,project/directory)
        for filename in ['game/presentation/exact_1080_capture_guard.gd','tests/presentation/bunker_hideout_contract.gd','assets/fonts/ChakraPetch-SemiBold.ttf','assets/fonts/IBMPlexMono-Regular.ttf']:
            dst=project/filename;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/filename,dst)
        (project/'project.godot').write_text(PROJECT)
        run([engine,'--headless','--path',str(project),'--resolution','1920x1080','--editor','--import','--quit'],project)
        results=[]
        for index in range(2):
            out=args.output/('run%d'%index)
            text=run(['xvfb-run','-a','-s','-screen 0 1920x1080x24',engine,'--path',str(project),'--resolution','1920x1080','--rendering-method','gl_compatibility','--audio-driver','Dummy','--script','res://tests/presentation/bunker_hideout_contract.gd','--','--output='+str(out)],project)
            match=re.search(r'BUNKER_NATIVE_RESULT checks=(\d+) failures=0',text)
            if not match:raise RuntimeError('Missing successful result marker')
            results.append(int(match[1]))
        images={}
        from PIL import Image
        for name in ['bunker-standard-1080.png','bunker-emergency-1080.png']:
            a=(args.output/'run0'/name).read_bytes();b=(args.output/'run1'/name).read_bytes()
            if a!=b:raise RuntimeError('Native capture is not repeatable: '+name)
            if Image.open(args.output/'run0'/name).size!=(1920,1080):raise RuntimeError('Wrong raw dimensions')
            shutil.copyfile(args.output/'run0'/name,args.output/name)
            images[name]=hashlib.sha256(a).hexdigest()
        record={'engine':PIN,'source_commit':os.environ.get('SOURCE_SHA','local'),'renderer':'OpenGL Compatibility / llvmpipe / Xvfb','native_runs':2,'checks':sum(results),'failures':0,'godot_diagnostics':0,'output':[1920,1080],'world':[640,360],'integer_scale':3,'screenshots':images,'human_approval':False,'scope':'Actual production bunker presentation in isolation; full six-addon UI host not claimed'}
        (args.output/'capture.json').write_text(json.dumps(record,indent=2)+'\n')
        print('BUNKER_CAPTURE_GATE',json.dumps(record))
    return 0

if __name__=='__main__':raise SystemExit(main())
