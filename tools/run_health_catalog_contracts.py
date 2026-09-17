#!/usr/bin/env python3
"""Differential health-catalog acceptance using the unchanged locked native addons.

This headless preflight benchmark does not measure rendering or establish FPS.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ERRORS = re.compile(
    r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|"
    r"ObjectDB instances leaked|resources still in use|_TIMEOUT")
MARKER = re.compile(r"(?m)^HEALTH_CATALOG_PERFORMANCE_RESULT checks=[1-9][0-9]* failures=0$")


def execute(command: list[str], env: dict[str, str]) -> str:
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    print(result.stdout, end="", flush=True)
    if result.returncode or ERRORS.search(result.stdout):
        raise RuntimeError(f"Native health-catalog command failed: {command}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        engine = str(args.godot.expanduser().resolve(strict=True))
        required = json.loads((root / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
        env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"}
        if execute([engine, "--version"], env).strip() != required:
            raise RuntimeError("Engine version does not match the lock")
        with tempfile.TemporaryDirectory(prefix="zerkov-health-catalog-") as temp:
            project = Path(temp) / "project"
            shutil.copytree(root, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
            env["XDG_DATA_HOME"] = str(Path(temp) / "userdata")
            base = [engine, "--headless", "--path", str(project), "--audio-driver", "Dummy"]
            execute(base + ["--editor", "--import", "--quit"], env)
            output = execute(base + ["--script", "res://tests/combat/health_catalog_performance_contract.gd"], env)
            if not MARKER.search(output):
                raise RuntimeError("Missing zero-failure health-catalog completion")
        print("HEALTH_CATALOG_RUNNER_COMPLETE")
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("HEALTH_CATALOG_RUNNER_FAILED:", error, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
