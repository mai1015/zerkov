#!/usr/bin/env python3
"""Verify the frozen checkpoint and seal this packet without staging or edits outside it."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical 1280x720 QA packet finalizer is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import datetime
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import sys

import run_validation as r


def read(name):
    return json.loads((r.OUT / name).read_text())


def seal():
    evidence = read('reviewed_diff.json')
    decoded = base64.b64decode(evidence['data'], validate=True)
    if evidence['encoding'] != 'base64' or hashlib.sha256(decoded).hexdigest() != evidence['decoded_sha256']:
        raise RuntimeError('Reviewed diff evidence failed lossless decoding verification')
    paths = sorted(p for p in r.OUT.rglob('*') if p.is_file()
                   and p.name not in ['packet_hashes.sha256', 'manifest_verification.log']
                   and '__pycache__' not in p.parts)
    gate = read('gate_result.json')
    gate['packet_seal'] = {'sealed_entries': len(paths),
        'files_including_manifest_and_verification': len(paths) + 2,
        'excluded_from_manifest': ['packet_hashes.sha256', 'manifest_verification.log'],
        'reviewed_diff_decodes_to_recorded_sha256': True}
    r.write_json('gate_result.json', gate)
    (r.OUT / 'packet_hashes.sha256').write_text(''.join(
        r.digest(p) + '  ' + str(p.relative_to(r.ROOT)) + '\n' for p in paths))
    check = subprocess.run(['shasum', '-a', '256', '-c',
        'docs/qa/inventory_ability_equipment/astra_final/packet_hashes.sha256'],
        cwd=r.ROOT, capture_output=True, text=True)
    (r.OUT / 'manifest_verification.log').write_text(check.stdout + check.stderr)
    print(json.dumps({'manifest_entries': len(paths), 'total_packet_files': len(paths) + 2,
                      'reviewed_diff_decodes_to_recorded_sha256': True, 'passed': check.returncode == 0}))
    return check.returncode


def main():
    if '--seal' in sys.argv:
        raise SystemExit(seal())
    final_import = r.run('final_editor_import', [r.ENGINE, '--headless', '--editor',
        '--path', str(r.ROOT), '--quit'], timeout=120)
    baseline = read('baseline.json')
    actual_frozen = {p: r.digest(r.ROOT / p) for p in r.FROZEN}
    r.write_json('frozen_hashes_after.json', actual_frozen)
    before = read('project_hashes_before.json')
    after = r.repo_inventory(r.ROOT, ['game', 'tests', 'ui', 'config', 'project.godot', 'addons', 'docs/spec'])
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    sibling_before = read('sibling_addons_before.json')
    sibling_checks = {}
    for key, value in sibling_before.items():
        current = r.sibling_state(pathlib.Path(value['path']))
        hashes_before, hashes_after = value['hashes'], current['hashes']
        changes = sorted(p for p in hashes_before.keys() | hashes_after.keys()
                         if hashes_before.get(p) != hashes_after.get(p))
        sibling_checks[key] = {'file_count': len(hashes_before), 'changed_files': changes,
            'git': value['git'], 'head_unchanged': value.get('head') == current.get('head'),
            'status_unchanged': value.get('status') == current.get('status'), 'passed': value == current}
    r.write_json('sibling_addons_after_verification.json', sibling_checks)
    status = r.cmd(['git', 'status', '--short', '--untracked-files=all'])
    (r.OUT / 'final_status.log').write_text(status)
    prefix = 'docs/qa/inventory_ability_equipment/astra_final/'
    outside_before = [s for s in baseline['status'].splitlines() if not s[3:].startswith(prefix)]
    outside_after = [s for s in status.splitlines() if not s[3:].startswith(prefix)]
    staged = r.cmd(['git', 'diff', '--cached'])
    (r.OUT / 'staging_status.log').write_text(staged)
    addon_status = r.cmd(['git', 'status', '--short', '--untracked-files=all', '--', 'addons'])
    (r.OUT / 'addon_status.log').write_text(addon_status)
    diff = subprocess.run(['git', 'diff', '--check'], cwd=r.ROOT, capture_output=True, text=True)
    (r.OUT / 'final_diff_check.log').write_text(diff.stdout + diff.stderr)
    flow, native = read('flow_results.json'), read('native_results.json')
    suites = read('suites_suite.json')
    runs = suites['results'] + read('flow_suite.json')['results'] + read('native_suite.json')['results'] + [final_import]
    diagnostics = {x['name']: r.DIAGNOSTICS.findall((r.OUT / (x['name'] + '.log')).read_text()) for x in runs}
    diagnostics = {key: value for key, value in diagnostics.items() if value}
    native_extra_labels = {
        'real macOS native window is visible', 'actual native rendering method is Compatibility',
        'actual native window size is 1280x720', 'four ordinary/isolation/recovery/teardown native frames are saved'}
    native_core = [(a['label'], a['passed']) for a in native['assertions']
                   if '.png framebuffer ' not in a['label']
                   and '.png readable native framebuffer saved' not in a['label']
                   and a['label'] not in native_extra_labels]
    flow_core = [(a['label'], a['passed']) for a in flow['assertions']]
    fields = ['fixture', 'label', 'tick', 'revision', 'applied', 'sources', 'live',
              'revoked', 'terminal_history', 'effects', 'ready', 'raid_lifecycle', 'adapter_lifecycle']
    state_rows = lambda data: [{key: row[key] for key in fields} for row in data['observations']]
    processes = r.godot_processes()
    pids = {x['pid'] for x in runs}
    alive = [p for p in processes if p['pid'] in pids]
    r.write_json('process_cleanup.json', {'owned_pids': sorted(pids), 'owned_processes_still_alive': alive,
        'all_reaped': all(x['reaped'] for x in runs), 'remaining_unrelated_godot_processes_untouched': processes,
        'temporary_files_outside_packet_created_by_validator': [], 'passed': not alive})
    patterns = {
        'private_key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
        'aws_access_key': re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
        'github_token': re.compile(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
        'openai_key': re.compile(r'\bsk-(?:proj-)?[A-Za-z0-9_-]{35,}\b'),
    }
    findings = []
    scan_paths = [r.ROOT / p for p in r.FROZEN] + [p for p in r.OUT.rglob('*')
                 if p.is_file() and p.suffix in ['.py', '.gd', '.md', '.json', '.log', '.patch']]
    for path in scan_paths:
        data = path.read_text(errors='replace')
        for name, pattern in patterns.items():
            for match in pattern.finditer(data):
                findings.append({'file': str(path.relative_to(r.ROOT)), 'line': data.count('\n', 0, match.start()) + 1, 'pattern': name})
    r.write_json('secret_scan.json', {'method': 'Targeted credential/private-key patterns; match contents never emitted',
        'files_scanned': len(scan_paths), 'findings': findings, 'passed': not findings})
    captures = {x['file']: r.digest(r.OUT / x['file']) for x in native['captures']}
    r.write_json('capture_hashes.json', captures)
    visual = read('visual_review.json')
    head = r.cmd(['git', 'rev-parse', 'HEAD']).strip()
    checks = {
        'frozen_sources_before_and_after_match_requested_hashes': read('frozen_hashes.json') == r.FROZEN == actual_frozen,
        'all_covered_project_files_unchanged': not changed,
        'all_six_sibling_addons_unchanged': all(v['passed'] for v in sibling_checks.values()),
        'vendored_addons_clean': addon_status == '',
        'no_non_packet_changes': outside_before == outside_after,
        'no_staging_or_commit': staged == baseline['staged_diff'] and head == baseline['head'],
        'engine_exact_and_unchanged': r.digest(pathlib.Path(r.ENGINE)) == baseline['engine_sha256']
            and native['metadata']['executable'] == r.ENGINE,
        'all_final_runners_pass': all(x['passed'] for x in runs),
        'all_current_engine_logs_clean': not diagnostics,
        'all_assertions_pass': flow['failures'] == native['failures'] == 0 and all(a['passed'] for a in flow['assertions'] + native['assertions']),
        'native_repeats_same_451_core_assertions': native_core == flow_core,
        'native_repeats_same_ordered_states': state_rows(flow) == state_rows(native),
        'native_window_and_captures_verified': native['metadata']['display_server'] == 'macOS'
            and native['metadata']['visible'] and native['metadata']['renderer'] == 'gl_compatibility'
            and native['metadata']['window_size'] == [1280, 720] and len(captures) == 4 and visual['passed'],
        'recovery_unresolved_empty': native['details']['recovery']['outcome']['details']['unresolved_records'] == [],
        'composition_constraint_honestly_recorded': native['details']['terminal_first_constraint']['automatic_raid_terminal_cleanup_claimed'] is False,
        'owned_processes_clean': not alive and all(x['reaped'] for x in runs),
        'final_diff_check_clean': diff.returncode == 0,
        'targeted_secret_scan_clean': not findings,
    }
    counts = {'promoted_and_adjacent_suites': 16, 'promoted_and_adjacent_assertions': suites['raw_checks'],
        'promoted_equipment_contract_assertions': runs[0]['checks'],
        'independent_headless_assertions': flow['checks'], 'independent_native_assertions': native['checks'],
        'native_additional_checks': native['checks'] - flow['checks'],
        'raw_assertion_executions': sum(x['checks'] or 0 for x in runs),
        'raw_failures': sum(x['failures'] or 0 for x in runs),
        'distinct_test_programs': 17, 'test_execution_variants': 18,
        'independent_fixture_cases': 6, 'native_repeats_headless_cases': True,
        'history_in_accepted_totals': False}
    gate = {'decision': 'ACCEPT' if all(checks.values()) else 'REJECT',
        'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'head': head,
        'human_approval': False, 'task': '4.10', 'checks': checks, 'counts': counts,
        'project_files_hashed': len(before), 'project_changed_files': changed,
        'sibling_integrity': sibling_checks, 'diagnostics': diagnostics,
        'qa_harness_sha256': r.digest(r.OUT / 'independent_flow.gd'),
        'limitations': ['Offline synchronous in-memory reconciliation; native signals are not an atomic multi-domain transaction.',
            'Unexpected native failure causes fail-stop recovery and may terminally quarantine the entire captured component.',
            'Native grant history has 64 entries; the 65th grant fails preflight and requires recovery.',
            'Accepted P2 follow-up for tasks 4.12/7.1: release adapter or destroy owner/component before RaidAuthority terminalization.',
            'Automated native validation harness only; production UI/input, human playtest, full raid loop and release acceptance are not claimed.']}
    r.write_json('gate_result.json', gate)
    print(json.dumps(gate, indent=2), flush=True)
    raise SystemExit(0 if gate['decision'] == 'ACCEPT' else 1)


if __name__ == '__main__':
    main()
