#!/usr/bin/env python3
"""Isolated native Godot test, not the full six-addon game or visual acceptance.

Copies the real presentation modules, a RefCounted test module, and compiled
synthetic pixels into a temporary project. No addon stubs or substituted game
systems. Every Godot invocation uses exact 1920x1080 and the pinned version.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = "4.7.2.stable.official.ed1daf0bf"
FILES = ["game/presentation/art/player_animation_state.gd",
         "game/presentation/art/layered_player_presenter.gd",
         "tests/presentation/art_module_contract.gd"]
DIAGNOSTIC = re.compile(r"(?:SCRIPT ERROR|ERROR|WARNING|Parse Error|ART_ASSERTION_FAILED):|Leaked instance|ObjectDB instances leaked", re.I)
RESULT = re.compile(r"ART_MODULE_RESULT checks=(\d+) failures=(\d+) digest=([0-9a-f]{64})")
PROJECT = '''config_version=5
[application]
config/name="Zerkov isolated art contract - synthetic pixels"
config/features=PackedStringArray("4.7", "GL Compatibility")
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''
DRIVER = '''extends SceneTree
func _initialize() -> void:
    root.size = Vector2i(1920, 1080)
    call_deferred("_run")
func _run() -> void:
    if root.size != Vector2i(1920, 1080):
        push_error("ART_OUTPUT_SIZE")
        quit(1)
        return
    var suite = load("res://tests/presentation/art_module_contract.gd").new()
    var result: Dictionary = suite.run()
    quit(0 if result["failures"] == 0 else 1)
'''


def checked(command: list[str], cwd: Path) -> str:
    print("RUN " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            timeout=180, env={**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"})
    output = result.stdout + result.stderr
    print(output, end="", flush=True)
    if result.returncode or DIAGNOSTIC.search(output):
        raise RuntimeError(f"process/diagnostic failure: exit={result.returncode}")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("ZERKOV_GODOT"))
    args = parser.parse_args()
    executable = shutil.which(args.godot) if args.godot else None
    if executable is None:
        print("ART_MODULE_BLOCKED: specify a usable pinned Godot executable")
        return 2
    try:
        version = checked([executable, "--version"], ROOT).strip()
        if version != PIN:
            raise RuntimeError(f"wrong engine: expected {PIN}, found {version}")
        # Import the actual compiler and explicit synthetic fixture only after
        # native prerequisites pass. Neither mutates the repository.
        import zerkov_art_pipeline as pipeline
        sys.path.insert(0, str(ROOT / "tests/tooling"))
        from test_art_pipeline import fixture
        recipe, pixels = fixture()
        plan = pipeline.build_plan(recipe, {"fixture.sheet": pixels}, "0" * 64)
        with tempfile.TemporaryDirectory(prefix="zerkov-art-native-") as directory:
            project = Path(directory)
            for name in FILES:
                target = project / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            for name, data in plan.items():
                target = project / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            (project / "project.godot").write_text(PROJECT, encoding="utf-8")
            (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
            common = [executable, "--headless", "--path", str(project),
                      "--resolution", "1920x1080", "--audio-driver", "Dummy"]
            checked(common + ["--editor", "--import", "--quit"], project)
            results = []
            for _ in range(2):
                output = checked(common + ["--script", "res://driver.gd"], project)
                match = RESULT.search(output)
                if match is None or int(match[1]) < 1 or int(match[2]) != 0:
                    raise RuntimeError("missing/invalid native result marker")
                results.append(match.groups())
            if results[0] != results[1]:
                raise RuntimeError("repeated native runs disagree")
            print(f"ART_NATIVE_GATE runs=2 checks={2 * int(results[0][0])} failures=0 diagnostics=0 "
                  f"digest={results[0][2]} scope=isolated-synthetic-pixels")
        return 0
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"ART_MODULE_BLOCKED: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
