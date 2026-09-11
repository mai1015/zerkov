"""Permanent static gate for current Zerkov UI runners.

This test reads source only. It never launches a UI, resizes a viewport, or
generates evidence. Historical compact/responsive and inventory_ui_binding
visual sources must fail closed before their retained implementation can run.
"""

from __future__ import annotations

import ast
import re
import subprocess
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
DEFERRED_INVENTORY_QA_PREFIX = "docs/qa/inventory_ui_binding/astra_final_accept/"
DEFERRED_PACKET_PYTHON_PREFIXES = (
    DEFERRED_INVENTORY_QA_PREFIX,
    "docs/qa/inventory_ability_equipment/astra_final/",
    "docs/qa/inventory_weapon_reload/astra_final/",
    "docs/qa/inventory_weapon_reload/astra_gate/",
)
DEFERRED_QA_GDSCRIPT = frozenset({
    "docs/qa/inventory_ability_equipment/astra_final/history/flow_1789069443010348000/independent_flow.gd",
    "docs/qa/inventory_ability_equipment/astra_final/independent_flow.gd",
    "docs/qa/inventory_weapon_reload/astra_final/independent_flow.gd",
    "docs/qa/inventory_weapon_reload/astra_gate/flow_playthrough.gd",
})
DEFERRED_PYTHON_GENERATORS = (
    "tests/visual/inventory_ui_binding/summarize.py",
    "tests/visual/render_scale/verify.py",
    "docs/qa/inventory_ui_binding/astra_final_accept/finalize_evidence.py",
    "docs/qa/inventory_ui_binding/astra_final_accept/run_suites.py",
    "docs/qa/inventory_ability_equipment/astra_final/history/flow_1789069443010348000/run_validation.py",
    "docs/qa/inventory_ability_equipment/astra_final/run_validation.py",
    "docs/qa/inventory_ability_equipment/astra_final/finalize_packet.py",
    "docs/qa/inventory_weapon_reload/astra_final/run_validation.py",
    "docs/qa/inventory_weapon_reload/astra_final/finalize_packet.py",
    "docs/qa/inventory_weapon_reload/astra_gate/finalize_packet.py",
    "docs/qa/inventory_weapon_reload/astra_gate/run_gate.py",
)
ACTIVE_CAPTURE_SOURCES = (
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
        name in DEFERRED_QA_GDSCRIPT
        or name.startswith(DEFERRED_INVENTORY_QA_PREFIX)
        or name == "tests/responsive_smoke.gd"
        or name.startswith("tests/compact_")
        or name.startswith("tests/visual/inventory_ui_binding/")
        or name == "tests/visual/render_scale/capture.gd"
    )


def ui_gd_runners() -> list[Path]:
    candidates = sorted((PROJECT_ROOT / "tests").rglob("*.gd"))
    candidates += sorted((PROJECT_ROOT / "tools").rglob("*.gd"))
    candidates += [PROJECT_ROOT / name for name in sorted(DEFERRED_QA_GDSCRIPT)]
    candidates += sorted(
        (PROJECT_ROOT / DEFERRED_INVENTORY_QA_PREFIX).glob("*.gd")
    )
    result: list[Path] = []
    for path in candidates:
        source = path.read_text(encoding="utf-8")
        if MAIN_SCENE_LITERAL in source or is_deferred(path):
            result.append(path)
    return result


