#!/usr/bin/env python3
"""Run source-local pure AI contracts without silently substituting native addons.

Default mode copies an explicit source allowlist into a temporary Godot project.
--native instead imports the complete checkout and requires the real Vision addon.
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

REQUIRED_VERSION = "4.7.2.stable.official.ed1daf0bf"
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
    "game/ai/debug/ai_debug_overlay.tscn",
    "tests/ai/fixtures/ai_test_fixtures.gd",
    "tests/ai/ai_workstream_contract.gd",
    "tests/ai/native_ai_vision_contract.gd",
    "tests/ai/native_ai_owner_contract.gd",
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
    for _ in range(2):
        execute(base + ["--headless", "--script", "res://tests/ai/ai_workstream_contract.gd"],
                result_name="AI_WORKSTREAM_RESULT")
    if native:
        execute(base + ["--headless", "--script", "res://tests/ai/native_ai_vision_contract.gd"],
                result_name="NATIVE_AI_VISION_RESULT")
        execute(base + ["--headless", "--script", "res://tests/ai/native_ai_owner_contract.gd"],
                result_name="NATIVE_AI_OWNER_RESULT")
    if render:
        command = base + ["--rendering-method", "gl_compatibility", "--script", "res://tests/ai/ai_debug_render_contract.gd"]
        if capture:
            command += ["--", f"--capture={capture.resolve()}"]
        execute(command, result_name="AI_DEBUG_RENDER_RESULT")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--native", action="store_true", help="Require full-checkout import and real Common Vision test.")
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
        expected = REQUIRED_VERSION
        pin = root / "config/toolchain.lock.json"
        if pin.exists():
            expected = json.loads(pin.read_text())["engine"]["required_version"]
        version = execute([str(godot), "--version"]).strip()
        if version != expected or version != REQUIRED_VERSION:
            raise RuntimeError(f"Exact tested engine required: {REQUIRED_VERSION}; got {version!r}")
        if args.native:
            run_project(godot, root, native=True, render=args.render, capture=args.capture)
        else:
            with tempfile.TemporaryDirectory(prefix="zerkov-ai-contract-") as temporary:
                project = Path(temporary)
                (project / "project.godot").write_text(PROJECT)
                for relative in SOURCES:
                    source = root / relative
                    if not source.is_file():
                        raise RuntimeError(f"Missing checked-in test dependency: {relative}")
                    target = project / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                    if source.with_suffix(source.suffix + ".uid").is_file():
                        shutil.copyfile(source.with_suffix(source.suffix + ".uid"), target.with_suffix(target.suffix + ".uid"))
                run_project(godot, project, native=False, render=args.render, capture=args.capture)
            print("AI_RUNNER_COMPLETE mode=isolated native_vision=NOT_RUN")
        return 0
    except (OSError, subprocess.TimeoutExpired, RuntimeError, KeyError, ValueError) as error:
        print(f"AI_RUNNER_FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
