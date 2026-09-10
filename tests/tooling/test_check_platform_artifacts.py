from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[2] / "tools" / "check_platform_artifacts.py"
SPEC = importlib.util.spec_from_file_location("check_platform_artifacts", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PlatformArtifactTests(unittest.TestCase):
    def _project(self, root: Path, *, create_binary: bool) -> None:
        (root / "config").mkdir()
        (root / "addons" / "example" / "bin").mkdir(parents=True)
        (root / "config" / "addons.lock.json").write_text(
            json.dumps({"addons": [{"id": "example"}]}),
            encoding="utf-8",
        )
        (root / "addons" / "example" / "example.gdextension").write_text(
            "[configuration]\nentry_symbol = \"example_init\"\n\n"
            "[libraries]\n"
            "windows.debug.x86_64 = "
            "\"res://addons/example/bin/example.dll\"\n",
            encoding="utf-8",
        )
        if create_binary:
            (root / "addons" / "example" / "bin" / "example.dll").write_bytes(b"x")

    def test_reports_missing_declared_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._project(root, create_binary=False)
            artifact = MODULE.inspect_package(root, "example", "windows.debug.x86_64")
            self.assertIsNone(artifact.error)
            self.assertFalse(artifact.exists)

    def test_reports_existing_declared_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._project(root, create_binary=True)
            artifact = MODULE.inspect_package(root, "example", "windows.debug.x86_64")
            self.assertIsNone(artifact.error)
            self.assertTrue(artifact.exists)

    def test_rejects_missing_library_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._project(root, create_binary=False)
            artifact = MODULE.inspect_package(root, "example", "linux.debug.x86_64")
            self.assertIn("missing [libraries] key", artifact.error or "")


if __name__ == "__main__":
    unittest.main()
