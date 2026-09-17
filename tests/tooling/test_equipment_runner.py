"""Runner regressions: never hide the original native/UI failure behind cleanup."""
from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[2] / "tools/run_equipment_contracts.py"
SPEC = importlib.util.spec_from_file_location("equipment_runner", SOURCE)
assert SPEC is not None and SPEC.loader is not None
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class EquipmentRunnerTests(unittest.TestCase):
    def test_real_subprocess_timeout_retains_output(self):
        command = [sys.executable, "-u", "-c",
                   "import time; print('SCRIPT ERROR: original UI failure'); time.sleep(10)"]
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(subprocess.TimeoutExpired):
            runner.execute(command, dict(os.environ), timeout=1)
        self.assertIn("SCRIPT ERROR: original UI failure", output.getvalue())
        self.assertIn("EQUIPMENT_COMMAND_TIMEOUT", output.getvalue())

    def test_timeout_decodes_bytes_and_handles_missing_or_text_output(self):
        for data in [None, b"parse failure\xff", "parse failure"]:
            with self.subTest(data=data):
                error = subprocess.TimeoutExpired(["godot"], 1, output=data)
                output = io.StringIO()
                with patch.object(runner.subprocess, "run", side_effect=error), redirect_stdout(output):
                    with self.assertRaises(subprocess.TimeoutExpired) as raised:
                        runner.execute(["godot"], {}, timeout=1)
                self.assertIs(raised.exception, error)
                if data is not None:
                    self.assertIn("parse failure", output.getvalue())

    def test_original_error_survives_cleanup_failure(self):
        primary = RuntimeError("create-stage compile failure")
        cleanup = Mock(side_effect=subprocess.TimeoutExpired(["cleanup"], 30))
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(RuntimeError) as raised:
            with runner.cleanup_after(cleanup):
                raise primary
        self.assertIs(raised.exception, primary)
        cleanup.assert_called_once_with()
        self.assertIn("original failure retained", output.getvalue())

    def test_original_timeout_survives_cleanup_failure(self):
        primary = subprocess.TimeoutExpired(["create"], 240, output=b"original")
        cleanup = Mock(side_effect=RuntimeError("cleanup also failed"))
        with redirect_stdout(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired) as raised:
            with runner.cleanup_after(cleanup):
                raise primary
        self.assertIs(raised.exception, primary)
        cleanup.assert_called_once_with()

    def test_cleanup_runs_after_success_and_failure(self):
        cleanup = Mock()
        with runner.cleanup_after(cleanup):
            pass
        cleanup.assert_called_once_with()
        cleanup.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "stage failed"):
            with runner.cleanup_after(cleanup):
                raise RuntimeError("stage failed")
        cleanup.assert_called_once_with()

    def test_cleanup_only_failure_is_not_suppressed(self):
        cleanup = Mock(side_effect=RuntimeError("cleanup failed"))
        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            with runner.cleanup_after(cleanup):
                pass
        cleanup.assert_called_once_with()

    def test_diagnostics_fail_even_with_success_marker_and_exit_code(self):
        stdout = "SCRIPT ERROR: parse failed\nEQUIPMENT_UI_RESULT checks=10 failures=0\n"
        result = subprocess.CompletedProcess(["godot"], 0, stdout)
        with patch.object(runner.subprocess, "run", return_value=result), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "diagnostics failed"):
                runner.execute(["godot"], {}, "EQUIPMENT_UI_RESULT")

    def test_requires_nonzero_checks_and_zero_failures(self):
        for stdout in ["", "EQUIPMENT_UI_RESULT checks=0 failures=0\n",
                       "EQUIPMENT_UI_RESULT checks=5 failures=1\n"]:
            with self.subTest(stdout=stdout):
                result = subprocess.CompletedProcess(["godot"], 0, stdout)
                with patch.object(runner.subprocess, "run", return_value=result), redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "Missing zero-failure marker"):
                        runner.execute(["godot"], {}, "EQUIPMENT_UI_RESULT")
        stdout = "EQUIPMENT_UI_RESULT checks=5 failures=0\n"
        result = subprocess.CompletedProcess(["godot"], 0, stdout)
        with patch.object(runner.subprocess, "run", return_value=result), redirect_stdout(io.StringIO()):
            self.assertEqual(runner.execute(["godot"], {}, "EQUIPMENT_UI_RESULT"), stdout)


if __name__ == "__main__":
    unittest.main()
