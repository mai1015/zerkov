#!/usr/bin/env python3
"""Native full-zone capture and collision walkthrough; isolated from the raid host.
A failing process, unexpected diagnostic or missing capture is never a passing skip.
"""
from __future__ import annotations
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PIN='4.7.2.stable.official.ed1daf0bf'
KNOWN='WARNING: Could not set V-Sync mode, as changing V-Sync mode is not supported by the graphics driver.'
DIAGNOSTIC=re.compile(r'(SCRIPT ERROR|ERROR:|WARNING:|Parse Error|ObjectDB instances leaked)',re.I)
PROJECT='''config_version=5
[application]
config/name="Zerkov - Northline full-zone environment review"
run/main_scene="res://game/presentation/northline_zone/northline_zone.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''
FOLDERS=['game/presentation/northline_zone','assets/world/northline_zone','game/presentation/map_studies','assets/world/map_studies']

def run(command:list[str],project:Path,log:Path)->str:
    completed=subprocess.run(command,cwd=project,capture_output=True,text=True,timeout=240,env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1','LIBGL_ALWAYS_SOFTWARE':'1'})
    output=completed.stdout+completed.stderr;log.write_text(output);print(output,flush=True)
    if completed.returncode or DIAGNOSTIC.search(output.replace(KNOWN,'KNOWN_VSYNC_NOTICE')):
        raise RuntimeError('Godot process or diagnostic failure: '+str(completed.returncode))
    return output

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();engine=shutil.which(args.godot)
    if not engine or not shutil.which('xvfb-run'):raise RuntimeError('Pinned Godot and Xvfb required')
    if args.output.exists():raise RuntimeError('Use a new evidence directory')
    output=args.output.resolve();output.mkdir(parents=True)
    if run([engine,'--version'],ROOT,output/'version.log').strip()!=PIN:raise RuntimeError('Wrong engine version')
    with tempfile.TemporaryDirectory(prefix='northline-native-') as temp:
        project=Path(temp)
        for folder in FOLDERS:shutil.copytree(ROOT/folder,project/folder,ignore=shutil.ignore_patterns('*.uid'))
        for name in ['game/presentation/exact_1080_capture_guard.gd','tests/presentation/northline_zone_contract.gd']:
            target=project/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,target)
        (project/'project.godot').write_text(PROJECT)
        run([engine,'--headless','--path',str(project),'--resolution','1920x1080','--editor','--import','--quit'],project,output/'import.log')
        counts=[];hashes=[];notices=0
        for i in range(2):
            dest=output/('run%d'%i);dest.mkdir()
            text=run(['xvfb-run','-a','-s','-screen 0 1920x1080x24',engine,'--path',str(project),'--resolution','1920x1080','--rendering-method','gl_compatibility','--audio-driver','Dummy','--script','res://tests/presentation/northline_zone_contract.gd','--','--output='+str(dest)],project,output/('native%d.log'%i))
            match=re.search(r'NORTHLINE_NATIVE_RESULT checks=(\d+) failures=0 captures=12 sectors=9 output=1920x1080 world=640x360',text)
            if match is None or int(match[1])<38:raise RuntimeError('Missing complete native result')
            counts.append(int(match[1]));notices+=text.count(KNOWN)
            hashes.append({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(dest.glob('*.png'))})
            if len(hashes[-1])!=12:raise RuntimeError('Incomplete screenshot inventory')
        if counts[0]!=counts[1] or hashes[0]!=hashes[1]:raise RuntimeError('Repeated native runs differ')
        for path in (output/'run0').glob('*.png'):shutil.copyfile(path,output/path.name)
        seal={'source_commit':os.environ.get('SOURCE_SHA','local-uploaded-project'),'engine':PIN,'runs':2,'checks':sum(counts),'failures':0,'unexpected_diagnostics':0,'known_vsync_notices':notices,'output':[1920,1080],'world_raster':[640,360],'world_size':[2688,1792],'area_multiplier':16,'screenshots':hashes[0],'source_files':{},'scope':'full connected environment with review walker; not the live raid host','human_approval':False}
        for folder in FOLDERS:
            for path in sorted((ROOT/folder).rglob('*')):
                if path.is_file() and path.suffix!='.uid':seal['source_files'][str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [ROOT/'tests/presentation/northline_zone_contract.gd',Path(__file__)]:seal['source_files'][str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
        (output/'capture.json').write_text(json.dumps(seal,indent=2)+'\n')
        print('NORTHLINE_GATE_RESULT runs=2 checks=%d failures=0 captures=12 repeatable=true'%sum(counts))
    return 0
if __name__=='__main__':raise SystemExit(main())
