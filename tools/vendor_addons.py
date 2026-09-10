#!/usr/bin/env python3
"""Verify and vendor Zerkov's locked Godot add-on snapshots.

The lock file is deliberately the only input that selects packages. Source
trees may be dirty, but their complete distributable content must match the
recorded digest before anything is copied. Copying happens into a staging
directory and every staged package is verified before destinations change.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK_PATH = PROJECT_ROOT / "config" / "addons.lock.json"
EXPECTED_ADDONS = {
    "common_ui",
    "common_vision",
    "gameplay_abilities",
    "inventory_system",
    "level_task_system",
    "weapon_system",
}
EXCLUDED_SUFFIXES = {".o", ".os", ".obj", ".d", ".pyc"}
EXCLUDED_NAMES = {".DS_Store"}


class VendorError(RuntimeError):
    """Raised when a lock or package cannot be verified safely."""


@dataclass(frozen=True)
class PackageDigest:
    file_count: int
    sha256: str


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _is_excluded(relative_path: Path) -> bool:
    parts = relative_path.parts
    if relative_path.name in EXCLUDED_NAMES:
        return True
    if relative_path.suffix in EXCLUDED_SUFFIXES:
        return True
    return len(parts) >= 2 and parts[0] == "native" and parts[1] in {
        ".build",
        "tests",
    }


def distributable_files(
    package_path: Path,
    ignored_relative_paths: set[str] | None = None,
) -> list[Path]:
    if not package_path.is_dir():
        raise VendorError(f"missing package directory: {package_path}")
    ignored = ignored_relative_paths or set()
    files: list[Path] = []
    for candidate in package_path.rglob("*"):
        if candidate.is_symlink():
            raise VendorError(f"symlinks are not permitted in locked packages: {candidate}")
        if not candidate.is_file():
            continue
        relative_path = candidate.relative_to(package_path)
        if relative_path.as_posix() in ignored:
            continue
        if not _is_excluded(relative_path):
            files.append(relative_path)
    return sorted(files, key=lambda path: path.as_posix())


def package_digest(
    package_path: Path,
    ignored_relative_paths: set[str] | None = None,
) -> PackageDigest:
    records = hashlib.sha256()
    files = distributable_files(package_path, ignored_relative_paths)
    for relative_path in files:
        file_digest = _sha256_file(package_path / relative_path)
        record = f"{file_digest}  ./{relative_path.as_posix()}\n"
        records.update(record.encode("utf-8"))
    return PackageDigest(len(files), records.hexdigest())


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise VendorError(f"missing JSON file: {path}") from error
    except json.JSONDecodeError as error:
        raise VendorError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise VendorError(f"expected a JSON object in {path}")
    return value


def load_lock(lock_path: Path) -> dict[str, Any]:
    lock = _read_json(lock_path)
    if lock.get("schema_version") != 1:
        raise VendorError("addons lock schema_version must be 1")
    addons = lock.get("addons")
    if not isinstance(addons, list):
        raise VendorError("addons lock must contain an addons array")
    identifiers = [entry.get("id") for entry in addons if isinstance(entry, dict)]
    if len(identifiers) != len(addons) or set(identifiers) != EXPECTED_ADDONS:
        raise VendorError(
            "addons lock must contain exactly: " + ", ".join(sorted(EXPECTED_ADDONS))
        )
    if len(set(identifiers)) != len(identifiers):
        raise VendorError("addons lock contains duplicate identifiers")
    return lock


def _git_head(repository_path: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repository_path), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def _verify_release_metadata(entry: dict[str, Any], package_path: Path) -> None:
    manifest_path = package_path / "release_manifest.json"
    manifest = _read_json(manifest_path)
    for field in ("addon", "version", "api_version", "protocol_version"):
        expected_field = "id" if field == "addon" else field
        expected = entry.get(expected_field)
        actual = manifest.get(field)
        if actual != expected:
            raise VendorError(
                f"{entry['id']}: release manifest {field} mismatch; "
                f"expected {expected!r}, got {actual!r}"
            )
    expected_manifest_digest = entry["source"].get("release_manifest_sha256")
    actual_manifest_digest = _sha256_file(manifest_path)
    if actual_manifest_digest != expected_manifest_digest:
        raise VendorError(
            f"{entry['id']}: release manifest digest mismatch; "
            f"expected {expected_manifest_digest}, got {actual_manifest_digest}"
        )


def verify_package(
    entry: dict[str, Any],
    package_path: Path,
    *,
    verify_git: bool = False,
    ignored_relative_paths: set[str] | None = None,
) -> PackageDigest:
    addon_id = str(entry["id"])
    expected_source = entry.get("source")
    if not isinstance(expected_source, dict):
        raise VendorError(f"{addon_id}: missing source lock")

    _verify_release_metadata(entry, package_path)
    actual_digest = package_digest(package_path, ignored_relative_paths)
    expected_count = expected_source.get("package_file_count")
    expected_digest = expected_source.get("package_tree_sha256")
    if actual_digest.file_count != expected_count or actual_digest.sha256 != expected_digest:
        raise VendorError(
            f"{addon_id}: unlocked package tree; expected files={expected_count} "
            f"sha256={expected_digest}, got files={actual_digest.file_count} "
            f"sha256={actual_digest.sha256}"
        )

    for artifact in entry.get("native_artifacts", []):
        artifact_path = package_path / str(artifact["path"])
        if not artifact_path.is_file():
            raise VendorError(f"{addon_id}: missing native artifact: {artifact_path}")
        actual_artifact_digest = _sha256_file(artifact_path)
        if actual_artifact_digest != artifact.get("sha256"):
            raise VendorError(
                f"{addon_id}: native artifact mismatch for {artifact['path']}; "
                f"expected {artifact.get('sha256')}, got {actual_artifact_digest}"
            )

    if verify_git:
        repository_path = Path(str(expected_source["repository_path"]))
        expected_head = expected_source.get("git_head")
        actual_head = _git_head(repository_path)
        if actual_head != expected_head:
            raise VendorError(
                f"{addon_id}: git revision mismatch; expected {expected_head!r}, "
                f"got {actual_head!r}"
            )
    return actual_digest


def source_package_path(entry: dict[str, Any]) -> Path:
    return Path(str(entry["source"]["package_path"]))


def destination_package_path(entry: dict[str, Any], project_root: Path) -> Path:
    destination = (project_root / str(entry["destination"])).resolve()
    addons_root = (project_root / "addons").resolve()
    if destination.parent != addons_root:
        raise VendorError(f"unsafe destination outside project addons root: {destination}")
    return destination


def verify_entries(
    entries: Iterable[dict[str, Any]],
    *,
    scope: str,
    project_root: Path,
) -> None:
    for entry in entries:
        addon_id = str(entry["id"])
        if scope in {"source", "all"}:
            digest = verify_package(entry, source_package_path(entry), verify_git=True)
            print(f"PASS source {addon_id} files={digest.file_count} sha256={digest.sha256}")
        if scope in {"destination", "all"}:
            destination = destination_package_path(entry, project_root)
            ignored_paths = {
                str(path) for path in entry.get("destination_generated_paths", [])
            }
            for ignored_path in ignored_paths:
                if not ignored_path.endswith(".uid"):
                    raise VendorError(
                        f"{addon_id}: destination-generated path must be a .uid sidecar: "
                        f"{ignored_path}"
                    )
                backing_path = destination / ignored_path.removesuffix(".uid")
                if not backing_path.is_file():
                    raise VendorError(
                        f"{addon_id}: destination-generated UID has no backing resource: "
                        f"{ignored_path}"
                    )
            digest = verify_package(
                entry,
                destination,
                ignored_relative_paths=ignored_paths,
            )
            print(
                f"PASS destination {addon_id} "
                f"files={digest.file_count} sha256={digest.sha256}"
            )


def _copy_package(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    for relative_path in distributable_files(source):
        source_file = source / relative_path
        destination_file = destination / relative_path
        destination_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, destination_file)


def apply_locked_packages(
    entries: list[dict[str, Any]],
    *,
    project_root: Path,
    dry_run: bool,
) -> None:
    verify_entries(entries, scope="source", project_root=project_root)
    if dry_run:
        for entry in entries:
            print(f"PLAN replace {entry['destination']} from locked source {entry['id']}")
        return

    project_root.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".vendor-staging-", dir=project_root))
    stage_packages = stage_root / "packages"
    backup_packages = stage_root / "backups"
    replaced: list[tuple[Path, Path | None]] = []
    try:
        for entry in entries:
            staged_package = stage_packages / str(entry["id"])
            _copy_package(source_package_path(entry), staged_package)
            verify_package(entry, staged_package)

        for entry in entries:
            destination = destination_package_path(entry, project_root)
            staged_package = stage_packages / str(entry["id"])
            backup: Path | None = None
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                backup_packages.mkdir(parents=True, exist_ok=True)
                backup = backup_packages / str(entry["id"])
                os.replace(destination, backup)
            try:
                os.replace(staged_package, destination)
            except Exception:
                if backup is not None and backup.exists():
                    os.replace(backup, destination)
                raise
            replaced.append((destination, backup))

        verify_entries(entries, scope="destination", project_root=project_root)
    except Exception:
        for destination, backup in reversed(replaced):
            if destination.exists():
                shutil.rmtree(destination)
            if backup is not None and backup.exists():
                os.replace(backup, destination)
        raise
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("check", "apply"),
        help="verify packages or atomically replace project add-on snapshots",
    )
    parser.add_argument(
        "--scope",
        choices=("source", "destination", "all"),
        default="all",
        help="package locations checked by the check command",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK_PATH)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        project_root = args.project_root.resolve()
        lock = load_lock(args.lock.resolve())
        entries = sorted(lock["addons"], key=lambda entry: str(entry["id"]))
        if args.command == "check":
            if args.dry_run:
                raise VendorError("--dry-run is only valid with apply")
            verify_entries(entries, scope=args.scope, project_root=project_root)
        else:
            apply_locked_packages(entries, project_root=project_root, dry_run=args.dry_run)
    except VendorError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
