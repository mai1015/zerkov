#!/usr/bin/env python3
"""Report existing exact-output policy findings and reject any new finding.

This is a nonregression comparison, not full repository policy certification.
The original checker, earlier classifications and AI sources are not weakened.
"""
from __future__ import annotations
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '8039a0c19570e022cfc6ec855b77dd014da3e553'
VISUAL = 'tests/presentation/map_studies_contract.gd'
COMMAND = 'tests/tooling/run_map_studies_gate.py'
CHECKER = 'tools/check_first_playable_1080.py'
POLICY = 'config/first_playable_1080_gate.json'
TEST = 'tests/tooling/test_ui_first_playable_scope.py'


def main() -> int:
    spec = importlib.util.spec_from_file_location('original_output_gate', ROOT / CHECKER)
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    with tempfile.TemporaryDirectory(prefix='map-policy-baseline-') as temp:
        baseline = Path(temp) / 'baseline'
        subprocess.run(['git', 'worktree', 'add', '--detach', str(baseline), BASE], cwd=ROOT, check=True, capture_output=True)
        try:
            if (ROOT / CHECKER).read_bytes() != (baseline / CHECKER).read_bytes():
                raise RuntimeError('checker implementation changed')
            current_policy = gate.load_manifest(ROOT / POLICY)
            old_policy = gate.load_manifest(baseline / POLICY)
            retained = copy.deepcopy(current_policy)
            del retained['active_visual_entrypoints'][VISUAL]
            del retained['active_command_entrypoints'][COMMAND]
            del retained['sanctioned_capture_writers'][VISUAL]
            if retained != old_policy:
                raise RuntimeError('pre-existing policy changed')
            old_test = (baseline / TEST).read_text()
            expected_test = old_test.replace('self.assertEqual(26, len(self.manifest["active_visual_entrypoints"]))', 'self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))')
            if (ROOT / TEST).read_text() != expected_test:
                raise RuntimeError('policy tests changed beyond additive inventory count')
            for path in (baseline / 'tests/ai').rglob('*.gd'):
                if path.read_bytes() != (ROOT / path.relative_to(baseline)).read_bytes():
                    raise RuntimeError('pre-existing AI test changed')
            before = set(gate.manifest_issues(old_policy, baseline, gate.repository_paths(baseline)))
            after = set(gate.manifest_issues(current_policy, ROOT, gate.repository_paths(ROOT)))
            for issue in sorted(before):
                print('PRE_EXISTING_BASELINE_ISSUE: ' + issue)
            for issue in sorted(after - before):
                print('NEW_POLICY_FAILURE: ' + issue)
            print('MAP_SCOPE_RESULT baseline_issues=%d current_issues=%d new_issues=%d full_policy_pass=%s' % (len(before), len(after), len(after - before), not after))
            return int(bool(after - before))
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(baseline)], cwd=ROOT, check=True, capture_output=True)


if __name__ == '__main__':
    raise SystemExit(main())
