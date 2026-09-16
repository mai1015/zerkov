"""Verifier negative controls. None simulate native networking behavior."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("verify", Path(__file__).with_name("verify.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
PASS = "ADDON_HARDENING_RESULT checks=80 failures=0 real_enet_peers=3 native=true\n"

class Verification(unittest.TestCase):
    def test_nonzero_exit_never_passes(self):
        with patch.object(verify.subprocess, "run", return_value=subprocess.CompletedProcess([], -6, PASS)), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError): verify.execute(["not-executed"])

    def test_script_errors_never_pass(self):
        for error in ["SCRIPT ERROR: parse failure", "ERROR: loader failure"]:
            with patch.object(verify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, error + "\n" + PASS)), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError): verify.execute(["not-executed"])

    def test_timeout_never_passes_and_preserves_diagnostic(self):
        capture = io.StringIO()
        with patch.object(verify.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 1, b"native diagnostic")), contextlib.redirect_stdout(capture):
            with self.assertRaises(subprocess.TimeoutExpired): verify.execute(["not-executed"])
        self.assertIn("native diagnostic", capture.getvalue())

    def test_empty_zero_failed_or_wrong_mode_markers_fail(self):
        for text in ["", PASS.replace("checks=80", "checks=0"), PASS.replace("failures=0", "failures=1"),
                     PASS.replace("native=true", "native=false"), PASS.replace("real_enet_peers=3", "real_enet_peers=0")]:
            with self.assertRaises(RuntimeError): verify.require_pass(text)

    def test_duplicate_markers_fail(self):
        with self.assertRaises(RuntimeError): verify.require_pass(PASS + PASS)

    def test_one_nonempty_native_marker_required(self):
        self.assertEqual(80, verify.require_pass("engine startup\n" + PASS))

if __name__ == "__main__": unittest.main()
