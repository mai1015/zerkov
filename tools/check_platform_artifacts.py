#!/usr/bin/env python3
"""Report whether every locked GDExtension ships a requested target binary."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


TARGET_LIBRARY_KEYS = {
    "windows-debug-client": "windows.debug.x86_64",
    "linux-debug-server": "linux.debug.x86_64",
}

LIBRARY_LINE = re.compile(
    r'^\s*([A-Za-z0-9_.]+)\s*=\s*"([^"]+)"\s*$'
)


@dataclass(frozen=True)
class PackageArtifact:
    package: str
    descriptor: Path
    resource_path: str | None
    filesystem_path: Path | None
    error: str | None = None

    @property
    def exists(self) -> bool:
        return self.filesystem_path is not None and self.filesystem_path.is_file()


def _locked_package_names(lock_path: Path) -> list[str]:
    payload = json.loads(lock_path.read_text(encoding="utf-8"))
    packages = payload.get("addons")
    if not isinstance(packages, list):
        raise ValueError(f"{lock_path}: addons must be an array")

    names: list[str] = []
    for entry in packages:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise ValueError(f"{lock_path}: every add-on needs a string id")
        names.append(entry["id"])
    return sorted(names)


def _library_entries(descriptor: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    in_libraries = False
    for line in descriptor.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_libraries = stripped == "[libraries]"
            continue
        if not in_libraries:
            continue
        match = LIBRARY_LINE.match(line)
        if match:
            entries[match.group(1)] = match.group(2)
    return entries


def inspect_package(
    project_root: Path, package: str, library_key: str
) -> PackageArtifact:
    package_dir = project_root / "addons" / package
    descriptors = sorted(package_dir.glob("*.gdextension"))
    if len(descriptors) != 1:
        return PackageArtifact(
            package,
            package_dir,
            None,
            None,
            f"expected exactly one .gdextension descriptor, found {len(descriptors)}",
        )

    descriptor = descriptors[0]
    resource_path = _library_entries(descriptor).get(library_key)
    if resource_path is None:
        return PackageArtifact(
            package,
            descriptor,
            None,
            None,
            f"missing [libraries] key {library_key}",
        )
    if not resource_path.startswith("res://"):
        return PackageArtifact(
            package,
            descriptor,
            resource_path,
            None,
            f"library path is not project-relative: {resource_path}",
        )

    return PackageArtifact(
        package,
        descriptor,
        resource_path,
        project_root / resource_path.removeprefix("res://"),
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=sorted(TARGET_LIBRARY_KEYS))
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--lock",
        type=Path,
        default=Path("config/addons.lock.json"),
        help="Path relative to --project-root unless absolute",
    )
    args = parser.parse_args(argv)

    project_root = args.project_root.resolve()
    lock_path = args.lock if args.lock.is_absolute() else project_root / args.lock
    library_key = TARGET_LIBRARY_KEYS[args.target]

    try:
        packages = _locked_package_names(lock_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"PLATFORM_ARTIFACT_ERROR {error}")
        return 1

    print(
        f"PLATFORM_ARTIFACT_REPORT target={args.target} "
        f"library_key={library_key}"
    )
    artifacts = [
        inspect_package(project_root, package, library_key) for package in packages
    ]
    ready = 0
    missing = 0
    errors = 0
    for artifact in artifacts:
        descriptor = artifact.descriptor.relative_to(project_root)
        if artifact.error is not None:
            errors += 1
            print(
                f"ERROR package={artifact.package} descriptor={descriptor} "
                f"reason={artifact.error}"
            )
        elif artifact.exists:
            ready += 1
            assert artifact.filesystem_path is not None
            print(
                f"READY package={artifact.package} "
                f"path={artifact.filesystem_path.relative_to(project_root)}"
            )
        else:
            missing += 1
            assert artifact.filesystem_path is not None
            print(
                f"MISSING package={artifact.package} "
                f"path={artifact.filesystem_path.relative_to(project_root)}"
            )

    status = "READY" if missing == 0 and errors == 0 else "BLOCKED"
    print(
        "PLATFORM_ARTIFACT_RESULT "
        f"packages={len(artifacts)} ready={ready} missing={missing} "
        f"errors={errors} status={status}"
    )
    return 0 if status == "READY" else 2


if __name__ == "__main__":
    sys.exit(main())
