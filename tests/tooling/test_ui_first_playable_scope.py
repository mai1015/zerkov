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
ACTIVE_CAPTURE_SOURCES = (
    "tests/presentation/feature_gates_8_9_contract.gd",
    "tests/presentation/feature_gates_8_9_visual_evidence.gd",
    "tests/presentation/ui_production_unavailable_8_11_contract.gd",
    "tests/ui_component_states.gd",
    "tests/visual/inventory_loot_ui_4_11/capture.gd",
    "tests/visual/live_character_ui_8_6/capture.gd",
    "tests/visual/zerkov_screen_lifecycle/capture.gd",
    "ui/main.gd",
)


def relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def is_deferred(path: Path) -> bool:
    name = relative(path)
    return (
        name == "tests/responsive_smoke.gd"
        or name.startswith("tests/compact_")
        or name.startswith("tests/visual/inventory_ui_binding/")
        or name == "tests/visual/render_scale/capture.gd"
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


def gdscript_function_containing(source: str, offset: int) -> str:
    """Return the complete top-level function containing a source offset."""
    starts = [match.start() for match in re.finditer(r"(?m)^func\s+", source)]
    start = max((position for position in starts if position <= offset), default=-1)
    if start < 0:
        return ""
    end = min((position for position in starts if position > offset), default=len(source))
    return source[start:end]


def assert_exact_guard_before(
    testcase: unittest.TestCase,
    body: str,
    write_position: int,
) -> None:
    """Require an exact readback comparison and terminating branch pre-write."""
    prefix = body[:write_position]
    size_matches = list(re.finditer(
        r"get_size\(\)\s*(!=|==)\s*(?:FIRST_PLAYABLE_SIZE|EXACT_SIZE|"
        r"DESKTOP_CANVAS|Vector2i\(\s*1920\s*,\s*1080\s*\))",
        prefix,
    ))
    testcase.assertTrue(size_matches, "write lacks an exact framebuffer comparison")
    guard_matches = list(re.finditer(
        r"(?m)^\s*if\s+(?:not\s+\w*exact\w*|[^\n]*get_size\(\)\s*!=)[^:]*:",
        prefix,
    ))
    testcase.assertTrue(guard_matches, "write lacks a nonexact rejection branch")
    rejection = prefix[guard_matches[-1].end():]
    testcase.assertRegex(
        rejection,
        r"(?:\breturn\b|\bquit\(\s*2\s*\))",
        "nonexact branch does not terminate before write",
    )


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

    def test_historical_image_generators_fail_before_imports(self) -> None:
        paths = (
            PROJECT_ROOT / "tests/visual/inventory_ui_binding/summarize.py",
            PROJECT_ROOT / "tests/visual/render_scale/verify.py",
        )
        for path in paths:
            source = path.read_text(encoding="utf-8")
            guard_position = source.find("raise SystemExit")
            import_positions = [
                position
                for position in (
                    source.find("from pathlib"),
                    source.find("import json"),
                    source.find("import argparse"),
                )
                if position >= 0
            ]
            with self.subTest(generator=relative(path)):
                self.assertIn(DEFERRED_MARKER, source)
                self.assertGreaterEqual(guard_position, 0)
                self.assertTrue(import_positions, "no retained import found")
                self.assertLess(guard_position, min(import_positions))

    def test_active_capture_writes_have_exact_frame_guards(self) -> None:
        """Known active writers must reject before saving a nonexact image.

        This complements runner discovery: a root-size assignment alone cannot
        prove the renderer's drawable/readback size on a clamped desktop.
        """
        for relative_path in ACTIVE_CAPTURE_SOURCES:
            path = PROJECT_ROOT / relative_path
            source = path.read_text(encoding="utf-8")
            with self.subTest(capture=relative_path):
                self.assertIn("save_png", source)
                for save in re.finditer(r"save_png\s*\(", source):
                    body = gdscript_function_containing(source, save.start())
                    self.assertTrue(body, "save_png is outside a top-level function")
                    local_save = body.find("save_png")
                    assert_exact_guard_before(self, body, local_save)
                for mkdir in re.finditer(r"make_dir_recursive_absolute\s*\(", source):
                    body = gdscript_function_containing(source, mkdir.start())
                    self.assertTrue(body, "directory creation is outside a top-level function")
                    local_mkdir = body.find("make_dir_recursive_absolute")
                    assert_exact_guard_before(self, body, local_mkdir)

        main_source = (PROJECT_ROOT / "ui/main.gd").read_text(encoding="utf-8")
        resize_body = re.search(
            r"(?ms)^func _on_window_resized\(\)[^:]*:\s*\n(.*?)(?=^func |\Z)",
            main_source,
        )
        self.assertIsNotNone(resize_body)
        body = resize_body.group(1)
        self.assertIn("qa_mode or _review_navigation_enabled", body)
        self.assertLess(body.find("quit(2)"), body.find("_sync_window_scale()"))

    def test_exact_write_guard_detector_negative_controls(self) -> None:
        good = """func capture():
    var image = root.get_texture().get_image()
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if not exact_frame:
        return
    image.save_png(path)
"""
        bad_failed_check_then_save = """func capture():
    var image = root.get_texture().get_image()
    check(image.get_size() == FIRST_PLAYABLE_SIZE, \"exact\")
    image.save_png(path)
"""
        bad_directory_first = """func run():
    DirAccess.make_dir_recursive_absolute(path)
    var image = root.get_texture().get_image()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
"""
        good_write = good.find("save_png")
        assert_exact_guard_before(self, good, good_write)
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(
                self,
                bad_failed_check_then_save,
                bad_failed_check_then_save.find("save_png"),
            )
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(
                self,
                bad_directory_first,
                bad_directory_first.find("make_dir_recursive_absolute"),
            )


if __name__ == "__main__":
    unittest.main()
