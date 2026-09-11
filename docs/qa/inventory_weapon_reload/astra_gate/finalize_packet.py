#!/usr/bin/env python3
"""Seal this validator's read-only review and execution evidence."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical 1280x720 QA packet finalizer is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import hashlib
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_weapon_reload/astra_gate'

expected = json.loads((OUT/'reviewed_hashes.json').read_text())
verification = {path: hashlib.sha256((ROOT/path).read_bytes()).hexdigest() == digest
                for path, digest in expected.items()}
dependencies = [
    'game/content/zerkov_inventory_catalog.gd',
    'addons/inventory_system/native/core/inv_runtime_state.cpp',
    'addons/inventory_system/native/core/inv_quantity_reservations.cpp',
    'addons/inventory_system/native/godot/inventory_authority.cpp',
    'addons/weapon_system/native/core/wpn_runtime.cpp',
    'addons/weapon_system/native/godot/weapon_authority.cpp',
    'addons/inventory_system/bin/libinventory_system.macos.template_debug.universal.dylib',
    'addons/weapon_system/bin/libweapon_system.macos.template_debug.universal.dylib',
]
dependency_hashes = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in dependencies}
godot = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
dependency_hashes[godot] = hashlib.sha256(pathlib.Path(godot).read_bytes()).hexdigest()
(OUT/'dependency_hashes.json').write_text(json.dumps(dependency_hashes, indent=2)+'\n')
processes = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
godot_processes = [line.strip() for line in processes.splitlines() if 'Godot' in line]
owned_remaining = [line for line in godot_processes if not line.split()[0] == '49133']
diff = subprocess.run(['git', 'diff', '--check'], cwd=ROOT, capture_output=True, text=True)
log_results = {}
for path in sorted(OUT.glob('*.log')):
    log = path.read_text()
    diagnostics = re.findall(
        r'(?im)^.*(?:SCRIPT ERROR|\bERROR:|stack overflow|ObjectDB instances leaked|RID[^\n]*leak|resources still in use|font[^\n]*leak).*$',
        log)
    log_results[path.name] = diagnostics
result = {
    'verdict': 'REJECT', 'task': '4.9', 'human_approval': False,
    'production_hashes_unchanged': verification,
    'validator_owned_processes_remaining': owned_remaining,
    'unrelated_godot_processes_untouched': godot_processes,
    'diff_check_exit_code': diff.returncode,
    'current_log_diagnostics': log_results,
    'diagnostic_interpretation': 'Two intentional assertion failures reproduce the magazine catalog blocker. Passing suites and continuous flows contain no runtime diagnostics. Earlier broad magazine-fixture failures and harness parse attempt are retained under authoring_history and excluded from current totals.',
    'automatically_generated_outside_packet': ['tests/raid/inventory_weapon_reload_contract.gd.uid'],
    'production_or_promoted_test_code_edits': False,
    'remaining_required_work': 'Make the canonical magazine item materialize its provided ammunition container; then prove source selection, held quantities, commit, cancellation and conservation through that real container and launch a fresh checkpoint gate.',
}
(OUT/'gate_result.json').write_text(json.dumps(result, indent=2)+'\n')
files = sorted(p for p in OUT.rglob('*') if p.is_file() and p.name != 'packet_hashes.sha256')
(OUT/'packet_hashes.sha256').write_text(''.join(
    hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(ROOT))+'\n' for p in files))
print(json.dumps({'verdict': result['verdict'], 'source_hashes_ok': all(verification.values()),
                  'owned_processes_remaining': owned_remaining, 'diff_check': diff.returncode,
                  'current_diagnostic_counts': {p: len(ds) for p, ds in log_results.items()}}, indent=2))
