#!/usr/bin/env python3
"""Run real map presentation under Godot and retain unmodified native screenshots.
This isolates the new environment scenes, not the full six-add-on raid host.
"""
from __future__ import annotations
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PIN='4.7.2.stable.official.ed1daf0bf'
KNOWN='WARNING: Could not set V-Sync mode, as changing V-Sync mode is not supported by the graphics driver.'
DIAGNOSTIC=re.compile(r'(SCRIPT ERROR|ERROR:|WARNING:|Parse Error|ObjectDB instances leaked)',re.I)
PROJECT='''config_version=5
[application]
config/name="Zerkov extraction environment studies"
run/main_scene="res://game/presentation/map_studies/map_studies.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''

def run(cmd:list[str],cwd:Path,log:Path)->str:
    result=subprocess.run(cmd,cwd=cwd,text=True,capture_output=True,timeout=120,
                          env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1','LIBGL_ALWAYS_SOFTWARE':'1'})
    text=result.stdout+result.stderr;log.write_text(text);print(text,flush=True)
    filtered=text.replace(KNOWN,'KNOWN_RENDERER_VSYNC_NOTICE')
    if result.returncode or DIAGNOSTIC.search(filtered):raise RuntimeError('native process/diagnostics failed: '+str(result.returncode))
    return text

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--godot',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();engine=shutil.which(args.godot)
    if engine is None or shutil.which('xvfb-run') is None:raise RuntimeError('pinned Godot and Xvfb are required')
    if args.output.exists():raise RuntimeError('use a new output directory to avoid stale evidence')
    output=args.output.resolve();output.mkdir(parents=True)
    if run([engine,'--version'],ROOT,output/'version.log').strip()!=PIN:raise RuntimeError('wrong Godot version')
    with tempfile.TemporaryDirectory(prefix='zerkov-map-study-') as temp:
        project=Path(temp)
        for path in ['game/presentation/map_studies','assets/world/map_studies']:
            shutil.copytree(ROOT/path,project/path,ignore=shutil.ignore_patterns('*.uid'))
        for path in ['game/presentation/exact_1080_capture_guard.gd','tests/presentation/map_studies_contract.gd']:
            target=project/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/path,target)
        (project/'project.godot').write_text(PROJECT)
        run([engine,'--headless','--path',str(project),'--resolution','1920x1080','--editor','--import','--quit'],project,output/'import.log')
        summaries=[];hashes=[];notices=0
        for i in range(2):
            out=output/('run'+str(i));out.mkdir()
            text=run(['xvfb-run','-a','-s','-screen 0 1920x1080x24',engine,'--path',str(project),'--resolution','1920x1080','--rendering-method','gl_compatibility','--audio-driver','Dummy','--script','res://tests/presentation/map_studies_contract.gd','--','--output='+str(out)],project,output/('native%d.log'%i))
            match=re.search(r'MAP_STUDY_NATIVE_RESULT checks=(\d+) failures=0 maps=2 captures=7 output=1920x1080 world=640x360 scale=3',text)
            if not match:raise RuntimeError('missing native success marker')
            summaries.append(int(match[1]));notices+=text.count(KNOWN)
            hashes.append({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(out.glob('*.png'))})
            if len(hashes[-1])!=7:raise RuntimeError('missing native PNGs')
        if hashes[0]!=hashes[1] or summaries[0]!=summaries[1]:raise RuntimeError('repeated native runs disagree')
        for file in (output/'run0').glob('*.png'):shutil.copyfile(file,output/file.name)
        seal={'engine':PIN,'runs':2,'checks':sum(summaries),'failures':0,'unexpected_diagnostics':0,'known_vsync_notices':notices,'output':[1920,1080],'world':[640,360],'scale':3,'screenshots':hashes[0],'source_files':{},'scope':'two environment studies, not live raid or full UI host','human_approval':False}
        for folder in ['game/presentation/map_studies','assets/world/map_studies']:
            for path in sorted((ROOT/folder).rglob('*')):
                if path.is_file() and path.suffix!='.uid':seal['source_files'][path.relative_to(ROOT).as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
        (output/'capture.json').write_text(json.dumps(seal,indent=2)+'\n')
        print('MAP_STUDY_GATE_RESULT runs=2 checks=%d failures=0 captures=7 repeatable=true'%sum(summaries))
    return 0
if __name__=='__main__':raise SystemExit(main())
