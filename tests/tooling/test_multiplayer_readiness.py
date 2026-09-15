"""Negative controls for task 10.1's inventory; no native behavior is simulated."""
from __future__ import annotations
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

FILE = Path(__file__).resolve().parents[2] / "tools/audit_multiplayer_readiness.py"
spec = importlib.util.spec_from_file_location("readiness", FILE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
REV = "a" * 40


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.lock = {"addons": []}
        for name in audit.ADDONS:
            directory = self.root / "addons" / name
            directory.mkdir(parents=True)
            manifest = directory / "release_manifest.json"
            manifest.write_text(json.dumps({"provenance": {"source_revision": REV}, "targets": []}))
            lines = ["[libraries]"]
            for platform in ("windows", "linux"):
                for build in ("debug", "release"):
                    lines.append(f'{platform}.{build}.x86_64 = "res://addons/{name}/bin/{platform}-{build}.native"')
            (directory / f"{name}.gdextension").write_text("\n".join(lines))
            self.lock["addons"].append({"id": name, "destination": f"addons/{name}",
                "source": {"release_manifest_sha256": audit.digest(manifest), "git_head": REV},
                "native_artifacts": []})
        (self.root / "config").mkdir()
        (self.root / "config/toolchain.lock.json").write_text('{"engine":{"required_version":"pinned.test"}}')
        self.save()

    def save(self):
        (self.root / "config/addons.lock.json").write_text(json.dumps(self.lock))

    def inspect(self):
        return audit.inspect(self.root, REV)

    def library(self, addon=0, platform="windows", build="debug", pin=True):
        entry = self.lock["addons"][addon]
        file = self.root / entry["destination"] / "bin" / f"{platform}-{build}.native"
        file.parent.mkdir(exist_ok=True)
        file.write_bytes(b"test bytes, not a native library")
        if pin:
            entry["native_artifacts"].append({"path": "bin/" + file.name, "sha256": audit.digest(file)})
            self.save()
        return file

    def test_empty_artifact_set_is_blocked_not_vacuously_ready(self):
        r = self.inspect()
        self.assertFalse(r["network_ready"])
        self.assertEqual(24, len(r["libraries"]))
        for target in r["platforms"].values():
            self.assertEqual(12, target["blocked_libraries"])
            self.assertFalse(target["artifact_prerequisite_passed"])

    def test_existing_unlocked_file_remains_blocked(self):
        self.library(pin=False)
        row = next(x for x in self.inspect()["libraries"] if x["state"] == "unlocked")
        self.assertIsNone(row["locked_sha256"])

    def test_wrong_bytes_fail_hash_match(self):
        self.library().write_bytes(b"corrupt")
        self.assertIn("mismatch", [x["state"] for x in self.inspect()["libraries"]])

    def test_lock_match_is_not_release_manifest_match(self):
        self.library()
        self.lock["addons"][0]["native_artifacts"][0]["release_manifest_sha256"] = "b" * 64
        self.save()
        row = next(x for x in self.inspect()["libraries"] if x["state"] == "locked_match")
        self.assertFalse(row["release_artifact_matches_lock"])

    def test_complete_files_cannot_claim_network_or_platform_support(self):
        for i in range(6):
            for platform in ("windows", "linux"):
                for build in ("debug", "release"):
                    self.library(i, platform, build)
        r = self.inspect()
        for value in r["platforms"].values():
            self.assertTrue(value["artifact_prerequisite_passed"])
            self.assertFalse(value["supported"])
            self.assertEqual("not_executed_by_inventory", value["build_load_export_status"])
        self.assertFalse(r["network_ready"])

    def test_missing_selector_not_silently_omitted(self):
        file = self.root / "addons/common_ui/common_ui.gdextension"
        file.write_text('[libraries]\n')
        self.assertEqual(4, sum(x["state"] == "selector_missing" for x in self.inspect()["libraries"]))

    def test_missing_package_rejected(self):
        self.lock["addons"].pop()
        self.save()
        with self.assertRaises(ValueError): self.inspect()

    def test_duplicate_package_rejected(self):
        self.lock["addons"][-1] = self.lock["addons"][0]
        self.save()
        with self.assertRaises(ValueError): self.inspect()

    def test_manifest_drift_is_disclosed(self):
        (self.root / "addons/common_ui/release_manifest.json").write_text('{"changed":true}')
        self.assertFalse(self.inspect()["packages"][0]["release_manifest_matches_lock"])

    def test_missing_manifest_is_not_empty_success(self):
        (self.root / "addons/common_ui/release_manifest.json").unlink()
        with self.assertRaises(OSError): self.inspect()

    def test_duplicate_native_lock_rejected(self):
        self.library()
        self.lock["addons"][0]["native_artifacts"] *= 2
        self.save()
        with self.assertRaises(ValueError): self.inspect()

    def test_malformed_sha_rejected(self):
        self.library()
        self.lock["addons"][0]["native_artifacts"][0]["sha256"] = "not a hash"
        self.save()
        with self.assertRaises(ValueError): self.inspect()

    def test_nonliteral_library_expression_rejected(self):
        (self.root / "addons/common_ui/common_ui.gdextension").write_text('[libraries]\nwindows.debug.x86_64 = callable()')
        with self.assertRaises(ValueError): self.inspect()

    def test_package_path_escapes_rejected(self):
        file = self.root / "addons/common_ui/common_ui.gdextension"
        for target in ['res://addons/weapon_system/bin/f', 'res://addons/common_ui/../../../secret', '/tmp/secret']:
            file.write_text('[libraries]\nwindows.debug.x86_64 = ' + json.dumps(target))
            with self.subTest(target=target), self.assertRaises(ValueError): self.inspect()

    def test_symlink_rejected(self):
        file = self.root / "addons/common_ui/release_manifest.json"
        other = self.base / "external.json"
        other.write_bytes(file.read_bytes())
        file.unlink()
        try: file.symlink_to(other)
        except OSError: self.skipTest("Host cannot create symlinks")
        with self.assertRaises(ValueError): self.inspect()

    def test_invalid_revision_rejected(self):
        for rev in ["main", "", "a" * 39, "G" * 40]:
            with self.subTest(rev=rev), self.assertRaises(ValueError): audit.inspect(self.root, rev)

    def test_fingerprint_changes_with_input(self):
        before = self.inspect()["input_sha256"]
        self.lock["comment"] = "edit"
        self.save()
        self.assertNotEqual(before, self.inspect()["input_sha256"])

    def test_cli_inventory_success_does_not_open_gate(self):
        output = self.base / "report.json"
        with contextlib.redirect_stdout(io.StringIO()):
            code = audit.main(["--root", str(self.root), "--revision", REV, "--output", str(output)])
        self.assertEqual(0, code)
        self.assertFalse(json.loads(output.read_text())["network_ready"])

    def test_cli_required_artifacts_returns_explicit_blocked(self):
        output = self.base / "report.json"
        with contextlib.redirect_stdout(io.StringIO()):
            code = audit.main(["--root", str(self.root), "--revision", REV, "--output", str(output),
                               "--require-platform-artifacts", "linux-server"])
        self.assertEqual(2, code)
        self.assertTrue(output.exists())

    def test_cannot_write_generated_report_into_checkout(self):
        with contextlib.redirect_stderr(io.StringIO()):
            code = audit.main(["--root", str(self.root), "--revision", REV,
                               "--output", str(self.root / "config/addons.lock.json")])
        self.assertEqual(1, code)
        self.assertEqual(self.lock, json.loads((self.root / "config/addons.lock.json").read_text()))


if __name__ == "__main__":
    unittest.main()
