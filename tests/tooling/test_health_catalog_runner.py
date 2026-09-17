#!/usr/bin/env python3
"""The native runner must reject diagnostics even after a success marker."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("health_runner", ROOT / "tools/run_health_catalog_contracts.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_valid_completion(self):
        output = "HEALTH_CATALOG_PERFORMANCE_RESULT checks=17 failures=0\n"
        self.assertIsNotNone(runner.MARKER.search(output))
        self.assertIsNone(runner.ERRORS.search(output))

    def test_missing_or_failed_completion(self):
        for output in ["", "HEALTH_CATALOG_PERFORMANCE_RESULT checks=0 failures=0",
                       "HEALTH_CATALOG_PERFORMANCE_RESULT checks=1 failures=1",
                       "HEALTH_CATALOG_PERFORMANCE_RESULT checks=1 failures=0 trailing"]:
            with self.subTest(output=output):
                self.assertIsNone(runner.MARKER.search(output))

    def test_zero_exit_does_not_hide_diagnostics(self):
        for diagnostic in ["SCRIPT ERROR: Bad call", "ERROR: leaked", "Parse Error: bad type",
                           "WARNING: ObjectDB instances leaked at exit",
                           "ERROR: 1 resources still in use at exit", "HEALTH_TIMEOUT"]:
            with self.subTest(diagnostic=diagnostic):
                output = "HEALTH_CATALOG_PERFORMANCE_RESULT checks=17 failures=0\n" + diagnostic
                result = subprocess.CompletedProcess(["godot"], 0, output)
                with patch.object(runner.subprocess, "run", return_value=result):
                    with self.assertRaises(RuntimeError):
                        runner.execute(["godot"], {})

    def test_nonzero_exit_is_failure(self):
        result = subprocess.CompletedProcess(["godot"], 1, "")
        with patch.object(runner.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError):
                runner.execute(["godot"], {})


if __name__ == "__main__":
    unittest.main()
