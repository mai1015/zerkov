#!/usr/bin/env python3
"""Pinned native art contracts: synthetic negative controls and verified player art.

Runs real presentation modules in an isolated project, not the six-addon game.
No addon stubs, world mutation, smaller display suite or visual approval claim.
"""
from __future__ import annotations

import argparse
import hashlib
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
         "tests/presentation/art_module_contract.gd",
         "tests/presentation/real_player_art_contract.gd"]
DIAGNOSTIC = re.compile(r"(?:SCRIPT ERROR|ERROR|WARNING|Parse Error|ART_ASSERTION_FAILED):|Leaked instance|ObjectDB instances leaked", re.I)
RESULT = re.compile(r"ART_MODULE_RESULT checks=(\d+) failures=(\d+) digest=([0-9a-f]{64})")
REAL_RESULT = re.compile(r"ART_REAL_PLAYER_RESULT checks=(\d+) failures=(\d+) sources=20 poses=66")
PROJECT = '''config_version=5
[application]
config/name="Zerkov isolated art contracts"
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
    call_deferred("_run")
func _run() -> void:
    # Engine startup can replace the early _initialize size. Apply the approved
    # output at deferred entry, before constructing or sampling any presentation.
    root.size = Vector2i(1920, 1080)
    root.content_scale_size = Vector2i(1920, 1080)
    if root.size != Vector2i(1920, 1080):
        push_error("ART_OUTPUT_SIZE: " + str(root.size))
        quit(1)
        return
    var suite = load("res://tests/presentation/art_module_contract.gd").new()
    var result: Dictionary = suite.run()
    var real_suite = load("res://tests/presentation/real_player_art_contract.gd").new()
    var real_result: Dictionary = real_suite.run()
    quit(0 if result["failures"] == 0 and real_result["failures"] == 0 else 1)
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
        import zerkov_art_pipeline as pipeline
        sys.path.insert(0, str(ROOT / "tests/tooling"))
        from test_art_pipeline import fixture
        recipe, pixels = fixture()
        plan = pipeline.build_plan(recipe, {"fixture.sheet": pixels}, "0" * 64)
        real_recipe = pipeline.validate_recipe(pipeline.read_json(pipeline.DEFAULT_RECIPE))
        # Select only explicitly named clip layer identities, never path guesses.
        ids = {sid for clip in real_recipe["clips"].values() for sid in clip["layers"]}
        real_recipe["sources"] = [s for s in real_recipe["sources"] if s["id"] in ids]
        selected = {s["id"]: (ROOT / "assets/original" / s["path"]).read_bytes()
                    for s in real_recipe["sources"]}
        archive_sha = "ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006"
        plan.update(pipeline.build_plan(real_recipe, selected, archive_sha))
        plan["game/content/art/player_recipe.json"] = pipeline.json_bytes(real_recipe)
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
                synthetic = RESULT.search(output)
                real = REAL_RESULT.search(output)
                if (synthetic is None or real is None or int(synthetic[1]) < 1
                        or int(real[1]) < 1 or int(synthetic[2]) or int(real[2])):
                    raise RuntimeError("missing/invalid native result marker")
                results.append((synthetic.groups(), real.groups()))
            if results[0] != results[1]:
                raise RuntimeError("repeated native runs disagree")
            count = 2 * (int(results[0][0][0]) + int(results[0][1][0]))
            print(f"ART_NATIVE_GATE runs=2 checks={count} failures=0 diagnostics=0 "
                  f"digest={results[0][0][2]} scope=isolated-real-player-and-synthetic")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"ART_MODULE_BLOCKED: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
