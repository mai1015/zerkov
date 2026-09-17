#!/usr/bin/env python3
"""Verify, fingerprint, and package the six Linux x86_64 GDExtensions."""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

ADDONS = (
    "common_ui",
    "common_vision",
    "gameplay_abilities",
    "inventory_system",
    "level_task_system",
    "weapon_system",
)
LIBRARY_KEYS = (
    ("debug", "linux.debug.x86_64"),
    ("release", "linux.release.x86_64"),
)


def run(args: list[str], *, cwd: Path | None = None, check: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def clean_ini_value(value: str) -> str:
    return value.strip().strip('"').strip("'")


def verify_library(path: Path, entry_symbol: str) -> dict[str, object]:
    if not path.is_file():
        raise RuntimeError(f"missing Linux GDExtension: {path}")
    if path.read_bytes()[:4] != b"\x7fELF":
        raise RuntimeError(f"not an ELF shared library: {path}")

    header = run(["readelf", "-h", str(path)])
    if "ELF64" not in header or "Advanced Micro Devices X86-64" not in header:
        raise RuntimeError(f"unexpected ELF architecture for {path}\n{header}")

    symbols = run(["nm", "-D", "--defined-only", str(path)])
    exported = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    if entry_symbol not in exported:
        raise RuntimeError(f"{path} does not export {entry_symbol}")

    dependencies = run(["ldd", str(path)], check=False)
    if "not found" in dependencies:
        raise RuntimeError(f"unresolved dynamic dependency in {path}\n{dependencies}")

    return {
        "path": path.as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "entry_symbol": entry_symbol,
        "ldd": dependencies.splitlines(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    artifacts: list[dict[str, object]] = []
    archive_paths: set[Path] = set()

    for addon in ADDONS:
        descriptor = root / "addons" / addon / f"{addon}.gdextension"
        config = configparser.ConfigParser(interpolation=None)
        config.optionxform = str
        if not config.read(descriptor, encoding="utf-8"):
            raise RuntimeError(f"cannot read descriptor: {descriptor}")
        entry_symbol = clean_ini_value(config["configuration"]["entry_symbol"])
        archive_paths.add(descriptor)
        for build, key in LIBRARY_KEYS:
            resource_path = clean_ini_value(config["libraries"][key])
            if not resource_path.startswith("res://"):
                raise RuntimeError(f"unexpected library path in {descriptor}: {resource_path}")
            library = root / resource_path.removeprefix("res://")
            info = verify_library(library, entry_symbol)
            info.update({"addon": addon, "build": build})
            artifacts.append(info)
            archive_paths.add(library)

    sdk = Path(os.environ["GODOT_CPP"]).resolve()
    manifest = {
        "schema_version": 1,
        "source_commit": run(["git", "rev-parse", "HEAD"], cwd=root),
        "godot_version": run([str(args.godot), "--version"]),
        "godot_cpp_commit": run(["git", "rev-parse", "HEAD"], cwd=sdk),
        "scons_version": run(["scons", "--version"]).splitlines()[0],
        "compiler": run(["g++", "--version"]).splitlines()[0],
        "platform": "linux",
        "arch": "x86_64",
        "artifacts": artifacts,
    }

    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    raw_manifest = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    args.manifest.write_text(raw_manifest, encoding="utf-8")
    args.archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.archive, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", raw_manifest)
        for path in sorted(archive_paths):
            archive.write(path, path.relative_to(root).as_posix())

    print(f"NATIVE_LINUX_ARTIFACTS_OK libraries={len(artifacts)} archive={args.archive}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"NATIVE_LINUX_ARTIFACTS_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
