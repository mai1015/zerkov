#!/usr/bin/env python3
"""Fresh Astra 4.10 gate. Authored and generated files stay in this QA packet."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical 1280x720 QA packet runner is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import time

ROOT = pathlib.Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_ability_equipment/astra_final'
ENGINE = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
SPEC = '/Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py'
FROZEN = {
    'tests/raid/inventory_ability_reconciliation_contract.gd': '0f8ea4e3b7308aa759cb2db789a2cc1408678a11cf57d501a9a4583133f2922b',
    'game/inventory/equipment/inventory_ability_adapter.gd': 'd83f3137fe7b93b5bace8c97669cb9b07072fe221bca74515bcec9bea5b9f063',
    'game/domain/ports/equipment_ability_participant_port.gd': '87c1dd521353f76ce644a0066626c52f790fdbe9b16f48f4c18afbc6b45c9746',
    'game/inventory/equipment/gameplay_ability_equipment_port.gd': '87c9d4ccbc0e3147791e324eb60275b6ac00009c0c03c2c1e964fe98c94f25b6',
    'game/content/zerkov_equipment_ability_content.gd': '12d322f7285e665da540ff8ba55c8fae4ab79d672f28d43f3cd525ddc79a6481',
    'game/content/zerkov_inventory_catalog.gd': '12c581a92c14fa17f147e34acc7d891e58d966756e26986d3b5f8c4ac99247d1',
}
SUITES = [
    ('tests/raid/inventory_ability_reconciliation_contract.gd', None),
    ('tests/raid/inventory_catalog_contract.gd', 537),
    ('tests/raid/inventory_weapon_reload_contract.gd', 159),
    ('tests/raid/equipped_item_reconciliation_contract.gd', 123),
    ('tests/raid/inventory_authority_contract.gd', 79),
    ('tests/raid/identity_contract.gd', 18442),
    ('tests/raid/session_lifecycle_contract.gd', 44),
    ('tests/raid/authority_replay_contract.gd', 81),
    ('tests/raid/units_clock_contract.gd', None),
    ('tests/raid/inventory_projection_contract.gd', 99),
    ('tests/raid/inventory_intent_adapter_contract.gd', 162),
    ('tests/raid/inventory_mutation_routing_contract.gd', 146),
    ('tests/raid/inventory_ui_binding_contract.gd', None),
    ('tests/raid/inventory_multi_controller_contract.gd', None),
    ('tests/combat/content_contract.gd', 79),
    ('tests/addons/combined_addons_smoke.gd', 155),
]
DIAGNOSTICS = re.compile(r'(?im)^.*(?:\bERROR\b|SCRIPT ERROR|\bassertion\b|stack overflow|ObjectDB[^\n]*leak|RID[^\n]*leak|resources still in use|font[^\n]*leak|\bWARNING\b|\bTIMEOUT\b).*$')


def write_json(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cmd(args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True)


def listed_files(repo, paths=None):
    args = ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
    if paths:
        args += ['--'] + paths
    return sorted(set(p for p in cmd(args, repo).split('\0') if p))


def repo_inventory(repo, paths=None):
    names = listed_files(repo, paths)
    return {name: digest(repo / name) for name in names if (repo / name).is_file()}


def sibling_state(repo):
    probe = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=repo,
                           capture_output=True, text=True)
    if probe.returncode == 0:
        return {'path': str(repo), 'git': True,
                'head': cmd(['git', 'rev-parse', 'HEAD'], repo).strip(),
                'status': cmd(['git', 'status', '--short', '--untracked-files=all'], repo),
                'hashes': repo_inventory(repo)}
    excluded = {'.git', '.godot', '.codegraph', '.build', '__pycache__'}
    names = sorted(p for p in repo.rglob('*') if p.is_file()
                   and not any(part in excluded for part in p.relative_to(repo).parts)
                   and p.name != '.DS_Store')
    return {'path': str(repo), 'git': False,
            'method': 'Full file SHA-256 snapshot; generated cache directories excluded',
            'excluded_directories': sorted(excluded),
            'hashes': {str(p.relative_to(repo)): digest(p) for p in names}}


def godot_processes():
    rows = []
    for line in cmd(['ps', '-axo', 'pid=,ppid=,comm=']).splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and 'godot' in parts[2].lower():
            rows.append({'pid': int(parts[0]), 'ppid': int(parts[1]), 'executable': parts[2]})
    return rows


def baseline():
    if (OUT / 'baseline.json').exists():
        return
    actual = {p: digest(ROOT / p) for p in FROZEN}
    if actual != FROZEN:
        raise RuntimeError('Frozen source mismatch before validation')
    write_json('frozen_hashes.json', actual)
    write_json('project_hashes_before.json', repo_inventory(ROOT, ['game', 'tests', 'ui', 'config', 'project.godot', 'addons', 'docs/spec']))
    lock = json.loads((ROOT / 'config/addons.lock.json').read_text())
    siblings = {}
    for entry in lock['addons']:
        repo = pathlib.Path(entry['source']['repository_path'])
        siblings[entry['id']] = sibling_state(repo)
    write_json('sibling_addons_before.json', siblings)
    write_json('baseline.json', {
        'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'head': cmd(['git', 'rev-parse', 'HEAD']).strip(),
        'status': cmd(['git', 'status', '--short', '--untracked-files=all']),
        'staged_diff': cmd(['git', 'diff', '--cached']),
        'engine': ENGINE, 'engine_version': cmd([ENGINE, '--version']).strip(),
        'engine_sha256': digest(pathlib.Path(ENGINE)),
        'godot_processes_before': godot_processes(), 'human_approval': False,
    })
    changed = cmd(['git', 'diff', '--', 'game/content/zerkov_inventory_catalog.gd'])
    (OUT / 'reviewed_diff.patch').write_text(changed)


def archive(name):
    files = [p for p in OUT.glob(name + '*') if p.is_file()]
    if not files:
        return
    dest = OUT / 'history' / (name + '_' + str(time.time_ns()))
    dest.mkdir(parents=True)
    for p in files:
        p.rename(dest / p.name)
    for p in [OUT / 'independent_flow.gd', pathlib.Path(__file__)]:
        if p.exists():
            (dest / p.name).write_bytes(p.read_bytes())


def run(name, args, expected=None, require_result=False, timeout=90):
    archive(name)
    start = time.monotonic()
    proc = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, start_new_session=True)
    timed_out = False
    cleanup = []
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGTERM)
        cleanup.append('SIGTERM owned process group after timeout')
        try:
            output, _ = proc.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            cleanup.append('SIGKILL owned process group after grace period')
            output, _ = proc.communicate()
    (OUT / (name + '.log')).write_text(output)
    matches = re.findall(r'checks=(\d+)\s+failures=(\d+)', output)
    checks, failures = map(int, matches[-1]) if matches else (None, None)
    diagnostics = DIAGNOSTICS.findall(output)
    passed = (proc.returncode == 0 and not timed_out and not diagnostics
              and (not require_result or (len(matches) == 1 and failures == 0))
              and (expected is None or checks == expected))
    result = dict(name=name, command=args, pid=proc.pid, exit_code=proc.returncode,
                  elapsed_seconds=round(time.monotonic() - start, 3), timed_out=timed_out,
                  expected_checks=expected, checks=checks, failures=failures,
                  diagnostics=diagnostics, cleanup_actions=cleanup, reaped=True, passed=passed)
    write_json(name + '_runner.json', result)
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['baseline', 'suites', 'flow', 'native'])
    args = parser.parse_args()
    baseline()
    if args.mode == 'baseline':
        print('BASELINE_RECORDED', flush=True)
        return
    results = []
    if args.mode == 'suites':
        for script, expected in SUITES:
            results.append(run(pathlib.Path(script).stem,
                [ENGINE, '--headless', '--path', str(ROOT), '--script', 'res://' + script],
                expected=expected, require_result=True))
        results.append(run('editor_import', [ENGINE, '--headless', '--editor', '--path', str(ROOT), '--quit'], timeout=120))
        results.append(run('spec_strict', ['python3', SPEC, '--path', str(ROOT), 'validate',
            'add-zerkov-playable-raid-2026-09-09', '--strict', '--json']))
        results.append(run('diff_check', ['git', 'diff', '--check']))
    else:
        engine_args = [ENGINE, '--path', str(ROOT), '--rendering-method', 'gl_compatibility']
        if args.mode == 'native':
            engine_args += ['--resolution', '1280x720', '--position', '40,40']
        else:
            engine_args += ['--headless']
        results.append(run(args.mode, engine_args + ['--script',
            'res://docs/qa/inventory_ability_equipment/astra_final/independent_flow.gd'], require_result=True))
    write_json(args.mode + '_suite.json', {
        'results': results, 'raw_checks': sum(r['checks'] or 0 for r in results),
        'failures': sum(r['failures'] or 0 for r in results),
        'passed': all(r['passed'] for r in results), 'human_approval': False,
    })
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__':
    main()
