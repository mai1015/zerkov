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
DEFERRED_QA_PREFIX = "docs/qa/"
DEFERRED_PYTHON_GENERATORS = (
    "tests/visual/inventory_ui_binding/summarize.py",
    "tests/visual/render_scale/verify.py",
    "docs/qa/health_ability_content/implementation/run_validation.py",
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
        name.startswith(DEFERRED_QA_PREFIX)
        or name == "tests/responsive_smoke.gd"
        or name.startswith("tests/compact_")
        or name.startswith("tests/visual/inventory_ui_binding/")
        or name == "tests/visual/render_scale/capture.gd"
    )


def ui_gd_runners() -> list[Path]:
    candidates = sorted((PROJECT_ROOT / "tests").rglob("*.gd"))
    candidates += sorted((PROJECT_ROOT / "tools").rglob("*.gd"))
    # All retained packet scripts are retired, including nonvisual writers and
    # nested authoring history. Current runners belong under tests/ or tools/.
    candidates += sorted((PROJECT_ROOT / DEFERRED_QA_PREFIX).rglob("*.gd"))
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
        gdscript_code(source),
    )
    return source[match.start(1):match.end(1)] if match else ""


def gdscript_function_region(source: str, offset: int) -> tuple[str, int]:
    """Return a top-level ordinary/static function and its source offset."""
    starts = [
        match.start()
        for match in re.finditer(r"(?m)^(?:static\s+)?func\s+", gdscript_code(source))
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


def gdscript_code(source: str) -> str:
    """Mask comments and string literals, preserving offsets and indentation."""
    def mask(match: re.Match[str]) -> str:
        value = re.sub(r"[^\n]", " ", match.group())
        # A literal remains an inert expression; its contents cannot act as
        # a condition, function boundary, return, image method or assignment.
        return value if match.group().startswith("#") else "0" + value[1:]

    return re.sub(
        r'(?s)("""(?:\\.|(?!""").)*"""|'
        r"'''(?:\\.|(?!''').)*'''|"
        r'"(?:\\.|[^"\\])*"|'
        r"'(?:\\.|[^'\\])*'|#[^\n]*)",
        mask, source,
    )


def line_indent(line: str) -> int:
    prefix = line[: len(line) - len(line.lstrip(" \t"))]
    return len(prefix.expandtabs(4))


def exact_receivers_when(expression: str, truth: bool) -> set[str]:
    """Prove exactness from boolean structure, never a matching substring.

    The supported GDScript expressions share Python's boolean/comparison AST.
    Unknown syntax or leaves establish no proof. Conjunction/disjunction use
    implication: every possible branch must establish the same saved receiver.
    """
    try:
        parsed = ast.parse(expression.replace("\\", " "), mode="eval").body
    except SyntaxError:
        return set()

    def prove(node: ast.AST, value: bool) -> set[str]:
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return prove(node.operand, not value)
        if isinstance(node, ast.BoolOp):
            proofs = [prove(part, value) for part in node.values]
            all_parts_hold = isinstance(node.op, ast.And) == value
            return set.union(*proofs) if all_parts_hold else set.intersection(*proofs)
        if not isinstance(node, ast.Compare) or len(node.ops) != 1:
            return set()
        if not ((isinstance(node.ops[0], ast.Eq) and value)
                or (isinstance(node.ops[0], ast.NotEq) and not value)):
            return set()
        readback = node.left
        expected = node.comparators[0]
        if not (isinstance(readback, ast.Call) and not readback.args
                and not readback.keywords and isinstance(readback.func, ast.Attribute)
                and readback.func.attr == "get_size"
                and isinstance(readback.func.value, ast.Name)):
            return set()
        exact = isinstance(expected, ast.Name) and expected.id in {
            "FIRST_PLAYABLE_SIZE", "EXACT_SIZE", "DESKTOP_CANVAS"
        }
        if isinstance(expected, ast.Call) and isinstance(expected.func, ast.Name):
            exact = expected.func.id == "Vector2i" and not expected.keywords \
                and len(expected.args) == 2 and all(
                    isinstance(argument, ast.Constant) and type(argument.value) is int
                    and argument.value == dimension
                    for argument, dimension in zip(expected.args, (1920, 1080))
                )
        return {readback.func.value.id} if exact else set()

    return prove(parsed, truth)


def assignment_expression_before(
    lines: list[str], guard_index: int, indent: int, variable: str
) -> tuple[str, int, int]:
    """Return an unconditional same-block assignment and its line range."""
    assignment = re.compile(
        rf"\b(?:var\s+)?{re.escape(variable)}\s*(?::\s*\w+\s*)?"
        r"(?P<operator>:=|=(?!=)|[+*/%&|^-]=)\s*(?P<value>.*)$"
    )
    for index in range(guard_index - 1, -1, -1):
        code = strip_gdscript_comment(lines[index]).strip()
        if not code:
            continue
        if line_indent(lines[index]) < indent:
            break
        match = assignment.search(code)
        if not match:
            continue
        if match.start() != 0 or line_indent(lines[index]) != indent \
                or match.group("operator") not in {":=", "="}:
            return "", -1, -1
        pieces = [match.group("value")]
        last = index
        while pieces[-1].rstrip().endswith("\\") and last + 1 < guard_index:
            last += 1
            pieces.append(strip_gdscript_comment(lines[last]).strip())
        return " ".join(pieces), index, last
    return "", -1, -1


def readonly_image_helpers(source: str) -> frozenset[str]:
    """Recognize single-expression image checks without mutation or callbacks."""
    helpers: set[str] = set()
    for match in re.finditer(
        r"(?m)^(?:static\s+)?func\s+(?P<helper>\w+)\("
        r"(?P<receiver>\w+):\s*Image\)\s*->\s*bool:",
        gdscript_code(source),
    ):
        body, _ = gdscript_function_region(source, match.start())
        lines = [line.strip() for line in gdscript_code(body).splitlines()[1:]]
        lines = [line for line in lines if line]
        if len(lines) != 1 or not lines[0].startswith("return "):
            continue
        try:
            expression = ast.parse(lines[0][7:], mode="eval").body
        except SyntaxError:
            continue
        receiver = match.group("receiver")
        calls = [node for node in ast.walk(expression) if isinstance(node, ast.Call)]

        def is_receiver_size_readback(call: ast.Call) -> bool:
            function = call.func
            return (
                isinstance(function, ast.Attribute)
                and function.attr == "get_size"
                and isinstance(function.value, ast.Name)
                and function.value.id == receiver
                and not call.args
                and not call.keywords
            )

        def is_readonly_call(call: ast.Call) -> bool:
            function = call.func
            if isinstance(function, ast.Name):
                return function.id in {"Vector2", "Vector2i"}
            if not isinstance(function, ast.Attribute):
                return False
            if is_receiver_size_readback(call):
                return True
            return (
                function.attr == "get_visible_rect"
                and not call.args
                and not call.keywords
            )

        if any(is_receiver_size_readback(call) for call in calls) \
                and all(is_readonly_call(call) for call in calls):
            helpers.add(match.group("helper"))
    return frozenset(helpers)


def image_aliases_before(source: str, receiver: str) -> frozenset[str]:
    """Return simple local names that may alias receiver before its proof.

    Alias discovery is deliberately monotonic. Once a local is assigned from
    the saved image (or another known alias), a later use must be treated as a
    possible use of that image even if retained source also reassigns the name.
    """
    aliases = {receiver}
    logical_source = re.sub(
        r"\\[ \t]*\r?\n[ \t]*", " ", gdscript_code(source)
    )
    assignment = re.compile(
        r"(?m)(?:^|;)[ \t]*(?:var[ \t]+)?(?P<target>[A-Za-z_]\w*)"
        r"(?:[ \t]*:[ \t]*(?![=])[^=\n;]+)?[ \t]*(?::=|=(?!=))[ \t]*"
        r"(?P<value>[^;\n]+?)[ \t]*(?=;|$)"
    )
    direct_alias = re.compile(
        r"\(*[ \t]*(?P<name>[A-Za-z_]\w*)"
        r"(?:[ \t]+as[ \t]+[A-Za-z_]\w*)?[ \t]*\)*"
    )
    for match in assignment.finditer(logical_source):
        value = direct_alias.fullmatch(match.group("value"))
        if value and value.group("name") in aliases:
            aliases.add(match.group("target"))
    return frozenset(aliases)


def assert_image_not_changed(
    testcase: unittest.TestCase, source: str, receivers: frozenset[str],
    helpers: frozenset[str],
) -> None:
    """Reject replacement, escape or mutation of a proven image before save."""
    # Strings cannot manufacture a method/alias occurrence, and comments cannot
    # hide one. This range contains only the proof and following write prefix.
    code = gdscript_code(source)
    readonly = {
        "get_size", "get_width", "get_height", "get_data", "get_pixel",
        "get_pixelv", "is_empty", "save_png",
    }
    testcase.assertIsNone(re.search(r"\bawait\b", code),
                          "frame proof cannot cross an asynchronous boundary")
    for receiver in sorted(receivers):
        for occurrence in re.finditer(rf"\b{re.escape(receiver)}\b", code):
            tail = code[occurrence.end():]
            method = re.match(r"\.(\w+)\s*\(", tail)
            if method and method.group(1) in readonly:
                continue
            if re.match(r"\s*(?:!=|==)\s*null\b", tail):
                continue
            helper = re.search(r"\b(\w+)\(\s*$", code[:occurrence.start()])
            if helper and helper.group(1) in helpers and re.match(r"\s*\)", tail):
                continue
            testcase.fail(
                "saved framebuffer or a pre-proof alias is replaced, aliased "
                "or passed to an unproven image operation"
            )


def call_end(source: str, open_parenthesis: int) -> int:
    """Return the exclusive end of a call whose opening parenthesis is known."""
    depth = 0
    for index in range(open_parenthesis, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return -1


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
    helpers: frozenset[str] = frozenset(),
) -> None:
    """Require a same-scope, receiver-specific, terminating exact-frame guard."""
    testcase.assertGreaterEqual(write_position, 0, "write token is missing")
    body = gdscript_code(body)
    line_start = body.rfind("\n", 0, write_position) + 1
    write_indent = line_indent(body[line_start:])
    save_match = next((match for match in re.finditer(
        r"\b(?P<receiver>\w+)\.(?P<method>save_png)\s*\(", body
    ) if match.start("method") == write_position), None)
    mkdir_match = next((match for match in re.finditer(
        r"(?P<method>make_dir_recursive_absolute)\s*\(", body
    ) if match.start("method") == write_position), None)
    receiver = save_match.group(1) if save_match else None
    testcase.assertTrue(
        receiver is not None or mkdir_match is not None,
        "unsupported capture write shape",
    )
    write_match = save_match or mkdir_match
    testcase.assertIsNotNone(write_match)
    open_parenthesis = body.find("(", write_match.start("method")) \
        if write_match else -1
    write_end = call_end(body, open_parenthesis)
    testcase.assertGreater(write_end, write_position, "capture write call is incomplete")

    prefix_chunks = body[:line_start].splitlines(keepends=True)
    prefix_lines = [chunk.rstrip("\r\n") for chunk in prefix_chunks]
    selected_guard = -1
    proof_start = -1
    proven_receiver = ""
    for index in range(len(prefix_lines) - 1, -1, -1):
        raw = prefix_lines[index]
        code = strip_gdscript_comment(raw).strip()
        if not code:
            continue
        if line_indent(raw) < write_indent:
            break
        if line_indent(raw) != write_indent:
            continue
        guard = re.fullmatch(r"if\s+(.+):", code)
        if not guard or not direct_return_in_guard(prefix_lines, index, write_indent):
            continue
        condition = guard.group(1).strip()
        proved = exact_receivers_when(condition, False)
        if proved and (receiver is None or receiver in proved):
            selected_guard = index
            proof_start = index
            proven_receiver = receiver or sorted(proved)[0]
            break
        exact_name = re.fullmatch(r"not\s+\(?([A-Za-z_]\w*)\)?", condition)
        if not exact_name:
            continue
        expression, assignment_start, _ = assignment_expression_before(
            prefix_lines, index, write_indent, exact_name.group(1)
        )
        proved = exact_receivers_when(expression, True)
        if proved and (receiver is None or receiver in proved):
            selected_guard = index
            proof_start = assignment_start
            proven_receiver = receiver or sorted(proved)[0]
            break

    testcase.assertGreaterEqual(
        selected_guard,
        0,
        "write lacks a same-scope receiver-specific exact-frame rejection with return",
    )
    proof_offset = sum(len(chunk) for chunk in prefix_chunks[:proof_start])
    aliases = image_aliases_before(body[:proof_offset], proven_receiver)
    intervening = body[proof_offset:write_end]
    assert_image_not_changed(testcase, intervening, aliases, helpers)


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
    uncommented = gdscript_code(source)
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
            if name.startswith(DEFERRED_QA_PREFIX)
        )
        self.assertEqual(set(DEFERRED_PYTHON_GENERATORS), discovered)
        for relative_path in DEFERRED_PYTHON_GENERATORS:
            path = PROJECT_ROOT / relative_path
            source = path.read_text(encoding="utf-8")
            with self.subTest(generator=relative(path)):
                assert_unconditional_python_retirement(
                    self, source, relative_path
                )

    def test_all_historical_gd_packets_are_discovered(self) -> None:
        discovered = {relative(path) for path in ui_gd_runners()}
        archived = {name for name in tracked_names("*.gd")
                    if name.startswith(DEFERRED_QA_PREFIX)}
        self.assertTrue(archived)
        self.assertTrue(archived.issubset(discovered))
        self.assertTrue(all(is_deferred(PROJECT_ROOT / name) for name in archived))
        self.assertIn(
            "docs/qa/inventory_weapon_reload/astra_final/independent_capacity.gd",
            archived,
        )
        self.assertIn(
            "docs/qa/inventory_weapon_reload/astra_gate/magazine_probe.gd",
            archived,
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
            helpers = readonly_image_helpers(source)
            code = gdscript_code(source)
            with self.subTest(capture=relative_path):
                self.assertIn("save_png", source)
                for save in re.finditer(r"save_png\s*\(", code):
                    body, body_start = gdscript_function_region(source, save.start())
                    self.assertTrue(body, "save_png is outside a top-level function")
                    local_save = save.start() - body_start
                    assert_exact_guard_before(self, body, local_save, helpers)
                for mkdir in re.finditer(r"make_dir_recursive_absolute\s*\(", code):
                    body, body_start = gdscript_function_region(source, mkdir.start())
                    self.assertTrue(body, "directory creation is outside a top-level function")
                    local_mkdir = mkdir.start() - body_start
                    assert_exact_guard_before(self, body, local_mkdir, helpers)

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
            "sibling_branch_guard": """func capture(image, path, enforce, capture_now):
    if enforce:
        if image.get_size() != FIRST_PLAYABLE_SIZE:
            return
    if capture_now:
        image.save_png(path)
""",
            "sibling_branch_assignment": """func capture(image, path, enforce, capture_now):
    var exact_frame = true
    if enforce:
        exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if capture_now:
        if not exact_frame:
            return
        image.save_png(path)
""",
            "permissive_rejection": """func capture(image, path, enforce):
    if image.get_size() != FIRST_PLAYABLE_SIZE and enforce:
        return
    image.save_png(path)
""",
            "permissive_assignment": """func capture(image, path, allow_any):
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE or allow_any
    if not exact_frame:
        return
    image.save_png(path)
""",
            "quoted_proof": """func capture(image, path):
    var exact_frame = "image.get_size() == FIRST_PLAYABLE_SIZE"
    if not exact_frame:
        return
    image.save_png(path)
""",
            "multiline_string_guard": """func capture(image, path):
    var text = '''Retained pseudocode:
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    '''
    image.save_png(path)
""",
            "conditional_assignment": """func capture(image, path, allow_any):
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if allow_any:
        exact_frame = true
    if not exact_frame:
        return
    image.save_png(path)
""",
            "inline_conditional_assignment": """func capture(image, path, allow_any):
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE
    if allow_any: exact_frame = true
    if not exact_frame:
        return
    image.save_png(path)
""",
            "image_clear": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.clear()
    image.save_png(path)
""",
            "image_alias": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    var replacement = image
    replacement.clear()
    image.save_png(path)
""",
            "unproven_image_call": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    change_image(image)
    image.save_png(path)
""",
            "mutating_proof_conjunct": """func capture(image, path):
    var exact_frame = image.get_size() == FIRST_PLAYABLE_SIZE and change_image(image)
    if not exact_frame:
        return
    image.save_png(path)
""",
            "directory_image_clear": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.clear()
    DirAccess.make_dir_recursive_absolute(path)
""",
            "asynchronous_gap": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    await process_frame
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

    def test_pre_guard_aliases_cannot_change_the_proven_image(self) -> None:
        safe_readback = """func capture(image, path):
    var alias: Image = image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    check(alias.get_size() == FIRST_PLAYABLE_SIZE, "still exact")
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, safe_readback, safe_readback.find("save_png")
        )

        mutation_before_proof = """func capture(image, path):
    var alias := image
    alias.clear()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, mutation_before_proof, mutation_before_proof.find("save_png")
        )

        unrelated = """func capture(image, metadata, path):
    var details = metadata
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    details.clear()
    image.save_png(path)
"""
        assert_exact_guard_before(self, unrelated, unrelated.find("save_png"))

        mutation_after_save = """func capture(image, path):
    var alias := image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path); alias.clear()
"""
        assert_exact_guard_before(
            self, mutation_after_save, mutation_after_save.find("save_png")
        )

        rejected = {
            "direct_mutation": """func capture(image, path):
    var alias = image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    alias.clear()
    image.save_png(path)
""",
            "typed_chain_mutation": """func capture(image, path):
    var first: Image = image
    var second := first
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    second.resize(1920, 1080)
    image.save_png(path)
""",
            "alias_consuming_call": """func capture(image, path):
    var alias := image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    change_image(alias)
    image.save_png(path)
""",
            "continued_cast_alias": """func capture(image, path):
    var alias: Image = \\
        (image as Image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    change_image(alias)
    image.save_png(path)
""",
        }
        for name, source in rejected.items():
            with self.subTest(alias_case=name), self.assertRaises(AssertionError):
                assert_exact_guard_before(self, source, source.find("save_png"))

    def test_same_line_writes_bind_each_exact_call_receiver(self) -> None:
        first_only = """func capture(first, second, path_a, path_b):
    if first.get_size() != FIRST_PLAYABLE_SIZE:
        return
    first.save_png(path_a); second.save_png(path_b)
"""
        assert_exact_guard_before(self, first_only, first_only.find("save_png"))
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(self, first_only, first_only.rfind("save_png"))

        both_guarded = """func capture(first, second, path_a, path_b):
    if first.get_size() != FIRST_PLAYABLE_SIZE:
        return
    if second.get_size() != FIRST_PLAYABLE_SIZE:
        return
    first.save_png(path_a); second.save_png(path_b)
"""
        assert_exact_guard_before(
            self, both_guarded, both_guarded.find("save_png")
        )
        assert_exact_guard_before(
            self, both_guarded, both_guarded.rfind("save_png")
        )

        changed_between_writes = """func capture(image, path_a, path_b):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path_a); image.clear(); image.save_png(path_b)
"""
        assert_exact_guard_before(
            self, changed_between_writes, changed_between_writes.find("save_png")
        )
        with self.assertRaises(AssertionError):
            assert_exact_guard_before(
                self, changed_between_writes,
                changed_between_writes.rfind("save_png"),
            )

    def test_readonly_helper_requires_its_image_receiver_readback(self) -> None:
        helpers_source = """func exact(image: Image) -> bool:
    return image.get_size() == EXACT_SIZE
func exact_with_viewport(image: Image) -> bool:
    return root.get_visible_rect().size == Vector2(EXACT_SIZE) and image.get_size() == EXACT_SIZE
func foreign_argument(image: Image) -> bool:
    return attacker.get_size(image) == EXACT_SIZE
func foreign_receiver(image: Image) -> bool:
    return attacker.get_size() == EXACT_SIZE and image.get_size() == EXACT_SIZE
func argumented_receiver(image: Image) -> bool:
    return image.get_size(attacker) == EXACT_SIZE
func argumented_viewport(image: Image) -> bool:
    return root.get_visible_rect(image).size == Vector2(EXACT_SIZE) \
        and image.get_size() == EXACT_SIZE
"""
        helpers = readonly_image_helpers(helpers_source)
        self.assertEqual(helpers, {"exact", "exact_with_viewport"})

        safe_use = helpers_source + """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    exact_with_viewport(image)
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, safe_use, safe_use.find("save_png"),
            readonly_image_helpers(safe_use),
        )

        for helper in (
            "foreign_argument", "foreign_receiver", "argumented_receiver",
            "argumented_viewport",
        ):
            source = helpers_source + """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    %s(image)
    image.save_png(path)
""" % helper
            with self.subTest(helper=helper), self.assertRaises(AssertionError):
                assert_exact_guard_before(
                    self, source, source.find("save_png"),
                    readonly_image_helpers(source),
                )

    def test_boolean_proof_accepts_only_necessary_exact_comparisons(self) -> None:
        for condition in (
            "image.get_size() != FIRST_PLAYABLE_SIZE or stop",
            "not (image.get_size() == FIRST_PLAYABLE_SIZE and ready)",
            "not ((image.get_size() == FIRST_PLAYABLE_SIZE and ready) "
            "or (image.get_size() == FIRST_PLAYABLE_SIZE and fallback))",
        ):
            source = "func capture(image, path):\n    if " + condition \
                + ":\n        return\n    image.save_png(path)\n"
            with self.subTest(condition=condition):
                assert_exact_guard_before(self, source, source.find("save_png"))

        helper_source = """func valid(image: Image) -> bool:
    return image.get_size() == EXACT_SIZE
func mutating(image: Image) -> bool:
    return image.clear() == null
"""
        self.assertEqual(readonly_image_helpers(helper_source), {"valid"})

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
