#!/usr/bin/env python3
"""Independent Astra checkpoint runner; all generated evidence stays here."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical 1280x720 QA packet runner is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_weapon_reload/astra_gate'
GODOT = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
SOURCES = [
    'game/domain/ports/weapon_reload_participant_port.gd',
    'game/domain/ports/weapon_reload_participant_port.gd.uid',
    'game/inventory/equipment/inventory_weapon_adapter.gd',
    'game/inventory/equipment/inventory_weapon_adapter.gd.uid',
    'game/inventory/equipment/weapon_authority_reload_port.gd',
    'game/inventory/equipment/weapon_authority_reload_port.gd.uid',
    'tests/raid/inventory_weapon_reload_contract.gd',
]
SUITES = [
    'tests/raid/inventory_weapon_reload_contract.gd',
    'tests/raid/inventory_authority_contract.gd',
    'tests/raid/inventory_catalog_contract.gd',
    'tests/raid/equipped_item_reconciliation_contract.gd',
    'tests/combat/content_contract.gd',
    'tests/raid/session_lifecycle_contract.gd',
    'tests/raid/authority_replay_contract.gd',
    'tests/raid/identity_contract.gd',
    'tests/raid/inventory_intent_adapter_contract.gd',
    'tests/raid/inventory_mutation_routing_contract.gd',
    'tests/raid/inventory_projection_contract.gd',
    'tests/addons/combined_addons_smoke.gd',
]
DIAGNOSTICS = re.compile(r'(?im)(SCRIPT ERROR|\bERROR:|stack overflow|ObjectDB instances leaked|RID[^\n]*leak|resources still in use|font[^\n]*leak|ASSERTION FAILED)')


def run(name, args, expect_result=False):
    started = time.time()
    proc = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=100)
    output = proc.stdout
    log = OUT / f'{name}.log'
    if log.exists():
        history = OUT / 'authoring_history'
        history.mkdir(exist_ok=True)
        log.replace(history / f'{name}_{time.time_ns()}.log')
    log.write_text(output)
    matches = re.findall(r'checks=(\d+)\s+failures=(\d+)', output)
    diagnostics = DIAGNOSTICS.findall(output)
    result = dict(name=name, command=args, exit_code=proc.returncode,
                  elapsed_seconds=round(time.time()-started, 3),
                  checks=int(matches[-1][0]) if matches else None,
                  failures=int(matches[-1][1]) if matches else None,
                  diagnostics=diagnostics)
    result['passed'] = proc.returncode == 0 and not diagnostics and (
        not expect_result or (bool(matches) and result['failures'] == 0))
    print(json.dumps(result), flush=True)
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'reviewed_hashes.json').write_text(json.dumps({
        p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in SOURCES
    }, indent=2)+'\n')
    results = []
    if '--native' in sys.argv:
        results.append(run('native_flow', [GODOT, '--path', str(ROOT), '--resolution', '1280x720',
            '--rendering-method', 'gl_compatibility',
            '--script', 'res://docs/qa/inventory_weapon_reload/astra_gate/flow_playthrough.gd'], True))
        filename = 'native_run.json'
    elif '--magazine' in sys.argv:
        results.append(run('magazine_probe', [GODOT, '--headless', '--path', str(ROOT),
            '--script', 'res://docs/qa/inventory_weapon_reload/astra_gate/magazine_probe.gd'], True))
        filename = 'magazine_run.json'
    elif '--flow' in sys.argv:
        results.append(run('independent_flow', [GODOT, '--headless', '--path', str(ROOT),
            '--script', 'res://docs/qa/inventory_weapon_reload/astra_gate/flow_playthrough.gd'], True))
        filename = 'independent_run.json'
    else:
        for suite in SUITES:
            results.append(run(pathlib.Path(suite).stem, [GODOT, '--headless', '--path', str(ROOT),
                '--script', 'res://'+suite], suite != 'tests/addons/combined_addons_smoke.gd'))
        results.append(run('editor_import', [GODOT, '--headless', '--editor', '--path', str(ROOT), '--quit']))
        results.append(run('diff_check', ['git', 'diff', '--check']))
        filename = 'suite_results.json'
    (OUT / filename).write_text(json.dumps({
        'human_approval': False, 'results': results,
        'checks': sum(r['checks'] or 0 for r in results),
        'failures': sum(r['failures'] or 0 for r in results),
        'passed': all(r['passed'] for r in results)
    }, indent=2)+'\n')
    sys.exit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__':
    main()
