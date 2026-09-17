#!/usr/bin/env python3
"""Original-art full Northline native scenes; two renders plus independent edit reopen.

Requires provisioned original PNGs and a graphical exact-1080 display. Copies the
saved scenes rather than regenerating them. Never touches a product profile.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PIN = '4.7.2.stable.official.ed1daf0bf'
ERROR = re.compile(r'SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|NATIVE_ZONE_ASSERT')
RESULT = re.compile(r'NATIVE_ZONE_RESULT checks=([1-9][0-9]*) failures=0 mode=(full|reopen)')
FILES = [
    'game/presentation/northline_zone/review_walker.gd',
    'game/presentation/northline_zone/review_locomotion_pose.gd',
    'game/presentation/northline_zone/zone.json',
    'assets/world/map_studies/atlas.json',
    'assets/world/northline_zone/review_outfit.webp',
    'assets/world/northline_zone/review_outfit.webp.import',
    'game/presentation/exact_1080_capture_guard.gd',
    'tests/presentation/northline_native_zone_contract.gd',
]
PROJECT = '''config_version=5
[application]
config/name="Northline native full-map review"
run/main_scene="res://game/presentation/northline_native/zone_review.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        spec = importlib.util.spec_from_file_location('source_installer', ROOT/'tools/install_northline_native_sources.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.verify(ROOT, module.manifest_at())
        engine = str(args.godot.resolve(strict=True))
        env = {**os.environ, 'GODOT_SILENCE_ROOT_WARNING':'1'}
        if subprocess.check_output([engine, '--version'], text=True, env=env).strip() != PIN:
            raise RuntimeError('wrong native engine')
        if args.output.exists():
            raise RuntimeError('output must be a fresh directory')
        args.output.mkdir(parents=True)

        def execute(label: str, command: list[str], mode: str | None = None) -> int:
            try:
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
                text, code = result.stdout+result.stderr, result.returncode
            except subprocess.TimeoutExpired as exc:
                data = exc.stdout or b''
                text = data.decode(errors='replace') if isinstance(data, bytes) else data
                code = 124
            (args.output/(label+'.log')).write_text(text)
            print(text, flush=True)
            if code or ERROR.search(text):
                raise RuntimeError(f'{label}: process/diagnostic failure, exit {code}')
            if mode:
                match = RESULT.search(text)
                if not match or match[2] != mode:
                    raise RuntimeError(label+': missing completion marker')
                return int(match[1])
            return 0

        files = list(FILES)
        for directory in ['game/world/northline_native','game/presentation/northline_native','assets/world/northline_native']:
            files.extend(p.relative_to(ROOT).as_posix() for p in (ROOT/directory).rglob('*')
                         if p.is_file() and p.suffix not in {'.pyc'})
        files = sorted(set(files))
        before = {n:digest(ROOT/n) for n in files}
        with tempfile.TemporaryDirectory(prefix='northline-full-native-') as temp:
            project = Path(temp)/'project'
            project.mkdir()
            for name in files:
                target=project/name
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(ROOT/name,target)
            (project/'project.godot').write_text(PROJECT)
            base=[engine,'--path',str(project),'--resolution','1920x1080','--audio-driver','Dummy']
            execute('import',base+['--headless','--editor','--import','--quit'])
            edit=Path(temp)/'edited.tscn'
            counts=[]; captures=[]
            for run in (1,2):
                output=args.output/f'run{run}'
                output.mkdir()
                counts.append(execute(f'run{run}',base+['--script','res://tests/presentation/northline_native_zone_contract.gd','--',
                    '--output='+str(output.resolve()),'--edited='+str(edit)],'full'))
                hashes={p.name:digest(p) for p in output.glob('*.png')}
                if len(hashes)!=12:
                    raise RuntimeError('twelve physical screenshots required; headless is not visual evidence')
                captures.append(hashes)
            counts.append(execute('reopen',base+['--headless','--script','res://tests/presentation/northline_native_zone_contract.gd','--',
                '--mode=reopen','--edited='+str(edit)],'reopen'))
            if captures[0]!=captures[1]:
                raise RuntimeError('repeated native PNGs differ')
        if before != {n:digest(ROOT/n) for n in files}:
            raise RuntimeError('canonical resource changed during test')
        report={'engine':PIN,'process_checks':counts,'checks':sum(counts),'failures':0,
                'districts':9,'interiors':19,'props':541,'solid_props':528,'static_solids':153,
                'render_surface':[1920,1080],'logical_detail_footprint':[640,360],
                'screenshots':captures[0],'source_files':before,
                'scope':'saved native full-map environment and collision review; not live raid or target-hardware performance'}
        (args.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print('FULL_NATIVE_ZONE_GATE checks=%d failures=0'%sum(counts))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print('FULL_NATIVE_ZONE_BLOCKED:',exc)
        return 2

if __name__=='__main__':
    raise SystemExit(main())
