#!/usr/bin/env python3
"""Actual campaign bunker input, real local persistence, and independent Continue.

Imports an outside copy with the real addons. Optional captures are raw native
1920x1080 readbacks; missing classes, errors, missing markers and timeouts fail.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_flow_runner", ROOT / "tools/run_local_flow_contracts.py")
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--graphical", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    try:
        if output.is_relative_to(ROOT) or ROOT.is_relative_to(output) or output.exists():
            raise ValueError("Output must be new and outside the checkout")
        output.mkdir(parents=True)
        env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1"}
        engine = str(args.godot.resolve(strict=True))
        pin = json.loads((ROOT / "config/toolchain.lock.json").read_text())["engine"]["required_version"]
        if flow.execute([engine, "--version"], env).strip() != pin:
            raise ValueError("Engine differs from the exact lock")
        with tempfile.TemporaryDirectory(prefix="zerkov-bunker-flow-") as tmp:
            project = Path(tmp) / "project"
            shutil.copytree(ROOT, project, ignore=shutil.ignore_patterns(".git", ".godot", ".codegraph", "__pycache__"))
            env["XDG_DATA_HOME"] = str(Path(tmp) / "user")
            base = [engine, "--path", str(project), "--resolution", "1920x1080", "--audio-driver", "Dummy"]
            flow.execute(base + ["--headless", "--editor", "--import", "--quit"], env)
            if not args.graphical:
                base.append("--headless")
            namespace = "localflow_" + uuid.uuid4().hex
            script = base + ["--script", "res://tests/local/native_bunker_flow_contract.gd", "--"]
            counts, fingerprints = [], []
            try:
                for mode in ("new", "continue"):
                    arguments = [mode, namespace, fingerprints[-1] if fingerprints else ""]
                    if args.graphical:
                        arguments.append(str(output / mode))
                    result = flow.execute(script + arguments, env, "BUNKER_FLOW_RESULT", timeout=200)
                    (output / (mode + ".log")).write_text(result)
                    match = re.search(r"(?m)^BUNKER_FLOW_FINGERPRINT ([a-f0-9]{64})$", result)
                    if not match:
                        raise RuntimeError("Missing saved fingerprint")
                    fingerprints.append(match[1])
                    counts.append(int(re.search(r"BUNKER_FLOW_RESULT checks=(\d+)", result)[1]))
            finally:
                flow.execute(script + ["cleanup", namespace], env, "BUNKER_FLOW_CLEANUP")
            if len(set(fingerprints)) != 1:
                raise RuntimeError("Continue changed saved campaign data")
        images = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.rglob("*.png"))}
        if args.graphical and len(images) != 14:
            raise RuntimeError("Missing expected application screenshots")
        report = {"engine": pin, "checks": counts, "failures": 0, "profile_fingerprint": fingerprints[0],
                  "graphical": args.graphical, "screenshots": images, "source_commit": os.environ.get("SOURCE_SHA", "local"),
                  "scope": "normal campaign root, actual input and real native persistence; new + independent Continue; pre-raid UX"}
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print("BUNKER_FLOW_RUNNER_COMPLETE", json.dumps(report))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, flow.subprocess.TimeoutExpired) as error:
        print("BUNKER_FLOW_RUNNER_FAILED:", error, flush=True)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
