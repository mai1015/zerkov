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
    parser.add_argument("--suite", choices=["hub", "workspaces", "journey", "loot", "storage"], default="hub")
    args = parser.parse_args()
    output = args.output.resolve()
    try:
        if output.is_relative_to(ROOT) or ROOT.is_relative_to(output) or output.exists():
            raise ValueError("Output must be new and outside the checkout")
        output.mkdir(parents=True)
        env = {**os.environ, "GODOT_SILENCE_ROOT_WARNING": "1",
               "ZERKOV_STORAGE_LAYOUT": "1" if args.suite == "storage" else "0",
               "ZERKOV_CONTEXTUAL_LOOT": "1" if args.suite == "loot" else "0",
               "ZERKOV_OFFLINE_JOURNEY": "1" if args.suite == "journey" else "0",
               "ZERKOV_BUNKER_WORKSPACES": "1" if args.suite == "workspaces" else "0"}
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
                    result = flow.execute(script + arguments, env, "BUNKER_FLOW_RESULT", timeout=330 if args.graphical else 200)
                    (output / (mode + ".log")).write_text(result)
                    if args.suite == "storage" and "STORAGE_LAYOUT_COMPLETE native=true" not in result:
                        raise RuntimeError("Storage layout driver did not complete")
                    if args.suite == "loot" and "CONTEXTUAL_LOOT_COMPLETE native=true" not in result:
                        raise RuntimeError("Contextual loot driver did not complete")
                    if args.suite == "journey" and "OFFLINE_JOURNEY_COMPLETE native=true" not in result:
                        raise RuntimeError("Journey driver did not complete")
                    if args.suite == "workspaces" and "BUNKER_WORKSPACES_COMPLETE native=true" not in result:
                        raise RuntimeError("Workspace driver did not complete")
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
        if args.graphical and len(images) != ({"hub": 14, "workspaces": 8, "journey": 22, "loot": 9, "storage": 9}[args.suite]):
            raise RuntimeError("Missing expected application screenshots")
        report = {"engine": pin, "checks": counts, "failures": 0, "profile_fingerprint": fingerprints[0],
                  "suite": args.suite, "graphical": args.graphical, "screenshots": images, "source_commit": os.environ.get("SOURCE_SHA", "local"),
                  "scope": "normal campaign root, real input and native persistence; " + {
                      "storage": "gear-gated storage, shared scrolling, native gear/legacy fixtures and the existing authored Quick Use row",
                      "journey": "preparation, deployment, actual abandoned-raid debrief and independent Continue",
                      "loot": "raid search/open/transfer/filter/close, committed abandonment and independent Continue",
                      "workspaces": "read-only bunker workspaces and independent Continue",
                      "hub": "new + independent Continue; pre-raid UX",
                  }[args.suite]}
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print("BUNKER_FLOW_RUNNER_COMPLETE", json.dumps(report))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, flow.subprocess.TimeoutExpired) as error:
        print("BUNKER_FLOW_RUNNER_FAILED:", error, flush=True)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
