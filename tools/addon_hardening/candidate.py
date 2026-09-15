#!/usr/bin/env python3
"""Stage/rebuild/test addon repair candidates, NEVER modify the checked-in addon pin.

Patches are applied only to a newly created external workspace. All changed paths
are declared with exact pre/postimage SHA-256s; deletions, renames, escapes,
symlinks and unlisted mutations fail. No network access or Git writes upstream.
The caller supplies the checked-out exact godot-cpp SDK and locked engine.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
KIT = Path(__file__).resolve().parent
PACKAGES = ('weapon_system', 'gameplay_abilities')
ERROR = re.compile(r'SCRIPT ERROR|(?m:^\s*(?:ERROR:|Parse Error:))')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe(root: Path, name: str) -> Path:
    part = PurePosixPath(name)
    if not name or part.is_absolute() or '..' in part.parts or '\\' in name or ':' in name:
        raise ValueError(f'unsafe path: {name!r}')
    file = root
    for piece in part.parts:
        file /= piece
        if file.is_symlink(): raise ValueError(f'symlink: {file}')
    if not file.resolve().is_relative_to(root.resolve()): raise ValueError('path escape')
    return file


def files(root: Path) -> dict[str, str]:
    found = {}
    for file in root.rglob('*'):
        if '.git' in file.relative_to(root).parts: continue
        if file.is_symlink(): raise ValueError(f'symlink: {file}')
        if file.is_file(): found[file.relative_to(root).as_posix()] = sha(file)
    return found


def run(cmd: list[str], *, cwd: Path, log: Path | None = None,
        marker: str | None = None, timeout: int = 300, env: dict | None = None) -> str:
    # Logs are outside the source checkout; keep real compiler/engine diagnostics.
    try:
        result = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        text = result.stdout
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or b''
        if isinstance(text, bytes): text = text.decode('utf-8', 'replace')
        if log: log.write_text(text, encoding='utf-8')
        print(text, flush=True)
        raise
    if log: log.write_text(text, encoding='utf-8')
    print(text, flush=True)
    if result.returncode or ERROR.search(text): raise RuntimeError(f'failed: {cmd}; exit={result.returncode}')
    if marker and not re.search(rf'(?m)^{re.escape(marker)} checks=\d+ failures=0(?:\s|$)', text):
        raise RuntimeError(f'missing zero-failure marker {marker}')
    return text


def stage(root: Path, out: Path) -> dict:
    root = root.resolve()
    if out.is_symlink() or out.exists() or out.resolve().is_relative_to(root):
        raise ValueError('candidate output must be a NEW directory outside source checkout')
    for ancestor in out.absolute().parents:
        if ancestor.is_symlink(): raise ValueError('symlink output ancestor')
    manifest = json.loads((KIT / 'manifest.json').read_text())
    if manifest['installed_update'] is not False: raise ValueError('not an installed update')
    patches = [safe(KIT, name) for name in manifest.get('patches', ['native-hardening.patch'])]
    if not patches or hashlib.sha256(b''.join(p.read_bytes() for p in patches)).hexdigest() != manifest['patch_sha256']:
        raise ValueError('patch checksum mismatch')
    for name, record in manifest['files'].items():
        if not any(name.startswith(f'addons/{pkg}/native/') for pkg in PACKAGES):
            raise ValueError('patch outside candidate native sources')
        file = safe(root, name)
        if (sha(file) if file.is_file() else None) != record['before']:
            raise ValueError(f'candidate preimage differs; reconcile owning source first: {name}')
        if not re.fullmatch(r'[a-f0-9]{64}', record['after']): raise ValueError('invalid postimage hash')
    out.mkdir(parents=True)
    project = out / 'project'
    project.mkdir()
    for package in PACKAGES:
        source = safe(root, f'addons/{package}')
        files(source)  # Reject symlinks before copying anything from package.
        shutil.copytree(source, project / 'addons' / package)
    before = files(project)
    run(['git', 'init', '-q'], cwd=project)
    for patch in patches:
        run(['git', 'apply', '--check', str(patch)], cwd=project)
        run(['git', 'apply', str(patch)], cwd=project)
    after = files(project)
    changed = {n for n in before.keys() | after.keys() if before.get(n) != after.get(n)}
    if changed != set(manifest['files']): raise ValueError('undeclared change, rename or deletion in patch')
    for name, record in manifest['files'].items():
        if after.get(name) != record['after']: raise ValueError(f'postimage mismatch: {name}')
    # Include all source bytes in the evidence, not binary-free packet claims.
    provenance = {'candidate_only': True, 'installed_update': False,
                  'base_revision': manifest['base_revision'], 'patch_sha256': manifest['patch_sha256'],
                  'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                  'before': before, 'after_patch': after}
    (out / 'source-provenance.json').write_text(json.dumps(provenance, sort_keys=True, indent=2)+'\n')
    shutil.copyfile(KIT / 'fixtures/SConstruct', out / 'SConstruct')
    shutil.copyfile(KIT / 'fixtures/native_network_contract.gd.in', project / 'contract.gd')
    # The same real Resource and dictionary definitions drive both peer catalogs.
    # These are unchanged game-owned test inputs, not a substitute native catalog.
    for relative in ['game/combat/content/zerkov_combat_content.gd', 'game/combat/melee/melee_policy.gd']:
        shutil.copyfile(safe(root, relative), project / Path(relative).name)
    (project / 'project.godot').write_text('''config_version=5
[application]
config/name="Isolated addon hardening candidate"
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
[rendering]
renderer/rendering_method="gl_compatibility"
''')
    return provenance


def core_test(project: Path, out: Path, compiler: str = 'g++') -> None:
    native = project / 'addons/weapon_system/native'
    binary = out / 'weapon-policy-test'
    sources = sorted(str(p) for folder in ['core', 'protocol'] for p in (native / folder).glob('*.cpp'))
    run([compiler, '-std=c++17', '-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
         '-I'+str(native), str(KIT/'fixtures/weapon_policy_test.cpp'), *sources, '-o', str(binary)],
        cwd=out, log=out/'core-build.log', timeout=180)
    run([str(binary)], cwd=out, log=out/'core-test.log', marker='ADDON_POLICY_RESULT')


def build(root: Path, out: Path, sdk: Path, godot: Path, jobs: int) -> None:
    lock = json.loads((root/'config/toolchain.lock.json').read_text())
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=sdk, text=True).strip()
    if actual != lock['native_sdk']['godot_cpp_commit']: raise ValueError('godot-cpp pin mismatch')
    env = {**os.environ, 'GODOT_CPP_ROOT': str(sdk), 'ADDON_CANDIDATE_PROJECT': str(out/'project'),
           'GODOT_SILENCE_ROOT_WARNING': '1'}
    version = subprocess.check_output([str(godot), '--headless', '--version'], env=env, text=True).strip()
    if version != lock['engine']['required_version']: raise ValueError(f'engine mismatch: {version}')
    platform = 'macos' if sys.platform == 'darwin' else 'linux' if sys.platform.startswith('linux') else 'windows'
    arch = 'arm64' if platform == 'macos' and os.uname().machine == 'arm64' else 'x86_64'
    # Trim the SDK to classes actually included by the two real addons and harness.
    api = json.loads((sdk/'gdextension/extension_api.json').read_text())
    names = {re.sub(r'(?<!^)(?=[A-Z])', '_', item['name']).lower(): item['name'] for item in api['classes']}
    # godot-cpp acronym conversion differs from the simple map. Derive requested
    # names via the generator's public utility, with explicit critical classes.
    included = {'Node','Resource','RefCounted','Object','Crypto','MultiplayerAPI','MultiplayerPeer',
                'SceneMultiplayer','ENetMultiplayerPeer','ENetConnection','SceneTree','Window'}
    for file in (out/'project/addons').rglob('*'):
        if file.suffix not in {'.cpp','.h','.hpp'}: continue
        for stem in re.findall(r'godot_cpp/classes/([a-z0-9_]+)\.hpp', file.read_text()):
            match = next((v['name'] for v in api['classes'] if re.sub('[^a-z0-9]','',v['name'].lower()) == stem.replace('_','')), None)
            if not match: raise ValueError(f'unresolved Godot class include: {stem}')
            included.add(match)
    profile = out/'build-profile.json'
    profile.write_text(json.dumps({'enabled_classes': sorted(included)}))
    run([sys.executable, '-m', 'SCons', '-j'+str(jobs), f'platform={platform}', f'arch={arch}',
         'target=template_debug', 'dev_build=no', 'generate_bindings=yes', 'build_profile='+str(profile)],
        cwd=out, env=env, log=out/'native-build.log', timeout=1800)
    extension = '.dll' if platform == 'windows' else '.dylib' if platform == 'macos' else '.so'
    records = []
    for name in PACKAGES:
        folder = out/'project/addons'/name
        lib = folder/'bin'/f'lib{name}.{platform}.template_debug.{arch}{extension}'
        if not lib.is_file(): raise ValueError(f'candidate library missing: {lib}')
        (folder/f'{name}.gdextension').write_text(f'''[configuration]
entry_symbol = "{name}_library_init"
compatibility_minimum = "4.7"
[libraries]
{platform}.debug = "res://addons/{name}/bin/{lib.name}"
''')
        records.append({'addon':name, 'sha256':sha(lib),'path':lib.relative_to(out).as_posix(),
                        'platform':platform,'arch':arch,'build':'debug','candidate_only':True})
    (out/'candidate-build.json').write_text(json.dumps({'installed_update':False, 'godot_cpp':actual,
        'godot':version, 'artifacts':records},indent=2)+'\n')
    base = [str(godot), '--headless', '--resolution', '1920x1080', '--audio-driver', 'Dummy', '--path', str(out/'project')]
    run(base+['--editor','--import','--quit'],cwd=out,env=env,log=out/'native-import.log')
    run(base+['--script','res://contract.gd'],cwd=out,env=env,log=out/'network-test.log',marker='ADDON_NETWORK_RESULT',timeout=90)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=ROOT)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--sdk',type=Path)
    p.add_argument('--godot',type=Path)
    p.add_argument('--jobs',type=int,default=2)
    p.add_argument('--core',action='store_true')
    args=p.parse_args()
    try:
        if bool(args.sdk) != bool(args.godot) or not 1 <= args.jobs <= 16: raise ValueError('supply both SDK and engine; jobs 1..16')
        root=args.root.resolve();out=args.out.absolute()
        stage(root,out)
        if args.core: core_test(out/'project',out)
        if args.sdk: build(root,out,args.sdk.resolve(),args.godot.resolve(),args.jobs)
        print('ADDON_CANDIDATE_COMPLETE installed_update=false network_ready=false')
        return 0
    except (ValueError, OSError, RuntimeError, KeyError, subprocess.SubprocessError) as exc:
        print(f'ADDON_CANDIDATE_FAILED {exc}', file=sys.stderr)
        return 1
if __name__ == '__main__':
    raise SystemExit(main())
