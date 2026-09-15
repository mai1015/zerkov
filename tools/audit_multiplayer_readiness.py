#!/usr/bin/env python3
"""Task 10.1 evidence inventory. This tool NEVER certifies networking/release safety.

Exit 0 means an inventory was produced; network_ready remains false. Exit 1 means
invalid/missing inputs. --require-platform-artifacts exits 2 when the requested
Windows/Linux debug+release libraries are missing, unlocked or mismatched. Even a
passing artifact prerequisite is NOT a build, load, export or hostile-client test.
No network requests, engine invocation, package mutation or speculative fallback.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ADDONS = ("common_ui", "common_vision", "gameplay_abilities", "inventory_system",
          "level_task_system", "weapon_system")
TARGETS = {"windows-client": "windows", "linux-server": "linux"}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SHA1 = re.compile(r"[0-9a-f]{40}\Z")


def inside(root: Path, relative: str) -> Path:
    """Reject escapes and symlinks, including links to another in-tree package."""
    p = PurePosixPath(relative)
    if not relative or "\\" in relative or p.is_absolute() or ".." in p.parts or ":" in relative:
        raise ValueError(f"Invalid repository path: {relative!r}")
    result = root
    for part in p.parts:
        result = result / part
        if result.is_symlink():
            raise ValueError(f"Symlink is not audited as package bytes: {relative}")
    result.resolve().relative_to(root.resolve())
    return result


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def load(root: Path, name: str, fingerprints: dict) -> dict:
    path = inside(root, name)
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected object: {name}")
    fingerprints[name] = digest(path)
    return value


def sha(value: object, label: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise ValueError(f"Missing/invalid SHA-256: {label}")
    return value


def inspect(root: Path, revision: str) -> dict:
    if not SHA1.fullmatch(revision):
        raise ValueError("An exact 40-hex source revision is required")
    root = root.resolve()
    fingerprints: dict[str, str] = {}
    lock = load(root, "config/addons.lock.json", fingerprints)
    toolchain = load(root, "config/toolchain.lock.json", fingerprints)
    engine = toolchain.get("engine", {}).get("required_version")
    if not isinstance(engine, str) or not engine or engine.strip() != engine:
        raise ValueError("Invalid engine.required_version")
    entries = lock.get("addons")
    if not isinstance(entries, list) or len(entries) != len(ADDONS):
        raise ValueError("Expected exactly six locked addons")
    ids = [a.get("id") if isinstance(a, dict) else None for a in entries]
    if len(set(ids)) != len(ids) or set(ids) != set(ADDONS):
        raise ValueError("Addon IDs missing, unknown or duplicated")
    packages = []
    rows = []
    for addon in sorted(entries, key=lambda a: a["id"]):
        name = addon["id"]
        destination = f"addons/{name}"
        if addon.get("destination") != destination:
            raise ValueError(f"Unexpected destination for {name}")
        source = addon.get("source", {})
        manifest = load(root, destination + "/release_manifest.json", fingerprints)
        manifest_digest = fingerprints[destination + "/release_manifest.json"]
        manifest_lock = sha(source.get("release_manifest_sha256"), name + " manifest lock")
        declared: dict[str, dict] = {}
        for artifact in addon.get("native_artifacts", []):
            path = destination + "/" + artifact["path"]
            inside(root, path)
            if path in declared:
                raise ValueError(f"Duplicate locked artifact: {path}")
            sha(artifact.get("sha256"), path)
            declared[path] = artifact
        ext_name = destination + f"/{name}.gdextension"
        ext = inside(root, ext_name)
        parser = configparser.ConfigParser(interpolation=None, strict=True)
        parser.read_string(ext.read_text(encoding="utf-8"))
        fingerprints[ext_name] = digest(ext)
        if not parser.has_section("libraries"):
            raise ValueError(f"Missing [libraries]: {ext_name}")
        libraries = dict(parser.items("libraries"))
        required = [f"{platform}.{build}.x86_64" for platform in TARGETS.values()
                    for build in ("debug", "release")]
        # Audit all declared desktop binaries plus each mandatory target selector.
        selectors = sorted(set(required) | {s for s in libraries if s.split(".")[0] in {"macos", "windows", "linux"}})
        for selector in selectors:
            path = None
            if selector in libraries:
                value = json.loads(libraries[selector])
                if not isinstance(value, str) or not value.startswith("res://" + destination + "/"):
                    raise ValueError(f"Library escaped package: {ext_name}: {selector}")
                path = value.removeprefix("res://")
            file = inside(root, path) if path else None
            actual = digest(file) if file is not None and file.is_file() else None
            pinned = declared.get(path, {})
            expected = pinned.get("sha256")
            upstream = pinned.get("release_manifest_sha256")
            state = ("selector_missing" if path is None else "missing" if actual is None
                     else "unlocked" if expected is None else "mismatch" if actual != expected else "locked_match")
            rows.append({"addon": name, "selector": selector, "path": path, "state": state,
                         "actual_sha256": actual, "locked_sha256": expected,
                         "release_artifact_sha256": upstream,
                         "release_artifact_matches_lock": expected == upstream if upstream else None})
        packages.append({"addon": name, "version": addon.get("version"),
                         "api_version": addon.get("api_version"), "protocol_version": addon.get("protocol_version"),
                         "source_git_head": source.get("git_head"),
                         "source_release_revision": source.get("release_source_revision"),
                         "source_tree_sha256": source.get("package_tree_sha256"),
                         "source_worktree_dirty_at_pin": source.get("package_worktree_dirty"),
                         "release_manifest_matches_lock": manifest_digest == manifest_lock,
                         "manifest_source_revision": manifest.get("provenance", {}).get("source_revision"),
                         "release_targets": manifest.get("targets", [])})
    platforms = {}
    for target, platform in TARGETS.items():
        selected = [r for r in rows if r["selector"] in [platform + ".debug.x86_64", platform + ".release.x86_64"]]
        blocked = [r for r in selected if r["state"] != "locked_match"]
        platforms[target] = {"required_libraries": len(ADDONS) * 2,
                             "blocked_libraries": len(blocked),
                             "artifact_prerequisite_passed": len(selected) == len(ADDONS) * 2 and not blocked,
                             "build_load_export_status": "not_executed_by_inventory",
                             "supported": False}
    return {"schema_version": 1, "source_revision": revision, "engine_required": engine,
            "inventory_completed": True, "network_ready": False,
            "task_10_1_hardening_signoff": "not_established_by_inventory",
            "scope": "all six declared desktop packages; server-specific exclusion needs reviewed composition",
            "input_sha256": fingerprints, "packages": packages, "libraries": rows,
            "platforms": platforms}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--revision", help="Exact audited source revision; default: git HEAD")
    parser.add_argument("--output", type=Path, help="JSON report path outside the source checkout")
    parser.add_argument("--require-platform-artifacts", choices=sorted(TARGETS))
    args = parser.parse_args(argv)
    try:
        root = args.root.resolve()
        revision = args.revision or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        report = inspect(root, revision)
        data = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            output = args.output.resolve()
            if output.is_relative_to(root):
                raise ValueError("Report output must be outside the source checkout")
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(data, encoding="utf-8")
        else:
            print(data, end="")
        print("MULTIPLAYER_INVENTORY completed=true network_ready=false revision=" + revision)
        return 2 if args.require_platform_artifacts and not report["platforms"][args.require_platform_artifacts]["artifact_prerequisite_passed"] else 0
    except (OSError, ValueError, TypeError, KeyError, configparser.Error, subprocess.SubprocessError) as error:
        print(f"MULTIPLAYER_INVENTORY_ERROR {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
