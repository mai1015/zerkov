"""Host-side tests for the task-5.7 runner; no Godot or native stubs required."""
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("combat_input_runner", ROOT / "tools/run_combat_input_contracts.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_lock_is_only_version_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "config").mkdir()
            (root / "config/toolchain.lock.json").write_text(json.dumps({"engine": {"required_version": "future.test.version"}}))
            self.assertEqual(runner.expected_version(root), "future.test.version")

    def test_invalid_lock_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "config").mkdir()
            for version in [None, 42, "", " version "]:
                (root / "config/toolchain.lock.json").write_text(json.dumps({"engine": {"required_version": version}}))
                with self.assertRaises(ValueError):
                    runner.expected_version(root)

    def test_native_copy_does_not_share_imported_cache_or_worktree(self):
        with tempfile.TemporaryDirectory() as d:
            root, dest = Path(d) / "source", Path(d) / "copy"
            root.mkdir()
            (root / ".godot").mkdir()
            (root / ".godot/cache").write_text("old import")
            (root / ".git").mkdir()
            (root / ".git/HEAD").write_text("private git config")
            (root / "game.gd").write_text("original")
            runner.prepare(root, dest, True)
            self.assertFalse((dest / ".godot").exists())
            self.assertFalse((dest / ".git").exists())
            (dest / "game.gd").write_text("import modified")
            self.assertEqual((root / "game.gd").read_text(), "original")

    def test_isolated_copy_excludes_native_sink(self):
        with tempfile.TemporaryDirectory() as d:
            root, dest = Path(d) / "source", Path(d) / "copy"
            for relative in runner.SOURCES:
                p = root / relative
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("test fixture source")
            native = root / "game/input/combat/raid_combat_intent_sink.gd"
            native.write_text("requires real RaidAuthority")
            runner.prepare(root, dest, False)
            self.assertFalse((dest / native.relative_to(root)).exists())
            self.assertIn("1920", (dest / "project.godot").read_text())

    def test_missing_source_fails(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(FileNotFoundError):
                runner.prepare(Path(d) / "source", Path(d) / "copy", False)

    def test_zero_exit_script_error_is_failure(self):
        out = subprocess.CompletedProcess([], 0, "SCRIPT ERROR: parse error\nCOMBAT_INTENT_RESULT failures=0\n")
        with patch.object(runner.subprocess, "run", return_value=out), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                runner.execute(["godot"])

    def test_blocked_native_is_not_pass(self):
        out = subprocess.CompletedProcess([], 2, "NATIVE_COMBAT_INTENT_BLOCKED missing_CommonVisionWorld2D\n")
        with patch.object(runner.subprocess, "run", return_value=out), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                runner.execute(["godot"])

    def test_named_result_required(self):
        with patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "Godot started\n")), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                runner.execute(["godot"], "COMBAT_INTENT_RESULT")

    def test_mismatched_replay_rejected(self):
        outputs = ["import", "COMBAT_INTENT_RESULT checks=1 failures=0 digest=" + "a" * 64,
                   "COMBAT_INTENT_RESULT checks=1 failures=0 digest=" + "b" * 64]
        with patch.object(runner, "execute", side_effect=outputs):
            with self.assertRaisesRegex(RuntimeError, "digests differ"):
                runner.run(Path("godot"), Path("project"), False)

    def test_native_suite_and_exact_canvas_requested(self):
        outputs = ["import"] + ["COMBAT_INTENT_RESULT checks=1 failures=0 digest=" + "a" * 64] * 2 + ["NATIVE_COMBAT_INTENT_RESULT checks=1 failures=0"]
        with patch.object(runner, "execute", side_effect=outputs) as execute, contextlib.redirect_stdout(io.StringIO()):
            runner.run(Path("godot"), Path("project"), True)
        self.assertEqual(execute.call_count, 4)
        for args in execute.call_args_list:
            command = args.args[0]
            self.assertIn("--headless", command)
            self.assertEqual(command[command.index("--resolution") + 1], "1920x1080")
        self.assertIn("res://tests/combat/native_combat_intent_contract.gd", execute.call_args.args[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
