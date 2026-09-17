#!/usr/bin/env python3
"""Native freight scene/collision/edit roundtrip. No full raid-host claim.

Requires the original PNGs (install_northline_native_sources.py) and a graphical
1920x1080 display. Runs real Godot twice, then reopens edits in a third process.
Never modifies the original scene, source art or player profile.
"""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, os, re, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PIN='4.7.2.stable.official.ed1daf0bf'
ERROR=re.compile(r'SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|NATIVE_FREIGHT_ASSERT')
RESULT=re.compile(r'NATIVE_FREIGHT_RESULT checks=([1-9][0-9]*) failures=0 mode=(full|reopen)')
FILES=[
    'game/presentation/northline_zone/review_walker.gd',
    'game/presentation/northline_zone/review_locomotion_pose.gd',
    'game/presentation/northline_zone/zone.json',
    'assets/world/map_studies/atlas.json',
    'assets/world/northline_zone/review_outfit.webp',
    'assets/world/northline_zone/review_outfit.webp.import',
    'game/presentation/exact_1080_capture_guard.gd',
    'tests/presentation/northline_native_contract.gd',
]
PROJECT='''config_version=5
[application]
config/name="Native Northline freight - scene review"
run/main_scene="res://game/presentation/northline_native/freight_review.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''
def digest(path:Path)->str:return hashlib.sha256(path.read_bytes()).hexdigest()
def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        spec=importlib.util.spec_from_file_location('native_sources',ROOT/'tools/install_northline_native_sources.py')
        source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)
        source.verify(ROOT,source.manifest_at())
        engine=str(args.godot.resolve(strict=True))
        env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1'}
        if subprocess.check_output([engine,'--version'],env=env,text=True).strip()!=PIN:
            raise RuntimeError('engine version differs from pin')
        if args.output.exists():raise RuntimeError('output must be a new directory')
        args.output.mkdir(parents=True)
        def execute(label,command,mode=None):
            try:
                result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=120)
                text=result.stdout+result.stderr;code=result.returncode
            except subprocess.TimeoutExpired as exc:
                raw=exc.stdout or b'';text=raw.decode(errors='replace') if isinstance(raw,bytes) else raw;code=124
            (args.output/(label+'.log')).write_text(text)
            print(text,flush=True)
            if code or ERROR.search(text):raise RuntimeError(label+' process/diagnostic failure')
            if mode:
                match=RESULT.search(text)
                if not match or match[2]!=mode:raise RuntimeError(label+' missing completion marker')
                return int(match[1])
            return 0
        paths=list(FILES)
        for directory in ['game/world/northline_native','game/presentation/northline_native','assets/world/northline_native']:
            paths.extend(p.relative_to(ROOT).as_posix() for p in (ROOT/directory).rglob('*') if p.is_file() and p.suffix not in ('.pyc',))
        paths=sorted(set(paths));before={p:digest(ROOT/p) for p in paths}
        with tempfile.TemporaryDirectory(prefix='northline-native-gate-') as temp:
            project=Path(temp)/'project';project.mkdir()
            for name in paths:
                dest=project/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,dest)
            (project/'project.godot').write_text(PROJECT)
            base=[engine,'--path',str(project),'--resolution','1920x1080','--audio-driver','Dummy']
            execute('import',base+['--headless','--editor','--import','--quit'])
            totals=[]
            edit=Path(temp)/'edited.tscn'
            captures=[]
            for index in (1,2):
                out=args.output/f'run{index}';out.mkdir()
                totals.append(execute(f'run{index}',base+['--script','res://tests/presentation/northline_native_contract.gd','--','--output='+str(out.resolve()),'--edited='+str(edit)],'full'))
                values={p.name:digest(p) for p in out.glob('*.png')}
                if len(values)!=4:raise RuntimeError('four physical renderer captures required; no headless visual pass')
                captures.append(values)
            totals.append(execute('reopen',base+['--script','res://tests/presentation/northline_native_contract.gd','--','--mode=reopen','--edited='+str(edit)],'reopen'))
            if captures[0]!=captures[1]:raise RuntimeError('repeated captures differ')
        if before!={p:digest(ROOT/p) for p in paths}:raise RuntimeError('canonical source changed')
        report={'engine':PIN,'process_checks':totals,'checks':sum(totals),'failures':0,
                'output':[1920,1080],'logical_camera_footprint':[640,360],
                'render_surface':[1920,1080],'screenshots':captures[0],'source_files':before,
                'scope':'native saved freight slice, source pixels, collision and serialized-edit reopening; not full game or clean graphical editor acceptance'}
        (args.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print('NATIVE_FREIGHT_GATE checks=%d failures=0'%sum(totals));return 0
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
        print('NATIVE_FREIGHT_GATE_BLOCKED:',exc);return 2
if __name__=='__main__':raise SystemExit(main())
