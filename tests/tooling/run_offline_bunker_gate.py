#!/usr/bin/env python3
"""Full native offline UI flow, two fresh processes; never use the user's save.

Run on the combined-native supported host. --graphical saves guarded 1080 PNGs.
No fixture loadout/provider or production-source substitutions are made.
"""
from __future__ import annotations
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
ERROR = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|OFFLINE_FLOW_ASSERTION", re.M)
RESULT = re.compile(r"OFFLINE_BUNKER_RESULT checks=([1-9][0-9]*) failures=0 mode=(create|continue)")

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--graphical', action='store_true')
    args = parser.parse_args()
    engine = str(args.godot.expanduser().resolve(strict=True))
    if args.output.exists():
        raise SystemExit('Output must be a new directory')
    args.output.mkdir(parents=True)
    env = {**os.environ, 'GODOT_SILENCE_ROOT_WARNING': '1'}
    def execute(name, cmd, marker=False):
        print('RUN',name,flush=True)
        try:
            p = subprocess.run(cmd, env=env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=180)
            text, code = p.stdout, p.returncode
        except subprocess.TimeoutExpired as exc:
            text = exc.stdout or b''
            text = text.decode(errors='replace') if isinstance(text,bytes) else text
            code = 124
        (args.output / (name+'.log')).write_text(text)
        print(text,flush=True)
        if code or ERROR.search(text) or (marker and not RESULT.search(text)):
            raise RuntimeError(f'{name} failed (exit={code})')
        return text
    try:
        version = execute('version',[engine,'--version']).strip()
        assert version == json.loads((ROOT/'config/toolchain.lock.json').read_text())['engine']['required_version']
        with tempfile.TemporaryDirectory(prefix='zerkov-offline-native-') as tmp:
            project = Path(tmp)/'project'
            shutil.copytree(ROOT, project, ignore=shutil.ignore_patterns('.git','.godot','__pycache__','.codegraph'))
            # Only the isolated test project's USER DATA namespace is changed.
            # Startup scene, UI, addons and all production scripts stay byte-identical.
            settings = project/'project.godot'
            text = settings.read_text()
            namespace = 'zerkov_offline_test_' + uuid.uuid4().hex
            text = text.replace('[application]', '[application]\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="'+namespace+'"', 1)
            settings.write_text(text)
            base = [engine, '--path',str(project),'--resolution','1920x1080','--audio-driver','Dummy']
            execute('import', base+['--headless','--editor','--import','--quit'])
            totals=[]
            for mode in ['create','continue']:
                capture = args.output/mode
                capture.mkdir()
                command = base+([] if args.graphical else ['--headless'])+['--script','res://tests/presentation/offline_bunker_flow.gd','--','--offline-case='+mode]
                if args.graphical:
                    command+=['--capture-dir='+str(capture.resolve())]
                result=execute(mode,command,True)
                totals.append(int(RESULT.search(result)[1]))
            report={'engine':version,'checks':sum(totals),'failures':0,'processes':2,
                    'graphical':args.graphical,'output':[1920,1080],
                    'source_files':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'game/offline').glob('*.gd'))},
                    'scope':'normal offline startup, bunker and persistent native inventory; no raid or multiplayer'}
            (args.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
            print('OFFLINE_BUNKER_GATE',json.dumps(report),flush=True)
        return 0
    except (OSError,RuntimeError,AssertionError) as exc:
        print('OFFLINE_BUNKER_GATE_FAILED',str(exc),flush=True)
        return 1
if __name__=='__main__':
    raise SystemExit(main())
