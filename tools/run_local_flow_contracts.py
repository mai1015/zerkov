#!/usr/bin/env python3
"""Run the actual local application in isolated copies and private save namespaces.

This is a functional-flow runner, not frame-rate acceptance. The integrated debug
build currently exceeds a real-time tick budget; report timings independently.
No native substitutes, skipped errors, fixture profile or fabricated outcome.
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
import uuid

ERRORS = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|_BLOCKED|_TIMEOUT")

def execute(command: list[str], env: dict[str, str], marker: str | None = None, timeout: int = 150) -> str:
    try:
        result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        print(output.decode(errors="replace") if isinstance(output, bytes) else output, flush=True)
        raise
    print(result.stdout, end="", flush=True)
    if result.returncode != 0 or ERRORS.search(result.stdout):
        raise RuntimeError(f"Command or diagnostics failed: exit={result.returncode} command={command}")
    if marker and not re.search(rf"(?m)^{re.escape(marker)} checks=[1-9][0-9]* failures=0(?:\s|$)", result.stdout):
        raise RuntimeError(f"Missing zero-failure completion: {marker}")
    return result.stdout

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    try:
        engine = str(args.godot.expanduser().resolve(strict=True))
        required = json.loads((source / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
        env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"}
        if execute([engine, "--version"], env).strip() != required:
            raise RuntimeError("Engine version does not match toolchain lock")
        with tempfile.TemporaryDirectory(prefix="zerkov-local-flow-") as temp:
            project = Path(temp) / "project"
            shutil.copytree(source, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
            env["XDG_DATA_HOME"] = str(Path(temp) / "user")
            base = [engine, "--headless", "--path", str(project), "--resolution", "1920x1080", "--audio-driver", "Dummy"]
            execute(base + ["--editor", "--import", "--quit"], env)
            namespace = "localflow_" + uuid.uuid4().hex
            script = base + ["--script", "res://tests/local/native_local_flow_contract.gd", "--"]
            try:
                result = execute(script + ["run", namespace], env, "NATIVE_LOCAL_FLOW_RESULT", timeout=660)
                match = re.search(r"(?m)^LOCAL_FLOW_FINGERPRINT ([a-f0-9]{64})$", result)
                if not match:
                    raise RuntimeError("Missing saved profile fingerprint")
                for _ in range(2):
                    execute(script + ["verify", namespace, match[1]], env, "LOCAL_FLOW_VERIFY")
            finally:
                execute(script + ["cleanup", namespace], env, "LOCAL_FLOW_CLEANUP")
        print("LOCAL_FLOW_RUNNER_COMPLETE")
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("LOCAL_FLOW_RUNNER_FAILED:", error, flush=True)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
