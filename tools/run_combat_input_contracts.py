#!/usr/bin/env python3
"""Task 5.7: queue admission tests, not a shooting/melee or UI playtest.

Both modes import temporary copies. --native additionally requires the real
RaidAuthority/addon baseline; no native classes are replaced by stubs.
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
    "game/domain/z_identity_rules.gd", "game/domain/z_stable_id.gd",
    "game/domain/z_entity_id.gd", "game/domain/z_session_id.gd",
    "game/domain/z_request_id.gd", "game/domain/z_raid_intent.gd",
    "game/domain/z_canonical_value.gd", "game/raid/raid_intent_queue.gd",
    "game/input/ui_intent_adapter.gd",
    "game/input/combat/combat_action_codec.gd",
    "game/input/combat/combat_input_adapter.gd",
    "game/input/combat/combat_intent_sink.gd",
    "game/input/combat/combat_action_router.gd",
    "tests/combat/combat_intent_contract.gd",
    "tests/combat/native_combat_intent_contract.gd",
)
ERRORS = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|extension.*(?:failed|not found)", re.I)
PROJECT = '''config_version=5
[application]
config/name="Zerkov combat input contract"
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/window_width_override=1920
window/size/window_height_override=1080
[rendering]
renderer/rendering_method="gl_compatibility"
'''


def expected_version(root: Path) -> str:
    lock = json.loads((root / "config/toolchain.lock.json").read_text(encoding="utf-8"))
    version = lock["engine"]["required_version"]
    if not isinstance(version, str) or not version or version.strip() != version:
        raise ValueError("Invalid engine version in toolchain lock")
    return version


def execute(command: list[str], result: str | None = None) -> str:
    completed = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=180,
                               env={**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"})
    output = completed.stdout
    print(output, end="" if output.endswith("\n") else "\n")
    if completed.returncode or ERRORS.search(output):
        raise RuntimeError(f"Command/diagnostics failed (exit {completed.returncode}): {command}")
    if result and not re.search(rf"(?m)^{re.escape(result)} .*\bfailures=0(?:\s|$)", output):
        raise RuntimeError(f"Missing zero-failure result: {result}")
    return output


def prepare(root: Path, project: Path, native: bool) -> None:
    if native:
        # No hardlinks/symlinks to the working checkout: imports may update files.
        shutil.copytree(root, project, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".git", ".godot", "__pycache__", ".DS_Store"))
    else:
        project.mkdir(parents=True, exist_ok=True)
        (project / "project.godot").write_text(PROJECT, encoding="utf-8")
        for relative in SOURCES:
            source = root / relative
            target = project / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            uid = source.with_suffix(source.suffix + ".uid")
            if uid.is_file():
                shutil.copyfile(uid, target.with_suffix(target.suffix + ".uid"))


def run(godot: Path, project: Path, native: bool) -> None:
    base = [str(godot), "--headless", "--resolution", "1920x1080", "--path", str(project), "--audio-driver", "Dummy"]
    execute(base + ["--editor", "--import", "--quit"])
    digests: list[str] = []
    for _ in range(2):
        output = execute(base + ["--script", "res://tests/combat/combat_intent_contract.gd"], "COMBAT_INTENT_RESULT")
        match = re.search(r"(?m)^COMBAT_INTENT_RESULT .*\bdigest=([0-9a-f]{64})(?:\s|$)", output)
        if match is None:
            raise RuntimeError("Missing combat replay digest")
        digests.append(match.group(1))
    if digests[0] != digests[1]:
        raise RuntimeError("Combat replay digests differ")
    if native:
        execute(base + ["--script", "res://tests/combat/native_combat_intent_contract.gd"], "NATIVE_COMBAT_INTENT_RESULT")
    print(f"COMBAT_INPUT_RUNNER_COMPLETE mode={'native' if native else 'isolated'} digest={digests[0]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    godot = args.godot.expanduser().resolve()
    try:
        pin = expected_version(root)
        if not godot.is_file() or not os.access(godot, os.X_OK):
            raise RuntimeError(f"Godot executable unavailable: {godot}")
        version = execute([str(godot), "--version"]).strip()
        if version != pin:
            raise RuntimeError(f"Expected locked Godot {pin}; got {version!r}")
        with tempfile.TemporaryDirectory(prefix="zerkov-combat-input-") as temporary:
            project = Path(temporary) / "project"
            prepare(root, project, args.native)
            run(godot, project, args.native)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"COMBAT_INPUT_RUNNER_FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
