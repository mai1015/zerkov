from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "run_pre_multiplayer_validation", ROOT / "tools/run_pre_multiplayer_validation.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PreMultiplayerValidationTests(unittest.TestCase):
    def test_isolated_plan_runs_portable_layers_without_native_flags(self) -> None:
        stages = MODULE.build_stages(
            python="python-test",
            godot=Path("/engine/godot"),
            mode="isolated",
            scenario="full",
        )
        self.assertEqual(
            [stage.name for stage in stages],
            ["tooling", "exact-1080-policy", "combat-isolated", "ai-isolated", "progression-isolated"],
        )
        commands = [stage.command for stage in stages]
        self.assertIn("--execution", commands[2])
        self.assertFalse(any("--native" in command for command in commands))
        self.assertFalse(any("run_local_flow_contracts.py" in command for command in commands))

    def test_native_plan_requires_real_native_contract_modes(self) -> None:
        stages = MODULE.build_stages(
            python="python-test",
            godot=Path("/engine/godot"),
            mode="native",
            scenario="full",
        )
        domain = stages[2:]
        self.assertEqual([stage.name for stage in domain], ["combat-native", "ai-native", "progression-native"])
        self.assertTrue(all("--native" in stage.command for stage in domain))
        self.assertIn("--execution", domain[0].command)

    def test_local_flow_plan_is_scenario_scoped_and_keeps_repository_guards(self) -> None:
        stages = MODULE.build_stages(
            python="python-test",
            godot=Path("/engine/godot"),
            mode="local-flow",
            scenario="death",
        )
        self.assertEqual(
            [stage.name for stage in stages],
            ["registration-idempotence", "exact-1080-policy", "local-flow-death"],
        )
        self.assertEqual(dict(stages[-1].environment), {"ZERKOV_TEST_SCENARIO": "death"})
        self.assertTrue(any(value.endswith("run_local_flow_contracts.py") for value in stages[-1].command))

    def test_engine_version_must_match_the_lock_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            (root / "config/toolchain.lock.json").write_text(
                json.dumps({"engine": {"required_version": "4.7.2.stable.expected"}}),
                encoding="utf-8",
            )
            engine = root / "godot"
            engine.write_text("", encoding="utf-8")

            def good_runner(*_args, **_kwargs):
                return SimpleNamespace(returncode=0, stdout="4.7.2.stable.expected\n")

            self.assertEqual(MODULE.verify_engine(engine, root, good_runner), "4.7.2.stable.expected")

            def bad_runner(*_args, **_kwargs):
                return SimpleNamespace(returncode=0, stdout="4.7.2.stable.other\n")

            with self.assertRaises(RuntimeError):
                MODULE.verify_engine(engine, root, bad_runner)

    def test_first_failed_stage_stops_the_plan(self) -> None:
        calls: list[list[str]] = []

        def runner(command, **_kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=7 if len(calls) == 2 else 0)

        stages = (
            MODULE.Stage("one", ("one",), 1),
            MODULE.Stage("two", ("two",), 1),
            MODULE.Stage("three", ("three",), 1),
        )
        self.assertFalse(MODULE.execute_stages(stages, root=ROOT, base_environment={}, runner=runner))
        self.assertEqual(calls, [["one"], ["two"]])

    def test_timeout_is_a_failure(self) -> None:
        def runner(_command, **_kwargs):
            raise subprocess.TimeoutExpired(["slow"], 1)

        self.assertFalse(
            MODULE.execute_stages(
                (MODULE.Stage("slow", ("slow",), 1),),
                root=ROOT,
                base_environment={},
                runner=runner,
            )
        )


if __name__ == "__main__":
    unittest.main()
