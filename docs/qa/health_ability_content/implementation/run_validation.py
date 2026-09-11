#!/usr/bin/env python3
"""Run and freeze the task 5.5 implementation evidence packet."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
PACKET = Path(__file__).resolve().parent
GODOT = Path(
    "/Volumes/Data/sdk/godot/editors/4.7.2/"
    "Godot.app/Contents/MacOS/Godot"
)
SPEC_TOOLKIT = Path(
    "/Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py"
)

IMPLEMENTATION_FILES = (
    "game/combat/content/zerkov_health_ability_content.gd",
    "game/combat/content/zerkov_health_ability_content.gd.uid",
    "game/combat/content/README.md",
    "game/content/zerkov_gameplay_ability_content.gd",
    "game/content/zerkov_gameplay_ability_content.gd.uid",
    "game/content/README.md",
    "tests/combat/health_ability_content_contract.gd",
    "tests/combat/health_ability_content_contract.gd.uid",
    "docs/qa/health_ability_content/README.md",
    "docs/qa/health_ability_content/implementation/run_validation.py",
)


def command_specs() -> tuple[dict[str, object], ...]:
    godot = str(GODOT)
    return (
        {
            "name": "health_ability_content_contract",
            "command": [
                godot,
                "--headless",
                "--path",
                ".",
                "--script",
                "res://tests/combat/health_ability_content_contract.gd",
            ],
            "required": r"HEALTH_ABILITY_CONTENT_RESULT checks=(\d+) failures=0",
        },
        {
            "name": "combat_content_contract",
            "command": [
                godot,
                "--headless",
                "--path",
                ".",
                "--script",
                "res://tests/combat/content_contract.gd",
            ],
            "required": r"COMBAT_CONTENT_RESULT checks=(\d+) failures=0",
        },
        {
            "name": "inventory_ability_reconciliation_contract",
            "command": [
                godot,
                "--headless",
                "--path",
                ".",
                "--script",
                "res://tests/raid/inventory_ability_reconciliation_contract.gd",
            ],
            "required": r"INVENTORY_ABILITY_RECONCILIATION_RESULT checks=(\d+) failures=0",
        },
        {
            "name": "combined_addons_smoke",
            "command": [
                godot,
                "--headless",
                "--path",
                ".",
                "--script",
                "res://tests/addons/combined_addons_smoke.gd",
            ],
            "required": r"ADDON_SMOKE_RESULT checks=(\d+) failures=0",
        },
        {
            "name": "editor_import",
            "command": [
                godot,
                "--headless",
                "--editor",
                "--path",
                ".",
                "--quit",
                "--quiet",
            ],
            "required": None,
        },
        {
            "name": "spec_strict",
            "command": [
                sys.executable,
                str(SPEC_TOOLKIT),
                "validate",
                "add-zerkov-playable-raid-2026-09-09",
                "--type",
                "change",
                "--strict",
            ],
            "required": r"^Valid$",
        },
        {
            "name": "diff_check",
            "command": ["git", "diff", "HEAD", "--check"],
            "required": None,
        },
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_one(spec: dict[str, object]) -> dict[str, object]:
    name = str(spec["name"])
    command = [str(value) for value in spec["command"]]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    output = completed.stdout + completed.stderr
    (PACKET / f"{name}.log").write_text(output, encoding="utf-8")
    (PACKET / f"{name}_runner.json").write_text(
        json.dumps(
            {
                "command": command,
                "cwd": str(ROOT),
                "returncode": completed.returncode,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    required = spec.get("required")
    match = re.search(str(required), output, re.MULTILINE) if required else None
    runtime_errors = "ERROR:" in output or "SCRIPT ERROR:" in output
    warnings = "WARNING:" in output
    passed = (
        completed.returncode == 0
        and not runtime_errors
        and not warnings
        and (required is None or match is not None)
    )
    return {
        "name": name,
        "passed": passed,
        "returncode": completed.returncode,
        "runtime_errors": runtime_errors,
        "warnings": warnings,
        "checks": int(match.group(1)) if match and match.groups() else None,
        "log": f"{name}.log",
        "runner": f"{name}_runner.json",
    }


def main() -> int:
    missing = [path for path in (GODOT, SPEC_TOOLKIT) if not path.is_file()]
    if missing:
        print("Missing required validator: " + ", ".join(map(str, missing)))
        return 2

    results = [run_one(spec) for spec in command_specs()]
    total_checks = sum(int(result["checks"] or 0) for result in results)
    all_passed = all(bool(result["passed"]) for result in results)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    hashes: dict[str, str] = {}
    for relative in IMPLEMENTATION_FILES:
        path = ROOT / relative
        if not path.is_file():
            print(f"Missing implementation file: {relative}")
            return 2
        hashes[relative] = sha256(path)
    (PACKET / "implementation_hashes.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "git_head_before_task_checkpoint": head,
                "files": hashes,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    verified = {
        relative: sha256(ROOT / relative) == expected
        for relative, expected in hashes.items()
    }
    matched_hashes = sum(1 for matched in verified.values() if matched)
    (PACKET / "hash_verification.log").write_text(
        "\n".join(
            f"{'MATCH' if matched else 'MISMATCH'} {relative}"
            for relative, matched in sorted(verified.items())
        )
        + f"\nHEALTH_ABILITY_HASH_RESULT matches={matched_hashes} "
        f"expected={len(verified)}\n",
        encoding="utf-8",
    )
    all_passed = all_passed and matched_hashes == len(verified)
    payload = {
        "schema_version": 2,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "git_head_before_task_checkpoint": head,
        "godot": str(GODOT),
        "godot_version": "4.7.2.stable.official.ed1daf0bf",
        "all_passed": all_passed,
        "total_assertions": total_checks,
        "implementation_hashes": {
            "expected": len(verified),
            "matched": matched_hashes,
            "log": "hash_verification.log",
        },
        "commands": results,
    }
    (PACKET / "results.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(
        "HEALTH_ABILITY_IMPLEMENTATION_EVIDENCE "
        f"commands={len(results)} checks={total_checks} "
        f"hashes={matched_hashes}/{len(verified)} "
        f"failures={0 if all_passed else 1}"
    )
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
