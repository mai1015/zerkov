"""Final independent Astra evidence runner. No production writes."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical multi-resolution QA runner is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_ui_binding/astra_final_accept'
GODOT = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
HEADLESS = [
    ('authority', 'tests/raid/inventory_authority_contract.gd'),
    ('replay', 'tests/raid/authority_replay_contract.gd'),
    ('equipped_reconciliation', 'tests/raid/equipped_item_reconciliation_contract.gd'),
    ('binding', 'tests/raid/inventory_ui_binding_contract.gd'),
    ('multi_controller', 'tests/raid/inventory_multi_controller_contract.gd'),
    ('reentrant', 'tests/visual/inventory_ui_binding/reentrant_probe.gd'),
    ('compact_extent', 'tests/visual/inventory_ui_binding/compact_extent_probe.gd'),
    ('inventory', 'tests/inventory_smoke.gd'),
    ('compact_inventory', 'tests/compact_inventory_smoke.gd'),
    ('projection', 'tests/raid/inventory_projection_contract.gd'),
    ('intent', 'tests/raid/inventory_intent_adapter_contract.gd'),
    ('mutation', 'tests/raid/inventory_mutation_routing_contract.gd'),
    ('composition', 'tests/ui_composition_smoke.gd'),
    ('responsive', 'tests/responsive_smoke.gd'),
    ('reflow', 'tests/ui_reflow_smoke.gd'),
    ('components', 'tests/ui_component_states.gd'),
]
NATIVE = [
    ('independent_surface', 'independent_surface_probe.gd'),
    ('fixture_status', 'fixture_status_probe.gd'),
    ('compact_continuity', 'compact_continuity.gd'),
    ('compact_native_selection', 'compact_native_selection.gd'),
    ('presentation_honesty', 'presentation_honesty.gd'),
    ('p2_presentation', 'p2_presentation.gd'),
    ('native_flow_typed_quantity', 'native_flow.gd'),
    ('native_pointer', 'native_pointer.gd'),
    ('compact_visual', 'compact_visual.gd'),
    ('core_capture', 'capture.gd'),
    ('live_sections', 'live_sections_probe.gd'),
    ('compact_tooltip_refresh', 'compact_tooltip_refresh_probe.gd'),
]

def run(name, args, require_checks=False):
    started = time.monotonic()
    result = subprocess.run([GODOT, '--path', str(ROOT), *args], cwd=ROOT,
                            capture_output=True, text=True, timeout=300)
    output = result.stdout + result.stderr
    (OUT / 'logs' / (name + '.log')).write_text(output)
    counters = re.findall(r'(?:RESULT|COMPLETE)[^\n]*?checks=(\d+) failures=(\d+)', output)
    diagnostics = [line for line in output.splitlines() if re.search(
        r'ERROR|SCRIPT ERROR|[Ll]eak|[Ss]tack overflow|RID.*(?:use|remain)', line)]
    record = dict(name=name, args=args, exit=result.returncode,
                  checks=int(counters[-1][0]) if counters else None,
                  failures=int(counters[-1][1]) if counters else None,
                  diagnostics=diagnostics, seconds=round(time.monotonic()-started, 3),
                  sha256=hashlib.sha256(output.encode()).hexdigest())
    record['passed'] = result.returncode == 0 and not diagnostics and (
        not require_checks or bool(counters) and record['failures'] == 0)
    print(json.dumps(record), flush=True)
    return record

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('group', choices=['import', 'final_import', 'headless', 'native', 'challenge', 'promoted'])
    opts = parser.parse_args()
    for directory in ['logs', 'core', 'p2', 'flow', 'honesty', 'promoted_p2', 'promoted_honesty']:
        (OUT / directory).mkdir(parents=True, exist_ok=True)
    if opts.group == 'import':
        records = [run('editor_import', ['--headless', '--editor', '--import', '--quit'])]
    elif opts.group == 'final_import':
        records = [run('editor_import_final', ['--headless', '--editor', '--import', '--quit'])]
    elif opts.group == 'headless':
        records = [run(name, ['--headless', '--script', 'res://' + path], True)
                   for name, path in HEADLESS]
    elif opts.group == 'native':
        records = [run(name, ['--script', 'res://docs/qa/inventory_ui_binding/astra_final_accept/' + path], True)
                   for name, path in NATIVE]
    elif opts.group == 'challenge':
        records = [run('overlay_and_sections_challenge', ['--script', 'res://docs/qa/inventory_ui_binding/astra_final_accept/overlay_and_sections_challenge.gd'], True)]
    else:
        records = [run(name, ['--script', 'res://docs/qa/inventory_ui_binding/astra_final_accept/' + path], True) for name,path in [('promoted_p2','promoted_p2.gd'),('promoted_honesty','promoted_honesty.gd')]]
    (OUT / (opts.group + '_results.json')).write_text(json.dumps(records, indent=2) + '\n')
    raise SystemExit(0 if all(row['passed'] for row in records) else 1)

if __name__ == '__main__':
    main()
