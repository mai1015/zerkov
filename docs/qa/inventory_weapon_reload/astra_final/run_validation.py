#!/usr/bin/env python3
"""Fresh Astra 4.9 validation. Only this new QA packet is writable."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import time

ROOT = pathlib.Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_weapon_reload/astra_final'
ENGINE = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
SPEC = '/Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py'
SOURCES = [
    'game/content/zerkov_inventory_catalog.gd',
    'game/domain/ports/weapon_reload_participant_port.gd',
    'game/domain/ports/weapon_reload_participant_port.gd.uid',
    'game/inventory/equipment/weapon_authority_reload_port.gd',
    'game/inventory/equipment/weapon_authority_reload_port.gd.uid',
    'game/inventory/equipment/inventory_weapon_adapter.gd',
    'game/inventory/equipment/inventory_weapon_adapter.gd.uid',
    'tests/raid/inventory_catalog_contract.gd',
    'tests/raid/inventory_weapon_reload_contract.gd',
    'tests/raid/inventory_weapon_reload_contract.gd.uid',
]
DEPENDENCIES = [
    'project.godot', 'config/addons.lock.json', 'config/toolchain.lock.json',
    'game/raid/raid_inventory_owner.gd',
    'game/inventory/equipment/equipped_item_reconciler.gd',
    'game/combat/content/zerkov_combat_content.gd',
    'addons/inventory_system/native/godot/inventory_authority.h',
    'addons/inventory_system/native/godot/inventory_authority.cpp',
    'addons/inventory_system/native/core/inv_runtime_state.cpp',
    'addons/inventory_system/native/core/inv_quantity_reservations.h',
    'addons/inventory_system/native/core/inv_quantity_reservations.cpp',
    'addons/inventory_system/native/core/inv_transaction.cpp',
    'addons/weapon_system/native/godot/weapon_authority.h',
    'addons/weapon_system/native/godot/weapon_authority.cpp',
    'addons/weapon_system/native/core/wpn_runtime.h',
    'addons/weapon_system/native/core/wpn_runtime.cpp',
    'addons/inventory_system/bin/libinventory_system.macos.template_debug.universal.dylib',
    'addons/weapon_system/bin/libweapon_system.macos.template_debug.universal.dylib',
    ENGINE,
]
SUITES = [
    ('tests/raid/inventory_catalog_contract.gd', 537),
    ('tests/raid/inventory_weapon_reload_contract.gd', 159),
    ('tests/raid/inventory_authority_contract.gd', 79),
    ('tests/raid/identity_contract.gd', 18442),
    ('tests/raid/equipped_item_reconciliation_contract.gd', 123),
    ('tests/combat/content_contract.gd', 79),
    ('tests/raid/session_lifecycle_contract.gd', 44),
    ('tests/raid/authority_replay_contract.gd', 81),
    ('tests/raid/units_clock_contract.gd', None),
    ('tests/raid/inventory_projection_contract.gd', 99),
    ('tests/raid/inventory_intent_adapter_contract.gd', 162),
    ('tests/raid/inventory_mutation_routing_contract.gd', 146),
    ('tests/raid/inventory_ui_binding_contract.gd', None),
    ('tests/raid/inventory_multi_controller_contract.gd', None),
    ('tests/addons/combined_addons_smoke.gd', 155),
]
DIAGNOSTICS = re.compile(
    r'(?im)^.*(?:\bERROR\b|SCRIPT ERROR|assertion|stack overflow|'
    r'ObjectDB[^\n]*leak|RID[^\n]*leak|resources still in use|font[^\n]*leak|'
    r'\bWARNING\b|\bTIMEOUT\b).*$')


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cmd_output(args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


def baseline():
    if (OUT / 'baseline.json').exists():
        return
    seals = ROOT / 'docs/qa/inventory_weapon_reload/astra_gate/packet_hashes.sha256'
    seal_check = subprocess.run(['shasum', '-a', '256', '-c', str(seals)],
                                cwd=ROOT, capture_output=True, text=True)
    (OUT / 'prior_packet_integrity_before.log').write_text(seal_check.stdout + seal_check.stderr)
    assert seal_check.returncode == 0, 'The prior REJECT packet seal must verify'
    addon_names = cmd_output(['git', 'ls-files', 'addons']).splitlines()
    specs = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'docs/spec').rglob('*') if p.is_file())
    write_json(OUT / 'reviewed_hashes.json', {p: digest(ROOT / p) for p in SOURCES})
    write_json(OUT / 'dependency_hashes.json', {p: digest(ROOT / p) for p in DEPENDENCIES if (ROOT / p).is_file()})
    write_json(OUT / 'addon_hashes.json', {p: digest(ROOT / p) for p in addon_names if (ROOT / p).is_file()})
    write_json(OUT / 'spec_hashes.json', {p: digest(ROOT / p) for p in specs})
    write_json(OUT / 'baseline.json', {
        'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'parent_commit': cmd_output(['git', 'rev-parse', 'HEAD']).strip(),
        'status': cmd_output(['git', 'status', '--short']),
        'engine': ENGINE,
        'engine_version': cmd_output([ENGINE, '--version']).strip(),
        'human_approval': False,
        'prior_packet_entries': len(seal_check.stdout.splitlines()),
        'addon_files_hashed': len(addon_names),
        'processes_before': cmd_output(['ps', '-axo', 'pid=,ppid=,comm=']),
    })


def archive(name):
    paths = [p for p in OUT.glob(name + '*') if p.is_file()]
    if not paths:
        return
    dest = OUT / 'history' / (name + '_' + str(time.time_ns()))
    dest.mkdir(parents=True)
    for p in paths:
        shutil.move(str(p), str(dest / p.name))
    for p in OUT.glob('independent_*.gd*'):
        shutil.copy2(p, dest / p.name)
    shutil.copy2(__file__, dest / pathlib.Path(__file__).name)


def run(name, args, expected=None, require_result=False, timeout=90):
    archive(name)
    start = time.monotonic()
    proc = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, start_new_session=True)
    timed_out = False
    cleanup_actions = []
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGTERM)
        cleanup_actions.append('SIGTERM process group after timeout')
        try:
            output, _ = proc.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            cleanup_actions.append('SIGKILL process group after grace period')
            output, _ = proc.communicate()
    (OUT / (name + '.log')).write_text(output)
    result_lines = [s for s in output.splitlines() if re.search(r'checks=\d+\s+failures=\d+', s)]
    matches = re.findall(r'checks=(\d+)\s+failures=(\d+)', output)
    diagnostics = DIAGNOSTICS.findall(output)
    checks, failures = (map(int, matches[-1]) if matches else (None, None))
    passed = (proc.returncode == 0 and not timed_out and not diagnostics
              and (not require_result or (len(matches) == 1 and failures == 0))
              and (expected is None or checks == expected))
    result = dict(name=name, command=args, pid=proc.pid, exit_code=proc.returncode,
                  elapsed_seconds=round(time.monotonic() - start, 3), timed_out=timed_out,
                  expected_checks=expected, checks=checks, failures=failures,
                  result_lines=result_lines, diagnostics=diagnostics,
                  cleanup_actions=cleanup_actions, reaped=True, passed=passed)
    write_json(OUT / (name + '_runner.json'), result)
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['baseline', 'flow', 'capacity', 'native', 'suites'])
    args = parser.parse_args()
    baseline()
    if args.mode == 'baseline':
        print('BASELINE_RECORDED', flush=True)
        return
    results = []
    if args.mode in ['flow', 'capacity', 'native']:
        script = 'independent_capacity.gd' if args.mode == 'capacity' else 'independent_flow.gd'
        engine_args = [ENGINE, '--path', str(ROOT), '--rendering-method', 'gl_compatibility']
        if args.mode == 'native':
            engine_args += ['--resolution', '1280x720', '--position', '40,40']
        else:
            engine_args += ['--headless']
        results.append(run(args.mode, engine_args + ['--script', 'res://docs/qa/inventory_weapon_reload/astra_final/' + script], require_result=True))
    else:
        for script, expected in SUITES:
            results.append(run(pathlib.Path(script).stem,
                [ENGINE, '--headless', '--path', str(ROOT), '--script', 'res://' + script],
                expected=expected, require_result=True))
        results.append(run('editor_import', [ENGINE, '--headless', '--editor', '--path', str(ROOT), '--quit'], timeout=120))
        results.append(run('spec_strict', ['python3', SPEC, '--path', str(ROOT), 'validate',
            'add-zerkov-playable-raid-2026-09-09', '--strict', '--json']))
        results.append(run('diff_check', ['git', 'diff', '--check']))
    write_json(OUT / (args.mode + '_suite.json'), {
        'human_approval': False, 'results': results,
        'raw_checks': sum(r['checks'] or 0 for r in results),
        'failures': sum(r['failures'] or 0 for r in results),
        'passed': all(r['passed'] for r in results),
    })
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__':
    main()
