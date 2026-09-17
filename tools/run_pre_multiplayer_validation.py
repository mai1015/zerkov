#!/usr/bin/env python3
"""Run the current pre-multiplayer validation layers without weakening them.

The repository ships macOS native add-ons only. ``isolated`` mode is therefore
portable and exercises source policy plus the source-isolated combat, AI and
progression runners. ``native`` and ``local-flow`` require a host on which the
checked-in add-ons can load. Every child runner owns its diagnostic policy; this
orchestrator treats any non-zero child result or timeout as a failure.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "config/toolchain.lock.json"
SCENARIOS = ("full", "death", "clock", "launch")
MODES = ("isolated", "native", "local-flow", "all")


@dataclass(frozen=True)
class Stage:
    name: str
    command: tuple[str, ...]
    timeout_seconds: int
    environment: Mapping[str, str] = field(default_factory=dict)


def locked_engine_version(root: Path = ROOT) -> str:
    payload = json.loads((root / "config/toolchain.lock.json").read_text(encoding="utf-8"))
    version = payload.get("engine", {}).get("required_version")
    if not isinstance(version, str) or not version:
        raise ValueError("config/toolchain.lock.json has no engine.required_version")
    return version


def verify_engine(
    godot: Path,
    root: Path = ROOT,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> str:
    if not godot.is_file():
        raise FileNotFoundError(f"Godot executable not found: {godot}")
    result = runner(
        [str(godot), "--version"],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
    observed = (result.stdout or "").strip().splitlines()
    version = observed[-1].strip() if observed else ""
    expected = locked_engine_version(root)
    if result.returncode != 0 or version != expected:
        raise RuntimeError(
            f"Godot version mismatch: expected {expected!r}, observed {version!r}, "
            f"exit={result.returncode}"
        )
    return version


def build_stages(
    *,
    python: str,
    godot: Path,
    mode: str,
    scenario: str,
) -> tuple[Stage, ...]:
    if mode not in MODES:
        raise ValueError(f"unsupported mode: {mode}")
    if scenario not in SCENARIOS:
        raise ValueError(f"unsupported local-flow scenario: {scenario}")

    stages: list[Stage] = []
    if mode in ("isolated", "native", "all"):
        stages.extend(
            [
                Stage(
                    "tooling",
                    (python, "-m", "unittest", "discover", "-s", "tests/tooling", "-p", "test_*.py", "-v"),
                    180,
                ),
                Stage("exact-1080-policy", (python, "tools/check_first_playable_1080.py"), 90),
            ]
        )
        native = mode in ("native", "all")
        combat = [python, "tools/run_combat_input_contracts.py", "--godot", str(godot), "--execution"]
        ai = [python, "tools/run_ai_contracts.py", "--godot", str(godot)]
        progression = [python, "tools/run_raid_progression_contracts.py", "--godot", str(godot)]
        if native:
            combat.append("--native")
            ai.append("--native")
            progression.append("--native")
        stages.extend(
            [
                Stage("combat-native" if native else "combat-isolated", tuple(combat), 900),
                Stage("ai-native" if native else "ai-isolated", tuple(ai), 900),
                Stage("progression-native" if native else "progression-isolated", tuple(progression), 900),
            ]
        )

    if mode in ("local-flow", "all"):
        # Local-flow mode still checks the two repository-level invariants that
        # can invalidate an otherwise green native run.
        if mode == "local-flow":
            stages.extend(
                [
                    Stage("registration-idempotence", (python, "tests/tooling/test_registration_idempotence.py"), 90),
                    Stage("exact-1080-policy", (python, "tools/check_first_playable_1080.py"), 90),
                ]
            )
        stages.append(
            Stage(
                f"local-flow-{scenario}",
                (python, "tools/run_local_flow_contracts.py", "--godot", str(godot)),
                1_200,
                {"ZERKOV_TEST_SCENARIO": scenario},
            )
        )
    return tuple(stages)


def execute_stages(
    stages: Sequence[Stage],
    *,
    root: Path = ROOT,
    base_environment: Mapping[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[object]] = subprocess.run,
) -> bool:
    environment = dict(os.environ if base_environment is None else base_environment)
    environment.setdefault("GODOT_SILENCE_ROOT_WARNING", "1")
    for stage in stages:
        stage_environment = environment.copy()
        stage_environment.update(stage.environment)
        print(
            "PRE_MULTIPLAYER_VALIDATION_STAGE"
            f" name={stage.name} state=start command={json.dumps(stage.command)}",
            flush=True,
        )
        started = time.monotonic()
        try:
            result = runner(
                list(stage.command),
                cwd=root,
                env=stage_environment,
                timeout=stage.timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            print(
                "PRE_MULTIPLAYER_VALIDATION_STAGE"
                f" name={stage.name} state=timeout seconds={elapsed:.3f}",
                file=sys.stderr,
                flush=True,
            )
            return False
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            print(
                "PRE_MULTIPLAYER_VALIDATION_STAGE"
                f" name={stage.name} state=failed exit={result.returncode} seconds={elapsed:.3f}",
                file=sys.stderr,
                flush=True,
            )
            return False
        print(
            "PRE_MULTIPLAYER_VALIDATION_STAGE"
            f" name={stage.name} state=passed seconds={elapsed:.3f}",
            flush=True,
        )
    return True


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--mode", choices=MODES, default="isolated")
    parser.add_argument("--scenario", choices=SCENARIOS, default="full")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        version = verify_engine(args.godot)
        stages = build_stages(
            python=sys.executable,
            godot=args.godot,
            mode=args.mode,
            scenario=args.scenario,
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"PRE_MULTIPLAYER_VALIDATION_SETUP_FAILED {error}", file=sys.stderr)
        return 2
    if not execute_stages(stages):
        return 1
    print(
        "PRE_MULTIPLAYER_VALIDATION_COMPLETE"
        f" mode={args.mode} scenario={args.scenario} stages={len(stages)} engine={version}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
