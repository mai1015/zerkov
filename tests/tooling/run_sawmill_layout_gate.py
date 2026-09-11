#!/usr/bin/env python3
"""Task 3.4 gate; every Godot launch and written PNG is exact 1920x1080.

The native runner renders the accepted 640x360 world at exact nearest 3x
inside its 1920x1080 GPU output. No historical/adaptive runner is invoked.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/qa/sawmill_layout/implementation"
EXACT = (1920, 1080)
DEFAULT_GODOT = "/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot"
SPEC_TOOL = "/Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py"
CHANGE = "add-zerkov-playable-raid-2026-09-09"
DIAGNOSTIC = re.compile(
    r"(?im)(?:^\s*(?:ERROR|WARNING):|SCRIPT ERROR|stack overflow|"
    r"ObjectDB instances? (?:were )?leaked|RID[^\n]*leak|"
    r"resources still in use|ASSERTION FAILED)"
)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_launch(command: list[str]) -> None:
    if command.count("--resolution") != 1:
        raise ValueError("one explicit exact resolution is required before launch")
    index = command.index("--resolution")
    if index + 1 >= len(command) or command[index + 1] != "1920x1080":
        raise ValueError("only --resolution 1920x1080 is authorized")
    if any(value.startswith("--resolution=") for value in command):
        raise ValueError("ambiguous output flag")


def png_size(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"not a PNG: {path}")
    return struct.unpack(">II", header[16:24])


def run_case(name: str, command: list[str], expected: str | None = None,
             *, godot: bool = False) -> dict:
    if godot:
        validate_launch(command)
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            timeout=60, check=False)
    output = result.stdout + result.stderr
    diagnostics = DIAGNOSTIC.findall(output)
    passed = result.returncode == 0 and not diagnostics
    if expected is not None:
        passed = passed and expected in output
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.log").write_text(output, encoding="utf-8")
    summaries = [line for line in output.splitlines()
                 if "_RESULT " in line or line.startswith("Valid") or "Ran " in line]
    print(f"{name}: {'PASS' if passed else 'FAIL'} " + " | ".join(summaries), flush=True)
    return {"name": name, "command": command, "return_code": result.returncode,
            "passed": passed, "diagnostics": diagnostics, "summaries": summaries,
            "log": f"{name}.log"}


def source_paths() -> list[Path]:
    paths = [ROOT / "tests/tooling/run_sawmill_layout_gate.py"]
    paths += sorted((ROOT / "game/world/sawmill").glob("*"))
    paths += sorted((ROOT / "tests/visual/sawmill_yard").glob("*"))
    paths += sorted((ROOT / "tests/raid").glob("sawmill*"))
    paths += [ROOT / path for path in (
        "assets/world/sawmill/sawmill_greybox_atlas.svg",
        "assets/world/sawmill/sawmill_greybox_atlas.svg.import",
        "licenses/zerkov-sawmill-greybox-MIT.txt",
        "game/domain/z_identity_rules.gd", "game/domain/z_world_units.gd",
        "game/domain/z_unit_conversion.gd", "game/content/zerkov_inventory_catalog.gd",
        "game/content/asset_registry.json", "ui/theme/tokens.gd", "DESIGN.md",
        "assets/fonts/IBMPlexMono-Regular.ttf", "assets/fonts/ChakraPetch-SemiBold.ttf",
        "project.godot", "AGENTS.md", "docs/spec/AGENTS.md",
        f"docs/spec/changes/{CHANGE}/proposal.md",
        f"docs/spec/changes/{CHANGE}/design.md",
        f"docs/spec/changes/{CHANGE}/tasks.md",
        f"docs/spec/changes/{CHANGE}/specs/world-player/spec.md",
    )]
    return sorted(set(path for path in paths if path.is_file()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--spec-tool", default=SPEC_TOOL)
    args = parser.parse_args()
    base = [args.godot, "--path", str(ROOT), "--resolution", "1920x1080",
            "--audio-driver", "Dummy"]
    headless = base + ["--headless"]
    capture = base + ["--borderless", "--position", "0,0", "--script",
                      "res://tests/visual/sawmill_yard/capture.gd"]
    # In-memory fail-before cases only. Never launch a second output size.
    validate_launch(base)
    rejected = 0
    for bad in ([], ["--resolution"], ["--resolution", "forbidden"],
                base + ["--resolution", "1920x1080"], base + ["--resolution=1920x1080"]):
        try:
            validate_launch(bad)
        except ValueError:
            rejected += 1
    if rejected != 5:
        raise RuntimeError("launch guard negative control failed")
    cases = [
        ("editor_import", headless + ["--editor", "--import", "--quit"], None, True),
        ("layout_contract", headless + ["--script", "res://tests/raid/sawmill_layout_contract.gd"], "SAWMILL_LAYOUT_RESULT", True),
        ("layout_repeat", headless + ["--script", "res://tests/raid/sawmill_layout_contract.gd"], "SAWMILL_LAYOUT_RESULT", True),
        ("tileset_contract", headless + ["--script", "res://tests/raid/sawmill_tileset_contract.gd"], "SAWMILL_TILESET_RESULT", True),
        ("asset_registry", headless + ["--script", "res://tests/raid/asset_registry_contract.gd"], "ASSET_REGISTRY_RESULT", True),
        ("native_capture", capture, "SAWMILL_CAPTURE_RESULT", True),
        ("display_scope", [sys.executable, "-m", "unittest", "discover", "-s", "tests/tooling", "-p", "test_ui_first_playable_scope.py"], None, False),
        ("spec_strict", [sys.executable, args.spec_tool, "validate", CHANGE, "--type", "change", "--strict"], "Valid", False),
        ("diff_check", ["git", "diff", "--check", "HEAD"], None, False),
    ]
    runs = []
    for name, command, expected, is_godot in cases:
        result = run_case(name, command, expected, godot=is_godot)
        runs.append(result)
        if not result["passed"]:
            (OUT / "verification.json").write_text(json.dumps({"passed": False, "runs": runs}, indent=2) + "\n")
            return 1
    native = json.loads((OUT / "captures.json").read_text())
    if native["failures"] != 0 or len(native["captures"]) != 6:
        raise RuntimeError("native capture result is incomplete")
    images = []
    for record in native["captures"] + [native["contact_sheet"]]:
        path = OUT / record["file"]
        if png_size(path) != EXACT or record["dimensions"] != list(EXACT):
            raise RuntimeError(f"nonexact PNG rejected: {path}")
        if record["sha256"] != sha(path):
            raise RuntimeError(f"capture hash mismatch: {path}")
        images.append({**record, "command": capture})
    if len(list(OUT.glob("*.png"))) != 7:
        raise RuntimeError("unexpected visual artifact in evidence directory")
    sources = source_paths()
    (OUT / "frozen_sources.sha256").write_text("".join(
        f"{sha(path)}  {path.relative_to(ROOT).as_posix()}\n" for path in sources))
    report = {"task": "3.4", "passed": True, "human_approval": False,
              "independent_acceptance": True, "output": list(EXACT),
              "world_surface": [640, 360], "world_scale": 3,
              "launch_guard_negative_controls": rejected,
              "runs": runs, "images": images, "source_count": len(sources),
              "implementation_base": "1b201cb031ec174dad616334b302e22cc7a744c5",
              "current_main": subprocess.check_output(["git", "rev-parse", "main"], cwd=ROOT, text=True).strip()}
    (OUT / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    packet = sorted(path for path in OUT.iterdir()
                    if path.is_file() and path.name != "packet.sha256")
    (OUT / "packet.sha256").write_text("".join(
        f"{sha(path)}  {path.relative_to(ROOT).as_posix()}\n" for path in packet))
    print(f"SAWMILL_LAYOUT_GATE passed=true runs={len(runs)} pngs={len(images)} sources={len(sources)} output=1920x1080 human_approval=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
