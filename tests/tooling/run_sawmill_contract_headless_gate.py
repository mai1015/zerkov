#!/usr/bin/env python3
"""Run the sawmill contract at the exact first-playable output."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
GODOT = os.environ.get("GODOT_BIN", os.environ.get("ZERKOV_GODOT", "godot"))
CONTRACT = "res://tests/raid/sawmill_contract.gd"
RESULT = re.compile(r"SAWMILL_CONTRACT_RESULT checks=(\d+) failures=(\d+)")
DIAGNOSTIC = re.compile(
    r"(?im)(?:^\s*(?:ERROR|WARNING):|SCRIPT ERROR|stack overflow|"
    r"ObjectDB instances? (?:were )?leaked|RID[^\n]*leak|"
    r"resources still in use|ASSERTION FAILED)"
)


def run_once() -> tuple[bool, str, int, int, list[str]]:
    process = subprocess.run(
        [
            GODOT,
            "--headless",
            "--path",
            str(PROJECT_ROOT),
            "--resolution",
            "1920x1080",
            "--audio-driver",
            "Dummy",
            "--script",
            CONTRACT,
        ],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=60,
        check=False,
    )
    output = process.stdout
    match = RESULT.search(output)
    checks = int(match.group(1)) if match else 0
    failures = int(match.group(2)) if match else 1
    diagnostics = DIAGNOSTIC.findall(output)
    passed = process.returncode == 0 and match is not None and failures == 0 and not diagnostics
    return passed, output, checks, failures, diagnostics


def main() -> int:
    runs = []
    for _ in range(2):
        runs.append(run_once())

    for index, (_, output, _, _, diagnostics) in enumerate(runs, start=1):
        print(f"--- Sawmill contract run {index} ---")
        print(output, end="" if output.endswith("\n") else "\n")
        if diagnostics:
            print("diagnostics:", *diagnostics, sep=" ", file=sys.stderr)

    total_checks = sum(run[2] for run in runs)
    total_failures = sum(run[3] for run in runs)
    diagnostic_count = sum(len(run[4]) for run in runs)
    passed = all(run[0] for run in runs)
    print(
        "SAWMILL_CONTRACT_HEADLESS_GATE"
        f" runs={len(runs)} checks={total_checks} failures={total_failures}"
        f" diagnostics={diagnostic_count}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
