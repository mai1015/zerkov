#!/usr/bin/env python3
"""Report existing exact-output policy findings and reject any new finding.
The only extensions are the original two studies and the full Northline review.
This does not certify the pre-existing AI policy failures as passing.
"""
from __future__ import annotations
import copy,importlib.util
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
BASE='babd45e938b7105f5b11f1a4dcb9898c7e1c120b'
PAIRS=[('tests/presentation/map_studies_contract.gd','tests/tooling/run_map_studies_gate.py'),('tests/presentation/northline_zone_contract.gd','tests/tooling/run_northline_zone_gate.py')]
CHECKER='tools/check_first_playable_1080.py'
POLICY='config/first_playable_1080_gate.json'
TEST='tests/tooling/test_ui_first_playable_scope.py'

def main()->int:
    spec=importlib.util.spec_from_file_location('original_output_gate',ROOT/CHECKER)
    gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
    with tempfile.TemporaryDirectory(prefix='map-policy-baseline-') as temp:
        baseline=Path(temp)/'baseline'
        subprocess.run(['git','worktree','add','--detach',str(baseline),BASE],cwd=ROOT,check=True,capture_output=True)
        try:
            if (ROOT/CHECKER).read_bytes()!=(baseline/CHECKER).read_bytes():raise RuntimeError('Checker implementation changed')
            current=gate.load_manifest(ROOT/POLICY);old=gate.load_manifest(baseline/POLICY)
            retained=copy.deepcopy(current)
            for visual,command in PAIRS:
                del retained['active_visual_entrypoints'][visual]
                del retained['active_command_entrypoints'][command]
                del retained['sanctioned_capture_writers'][visual]
            if retained!=old:raise RuntimeError('Pre-existing policy changed')
            old_test=(baseline/TEST).read_text()
            # Each study adds one visual entrypoint and one sanctioned capture writer.
            expected=old_test.replace('self.assertEqual(27, len(self.manifest["active_visual_entrypoints"]))','self.assertEqual(29, len(self.manifest["active_visual_entrypoints"]))').replace('self.assertEqual(10, len(self.manifest["sanctioned_capture_writers"]))','self.assertEqual(12, len(self.manifest["sanctioned_capture_writers"]))')
            if (ROOT/TEST).read_text()!=expected:raise RuntimeError('Policy tests changed beyond additive inventory count')
            for path in (baseline/'tests/ai').rglob('*.gd'):
                if path.read_bytes()!=(ROOT/path.relative_to(baseline)).read_bytes():raise RuntimeError('Pre-existing AI test changed')
            before=set(gate.manifest_issues(old,baseline,gate.repository_paths(baseline)))
            after=set(gate.manifest_issues(current,ROOT,gate.repository_paths(ROOT)))
            for issue in sorted(before):print('PRE_EXISTING_BASELINE_ISSUE: '+issue)
            for issue in sorted(after-before):print('NEW_POLICY_FAILURE: '+issue)
            print('MAP_SCOPE_RESULT baseline_issues=%d current_issues=%d new_issues=%d full_policy_pass=%s'%(len(before),len(after),len(after-before),not after))
            return int(bool(after-before))
        finally:subprocess.run(['git','worktree','remove','--force',str(baseline)],cwd=ROOT,check=True,capture_output=True)
if __name__=='__main__':raise SystemExit(main())
