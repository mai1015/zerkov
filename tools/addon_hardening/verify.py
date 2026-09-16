#!/usr/bin/env python3
"""Load only newly built candidates via explicit extension registration.
No changes to the source checkout. Automatic first editor discovery/export is
NOT tested by this loader; the observed baseline abort is documented separately.
"""
from pathlib import Path
import argparse, json, hashlib, shutil, subprocess, os, re, sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(args):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=150,
                           env={**os.environ, 'GODOT_SILENCE_ROOT_WARNING': '1'})
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b''
        print(output.decode(errors='replace') if isinstance(output, bytes) else output, flush=True)
        raise
    print(p.stdout, flush=True)
    if p.returncode or re.search(r'SCRIPT ERROR|(?m:^\s*ERROR:)', p.stdout):
        raise RuntimeError(f'native execution failed exit={p.returncode} command={args}')
    return p.stdout


def require_pass(output):
    matches = re.findall(r'(?m)^ADDON_HARDENING_RESULT checks=([1-9]\d*) failures=0 real_enet_peers=3 native=true$', output)
    if len(matches) != 1:
        raise RuntimeError('Missing unique nonempty native pass marker')
    return int(matches[0])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--godot', type=Path, required=True)
    p.add_argument('--platform', choices=['linux', 'macos', 'windows'], required=True)
    p.add_argument('--arch', required=True)
    p.add_argument('--target', choices=['template_debug', 'template_release'], required=True)
    a = p.parse_args()
    root, candidate, godot = a.root.resolve(), a.candidate.resolve(), a.godot.resolve()
    if candidate.is_relative_to(root) or root.is_relative_to(candidate):
        raise ValueError('Candidate must be outside the source checkout')
    lock = json.loads((root / 'config/toolchain.lock.json').read_text())
    if execute([str(godot), '--version']).strip() != lock['engine']['required_version']:
        raise ValueError('Engine differs from the exact lock')
    provenance = json.loads((candidate / 'candidate-source.json').read_text())
    for name, expected in provenance['source_files'].items():
        path = candidate / name
        if not path.resolve().is_relative_to(candidate) or path.is_symlink() or digest(path) != expected:
            raise ValueError('Staged source changed after verification: ' + name)
    changes = json.loads((root / 'tools/addon_hardening/changes.json').read_text())
    for row in changes['changes']:
        if provenance['changed_files'].get(row['path']) != row['after']:
            raise ValueError('Build source differs from current reviewed candidate')
    project = candidate / ('test-' + a.target)
    if project.is_symlink():
        raise ValueError('Test project must not be a symlink')
    if project.exists():
        shutil.rmtree(project)
    project.mkdir()
    artifacts, descriptors = {}, []
    suffix = {'linux': '.so', 'macos': '.dylib', 'windows': '.dll'}[a.platform]
    for name in ['weapon_system', 'gameplay_abilities']:
        lib = candidate / 'addons' / name / 'bin' / f'lib{name}.{a.platform}.{a.target}.{a.arch}{suffix}'
        if not lib.is_file():
            raise RuntimeError('Missing newly-built artifact: ' + str(lib))
        addon = project / 'addons' / name
        (addon / 'bin').mkdir(parents=True)
        shutil.copyfile(lib, addon / 'bin' / lib.name)
        artifacts[str(lib.relative_to(candidate))] = digest(lib)
        descriptor = f'[configuration]\nentry_symbol = "{name}_library_init"\ncompatibility_minimum = "4.7"\nreloadable = false\n[libraries]\n'
        for target in ['debug', 'release']:
            key = f'{a.platform}.{target}' + ('' if a.platform == 'macos' else '.x86_64')
            descriptor += f'{key} = "res://addons/{name}/bin/{lib.name}"\n'
        (addon / f'{name}.gdextension').write_text(descriptor)
        descriptors.append(f'res://addons/{name}/{name}.gdextension')
    for path in ['game/combat/content/zerkov_combat_content.gd', 'game/combat/melee/melee_policy.gd',
                 'game/domain/z_world_units.gd', 'game/domain/z_unit_conversion.gd']:
        out = project / path
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / path, out)
    test_source = root / 'tools/addon_hardening/tests/bridge_contract.gd.in'
    (project / 'contract.gd').write_bytes(test_source.read_bytes())
    (project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Native addon candidate security contract"\n[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    # Start with explicit known extensions. This is not a cached import, a retry,
    # or suppression of nonzero engine exit codes. No script/import cache copied.
    (project / '.godot').mkdir()
    (project / '.godot/extension_list.cfg').write_text('\n'.join(descriptors) + '\n')
    base = [str(godot), '--headless', '--resolution', '1920x1080', '--max-fps', '120',
            '--path', str(project), '--audio-driver', 'Dummy']
    execute(base + ['--editor', '--import', '--quit'])
    outputs = []
    for _ in range(2):
        output = execute(base + ['--script', 'res://contract.gd'])
        require_pass(output)
        outputs.append(output)
    report = {'candidate_source': provenance, 'platform': a.platform, 'arch': a.arch,
              'configuration': a.target, 'engine': lock['engine']['required_version'],
              'artifacts': artifacts, 'test_source_sha256': digest(test_source),
              'native_outputs': outputs, 'runs': 2,
              'extension_loading': 'explicit_startup_registration',
              'automatic_editor_discovery_tested': False,
              'upstream_signoff': False, 'installed': False, 'export_tested': False}
    (candidate / (a.target + '-verification.json')).write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, AssertionError, RuntimeError, subprocess.SubprocessError) as error:
        print('ADDON_HARDENING_FAILED', error, file=sys.stderr)
        sys.exit(1)
