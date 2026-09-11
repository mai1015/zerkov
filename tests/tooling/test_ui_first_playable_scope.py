"""Permanent static gate for current Zerkov UI runners.

This test reads source only. It never launches a UI, resizes a viewport, or
generates evidence. Historical compact/responsive and inventory_ui_binding
visual sources must fail closed before their retained implementation can run.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MAIN_SCENE_LITERAL = "res://ui/main.tscn"
EXACT_VECTOR = re.compile(r"Vector2i\(\s*1920\s*,\s*1080\s*\)")
FORBIDDEN_OUTPUTS = (
    re.compile(r"Vector2i\(\s*1600\s*,\s*900\s*\)"),
    re.compile(r"Vector2i\(\s*1280\s*,\s*720\s*\)"),
    re.compile(r"Vector2i\(\s*960\s*,\s*540\s*\)"),
)
DEFERRED_MARKER = "DEFERRED_DISPLAY_SUITE"


def relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def is_deferred(path: Path) -> bool:
    name = relative(path)
    return (
        name == "tests/responsive_smoke.gd"
        or name.startswith("tests/compact_")
        or name.startswith("tests/visual/inventory_ui_binding/")
    )


def ui_gd_runners() -> list[Path]:
    candidates = sorted((PROJECT_ROOT / "tests").rglob("*.gd"))
    candidates += sorted((PROJECT_ROOT / "tools").rglob("*.gd"))
    result: list[Path] = []
    for path in candidates:
        source = path.read_text(encoding="utf-8")
        if MAIN_SCENE_LITERAL in source or is_deferred(path):
            result.append(path)
    return result


def initialize_body(source: str) -> str:
    match = re.search(
        r"(?ms)^func _initialize\([^\n]*\)[^\n]*:\s*\n(.*?)(?=^func |\Z)",
        source,
    )
    return match.group(1) if match else ""


def has_exact_output_gate(source: str) -> bool:
    if not EXACT_VECTOR.search(source):
        return False
    direct = re.search(
        r"root\.size\s*=\s*(?:FIRST_PLAYABLE_SIZE|EXACT_SIZE|"
        r"Vector2i\(\s*1920\s*,\s*1080\s*\))",
        source,
    )
    if direct:
        return True
    singleton_loop = re.search(
        r"for\s+(\w+)\s+in\s+\[\s*FIRST_PLAYABLE_SIZE\s*\]",
        source,
    )
    if not singleton_loop:
        return False
    variable = re.escape(singleton_loop.group(1))
    return re.search(
        rf"root\.(?:size|content_scale_size)\s*=\s*{variable}", source
    ) is not None


class FirstPlayableUIScopeContract(unittest.TestCase):
    def test_every_ui_runner_is_exact_or_fails_closed(self) -> None:
        runners = ui_gd_runners()
        self.assertTrue(runners, "no UI runners were discovered")
        active = [path for path in runners if not is_deferred(path)]
        deferred = [path for path in runners if is_deferred(path)]

        for path in active:
            source = path.read_text(encoding="utf-8")
            with self.subTest(runner=relative(path)):
                self.assertTrue(
                    has_exact_output_gate(source),
                    "current UI runner lacks an exact 1920x1080 output gate",
                )
                for pattern in FORBIDDEN_OUTPUTS:
                    self.assertIsNone(
                        pattern.search(source),
                        "current UI runner contains a forbidden smaller output",
                    )
                self.assertNotIn("--layout=compact", source)
                self.assertIsNone(
                    re.search(r'ui_layout_mode\s*=\s*["\']compact["\']', source)
                )

        for path in deferred:
            source = path.read_text(encoding="utf-8")
            body = initialize_body(source)
            with self.subTest(runner=relative(path)):
                self.assertIn(DEFERRED_MARKER, body)
                self.assertRegex(body, r"quit\(\s*2\s*\)")
                run_position = source.find("func run")
                guard_position = source.find(DEFERRED_MARKER)
                self.assertTrue(
                    run_position < 0 or guard_position < run_position,
                    "deferred guard must precede retained runner logic",
                )

        # These counts are deliberately lower bounds: newly added runners are
        # discovered automatically and must satisfy one of the policies above.
        self.assertGreaterEqual(len(active), 20)
        self.assertGreaterEqual(len(deferred), 13)

    def test_historical_contact_sheet_generator_fails_before_imports(self) -> None:
        path = PROJECT_ROOT / "tests/visual/inventory_ui_binding/summarize.py"
        source = path.read_text(encoding="utf-8")
        guard_position = source.find("raise SystemExit")
        first_import = min(
            position
            for position in (source.find("from pathlib"), source.find("import json"))
            if position >= 0
        )
        self.assertIn(DEFERRED_MARKER, source)
        self.assertGreaterEqual(guard_position, 0)
        self.assertLess(guard_position, first_import)


if __name__ == "__main__":
    unittest.main()
