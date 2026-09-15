#!/usr/bin/env python3
"""Run source-local pure AI contracts without silently substituting native addons.

Default mode copies an explicit source allowlist into a temporary Godot project.
--native imports a temporary copy of the complete checkout with the real addons.
Neither mode writes an import cache into the source checkout.
--render additionally requires a graphical session; it never treats headless as
visual evidence. No engine, logs, imported caches or captures are checked in.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SOURCES = (
    "game/domain/z_identity_rules.gd",
    "game/domain/z_world_units.gd",
    "game/domain/z_unit_conversion.gd",
    "game/ai/ai_values.gd",
    "game/ai/ai_profile.gd",
    "game/ai/ai_agent.gd",
    "game/ai/ai_world_port.gd",
    "game/ai/ai_phase_driver.gd",
    "game/ai/raid_ai_runtime.gd",
    "game/ai/noise/raid_noise_service.gd",
    "game/ai/vision/raid_vision_actor_registry.gd",
    "game/ai/vision/vision_ai_adapter.gd",
    "game/ai/profiles/scav.tres",
    "game/ai/profiles/mutant.tres",
    "game/ai/debug/ai_debug_overlay.gd",
    "tests/ai/fixtures/ai_test_fixtures.gd",
    "tests/ai/ai_workstream_contract.gd",
    "tests/ai/ai_review_regression_contract.gd",
    "tests/ai/noise_service_contract.gd",
)
RENDER_SOURCES = (
    "game/ai/debug/ai_debug_overlay.tscn",
    "tests/ai/ai_debug_render_contract.gd",
)
ERROR_PATTERN = re.compile(r"SCRIPT ERROR|(^|\n)\s*(?:ERROR:|Parse Error:)|extension.*(?:failed|not found)", re.I)
PROJECT = '''config_version=5
[application]
config/name="Zerkov isolated AI contract"
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''


def execute(command: list[str], *, result_name: str | None = None) -> str:
    completed = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=120,
                               env={**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"})
    output = completed.stdout
    print(output, end="" if output.endswith("\n") else "\n")
    if completed.returncode or ERROR_PATTERN.search(output):
        raise RuntimeError(f"Command or diagnostics failed (exit {completed.returncode}): {command}")
    if result_name and not re.search(rf"(?m)^{re.escape(result_name)} .*\bfailures=0(?:\s|$)", output):
        raise RuntimeError(f"Missing zero-failure result: {result_name}")
    return output


def run_project(godot: Path, project: Path, *, native: bool, render: bool, capture: Path | None) -> None:
    base = [str(godot), "--path", str(project), "--audio-driver", "Dummy"]
    execute(base + ["--headless", "--editor", "--import", "--quit"])
    digests = []
    for _ in range(2):
        output = execute(base + ["--headless", "--script", "res://tests/ai/ai_workstream_contract.gd"],
                         result_name="AI_WORKSTREAM_RESULT")
        match = re.search(r"(?m)^AI_WORKSTREAM_RESULT .*\bdigest=([a-f0-9]{64})(?:\s|$)", output)
        if not match:
            raise RuntimeError("Missing deterministic AI replay digest")
        digests.append(match.group(1))
    if digests[0] != digests[1]:
        raise RuntimeError("Repeated AI runs produced different digests")
    execute(base + ["--headless", "--script", "res://tests/ai/noise_service_contract.gd"],
            result_name="NOISE_SERVICE_RESULT")
    execute(base + ["--headless", "--script", "res://tests/ai/ai_review_regression_contract.gd"],
            result_name="AI_REVIEW_RESULT")
    if native:
        execute(base + ["--headless", "--script", "res://tests/ai/native_ai_vision_contract.gd"],
                result_name="NATIVE_AI_VISION_RESULT")
        execute(base + ["--headless", "--script", "res://tests/ai/native_ai_owner_contract.gd"],
                result_name="NATIVE_AI_OWNER_RESULT")
        execute(base + ["--headless", "--script", "res://tests/ai/native_ai_owner_review_contract.gd"],
                result_name="NATIVE_AI_OWNER_REVIEW_RESULT")
    if render:
        command = base + ["--rendering-method", "gl_compatibility", "--script", "res://tests/ai/ai_debug_render_contract.gd"]
        if capture:
            command += ["--", f"--capture={capture.resolve()}"]
        execute(command, result_name="AI_DEBUG_RENDER_RESULT")


def required_version(root: Path) -> str:
    """The checked-in lock is the only engine version authority."""
    value = json.loads((root / "config/toolchain.lock.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("engine"), dict):
        raise ValueError("Invalid engine lock")
    version = value["engine"].get("required_version")
    if not isinstance(version, str) or not version.strip() or version != version.strip():
        raise ValueError("Missing or invalid engine.required_version")
    return version


def check_version(godot: Path, root: Path) -> None:
    expected = required_version(root)
    actual = execute([str(godot), "--version"]).strip()
    if actual != expected:
        raise RuntimeError(f"Locked engine required: {expected}; got {actual!r}")


def prepare_project(root: Path, project: Path, *, native: bool, render: bool) -> None:
    """Copy sources, never source import caches. Project must be outside root."""
    root, project = root.resolve(), project.resolve()
    if os.path.commonpath([str(root), str(project)]) == str(root):
        raise ValueError("Test staging directory must be outside the source checkout")
    if native:
        if not (root / "project.godot").is_file():
            raise RuntimeError("Missing project.godot for native checkout staging")
        shutil.copytree(root, project, symlinks=False,
                        ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
        return
    project.mkdir(parents=True)
    (project / "project.godot").write_text(PROJECT, encoding="utf-8")
    for relative in SOURCES + (RENDER_SOURCES if render else ()):
        source = root / relative
        if not source.is_file():
            raise RuntimeError(f"Missing checked-in test dependency: {relative}")
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        uid = source.with_suffix(source.suffix + ".uid")
        if uid.is_file():
            shutil.copyfile(uid, target.with_suffix(target.suffix + ".uid"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--native", action="store_true", help="Require a temporary full-checkout import and real Common Vision tests.")
    parser.add_argument("--render", action="store_true", help="Require real 1920x1080 renderer/virtual display.")
    parser.add_argument("--capture", type=Path, help="Optional diagnostic PNG; requires --render.")
    args = parser.parse_args()
    if args.capture and not args.render:
        parser.error("--capture requires --render")
    godot = args.godot.expanduser().resolve()
    root = Path(__file__).resolve().parents[1]
    try:
        if not godot.is_file() or not os.access(godot, os.X_OK):
            raise RuntimeError(f"Godot executable unavailable: {godot}")
        check_version(godot, root)
        with tempfile.TemporaryDirectory(prefix="zerkov-ai-contract-") as temporary:
            project = Path(temporary) / "project"
            prepare_project(root, project, native=args.native, render=args.render)
            run_project(godot, project, native=args.native, render=args.render, capture=args.capture)
        print("AI_RUNNER_COMPLETE mode=" + ("native-copy native_vision=PASSED" if args.native else "isolated native_vision=NOT_RUN"))
        return 0
    except (OSError, subprocess.TimeoutExpired, RuntimeError, KeyError, ValueError) as error:
        print(f"AI_RUNNER_FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