def tracked_names(pathspec: str) -> list[str]:
    return sorted(item for item in subprocess.run(
        ["git", "ls-files", "-z", "--", pathspec],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split("\0") if item)


def active_png_writers() -> list[Path]:
    """Discover every current GDScript PNG writer, including QA artifacts."""
    result: list[Path] = []
    for name in tracked_names("*.gd"):
        path = PROJECT_ROOT / name
        if is_deferred(path):
            continue
        if re.search(r"\bsave_png\s*\(", path.read_text(encoding="utf-8")):
            result.append(path)
    return result


def initialize_body(source: str) -> str:
    match = re.search(
        r"(?ms)^func _initialize\([^\n]*\)[^\n]*:\s*\n"
        r"(.*?)(?=^(?:static\s+)?func |\Z)",
        source,
    )
    return match.group(1) if match else ""


def gdscript_function_region(source: str, offset: int) -> tuple[str, int]:
    """Return a top-level ordinary/static function and its source offset."""
    starts = [
        match.start()
        for match in re.finditer(r"(?m)^(?:static\s+)?func\s+", source)
    ]
    start = max((position for position in starts if position <= offset), default=-1)
    if start < 0:
        return "", -1
    end = min((position for position in starts if position > offset), default=len(source))
    return source[start:end], start


def gdscript_function_containing(source: str, offset: int) -> str:
    """Return the complete top-level function containing a source offset."""
    return gdscript_function_region(source, offset)[0]


def strip_gdscript_comment(line: str) -> str:
    """Remove a GDScript comment without treating # inside a string as one."""
    quote = ""
    escaped = False
    for index, character in enumerate(line):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote:
            escaped = True
            continue
        if quote:
            if character == quote:
                quote = ""
            continue
        if character in ("'", '"'):
            quote = character
        elif character == "#":
            return line[:index]
    return line


def line_indent(line: str) -> int:
    prefix = line[: len(line) - len(line.lstrip(" \t"))]
    return len(prefix.expandtabs(4))


def exact_size_expression(receiver: str | None = None, equality: str = "==") -> re.Pattern[str]:
    image = rf"{re.escape(receiver)}\.get_size\(\)" if receiver else r"\w+\.get_size\(\)"
    exact = (
        r"(?:FIRST_PLAYABLE_SIZE|EXACT_SIZE|DESKTOP_CANVAS|"
        r"Vector2i\(\s*1920\s*,\s*1080\s*\))"
    )
    return re.compile(rf"{image}\s*{re.escape(equality)}\s*{exact}")


def assignment_expression_before(
    lines: list[str], guard_index: int, indent: int, variable: str
) -> tuple[str, int]:
    """Return the closest same-scope assignment expression and its last line."""
    assignment = re.compile(rf"^(?:var\s+)?{re.escape(variable)}\s*(?::=|=)\s*(.*)$")
    for index in range(guard_index - 1, -1, -1):
        code = strip_gdscript_comment(lines[index]).strip()
        if not code:
            continue
        if line_indent(lines[index]) < indent:
            break
        if line_indent(lines[index]) != indent:
            continue
        match = assignment.match(code)
        if not match:
            continue
        pieces = [match.group(1)]
        last = index
        while pieces[-1].rstrip().endswith("\\") and last + 1 < guard_index:
            last += 1
            pieces.append(strip_gdscript_comment(lines[last]).strip())
        return " ".join(pieces), last
    return "", -1


def direct_return_in_guard(lines: list[str], guard_index: int, indent: int) -> bool:
    """Require an unconditional return in the rejecting branch itself."""
    branch_indent = -1
    for index in range(guard_index + 1, len(lines)):
        code = strip_gdscript_comment(lines[index]).strip()
        if not code:
            continue
        current = line_indent(lines[index])
        if current <= indent:
            return False
        if branch_indent < 0:
            branch_indent = current
        if current == branch_indent and re.fullmatch(r"return(?:\s+.+)?", code):
            return True
    return False


def assert_exact_guard_before(
    testcase: unittest.TestCase,
    body: str,
    write_position: int,
) -> None:
    """Require a same-scope, receiver-specific, terminating exact-frame guard."""
    testcase.assertGreaterEqual(write_position, 0, "write token is missing")
    line_start = body.rfind("\n", 0, write_position) + 1
    line_end = body.find("\n", write_position)
    if line_end < 0:
        line_end = len(body)
    write_line = strip_gdscript_comment(body[line_start:line_end])
    write_indent = line_indent(body[line_start:line_end])
    save_match = re.search(r"\b(\w+)\.save_png\s*\(", write_line)
    receiver = save_match.group(1) if save_match else None
    testcase.assertTrue(
        receiver is not None or "make_dir_recursive_absolute" in write_line,
        "unsupported capture write shape",
    )

    prefix_lines = body[:line_start].splitlines()
    selected_guard = -1
    proof_end = -1
    for index in range(len(prefix_lines) - 1, -1, -1):
        raw = prefix_lines[index]
        code = strip_gdscript_comment(raw).strip()
        if line_indent(raw) != write_indent:
            continue
        guard = re.fullmatch(r"if\s+(.+):", code)
        if not guard or not direct_return_in_guard(prefix_lines, index, write_indent):
            continue
        condition = guard.group(1).strip()
        direct_receiver = receiver if receiver else None
        if exact_size_expression(direct_receiver, "!=").search(condition):
            selected_guard = index
            proof_end = index
            break
        exact_name = re.fullmatch(r"not\s+\(?([A-Za-z_]\w*)\)?", condition)
        if not exact_name:
            continue
        expression, assignment_end = assignment_expression_before(
            prefix_lines, index, write_indent, exact_name.group(1)
        )
        if expression and exact_size_expression(receiver, "==").search(expression):
            selected_guard = index
            proof_end = assignment_end
            break

    testcase.assertGreaterEqual(
        selected_guard,
        0,
        "write lacks a same-scope receiver-specific exact-frame rejection with return",
    )
    if receiver:
        intervening = "\n".join(prefix_lines[proof_end + 1 :])
        testcase.assertIsNone(
            re.search(
                rf"(?m)^\s*(?:var\s+)?{re.escape(receiver)}\s*(?::=|=)|"
                rf"\b{re.escape(receiver)}\.(?:resize|set_data)\s*\(",
                intervening,
            ),
            "saved framebuffer is replaced or resized after its exact-size proof",
        )


def assert_unconditional_python_retirement(
    testcase: unittest.TestCase, source: str, filename: str = "<fixture>"
) -> None:
    """Require the first executable Python statement to terminate the module."""
    module = ast.parse(source, filename=filename)
    statements = list(module.body)
    if statements and isinstance(statements[0], ast.Expr) \
            and isinstance(statements[0].value, ast.Constant) \
            and isinstance(statements[0].value.value, str):
        statements.pop(0)
    testcase.assertTrue(statements, "historical generator is empty")
    guard = statements[0]
    testcase.assertIsInstance(
        guard, ast.Raise,
        "first executable statement must be an unconditional raise",
    )
    exception = guard.exc if isinstance(guard, ast.Raise) else None
    testcase.assertIsInstance(exception, ast.Call)
    function = exception.func if isinstance(exception, ast.Call) else None
    testcase.assertIsInstance(function, ast.Name)
    testcase.assertEqual(
        function.id if isinstance(function, ast.Name) else "", "SystemExit"
    )
    marker_text = " ".join(
        str(argument.value)
        for argument in exception.args
        if isinstance(argument, ast.Constant)
    ) if isinstance(exception, ast.Call) else ""
    testcase.assertIn(DEFERRED_MARKER, marker_text)


def has_exact_output_gate(source: str) -> bool:
    uncommented = "\n".join(
        strip_gdscript_comment(line) for line in source.splitlines()
    )
    exact_constants = {
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s*const\s+([A-Za-z_]\w*)\s*(?::=|=)\s*"
            r"Vector2i\(\s*1920\s*,\s*1080\s*\)",
            uncommented,
        )
    }
    if not exact_constants and not EXACT_VECTOR.search(uncommented):
        return False
    exact_value = (
        r"Vector2i\(\s*1920\s*,\s*1080\s*\)"
        if not exact_constants
        else r"(?:Vector2i\(\s*1920\s*,\s*1080\s*\)|" \
            + "|".join(map(re.escape, sorted(exact_constants))) + r")"
    )
    direct = re.search(
        rf"root\.(?:size|content_scale_size)\s*=\s*{exact_value}",
        uncommented,
    )
    if direct:
        return True
    singleton_loop = re.search(
        rf"for\s+(\w+)\s+in\s+\[\s*{exact_value}\s*\]",
        uncommented,
    )
    if not singleton_loop:
        return False
    variable = re.escape(singleton_loop.group(1))
    return re.search(
        rf"root\.(?:size|content_scale_size)\s*=\s*{variable}", uncommented
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
                executable = [
                    strip_gdscript_comment(line).strip()
                    for line in body.splitlines()
                    if strip_gdscript_comment(line).strip()
                ]
                self.assertGreaterEqual(len(executable), 3)
                self.assertTrue(executable[0].startswith("push_error("))
                self.assertIn(DEFERRED_MARKER, executable[0])
                self.assertRegex(executable[1], r"^quit\(\s*2\s*\)$")
                self.assertEqual(executable[2], "return")
                run_position = source.find("func run")
                guard_position = source.find(DEFERRED_MARKER)
                self.assertTrue(
                    run_position < 0 or guard_position < run_position,
                    "deferred guard must precede retained runner logic",
                )

        # These counts are deliberately lower bounds: newly added runners are
        # discovered automatically and must satisfy one of the policies above.
        self.assertGreaterEqual(len(active), 20)
        self.assertGreaterEqual(len(deferred), 32)

    def test_historical_image_generators_fail_before_imports(self) -> None:
        discovered = {
            "tests/visual/inventory_ui_binding/summarize.py",
            "tests/visual/render_scale/verify.py",
        }
        discovered.update(
            name for name in tracked_names("*.py")
            if name.startswith(DEFERRED_PACKET_PYTHON_PREFIXES)
        )
        self.assertEqual(set(DEFERRED_PYTHON_GENERATORS), discovered)
        for relative_path in DEFERRED_PYTHON_GENERATORS:
            path = PROJECT_ROOT / relative_path
            source = path.read_text(encoding="utf-8")
            with self.subTest(generator=relative(path)):
                assert_unconditional_python_retirement(
                    self, source, relative_path
                )

    def test_active_capture_writes_have_exact_frame_guards(self) -> None:
        """Known active writers must reject before saving a nonexact image.

        This complements runner discovery: a root-size assignment alone cannot
        prove the renderer's drawable/readback size on a clamped desktop.
        """
        writers = active_png_writers()
        self.assertGreaterEqual(len(writers), len(ACTIVE_CAPTURE_SOURCES))
        for path in writers:
            relative_path = relative(path)
            source = path.read_text(encoding="utf-8")
            with self.subTest(capture=relative_path):
                self.assertIn("save_png", source)
                for save in re.finditer(r"save_png\s*\(", source):
                    body, body_start = gdscript_function_region(source, save.start())
                    self.assertTrue(body, "save_png is outside a top-level function")
                    local_save = save.start() - body_start
                    assert_exact_guard_before(self, body, local_save)
                for mkdir in re.finditer(r"make_dir_recursive_absolute\s*\(", source):
                    body, body_start = gdscript_function_region(source, mkdir.start())
                    self.assertTrue(body, "directory creation is outside a top-level function")
                    local_mkdir = mkdir.start() - body_start
                    assert_exact_guard_before(self, body, local_mkdir)

        main_source = (PROJECT_ROOT / "ui/main.gd").read_text(encoding="utf-8")
        resize_body = re.search(
            r"(?ms)^func _on_window_resized\(\)[^:]*:\s*\n(.*?)(?=^func |\Z)",
            main_source,
        )
        self.assertIsNotNone(resize_body)
        body = resize_body.group(1)
        self.assertIn(
            "qa_mode or _review_navigation_enabled or exact_capture_mode", body
        )
        self.assertLess(body.find("quit(2)"), body.find("_sync_window_scale()"))

    def test_production_data_capture_hosts_reject_resize_before_mount(self) -> None:
        paths = (
            PROJECT_ROOT / "tests/presentation/ui_production_unavailable_8_11_contract.gd",
            PROJECT_ROOT / "tests/visual/live_character_ui_8_6/capture.gd",
        )
        for path in paths:
            source = path.read_text(encoding="utf-8")
            mounts = list(re.finditer(r"root\.add_child\(app\)", source))
            self.assertTrue(mounts, relative(path) + " has no app mount")
            for mount in mounts:
                body, body_start = gdscript_function_region(source, mount.start())
                prefix = body[: mount.start() - body_start]
                with self.subTest(host=relative(path), mount=mount.start()):
                    self.assertIn(
                        "require_exact_capture_canvas()", prefix,
                        "production-data capture host can reflow before rejection",
                    )

    def test_exact_write_guard_detector_negative_controls(self) -> None:
        good = """func capture():
    var image = root.get_texture().get_image()
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if not exact_frame:
        return
    image.save_png(path)
"""
        good_write = good.find("save_png")
        assert_exact_guard_before(self, good, good_write)
        fixtures = {
            "failed_check": """func capture(image, path):
    check(image.get_size() == FIRST_PLAYABLE_SIZE, "exact")
    image.save_png(path)
""",
            "directory_first": """func run(image, path):
    DirAccess.make_dir_recursive_absolute(path)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
""",
            "queued_quit": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        quit(2)
    image.save_png(path)
""",
            "unrelated_return": """func capture(image, path, skip):
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if not exact_frame:
        check(false, "nonexact")
    if skip:
        return
    image.save_png(path)
""",
            "commented_return": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        push_error("nonexact") # must return here
    image.save_png(path)
""",
            "headless_bypass": """func run(image, path):
    if DisplayServer.get_name() != "headless":
        if image.get_size() != FIRST_PLAYABLE_SIZE:
            return
    DirAccess.make_dir_recursive_absolute(path)
""",
            "wrong_readback": """func capture(image, other_image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    other_image.save_png(path)
""",
            "nested_return": """func capture(image, path, stop):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        if stop:
            return
    image.save_png(path)
""",
        }
        for name, source in fixtures.items():
            token = "make_dir_recursive_absolute" if "directory" in name \
                or "headless" in name else "save_png"
            with self.subTest(negative=name), self.assertRaises(AssertionError):
                assert_exact_guard_before(self, source, source.find(token))

        cross_function = """func prior(image):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
static func capture(image, path):
    image.save_png(path)
"""
        write = cross_function.find("save_png")
        body, body_start = gdscript_function_region(cross_function, write)
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(self, body, write - body_start)

        replaced = """func capture(image, replacement, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
    image = replacement
    image.save_png(path)
"""
        second_write = replaced.rfind("save_png")
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(self, replaced, second_write)

    def test_python_retirement_guard_negative_controls(self) -> None:
        fixtures = {
            "conditional": """if False:
    raise SystemExit("DEFERRED_DISPLAY_SUITE")
import argparse
""",
            "comment": """# raise SystemExit("DEFERRED_DISPLAY_SUITE")
import argparse
""",
            "subprocess_first": """import subprocess
subprocess.run(command)
raise SystemExit("DEFERRED_DISPLAY_SUITE")
""",
            "directory_first": """from pathlib import Path
Path(path).mkdir()
raise SystemExit("DEFERRED_DISPLAY_SUITE")
""",
        }
        for name, source in fixtures.items():
            with self.subTest(negative=name), self.assertRaises(AssertionError):
                assert_unconditional_python_retirement(self, source)

    def test_exact_runner_gate_negative_controls(self) -> None:
        self.assertTrue(has_exact_output_gate("""const EXACT_SIZE := Vector2i(1920, 1080)
func run():
    root.size = EXACT_SIZE
"""))
        self.assertFalse(has_exact_output_gate("""# Vector2i(1920, 1080)
func run(dimensions):
    root.size = dimensions
"""))
        self.assertFalse(has_exact_output_gate("""const EXACT_SIZE := Vector2i(1920, 1080)
func run():
    root.size = Vector2i(1111, 777)
"""))


if __name__ == "__main__":
    unittest.main()
