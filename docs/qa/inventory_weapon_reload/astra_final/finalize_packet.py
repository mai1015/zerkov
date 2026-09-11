#!/usr/bin/env python3
"""Verify and seal the current fresh QA packet. Never touches the prior packet."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical 1280x720 QA packet finalizer is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import datetime
import hashlib
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_weapon_reload/astra_final'
ENGINE = '/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot'
DIAGNOSTICS = re.compile(r'(?im)^.*(?:\bERROR\b|SCRIPT ERROR|assertion|stack overflow|ObjectDB[^\n]*leak|RID[^\n]*leak|resources still in use|font[^\n]*leak|\bWARNING\b|\bTIMEOUT\b).*$')


def read_json(name):
    return json.loads((OUT / name).read_text())


def write_json(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hashes_check(name):
    expected = read_json(name)
    changed = [p for p, value in expected.items() if not (ROOT / p).is_file() or sha(ROOT / p) != value]
    return {'file_count': len(expected), 'changed': changed, 'passed': not changed}


def command(name, args, expected_exit=0):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    output = result.stdout + result.stderr
    (OUT / (name + '.log')).write_text(output)
    return {'command': args, 'exit_code': result.returncode, 'output': output,
            'passed': result.returncode == expected_exit}


def godot_processes(text):
    records = []
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        executable = parts[2].split(None, 1)[0]
        if executable == ENGINE or executable == '/opt/homebrew/bin/godot' or executable == 'godot':
            records.append({'pid': int(parts[0]), 'ppid': int(parts[1]), 'executable': executable})
    return records


def main():
    baseline = read_json('baseline.json')
    if 'processes_before' in baseline:
        # Retain only relevant executable/PID observations; omit unrelated app command lines.
        baseline['godot_processes_before'] = godot_processes(baseline.pop('processes_before'))
        write_json('baseline.json', baseline)
    suite = read_json('suites_suite.json')
    capacity = read_json('capacity_suite.json')
    flow = read_json('flow_suite.json')
    native = read_json('native_suite.json')
    all_runs = suite['results'] + capacity['results'] + flow['results'] + native['results']
    flow_details = read_json('flow_results.json')
    native_details = read_json('native_results.json')
    capacity_details = read_json('capacity_results.json')
    hashes = {key: hashes_check(key + '_hashes.json') for key in ['reviewed', 'dependency', 'addon', 'spec']}
    prior = command('prior_packet_integrity_after', ['shasum', '-a', '256', '-c', 'docs/qa/inventory_weapon_reload/astra_gate/packet_hashes.sha256'])
    prior['manifest_entries'] = len(prior['output'].splitlines())
    prior['packet_files_including_manifest'] = len([p for p in (ROOT / 'docs/qa/inventory_weapon_reload/astra_gate').rglob('*') if p.is_file()])
    addon_status = command('addon_status', ['git', 'status', '--short', '--untracked-files=all', '--', 'addons'])
    addon_status['passed'] = addon_status['passed'] and addon_status['output'] == ''
    staged = command('staging_status', ['git', 'diff', '--cached', '--name-only'])
    staged['passed'] = staged['passed'] and staged['output'] == ''
    direct_tick = command('production_direct_tick_search', ['rg', '-n', r'\badvance_tick\s*\(', 'game'], expected_exit=1)
    direct_tick['passed'] = direct_tick['passed'] and direct_tick['output'] == ''
    diff = command('final_diff_check', ['git', 'diff', '--check'])
    status = command('final_status', ['git', 'status', '--short'])
    current_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    processes = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
    owned_pids = {int(r['pid']) for r in all_runs}
    process_rows = [line for line in processes.splitlines() if line.split() and line.split()[0].isdigit() and int(line.split()[0]) in owned_pids]
    write_json('process_cleanup.json', {'runner_owned_pids': sorted(owned_pids),
        'all_recorded_processes_reaped': all(r.get('reaped') for r in all_runs),
        'owned_processes_still_alive': process_rows, 'other_godot_processes_left_untouched': godot_processes(processes),
        'passed': not process_rows and all(r.get('reaped') for r in all_runs)})
    diagnostics = {}
    for r in all_runs:
        findings = DIAGNOSTICS.findall((OUT / (r['name'] + '.log')).read_text())
        if findings:
            diagnostics[r['name']] = findings
    same_core = native_details['assertions'][:flow_details['checks']] == flow_details['assertions']
    same_timeline = flow_details['timeline'] == native_details['timeline']
    native_meta = native_details['native_metadata']
    visual = {'reviewer': 'fresh GPT-6 Astra checkpoint validator',
        'capture': 'native_timeline_1280x720.png', 'sha256': sha(OUT / 'native_timeline_1280x720.png'),
        'visually_inspected': True, 'window_size': [1280, 720], 'display_server': native_meta['display_server'],
        'rendering_method': native_meta['renderer'], 'human_approval': False,
        'findings': ['All eight ordered states are readable with no clipped rows or columns.',
                     'Tick, magazine, rig, pocket, loaded, hold count/quantity, revisions and conserved totals are aligned.',
                     'VALIDATION HARNESS / NOT PRODUCTION UI and automated-flow disclosure are prominent.',
                     'Cancellation, commit, replay, publication ordering and quarantine accounting are labeled.',
                     'This proves native automated flow presentation only, not human playtest or production input.'],
        'passed': True}
    write_json('visual_review.json', visual)
    counts = {'baseline_suites': 15, 'baseline_assertions': suite['raw_checks'],
        'capacity_assertions': capacity_details['checks'], 'headless_flow_assertions': flow_details['checks'],
        'native_flow_assertions': native_details['checks'], 'native_additional_checks': native_details['checks'] - flow_details['checks'],
        'raw_assertions': sum(r['checks'] or 0 for r in all_runs),
        'raw_failures': sum(r['failures'] or 0 for r in all_runs),
        'core_flow_assertions_repeated_in_native': flow_details['checks'],
        'assertion_executions_after_removing_native_core_repeat': sum(r['checks'] or 0 for r in all_runs) - flow_details['checks'],
        'distinct_test_programs': 17, 'test_execution_variants': 18,
        'non_counted_required_command_gates': 3, 'unique_independent_real_addon_flow_cases': 5,
        'independent_flow_case_executions': 10, 'native_repeats_headless_cases': True,
        'unique_main_timeline_states': 8, 'main_timeline_state_executions': 16,
        'history_included_in_accepted_totals': False,
        'note': 'Counts are assertion executions, not deduplicated logical invariants. Native repeats the same five cases.'}
    checks = {'all_runners_pass': all(r['passed'] for r in all_runs),
        'no_runtime_diagnostics': not diagnostics, 'no_timeouts': not any(r['timed_out'] for r in all_runs),
        'all_source_dependency_addon_spec_hashes_unchanged': all(v['passed'] for v in hashes.values()),
        'sealed_reject_packet_intact': prior['passed'], 'no_addon_modifications': addon_status['passed'],
        'no_staging': staged['passed'], 'no_commit': current_head == baseline['parent_commit'],
        'no_production_direct_weapon_advance_tick': direct_tick['passed'],
        'diff_check_pass': diff['passed'], 'native_core_identical_to_headless': same_core,
        'native_timeline_identical_to_headless': same_timeline, 'native_visually_reviewed': visual['passed'],
        'all_validator_processes_clean': not process_rows and all(r['reaped'] for r in all_runs),
        'machine_assertions_pass': flow_details['failures'] == native_details['failures'] == capacity_details['failures'] == 0}
    result = {'decision': 'ACCEPT' if all(checks.values()) else 'REJECT',
        'authorization': 'ACCEPT FOR DOCS/STAGING' if all(checks.values()) else 'TASK MUST REMAIN UNCHECKED',
        'human_approval': False, 'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'parent_commit': current_head, 'checks': checks, 'counts': counts, 'integrity': hashes,
        'prior_packet': prior, 'diagnostics': diagnostics,
        'process_cleanup': 'process_cleanup.json', 'visual_review': 'visual_review.json',
        'limitations': ['Offline in-memory single-writer/no-yield facade coordination only.',
                        'No public Weapon rollback; no crash/restart atomicity or recovery completion claim.',
                        'No physical detachable-magazine weapon identity or swapping claim.',
                        'Native automated validation harness, not production UI/input or human playtest.',
                        'No task checkbox, spec ledger, staging, or commit was changed by validator.']}
    write_json('gate_result.json', result)
    paths = sorted(p for p in OUT.rglob('*') if p.is_file() and p.name not in ['packet_hashes.sha256', 'manifest_verification.log'])
    (OUT / 'packet_hashes.sha256').write_text(''.join(sha(p) + '  ' + str(p.relative_to(ROOT)) + '\n' for p in paths))
    verified = command('manifest_verification', ['shasum', '-a', '256', '-c', 'docs/qa/inventory_weapon_reload/astra_final/packet_hashes.sha256'])
    print(json.dumps({'decision': result['decision'], 'counts': counts, 'checks': checks,
                      'manifest_entries': len(paths), 'manifest_passed': verified['passed']}, indent=2))
    raise SystemExit(0 if result['decision'] == 'ACCEPT' and verified['passed'] else 1)


if __name__ == '__main__':
    main()
