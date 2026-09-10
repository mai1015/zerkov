#!/usr/bin/env python3
"""Validate Zerkov's license inventory and report public-package blockers."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: root must be an object")
    return value


def main() -> int:
    project_root = Path(__file__).resolve().parents[1]
    lock_path = project_root / "config" / "addons.lock.json"
    registry_path = project_root / "config" / "distribution_licenses.json"
    try:
        lock = _load(lock_path)
        registry = _load(registry_path)
        locked_ids = {
            entry["id"] for entry in lock.get("addons", []) if isinstance(entry, dict)
        }
        addon_entries = registry.get("addons", [])
        if not isinstance(addon_entries, list):
            raise ValueError(f"{registry_path}: addons must be an array")
        registry_by_id = {
            entry["id"]: entry for entry in addon_entries if isinstance(entry, dict)
        }
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"LICENSE_INVENTORY_ERROR {error}")
        return 1

    errors: list[str] = []
    blockers: list[str] = []
    if set(registry_by_id) != locked_ids:
        errors.append(
            "locked/registered add-on mismatch: "
            f"locked={sorted(locked_ids)} registered={sorted(registry_by_id)}"
        )

    sections = ("addons", "shared_dependencies", "asset_families")
    checked = 0
    for section in sections:
        entries = registry.get(section, [])
        if not isinstance(entries, list):
            errors.append(f"{section} must be an array")
            continue
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
                errors.append(f"{section} contains an entry without a string id")
                continue
            checked += 1
            entry_id = entry["id"]
            for field in ("license_file", "third_party_notice_file"):
                reference = entry.get(field)
                if reference is not None and not (project_root / reference).is_file():
                    errors.append(f"{entry_id}: missing {field} {reference}")
            status = entry.get("distribution_status")
            if status == "blocked":
                reason = entry.get("blocker")
                if not isinstance(reason, str) or not reason:
                    errors.append(f"{entry_id}: blocked entry has no reason")
                else:
                    blockers.append(f"{entry_id}: {reason}")
            elif status != "cleared":
                errors.append(f"{entry_id}: invalid distribution_status {status!r}")

    for message in errors:
        print(f"ERROR {message}")
    for message in blockers:
        print(f"BLOCKED {message}")
    status = "ERROR" if errors else "BLOCKED" if blockers else "CLEARED"
    print(
        f"LICENSE_INVENTORY_RESULT entries={checked} errors={len(errors)} "
        f"blockers={len(blockers)} status={status}"
    )
    if errors:
        return 1
    return 2 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
