"""Runner regressions: never hide the original native/UI failure behind cleanup."""
from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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


    def test_runtime_import_only_disables_editor_dashboards_and_restores_bytes(self):
        config = b'[autoload]\nCommonUI="*res://addons/common_ui/runtime.gd"\n\n[editor_plugins]\nenabled=PackedStringArray("res://addons/example/plugin.cfg")\n\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp)
            path = project / "project.godot"
            path.write_bytes(config)
            extension = project / "example.gdextension"
            extension.write_bytes(b"native-extension-unchanged")
            def inspect(command, env):
                self.assertEqual(command, ["godot", "--headless", "--editor", "--import", "--quit"])
                self.assertEqual(path.read_bytes(), config.replace(b'enabled=PackedStringArray("res://addons/example/plugin.cfg")', b'enabled=PackedStringArray()'))
                self.assertEqual(extension.read_bytes(), b"native-extension-unchanged")
                return "import complete"
            with patch.object(runner, "execute", side_effect=inspect), redirect_stdout(io.StringIO()):
                runner.import_runtime_project(["godot", "--headless"], {}, project)
            self.assertEqual(path.read_bytes(), config)

    def test_failed_runtime_import_restores_config_and_keeps_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp)
            path = project / "project.godot"
            original = b'[editor_plugins]\nenabled=PackedStringArray("plugin.cfg")\n'
            path.write_bytes(original)
            error = RuntimeError("native import failed")
            with patch.object(runner, "execute", side_effect=error), redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError) as raised:
                    runner.import_runtime_project(["godot"], {}, project)
            self.assertIs(raised.exception, error)
            self.assertEqual(path.read_bytes(), original)

    def test_full_flow_uses_distinct_namespace_and_two_fingerprint_reads(self):
        calls = []
        def execute(command, env, marker, timeout=180):
            calls.append((command, env, marker))
            return "LOCAL_FLOW_FINGERPRINT " + "a" * 64 + "\n"
        with patch.object(runner, "execute", side_effect=execute), redirect_stdout(io.StringIO()):
            runner.verify_local_flow(["godot"], {"ZERKOV_TEST_SCENARIO": "death"})
        self.assertEqual([c[2] for c in calls], ["NATIVE_LOCAL_FLOW_RESULT", "LOCAL_FLOW_VERIFY", "LOCAL_FLOW_VERIFY", "LOCAL_FLOW_CLEANUP"])
        self.assertTrue(all(c[1]["ZERKOV_TEST_SCENARIO"] == "full" for c in calls))
        namespaces = [c[0][c[0].index("--") + 2] for c in calls]
        self.assertEqual(len(set(namespaces)), 1)
        self.assertRegex(namespaces[0], r"^localflow_[a-f0-9]{32}$")


if __name__ == "__main__":
    unittest.main()
