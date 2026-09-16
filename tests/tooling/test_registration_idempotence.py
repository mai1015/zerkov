"""Registration must preserve current manifest bytes without hiding real drift."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CASES = (
    ("register_map_studies.py", "tests/presentation/map_studies_contract.gd",
     "tests/tooling/run_map_studies_gate.py"),
    ("register_northline_zone.py", "tests/presentation/northline_zone_contract.gd",
     "tests/tooling/run_northline_zone_gate.py"),
)


class RegistrationIdempotenceTests(unittest.TestCase):
    def test_formats_remain_byte_identical_but_changed_source_is_detected(self) -> None:
        for script, visual, command in CASES:
            for indent in (None, 2):
                with self.subTest(script=script, indent=indent), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    for name in ("tools", "config", "tests/presentation", "tests/tooling"):
                        (root / name).mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / "tools" / script, root / "tools" / script)
                    for name in (visual, command):
                        (root / name).write_text("# reviewed source\n", encoding="utf-8")
                    manifest = {
                        "active_visual_entrypoints": {"later.gd": {"sha256": "retained"}},
                        "active_command_entrypoints": {},
                        "sanctioned_capture_writers": {},
                        "unrelated_policy": {"strict": True},
                    }
                    path = root / "config/first_playable_1080_gate.json"
                    test = root / "tests/tooling/test_ui_first_playable_scope.py"
                    path.write_text(json.dumps(manifest), encoding="utf-8")
                    test.write_text('self.assertEqual(1, len(self.manifest["active_visual_entrypoints"]))\n', encoding="utf-8")
                    argv = [sys.executable, str(root / "tools" / script)]
                    subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    current = json.loads(path.read_text())
                    self.assertEqual(current["unrelated_policy"], manifest["unrelated_policy"])
                    self.assertEqual(current["active_visual_entrypoints"]["later.gd"], {"sha256": "retained"})
                    self.assertIn(visual, current["active_visual_entrypoints"])
                    self.assertIn(command, current["active_command_entrypoints"])
                    self.assertIn(visual, current["sanctioned_capture_writers"])
                    path.write_text(json.dumps(current, indent=indent) + "\n", encoding="utf-8")
                    before = (path.read_bytes(), test.read_bytes())
                    subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.assertEqual(before, (path.read_bytes(), test.read_bytes()))
                    # An actual source edit still rewrites its hash, so CI's diff
                    # fails until that specific changed registration is reviewed.
                    (root / visual).write_text("# changed source\n", encoding="utf-8")
                    subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    self.assertNotEqual(before[0], path.read_bytes())
                    after = json.loads(path.read_text())
                    self.assertEqual(after["active_visual_entrypoints"][visual]["sha256"],
                                     hashlib.sha256((root / visual).read_bytes()).hexdigest())
                    self.assertEqual(after["unrelated_policy"], manifest["unrelated_policy"])
                    self.assertEqual(after["active_visual_entrypoints"]["later.gd"], {"sha256": "retained"})


if __name__ == "__main__":
    unittest.main()
