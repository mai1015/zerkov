#!/usr/bin/env python3
"""Real native equipment/UI and separate-process local-save contracts at 1080p."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ERRORS = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|ObjectDB instances leaked|resources still in use|_TIMEOUT")

def execute(command: list[str], env: dict[str, str], marker: str | None = None, timeout: int = 180) -> str:
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end="", flush=True)
    if result.returncode or ERRORS.search(result.stdout):
        raise RuntimeError(f"Native command/diagnostics failed: {result.returncode}: {command}")
    if marker and not re.search(rf"(?m)^{re.escape(marker)} checks=[1-9][0-9]* failures=0(?:\s|$)", result.stdout):
        raise RuntimeError(f"Missing zero-failure marker: {marker}")
    return result.stdout

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, help="Record native windowed AVI clips; not a real-time FPS measurement")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"}
    engine = str(args.godot.expanduser().resolve(strict=True))
    required = json.loads((source / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
    if execute([engine, "--version"], env).strip() != required:
        raise RuntimeError("Engine version does not match lock")
    with tempfile.TemporaryDirectory(prefix="zerkov-equipment-") as temp:
        project = Path(temp) / "project"
        shutil.copytree(source, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
        env["XDG_DATA_HOME"] = str(Path(temp) / "user")
        base = [engine, "--headless", "--path", str(project), "--resolution", "1920x1080", "--audio-driver", "Dummy"]
        execute(base + ["--editor", "--import", "--quit"], env)
        for path, marker in [
            ("tests/equipment/equipment_contract.gd", "EQUIPMENT_CONTRACT_RESULT"),
            ("tests/raid/equipped_item_reconciliation_contract.gd", "EQUIPPED_ITEM_RECONCILIATION_RESULT"),
            ("tests/raid/inventory_ability_reconciliation_contract.gd", "INVENTORY_ABILITY_RECONCILIATION_RESULT"),
            ("tests/presentation/character_ui_binding_8_6_contract.gd", "CHARACTER_UI_BINDING_8_6_RESULT"),
        ]:
            execute(base + ["--script", "res://" + path], env, marker)
        namespace = "equipflow_" + uuid.uuid4().hex
        saved: list[str] = []
        try:
            for stage in ("create", "resume", "deploy"):
                command = base.copy()
                stage_env = {**env, "ZERKOV_EQUIPMENT_MOVIE": "0"}
                if args.capture_dir:
                    output = args.capture_dir.resolve()
                    output.mkdir(parents=True, exist_ok=True)
                    command.remove("--headless")
                    command += ["--rendering-method", "gl_compatibility", "--write-movie", str(output / (stage + ".avi")), "--fixed-fps", "15"]
                    stage_env["ZERKOV_EQUIPMENT_MOVIE"] = "1"
                log = execute(command + ["--script", "res://tests/equipment/equipment_ui_flow.gd", "--", stage, namespace] + saved,
                              stage_env, "EQUIPMENT_UI_RESULT", 240)
                match = re.search(r"(?m)^EQUIPMENT_UI_SAVE item=([1-9][0-9]*) fingerprint=([0-9a-f]{64})$", log)
                if not match:
                    raise RuntimeError("Missing exact saved identity/fingerprint")
                saved = list(match.groups())
        finally:
            execute(base + ["--script", "res://tests/equipment/equipment_ui_flow.gd", "--", "cleanup", namespace], env, "EQUIPMENT_UI_RESULT")
    print("EQUIPMENT_RUNNER_COMPLETE")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("EQUIPMENT_RUNNER_FAILED:", error, flush=True)
        raise SystemExit(1)
