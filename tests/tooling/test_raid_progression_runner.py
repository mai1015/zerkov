"""Task 7 runner isolation, diagnostics and fresh-process sequencing."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('progression_runner',ROOT/'tools/run_raid_progression_contracts.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
class RunnerTests(unittest.TestCase):
    def test_zero_exit_with_script_error_fails(self):
        with patch.object(runner.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'SCRIPT ERROR: fixture')),contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):runner.execute(['fake'])
    def test_zero_count_missing_and_failure_marker_fail(self):
        for output in ['', 'OK checks=0 failures=0', 'OK checks=1 failures=1','OK_BLOCKED missing_native']:
            with patch.object(runner.subprocess,'run',return_value=subprocess.CompletedProcess([],0,output)),contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):runner.execute(['fake'],'OK')
    def test_nonzero_success_text_fails(self):
        with patch.object(runner.subprocess,'run',return_value=subprocess.CompletedProcess([],2,'OK checks=1 failures=0')),contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):runner.execute(['fake'],'OK')
    def test_timeout_prints_captured_diagnostics(self):
        output=io.StringIO()
        with patch.object(runner.subprocess,'run',side_effect=subprocess.TimeoutExpired(['fake'],1,output=b'SCRIPT ERROR: syntax')),contextlib.redirect_stdout(output):
            with self.assertRaises(subprocess.TimeoutExpired):runner.execute(['fake'])
        self.assertIn('syntax',output.getvalue())
    def test_fresh_process_restart_sequence(self):
        outputs=['RAID_RESTART_RESULT checks=1 failures=0 mode=prepare input='+'a'*64,
                 'RAID_RESTART_RESULT checks=1 failures=0 mode=recover input='+'a'*64+' profile='+'b'*64,
                 'RAID_RESTART_RESULT checks=1 failures=0 mode=verify input='+'a'*64+' profile='+'b'*64,
                 'RAID_RESTART_CLEANUP checks=4 failures=0']
        with patch.object(runner,'execute',side_effect=outputs) as execute:
            runner.restart(['godot','--headless'],{})
        self.assertEqual(4,execute.call_count)
        calls=[row.args[0] for row in execute.call_args_list]
        self.assertEqual(['prepare','recover','verify','cleanup'],[row[row.index('--')+1] for row in calls])
        self.assertEqual(1,len({row[row.index('--')+2] for row in calls}))
        self.assertEqual(['a'*64,'b'*64],calls[2][-2:])
    def test_missing_digest_rejects_and_cleans_up(self):
        with patch.object(runner,'execute',side_effect=['missing-digest','cleanup']) as execute:
            with self.assertRaises(RuntimeError):runner.restart(['godot'],{})
        self.assertEqual('cleanup',execute.call_args.args[0][-2])
    def test_recovery_mismatch_rejects_and_cleans_up(self):
        outputs=['mode=prepare input='+'a'*64,'mode=recover input='+'c'*64+' profile='+'b'*64,'cleanup']
        with patch.object(runner,'execute',side_effect=outputs) as execute:
            with self.assertRaises(RuntimeError):runner.restart(['godot'],{})
        self.assertEqual('cleanup',execute.call_args.args[0][-2])
    def test_prepare_exception_still_cleans_up(self):
        with patch.object(runner,'execute',side_effect=[RuntimeError('write failed'),'cleanup']) as execute:
            with self.assertRaises(RuntimeError):runner.restart(['godot'],{})
        self.assertEqual(2,execute.call_count)
if __name__=='__main__':unittest.main()
