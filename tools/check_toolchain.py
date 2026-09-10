#!/usr/bin/env python3
"""Check the local Zerkov development toolchain against its pinned contract."""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = PROJECT_ROOT / "config" / "toolchain.lock.json"


def run(command: list[str], environment: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{' '.join(command)} failed: {detail}")
    return result.stdout.strip()


def version_tuple(value: str, width: int = 3) -> tuple[int, ...]:
    numbers = [int(part) for part in re.findall(r"\d+", value)[:width]]
    numbers.extend([0] * (width - len(numbers)))
    return tuple(numbers)


def load_lock() -> dict[str, Any]:
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    if lock.get("schema_version") != 1:
        raise RuntimeError("unsupported toolchain lock schema")
    return lock


def main() -> int:
    lock = load_lock()
    failures: list[str] = []
    notes: list[str] = []

    engine = lock["engine"]
    godot_override = os.environ.get("ZERKOV_GODOT", "")
    godot_path = Path(godot_override or engine["path_hint"])
    if not godot_path.is_file():
        discovered = shutil.which("godot")
        godot_path = Path(discovered) if discovered else godot_path
    try:
        actual_godot = run([str(godot_path), "--version"])
        if actual_godot != engine["required_version"]:
            failures.append(
                f"Godot expected {engine['required_version']}, got {actual_godot}"
            )
        else:
            notes.append(f"Godot {actual_godot} ({godot_path})")
    except RuntimeError as error:
        failures.append(str(error))

    python_actual = platform.python_version()
    python_minimum = lock["tools"]["python"]["minimum"]
    if version_tuple(python_actual) < version_tuple(python_minimum):
        failures.append(f"Python requires >= {python_minimum}, got {python_actual}")
    else:
        notes.append(f"Python {python_actual}")

    try:
        scons_output = run(["scons", "--version"])
        match = re.search(r"SCons: v([0-9.]+)", scons_output)
        if match is None:
            failures.append("could not parse SCons version")
        else:
            scons_actual = match.group(1)
            scons_minimum = lock["tools"]["scons"]["minimum"]
            if version_tuple(scons_actual) < version_tuple(scons_minimum):
                failures.append(f"SCons requires >= {scons_minimum}, got {scons_actual}")
            else:
                notes.append(f"SCons {scons_actual}")
    except RuntimeError as error:
        failures.append(str(error))

    try:
        compiler_output = run(["clang++", "--version"])
        match = re.search(r"Apple clang version ([0-9.]+)", compiler_output)
        if match is None:
            failures.append("Apple Clang is required on the validated macOS host")
        else:
            clang_actual = match.group(1)
            clang_minimum = int(lock["tools"]["cxx"]["minimum_major"])
            if version_tuple(clang_actual, 1)[0] < clang_minimum:
                failures.append(
                    f"Apple Clang requires major >= {clang_minimum}, got {clang_actual}"
                )
            else:
                notes.append(f"Apple Clang {clang_actual}")
    except RuntimeError as error:
        failures.append(str(error))

    if platform.system() == "Darwin":
        try:
            sdk_actual = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
            sdk_minimum = "14.0"
            if version_tuple(sdk_actual) < version_tuple(sdk_minimum):
                failures.append(f"macOS SDK requires >= {sdk_minimum}, got {sdk_actual}")
            else:
                notes.append(f"macOS SDK {sdk_actual}")
        except RuntimeError as error:
            failures.append(str(error))

    expected_architecture = lock["validated_host"]["architecture"]
    actual_architecture = platform.machine()
    if actual_architecture != expected_architecture:
        failures.append(
            f"validated host architecture is {expected_architecture}, got {actual_architecture}"
        )
    else:
        notes.append(f"Host architecture {actual_architecture}")

    expected_godot_cpp = lock["native_sdk"]["godot_cpp_commit"]
    dependency_files = sorted((PROJECT_ROOT / "addons").glob("*/native/dependencies.json"))
    if len(dependency_files) != 6:
        failures.append(f"expected 6 add-on dependency manifests, found {len(dependency_files)}")
    for dependency_path in dependency_files:
        dependency = json.loads(dependency_path.read_text(encoding="utf-8"))
        actual_commit = dependency.get("godot_cpp", {}).get("commit")
        addon_id = dependency_path.parents[1].name
        if actual_commit != expected_godot_cpp:
            failures.append(
                f"{addon_id} godot-cpp expected {expected_godot_cpp}, got {actual_commit}"
            )
    if dependency_files and not any("godot-cpp" in item for item in failures):
        notes.append(f"godot-cpp {expected_godot_cpp} shared by 6 add-ons")

    for note in notes:
        print("PASS", note)
    for failure in failures:
        print("FAIL", failure, file=sys.stderr)
    print(f"TOOLCHAIN_RESULT checks={len(notes) + len(failures)} failures={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
