"""AI runner lock and checkout-isolation regressions; no engine needed."""
from __future__ import annotations

import importlib.util
import json
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[2] / "tools/run_ai_contracts.py"
spec = importlib.util.spec_from_file_location("ai_runner", MODULE_PATH)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerContract(unittest.TestCase):
    def setUp(self):
        output = patch("sys.stdout", new_callable=io.StringIO)
        output.start()
        self.addCleanup(output.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "checkout"
        (self.root / "config").mkdir(parents=True)
        self.lock = self.root / "config/toolchain.lock.json"

    def write_lock(self, version):
        self.lock.write_text(json.dumps({"engine": {"required_version": version}}))

    def test_lock_is_only_version_authority(self):
        self.write_lock("99.2.review.official.test")
        with patch.object(runner, "execute", return_value="99.2.review.official.test\n"):
            runner.check_version(Path("godot"), self.root)

    def test_mismatch_rejected(self):
        self.write_lock("99.2.review.official.test")
        with patch.object(runner, "execute", return_value="99.1.other"):
            with self.assertRaisesRegex(RuntimeError, "Locked engine required"):
                runner.check_version(Path("godot"), self.root)

    def test_missing_lock_rejected(self):
        with self.assertRaises(FileNotFoundError):
            runner.required_version(self.root)

    def test_malformed_lock_rejected(self):
        for value in [None, [], {}, {"engine": []}, {"engine": {}},
                      {"engine": {"required_version": 4}},
                      {"engine": {"required_version": " 4.7 "}},
                      {"engine": {"required_version": ""}}]:
            with self.subTest(value=value):
                self.lock.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    runner.required_version(self.root)

    def test_native_copy_does_not_touch_source_cache(self):
        (self.root / "project.godot").write_text(runner.PROJECT)
        (self.root / ".godot").mkdir()
        marker = self.root / ".godot/keep"
        marker.write_bytes(b"original cache")
        before = marker.stat().st_mtime_ns
        (self.root / "addons").mkdir()
        (self.root / "addons/native.so").write_bytes(b"test artifact bytes")
        (self.root / ".git").mkdir()
        (self.root / ".git/config").write_text("not a project dependency")
        target = self.base / "staged"
        runner.prepare_project(self.root, target, native=True, render=False)
        self.assertFalse((target / ".godot").exists())
        self.assertFalse((target / ".git").exists())
        self.assertEqual((target / "addons/native.so").read_bytes(), b"test artifact bytes")
        (target / ".godot").mkdir()
        (target / ".godot/keep").write_bytes(b"generated cache")
        self.assertEqual(marker.read_bytes(), b"original cache")
        self.assertEqual(marker.stat().st_mtime_ns, before)

    def test_staging_inside_checkout_rejected(self):
        with self.assertRaisesRegex(ValueError, "outside"):
            runner.prepare_project(self.root, self.root / "staged", native=True, render=False)

    def test_missing_dependency_rejected(self):
        with patch.object(runner, "SOURCES", ("missing.gd",)):
            with self.assertRaisesRegex(RuntimeError, "Missing checked-in"):
                runner.prepare_project(self.root, self.base / "staged", native=False, render=False)

    def test_zero_exit_script_error_rejected(self):
        result = subprocess.CompletedProcess([], 0, "SCRIPT ERROR: simulated\n")
        with patch.object(runner.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError):
                runner.execute(["fake-godot"])

    def test_missing_or_failed_marker_rejected(self):
        for output in ["", "EXPECTED checks=3 failures=1\n", "EXPECTED_BLOCKED missing_native\n"]:
            with patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)):
                with self.assertRaises(RuntimeError):
                    runner.execute(["fake-godot"], result_name="EXPECTED")

    def test_different_replay_digests_rejected(self):
        with patch.object(runner, "execute", side_effect=["import", *[
            "AI_WORKSTREAM_RESULT checks=1 failures=0 digest=" + digit * 64 for digit in ["a", "b"]
        ]]):
            with self.assertRaisesRegex(RuntimeError, "different digests"):
                runner.run_project(Path("godot"), self.root, native=False, render=False, capture=None)

    def test_native_mode_runs_owner_failure_contract(self):
        calls = []
        def execute(command, **kwargs):
            calls.append(command)
            return "AI_WORKSTREAM_RESULT checks=1 failures=0 digest=" + "a" * 64
        with patch.object(runner, "execute", side_effect=execute):
            runner.run_project(Path("godot"), self.base / "copy", native=True, render=False, capture=None)
        scripts = [command[command.index("--script") + 1] for command in calls if "--script" in command]
        self.assertIn("res://tests/ai/native_ai_owner_review_contract.gd", scripts)
        self.assertIn("res://tests/ai/native_ai_owner_contract.gd", scripts)
        self.assertIn("res://tests/ai/ai_review_regression_contract.gd", scripts)


if __name__ == "__main__":
    unittest.main()
