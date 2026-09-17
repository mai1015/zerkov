#!/usr/bin/env python3
"""Run real native equipment contracts in a private exact-1080 copy."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

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
        execute(base + ["--script", "res://tests/equipment/equipment_contract.gd"], env, "EQUIPMENT_CONTRACT_RESULT")
    print("EQUIPMENT_RUNNER_COMPLETE")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("EQUIPMENT_RUNNER_FAILED:", error, flush=True)
        raise SystemExit(1)
