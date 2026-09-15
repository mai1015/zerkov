#!/usr/bin/env python3
"""Task 7 source-isolated and real-native contracts; source caches stay untouched."""
from __future__ import annotations
import argparse, json, os, re, shutil, subprocess, tempfile, uuid
from pathlib import Path
PURE = (
    'game/domain/z_identity_rules.gd', 'game/raid/raid_clock.gd',
    'game/profile/profile_store.gd', 'game/profile/profile_canonical_codec.gd',
    'game/profile/profile_file_operations.gd', 'game/profile/godot_profile_file_operations.gd',
    'game/raid/progression/raid_progression_values.gd', 'game/raid/progression/settlement_inventory_port.gd',
    'game/raid/progression/raid_settlement_service.gd', 'game/raid/progression/extraction_countdown.gd',
    'tests/raid/profile_store_contract.gd', 'tests/raid/raid_progression_contract.gd',
)
PROJECT = '''config_version=5
[application]
config/name="Raid progression contracts"
config/use_custom_user_dir=true
config/custom_user_dir_name="zerkov_task7_test"
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''
ERROR = re.compile(r'SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|RUNNER_FAILED')
def execute(command, marker=None, environment=None):
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=120, env=environment)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        print(output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output, flush=True)
        raise
    print(result.stdout, end='', flush=True)
    if result.returncode or ERROR.search(result.stdout):
        raise RuntimeError(f'Execution/diagnostics failed: {command} (exit {result.returncode})')
    if marker and not re.search(rf'(?m)^{marker} checks=[1-9][0-9]* failures=0(?:\s|$)', result.stdout):
        raise RuntimeError(f'Missing passing completion: {marker}')
    return result.stdout

def restart(godot_base, environment):
    namespace = "task7_" + uuid.uuid4().hex
    prefix = godot_base + ['--script', 'res://tests/raid/raid_restart_contract.gd', '--']
    try:
        prepared = execute(prefix + ['prepare', namespace], 'RAID_RESTART_RESULT', environment)
        digest = re.search(r"mode=prepare input=([a-f0-9]{64})", prepared)
        if not digest:
            raise RuntimeError("Missing prepared restart digest")
        recovered = execute(prefix + ['recover', namespace, digest[1]], 'RAID_RESTART_RESULT', environment)
        final = re.search(r"mode=recover input=" + digest[1] + r" profile=([a-f0-9]{64})", recovered)
        if not final:
            raise RuntimeError("Missing committed restart fingerprint")
        execute(prefix + ['verify', namespace, digest[1], final[1]], 'RAID_RESTART_RESULT', environment)
    finally:
        execute(prefix + ['cleanup', namespace], 'RAID_RESTART_CLEANUP', environment)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot',type=Path,required=True)
    parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    try:
        expected=json.loads((root/'config/toolchain.lock.json').read_text())['engine']['required_version']
        godot=str(args.godot.expanduser().resolve(strict=True))
        env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1'}
        if execute([godot,'--version'],environment=env).strip()!=expected:
            raise RuntimeError('Engine does not match checked-in lock')
        with tempfile.TemporaryDirectory(prefix='zerkov-progression-') as tmp:
            p=Path(tmp)/'project'
            if args.native:
                shutil.copytree(root,p,ignore=shutil.ignore_patterns('.git','.godot','.codegraph','__pycache__'))
            else:
                p.mkdir();(p/'project.godot').write_text(PROJECT)
                for relative in PURE:
                    dst=p/relative;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/relative,dst)
            env['XDG_DATA_HOME']=str(Path(tmp)/'user')
            base=[godot,'--headless','--path',str(p),'--resolution','1920x1080','--audio-driver','Dummy']
            execute(base+['--editor','--import','--quit'],environment=env)
            for _ in range(2):
                execute(base+['--script','res://tests/raid/raid_progression_contract.gd'],'RAID_PROGRESSION_RESULT',env)
            if args.native:
                execute(base+['--script','res://tests/raid/native_raid_progression_contract.gd'],'NATIVE_RAID_PROGRESSION_RESULT',env)
                restart(base, env)
            execute(base+['--script','res://tests/raid/profile_store_contract.gd'],'PROFILE_STORE_RESULT',env)
        print('RAID_PROGRESSION_RUNNER_COMPLETE mode='+('native' if args.native else 'isolated'))
        return 0
    except (OSError,ValueError,KeyError,RuntimeError,subprocess.TimeoutExpired) as exc:
        print('RAID_PROGRESSION_RUNNER_FAILED:',exc,flush=True);return 1
if __name__=='__main__':
    raise SystemExit(main())
