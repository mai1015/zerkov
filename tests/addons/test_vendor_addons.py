#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = PROJECT_ROOT / "tools" / "vendor_addons.py"
SPEC = importlib.util.spec_from_file_location("vendor_addons", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
vendor_addons = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = vendor_addons
SPEC.loader.exec_module(vendor_addons)


class VendorAddonsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_directory.name)
        self.source_repository = self.root / "source"
        self.source_package = self.source_repository / "addons" / "fixture_addon"
        self.destination_root = self.root / "project"
        self.destination_package = self.destination_root / "addons" / "fixture_addon"
        self.source_package.mkdir(parents=True)
        (self.source_package / "runtime.gd").write_text("extends Node\n", encoding="utf-8")
        (self.source_package / "native" / ".build").mkdir(parents=True)
        (self.source_package / "native" / ".build" / "ignored.o").write_bytes(b"volatile")
        (self.source_package / "native" / "core").mkdir(parents=True)
        (self.source_package / "native" / "core" / "fixture.cpp").write_text(
            "// rebuild source\n", encoding="utf-8"
        )
        (self.source_package / "bin").mkdir()
        self.artifact = self.source_package / "bin" / "libfixture.dylib"
        self.artifact.write_bytes(b"native artifact")
        self.release_manifest = self.source_package / "release_manifest.json"
        self.release_manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "addon": "fixture_addon",
                    "version": "1.0.0",
                    "api_version": "1.0.0",
                    "protocol_version": 1,
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        digest = vendor_addons.package_digest(self.source_package)
        self.entry = {
            "id": "fixture_addon",
            "version": "1.0.0",
            "api_version": "1.0.0",
            "protocol_version": 1,
            "source": {
                "repository_path": str(self.source_repository),
                "package_path": str(self.source_package),
                "git_head": None,
                "package_file_count": digest.file_count,
                "package_tree_sha256": digest.sha256,
                "release_manifest_sha256": vendor_addons._sha256_file(
                    self.release_manifest
                ),
            },
            "destination": "addons/fixture_addon",
            "native_artifacts": [
                {
                    "path": "bin/libfixture.dylib",
                    "sha256": vendor_addons._sha256_file(self.artifact),
                }
            ],
        }

    def tearDown(self) -> None:
        self.temp_directory.cleanup()

    def test_copy_is_verified_and_excludes_build_intermediates(self) -> None:
        vendor_addons.apply_locked_packages(
            [self.entry], project_root=self.destination_root, dry_run=False
        )
        vendor_addons.verify_package(self.entry, self.destination_package)
        self.assertTrue((self.destination_package / "runtime.gd").is_file())
        self.assertTrue(
            (self.destination_package / "native" / "core" / "fixture.cpp").is_file()
        )
        self.assertFalse(
            (self.destination_package / "native" / ".build" / "ignored.o").exists()
        )

    def test_declared_generated_uid_does_not_unlock_destination(self) -> None:
        vendor_addons.apply_locked_packages(
            [self.entry], project_root=self.destination_root, dry_run=False
        )
        generated_uid = self.destination_package / "runtime.gd.uid"
        generated_uid.write_text("uid://fixture\n", encoding="utf-8")
        self.entry["destination_generated_paths"] = ["runtime.gd.uid"]
        vendor_addons.verify_entries(
            [self.entry], scope="destination", project_root=self.destination_root
        )

    def test_source_drift_is_rejected(self) -> None:
        (self.source_package / "runtime.gd").write_text(
            "extends Node\n# drift\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(vendor_addons.VendorError, "unlocked package tree"):
            vendor_addons.verify_package(self.entry, self.source_package)

    def test_native_artifact_drift_is_rejected(self) -> None:
        self.artifact.write_bytes(b"changed artifact")
        digest = vendor_addons.package_digest(self.source_package)
        self.entry["source"]["package_file_count"] = digest.file_count
        self.entry["source"]["package_tree_sha256"] = digest.sha256
        with self.assertRaisesRegex(vendor_addons.VendorError, "native artifact mismatch"):
            vendor_addons.verify_package(self.entry, self.source_package)


if __name__ == "__main__":
    unittest.main()
