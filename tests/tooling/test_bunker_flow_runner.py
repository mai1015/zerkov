"""Runner controls only. These mocks never substitute for native app evidence."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bunker_flow_runner", ROOT / "tools/run_bunker_flow_contracts.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class RunnerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / "checkout"
        (self.root / "config").mkdir(parents=True)
        (self.root / "config/toolchain.lock.json").write_text('{"engine":{"required_version":"locked.test"}}')
        (self.root / ".godot").mkdir()
        (self.root / ".godot/keep").write_text("source cache")
        self.engine = self.base / "not-executed"
        self.engine.write_text("not an engine")
        self.out = self.base / "results"
        self.calls = []

    def result(self, command, env, marker=None, **kwargs):
        self.calls.append(command)
        if "--version" in command: return "locked.test\n"
        if "--import" in command:
            project = Path(command[command.index("--path") + 1])
            self.assertFalse((project / ".godot").exists())
            return "imported"
        if "cleanup" in command: return "BUNKER_FLOW_CLEANUP checks=1 failures=0\n"
        return "BUNKER_FLOW_RESULT checks=2 failures=0\nBUNKER_FLOW_FINGERPRINT " + "a" * 64 + "\n"

    def run_main(self, action=None, output=None, graphical=False):
        args = ["runner", "--godot", str(self.engine), "--output", str(output or self.out)]
        if graphical: args.append("--graphical")
        with patch.object(runner, "ROOT", self.root), patch.object(sys, "argv", args), \
             patch.object(runner.flow, "execute", side_effect=action or self.result), contextlib.redirect_stdout(io.StringIO()):
            return runner.main()

    def test_current_lock_and_two_processes_and_cleanup(self):
        self.assertEqual(0, self.run_main())
        self.assertEqual(5, len(self.calls))
        for command in self.calls[1:]:
            self.assertIn("--headless", command)
            self.assertEqual("1920x1080", command[command.index("--resolution") + 1])
        self.assertIn("new", self.calls[2])
        self.assertIn("continue", self.calls[3])
        self.assertIn("cleanup", self.calls[4])
        self.assertEqual("source cache", (self.root / ".godot/keep").read_text())
        self.assertEqual([2, 2], json.loads((self.out / "result.json").read_text())["checks"])

    def test_cannot_write_into_checkout(self):
        self.assertEqual(1, self.run_main(output=self.root / "result"))
        self.assertFalse((self.root / "result").exists())

    def test_existing_output_is_not_deleted(self):
        self.out.mkdir()
        (self.out / "keep").write_text("retained")
        self.assertEqual(1, self.run_main())
        self.assertEqual("retained", (self.out / "keep").read_text())

    def test_wrong_engine_stops_before_import(self):
        self.assertEqual(1, self.run_main(action=lambda *a, **k: "wrong.version"))

    def test_failure_does_not_skip_cleanup(self):
        def execute(command, *args, **kwargs):
            if "new" in command:
                raise RuntimeError("native failure")
            return self.result(command, *args, **kwargs)
        self.assertEqual(1, self.run_main(execute))
        self.assertIn("cleanup", self.calls[-1])
        self.assertFalse((self.out / "result.json").exists())

    def test_missing_fingerprint_is_not_success(self):
        def execute(command, *args, **kwargs):
            if "new" in command: return "BUNKER_FLOW_RESULT checks=2 failures=0\n"
            return self.result(command, *args, **kwargs)
        self.assertEqual(1, self.run_main(execute))
        self.assertIn("cleanup", self.calls[-1])

    def test_continue_must_preserve_fingerprint(self):
        def execute(command, *args, **kwargs):
            out = self.result(command, *args, **kwargs)
            return out.replace("a" * 64, "b" * 64) if "continue" in command else out
        self.assertEqual(1, self.run_main(execute))

    def test_graphical_output_requires_real_capture_set(self):
        self.assertEqual(1, self.run_main(graphical=True))
        self.assertNotIn("--headless", self.calls[2])
        self.assertFalse((self.out / "result.json").exists())

if __name__ == "__main__":
    unittest.main()
