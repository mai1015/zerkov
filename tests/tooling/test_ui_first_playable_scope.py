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
PREPROOF_READONLY_IMAGE_METHODS = frozenset({
    "get_size", "get_width", "get_height", "get_data", "get_pixel",
    "get_pixelv", "is_empty",
})
FRESH_PROOF_IMAGE_MUTATOR_METHODS = frozenset({
    "blend_rect", "blend_rect_mask", "blit_rect", "blit_rect_mask",
    "clear", "clear_mipmaps", "compress", "convert", "crop", "decompress",
    "fill", "fill_rect", "fix_alpha_edges", "generate_mipmaps",
    "normal_map_to_xy", "premultiply_alpha", "resize", "set_pixel",
    "set_pixelv", "shrink_x2", "sRGB_to_linear", "linear_to_sRGB",
})
POST_PROOF_READONLY_IMAGE_METHODS = PREPROOF_READONLY_IMAGE_METHODS | {
    "save_png",
}
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


def top_level_gdscript_statements(source: str) -> list[str]:
    """Return lexical top-level statements, including continued assignments."""
    statements: list[str] = []
    current: list[str] = []
    depth = 0
    continued = False
    for raw in gdscript_code(source).splitlines():
        stripped = raw.strip()
        if not stripped:
            continue
        indent = line_indent(raw)
        if not current:
            if indent != 0:
                continue
            current = [stripped]
        elif depth > 0 or continued:
            current.append(stripped)
        elif indent == 0:
            statements.append(" ".join(current))
            current = [stripped]
        else:
            continue
        depth += sum(stripped.count(character) for character in "([{")
        depth -= sum(stripped.count(character) for character in ")]}")
        continued = stripped.endswith("\\")
        if depth <= 0 and not continued:
            statements.append(" ".join(current))
            current = []
            depth = 0
    if current:
        statements.append(" ".join(current))
    return statements


def assert_no_top_level_gdscript_imports(
    testcase: unittest.TestCase, source: str,
) -> None:
    """Retired scripts cannot execute load/preload before `_initialize`."""
    for statement in top_level_gdscript_statements(source):
        if not re.match(
            r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+)?(?:const|var)\b",
            statement,
        ):
            continue
        testcase.assertIsNone(
            re.search(r"(?<![\w.])(?:preload|load)\s*\(", statement),
            "retired GDScript has a top-level import that executes before "
            "its _initialize guard",
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


def is_readonly_exact_proof(
    expression: str, image_receivers: frozenset[str],
    helpers: frozenset[str],
) -> bool:
    """Accept only inert reads while establishing a frame-size proof."""
    try:
        parsed = ast.parse(expression.replace("\\", " "), mode="eval").body
    except SyntaxError:
        return False

    def pure(node: ast.AST) -> bool:
        if isinstance(node, (ast.Name, ast.Constant)):
            return True
        if isinstance(node, ast.BoolOp):
            return all(pure(value) for value in node.values)
        if isinstance(node, ast.UnaryOp):
            return isinstance(node.op, (ast.Not, ast.UAdd, ast.USub)) \
                and pure(node.operand)
        if isinstance(node, ast.BinOp):
            return pure(node.left) and pure(node.right)
        if isinstance(node, ast.Compare):
            return pure(node.left) and all(
                pure(comparator) for comparator in node.comparators
            )
        if isinstance(node, ast.IfExp):
            return pure(node.test) and pure(node.body) and pure(node.orelse)
        if isinstance(node, ast.Attribute):
            # An Image member without an immediate allowlisted call is a
            # callable/property capture, not a read-only image observation.
            return not (
                isinstance(node.value, ast.Name)
                and node.value.id in image_receivers
            ) and pure(node.value)
        if not isinstance(node, ast.Call):
            return False
        if node.keywords:
            return False
        function = node.func
        if isinstance(function, ast.Name):
            if function.id in {"Vector2", "Vector2i"}:
                return all(pure(argument) for argument in node.args)
            if function.id == "get_viewport":
                return not node.args
            return function.id in helpers and len(node.args) == 1 \
                and isinstance(node.args[0], ast.Name) \
                and node.args[0].id in image_receivers
        if not isinstance(function, ast.Attribute):
            return False
        if function.attr in PREPROOF_READONLY_IMAGE_METHODS \
                and isinstance(function.value, ast.Name) \
                and function.value.id in image_receivers:
            return all(pure(argument) for argument in node.args)
        if function.attr == "get_visible_rect" and not node.args:
            return pure(function.value)
        return False

    return pure(parsed)


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
    direct_assignments = [
        (match.group("target"), direct_image_alias_name(match.group("value")))
        for match in assignment.finditer(logical_source)
    ]
    changed = True
    while changed:
        changed = False
        for target, value in direct_assignments:
            if not value:
                continue
            # The proof can name an alias rather than the original local. A
            # direct assignment connects the two in either direction: an
            # earlier escape of the source local is just as dangerous as an
            # escape of the later proven alias.
            if value in aliases and target not in aliases:
                aliases.add(target)
                changed = True
            if target in aliases and value not in aliases:
                aliases.add(value)
                changed = True
    return frozenset(aliases)


def direct_image_alias_name(expression: str) -> str:
    """Return a bare local image alias, never a computed expression."""
    direct_alias = re.compile(
        r"\(*[ \t]*(?P<name>[A-Za-z_]\w*)"
        r"(?:[ \t]+as[ \t]+[A-Za-z_]\w*)?[ \t]*\)*"
    )
    match = direct_alias.fullmatch(expression)
    return match.group("name") if match else ""


def has_preproof_image_escape(
    source: str, aliases: frozenset[str], helpers: frozenset[str],
) -> bool:
    """Reject retained pre-proof references outside a direct local alias.

    The only safe use before an exact-size proof is another direct local alias,
    an explicitly recognized read, or a known direct Image mutation that the
    following proof refreshes. Once the image reaches a container, property,
    index, callable, lambda, computed expression, or unknown method, lexical
    inspection can no longer prove it cannot be invoked or mutated after the
    proof. Treat that escape as permanent for the later write.
    """
    logical_source = re.sub(
        r"\\[ \t]*\r?\n[ \t]*", " ", gdscript_code(source)
    )
    lines = logical_source.splitlines()

    # Local lambdas retain their outer locals even though their bodies can run
    # after the textual proof.  Their use must therefore fail closed.
    for index, raw in enumerate(lines):
        code = strip_gdscript_comment(raw).strip()
        if not code or line_indent(raw) == 0 or not re.search(r"\bfunc\b", code):
            continue
        indent = line_indent(raw)
        lambda_region = [code]
        for nested in lines[index + 1:]:
            nested_code = strip_gdscript_comment(nested).strip()
            if nested_code and line_indent(nested) <= indent:
                break
            lambda_region.append(nested_code)
        lambda_source = "\n".join(lambda_region)
        if any(re.search(
            rf"(?<![\w.]){re.escape(alias)}\b", lambda_source
        ) for alias in aliases):
            return True

    local_assignment = re.compile(
        r"^\s*(?:var\s+)?(?P<target>[A-Za-z_]\w*)"
        r"(?:\s*:\s*(?![=])[^=]+?)?\s*(?::=|=(?!=))\s*"
        r"(?P<value>.*?)\s*$"
    )
    local_declaration = re.compile(
        r"^\s*(?:var\s+)?(?P<target>[A-Za-z_]\w*)"
        r"(?:\s*:\s*[^=]+)?\s*$"
    )
    top_level_function = re.compile(r"^(?:static\s+)?func\b")

    for raw in lines:
        code = strip_gdscript_comment(raw).strip()
        if not code or (line_indent(raw) == 0 and top_level_function.match(code)):
            continue
        for statement in code.split(";"):
            statement = statement.strip()
            if not statement:
                continue
            assignment = local_assignment.fullmatch(statement)
            declaration = local_declaration.fullmatch(statement)
            if assignment and direct_image_alias_name(
                assignment.group("value")
            ) in aliases:
                # The only pre-proof flow we can prove is a direct local name.
                continue
            ignored_target = ""
            ignored_start = -1
            if assignment:
                ignored_target = assignment.group("target")
                ignored_start = assignment.start("target")
            elif declaration:
                ignored_target = declaration.group("target")
                ignored_start = declaration.start("target")

            for alias in aliases:
                for occurrence in re.finditer(
                    rf"(?<![\w.]){re.escape(alias)}\b", statement
                ):
                    if alias == ignored_target and occurrence.start() == ignored_start:
                        # Declaring or replacing the direct local name does not
                        # itself retain the pre-proof image elsewhere.
                        continue
                    before = statement[:occurrence.start()]
                    tail = statement[occurrence.end():]
                    if re.match(r"\s*(?:==|!=)\s*null\b", tail) \
                            or re.search(r"\bnull\s*(?:==|!=)\s*$", before):
                        continue
                    method = re.match(
                        r"\s*\.\s*(?P<name>[A-Za-z_]\w*)\s*\(", tail
                    )
                    if method and method.group("name") in (
                        PREPROOF_READONLY_IMAGE_METHODS
                        | FRESH_PROOF_IMAGE_MUTATOR_METHODS
                    ):
                        continue
                    helper = re.search(r"\b(\w+)\(\s*$", before)
                    if helper and helper.group(1) in helpers \
                            and re.match(r"\s*\)", tail):
                        continue
                    return True
    return False


def gdscript_local_assignments(source: str) -> dict[str, str]:
    """Return the last simple-local initializer for each lexical name."""
    assignment = re.compile(
        r"^\s*(?:var\s+)?(?P<target>[A-Za-z_]\w*)"
        r"(?:\s*:\s*(?![=])[^=]+?)?\s*(?::=|=(?!=))\s*"
        r"(?P<value>.*?)\s*$"
    )
    logical_source = re.sub(
        r"\\[ \t]*\r?\n[ \t]*", " ", gdscript_code(source)
    )
    result: dict[str, str] = {}
    for raw in logical_source.splitlines():
        code = strip_gdscript_comment(raw).strip()
        if not code or (line_indent(raw) == 0 and re.match(
            r"^(?:static\s+)?func\b", code
        )):
            continue
        for statement in code.split(";"):
            match = assignment.fullmatch(statement.strip())
            if match:
                result[match.group("target")] = match.group("value")
    return result


def gdscript_function_parameters(source: str) -> dict[str, str]:
    """Return the first enclosing function's parameter names and annotations."""
    match = re.search(
        r"(?m)^(?:static\s+)?func\s+\w+\((?P<parameters>[^)]*)\)",
        gdscript_code(source),
    )
    if not match:
        return {}
    parameters: dict[str, str] = {}
    for raw_parameter in match.group("parameters").split(","):
        parameter = raw_parameter.strip()
        name = re.match(
            r"(?P<name>[A-Za-z_]\w*)(?:\s*:\s*(?P<type>[A-Za-z_]\w*))?",
            parameter,
        )
        if name:
            parameters[name.group("name")] = name.group("type") or ""
    return parameters


def is_fresh_image_expression(
    expression: str, fresh_helpers: frozenset[str],
    fresh_textures: frozenset[str],
) -> bool:
    """Recognize direct readback/allocation forms that create a fresh Image."""
    value = normalized_image_expression(expression)
    if re.fullmatch(
        r"Image\.(?:new|load_from_file|create_from_data)\s*\([^)]*\)", value
    ):
        return True
    if re.search(
        r"\.get_texture\s*\(\s*\)\s*\.get_image\s*\(\s*\)\s*$", value
    ):
        return True
    texture_readback = re.fullmatch(
        r"(?P<texture>[A-Za-z_]\w*)\.get_image\s*\(\s*\)", value
    )
    if texture_readback and texture_readback.group("texture") in fresh_textures:
        return True
    helper = re.fullmatch(r"(?P<helper>[A-Za-z_]\w*)\s*\(\s*\)", value)
    return bool(helper and helper.group("helper") in fresh_helpers)


def normalized_image_expression(expression: str) -> str:
    """Remove inert outer syntax before classifying an Image initializer."""
    value = re.sub(r"^\s*await\s+", "", expression.strip())

    def outer_parentheses(text: str) -> bool:
        if not (text.startswith("(") and text.endswith(")")):
            return False
        depth = 0
        for index, character in enumerate(text):
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            if depth == 0 and index != len(text) - 1:
                return False
            if depth < 0:
                return False
        return depth == 0

    while outer_parentheses(value):
        value = value[1:-1].strip()
    cast = re.fullmatch(
        r"(?P<value>.+?)\s+as\s+[A-Za-z_]\w*", value,
    )
    if cast:
        value = cast.group("value").strip()
        while outer_parentheses(value):
            value = value[1:-1].strip()
    return value


def fresh_image_helper_names(source: str) -> frozenset[str]:
    """Find no-argument helpers that return a directly fresh Image readback."""
    helpers: set[str] = set()
    for match in re.finditer(
        r"(?m)^(?:static\s+)?func\s+(?P<name>\w+)\(\s*\)\s*"
        r"->\s*Image\s*:",
        gdscript_code(source),
    ):
        body, _ = gdscript_function_region(source, match.start())
        returns = re.findall(r"(?m)^\s*return\s+(.+?)\s*$", gdscript_code(body))
        if len(returns) != 1:
            continue
        assignments = gdscript_local_assignments(body)
        value = returns[0]
        direct = direct_image_alias_name(value)
        if direct in assignments:
            value = assignments[direct]
        fresh_textures = frozenset(
            target for target, initializer in assignments.items()
            if re.search(r"\.get_texture\s*\(\s*\)\s*$", initializer)
        )
        if is_fresh_image_expression(value, frozenset(), fresh_textures):
            helpers.add(match.group("name"))
    return frozenset(helpers)


def tainted_image_origin_bases(
    source: str, receiver: str, fresh_helpers: frozenset[str],
) -> frozenset[str]:
    """Track owners that may still share a receiver acquired before proof."""
    assignments = gdscript_local_assignments(source)
    parameters = gdscript_function_parameters(source)
    fresh_textures = frozenset(
        target for target, initializer in assignments.items()
        if re.search(r"\.get_texture\s*\(\s*\)\s*$", initializer)
    )
    potential_parameters = {
        name for name, annotation in parameters.items()
        if annotation in {"", "Variant", "Image"}
    }
    resolving: set[str] = set()

    def expression_bases(expression: str) -> frozenset[str]:
        value = normalized_image_expression(expression)
        # An unqualified call has no inspectable owner and is potentially
        # shared unless it was recognized as a fresh helper above. Search the
        # complete normalized expression so parentheses/casts cannot conceal
        # a shared-returning call.
        if re.search(r"(?<![\w.])[A-Za-z_]\w*\s*\(", value):
            return frozenset({"*"})
        names = {
            name.group("name") for name in re.finditer(
                r"(?<![\w.])(?P<name>[A-Za-z_]\w*)\b", value
            ) if name.group("name") not in {
                "Image", "Vector2", "Vector2i", "null", "true", "false",
                "await", "as",
            }
        }
        return frozenset(names or {"*"})

    def resolve(name: str) -> frozenset[str]:
        if name in resolving:
            return frozenset({"*"})
        initializer = assignments.get(name)
        if initializer is None:
            if name in parameters:
                # A parameter can be aliased by another Image/Variant or
                # untyped parameter. The saved receiver itself is checked by
                # the ordinary post-proof receiver guard.
                return frozenset(potential_parameters - {receiver}) \
                    if name == receiver else frozenset({name})
            return frozenset({"*"})
        direct = direct_image_alias_name(initializer)
        if direct:
            resolving.add(name)
            result = resolve(direct)
            resolving.remove(name)
            return result
        if is_fresh_image_expression(initializer, fresh_helpers, fresh_textures):
            return frozenset()
        return expression_bases(initializer)

    return resolve(receiver)


def tainted_image_parameter_bases(
    source: str, receiver: str,
) -> frozenset[str]:
    """Return sibling parameters that can be the same direct Image object.

    A direct parameter (or a direct local alias of one) has no external
    container owner.  Its potentially shared sibling Image/Variant parameters
    may still be read through the narrow post-proof Image-method allowlist.
    Property, index and arbitrary-call origins intentionally return no safe
    bases: their owner is not known to be an Image and all later owner access
    must fail closed.
    """
    assignments = gdscript_local_assignments(source)
    parameters = gdscript_function_parameters(source)
    potential_parameters = {
        name for name, annotation in parameters.items()
        if annotation in {"", "Variant", "Image"}
    }
    resolving: set[str] = set()

    def resolve(name: str) -> frozenset[str]:
        if name in resolving:
            return frozenset()
        initializer = assignments.get(name)
        if initializer is None:
            return frozenset(potential_parameters - {receiver}) \
                if name in parameters else frozenset()
        direct = direct_image_alias_name(initializer)
        if not direct:
            return frozenset()
        resolving.add(name)
        result = resolve(direct)
        resolving.remove(name)
        return result

    return resolve(receiver)


def tainted_base_aliases(source: str, bases: frozenset[str]) -> frozenset[str]:
    """Follow direct locals so a shared base cannot be renamed after proof."""
    aliases = set(bases)
    assignments = gdscript_local_assignments(source)
    changed = True
    while changed:
        changed = False
        for target, initializer in assignments.items():
            direct = direct_image_alias_name(initializer)
            if direct in aliases and target not in aliases:
                aliases.add(target)
                changed = True
    return frozenset(aliases)


def has_postproof_tainted_base_use(
    prefix_source: str, postproof_source: str, bases: frozenset[str],
    direct_image_bases: frozenset[str],
) -> bool:
    """Reject post-proof access to an owner that can still mutate the image."""
    aliases = tainted_base_aliases(prefix_source, bases)
    logical_source = re.sub(
        r"\\[ \t]*\r?\n[ \t]*", " ", gdscript_code(postproof_source)
    )
    readonly = POST_PROOF_READONLY_IMAGE_METHODS
    for raw in logical_source.splitlines():
        code = strip_gdscript_comment(raw).strip()
        for statement in code.split(";"):
            statement = statement.strip()
            if not statement:
                continue
            # A complete direct non-mutating Image call is safe only for a
            # sibling direct-parameter Image. An owner of a property/index/
            # arbitrary-call result is not known to be an Image, so even a
            # similarly named method must remain forbidden.
            safe_call = re.fullmatch(
                r"(?:[A-Za-z_]\w*\.)?(?P<receiver>[A-Za-z_]\w*)\."
                r"(?P<method>\w+)\s*\(.*\)", statement
            )
            if safe_call and safe_call.group("receiver") in aliases \
                    and safe_call.group("receiver") in direct_image_bases \
                    and safe_call.group("method") in readonly:
                continue
            for alias in aliases:
                for occurrence in re.finditer(
                    rf"(?<![\w.]){re.escape(alias)}\b", statement
                ):
                    before = statement[:occurrence.start()]
                    tail = statement[occurrence.end():]
                    if re.match(r"\s*(?:==|!=)\s*null\b", tail) \
                            or re.search(r"\bnull\s*(?:==|!=)\s*$", before):
                        continue
                    method = re.match(
                        r"\s*\.\s*(?P<name>[A-Za-z_]\w*)\s*\(", tail
                    )
                    if method and alias in direct_image_bases \
                            and method.group("name") in readonly:
                        continue
                    return True
    return False


def assert_image_not_changed(
    testcase: unittest.TestCase, source: str, receivers: frozenset[str],
    helpers: frozenset[str],
) -> None:
    """Reject replacement, escape or mutation of a proven image before save."""
    # Strings cannot manufacture a method/alias occurrence, and comments cannot
    # hide one. This range contains only the proof and following write prefix.
    code = gdscript_code(source)
    readonly = POST_PROOF_READONLY_IMAGE_METHODS
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
    fresh_helpers: frozenset[str] = frozenset(),
) -> None:
    """Require a same-scope, receiver-specific, terminating exact-frame guard."""
    testcase.assertGreaterEqual(write_position, 0, "write token is missing")
    body = gdscript_code(body)
    line_start = body.rfind("\n", 0, write_position) + 1
    write_indent = line_indent(body[line_start:])
    save_match = next((match for match in re.finditer(
        r"(?<![\w.])(?P<receiver>[A-Za-z_]\w*)\."
        r"(?P<method>save_png)\s*\(", body
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
    proof_expression = ""
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
            proof_expression = condition
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
            proof_expression = expression
            break

    testcase.assertGreaterEqual(
        selected_guard,
        0,
        "write lacks a same-scope receiver-specific exact-frame rejection with return",
    )
    proof_offset = sum(len(chunk) for chunk in prefix_chunks[:proof_start])
    function_starts = [
        match.start() for match in re.finditer(
            r"(?m)^(?:static\s+)?func\s+", body
        ) if match.start() <= proof_offset
    ]
    preproof_source = body[max(function_starts, default=0):proof_offset]
    aliases = image_aliases_before(preproof_source, proven_receiver)
    tainted_bases = tainted_image_origin_bases(
        preproof_source, proven_receiver, fresh_helpers
    )
    direct_image_bases = tainted_image_parameter_bases(
        preproof_source, proven_receiver
    )
    testcase.assertNotIn(
        "*", tainted_bases,
        "saved Image has an unknown potentially shared initializer",
    )
    testcase.assertTrue(
        is_readonly_exact_proof(proof_expression, aliases, helpers),
        "exact-frame proof invokes a non-readonly call, callable, property "
        "or complex expression",
    )
    testcase.assertFalse(
        has_preproof_image_escape(preproof_source, aliases, helpers),
        "saved framebuffer or a pre-proof alias escapes into a container, "
        "property, index, callable, lambda or complex expression before "
        "the exact-frame proof",
    )
    postproof_before_write = body[proof_offset:write_match.start()]
    testcase.assertFalse(
        has_postproof_tainted_base_use(
            body[:write_match.start()], postproof_before_write, tainted_bases,
            direct_image_bases,
        ),
        "a shared Image origin is accessed after its proof and before the write",
    )
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
    testcase.assertIsNone(
        guard.cause if isinstance(guard, ast.Raise) else None,
        "retirement raise must not evaluate a cause",
    )
    testcase.assertEqual(
        len(exception.args) if isinstance(exception, ast.Call) else 0, 1,
        "retirement SystemExit must have exactly one inert marker argument",
    )
    testcase.assertFalse(
        exception.keywords if isinstance(exception, ast.Call) else (),
        "retirement SystemExit must not evaluate keyword arguments",
    )
    marker = exception.args[0] if isinstance(exception, ast.Call) \
        and len(exception.args) == 1 else None
    testcase.assertIsInstance(
        marker, ast.Constant,
        "retirement SystemExit marker must be a constant string",
    )
    marker_value = marker.value if isinstance(marker, ast.Constant) else None
    testcase.assertIs(
        type(marker_value), str,
        "retirement SystemExit marker must be an inert string literal",
    )
    testcase.assertIn(
        DEFERRED_MARKER, marker_value if type(marker_value) is str else "",
    )


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
                assert_no_top_level_gdscript_imports(self, source)
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

        top_level_preload = """extends SceneTree
const CONTENT = preload("res://retired.gd")
func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE")
    quit(2)
    return
"""
        continued_top_level_load = """extends SceneTree
var content = \\
    load("res://retired.gd")
func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE")
    quit(2)
    return
"""
        for source in (top_level_preload, continued_top_level_load):
            with self.assertRaises(AssertionError):
                assert_no_top_level_gdscript_imports(self, source)

        lazy_import = """extends SceneTree
var content: Script
func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE")
    quit(2)
    return
func run() -> void:
    content = load("res://retired.gd")
"""
        assert_no_top_level_gdscript_imports(self, lazy_import)

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
            fresh_helpers = fresh_image_helper_names(source)
            code = gdscript_code(source)
            with self.subTest(capture=relative_path):
                self.assertIn("save_png", source)
                for save in re.finditer(r"save_png\s*\(", code):
                    body, body_start = gdscript_function_region(source, save.start())
                    self.assertTrue(body, "save_png is outside a top-level function")
                    local_save = save.start() - body_start
                    assert_exact_guard_before(
                        self, body, local_save, helpers, fresh_helpers
                    )
                for mkdir in re.finditer(r"make_dir_recursive_absolute\s*\(", code):
                    body, body_start = gdscript_function_region(source, mkdir.start())
                    self.assertTrue(body, "directory creation is outside a top-level function")
                    local_mkdir = mkdir.start() - body_start
                    assert_exact_guard_before(
                        self, body, local_mkdir, helpers, fresh_helpers
                    )

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
            "qualified_receiver_with_decoy": """func capture(holder, image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.image.save_png(path)
""",
            "indexed_receiver_with_decoy": """func capture(holder, image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder[0].save_png(path)
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
            "side_effectful_guard_expression": """func capture(image, box, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE or mutate(box):
        return
    image.save_png(path)
""",
            "side_effectful_assigned_proof": """func capture(image, box, path):
    var exact_frame := image.get_size() == FIRST_PLAYABLE_SIZE and mutate(box)
    if not exact_frame:
        return
    image.save_png(path)
""",
            "mutating_guard_expression": """func capture(image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE or image.clear():
        return
    image.save_png(path)
""",
            "directory_prewrite_list_escape": """func run(image, path):
    var aliases := [image]
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    var extracted := aliases[0]
    extracted.resize(1920, 1080)
    DirAccess.make_dir_recursive_absolute(path)
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

        safe_direct_alias_chain = """func capture(image, path):
    var first: Image = image
    var second := (first as Image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    check(second.get_size() == FIRST_PLAYABLE_SIZE, "direct alias stays readable")
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, safe_direct_alias_chain,
            safe_direct_alias_chain.find("save_png"),
        )

        safe_preproof_readback = """func capture(image, path):
    var alias := image
    var observed_size := alias.get_size()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    check(observed_size == FIRST_PLAYABLE_SIZE, "direct alias read is inert")
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, safe_preproof_readback, safe_preproof_readback.find("save_png")
        )

        mutation_before_fresh_proof = """func capture(image, path):
    var alias := image
    alias.clear()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
"""
        assert_exact_guard_before(
            self, mutation_before_fresh_proof,
            mutation_before_fresh_proof.find("save_png"),
        )

        unrelated = """func capture(image, metadata: Dictionary, path):
    var details: Dictionary = metadata
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
            "list_capture_and_invocation": """func capture(image, path):
    var aliases := [image]
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    aliases[0].resize(1920, 1080)
    image.save_png(path)
""",
            "transitive_alias_list_extraction": """func capture(image, path):
    var direct := image
    var aliases := [direct]
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    var extracted := aliases[0]
    extracted.resize(1920, 1080)
    image.save_png(path)
""",
            "reverse_direct_alias_escape": """func capture(image, path):
    var saved := image
    var aliases := [image]
    if saved.get_size() != FIRST_PLAYABLE_SIZE:
        return
    aliases[0].clear()
    saved.save_png(path)
""",
            "dictionary_capture_and_invocation": """func capture(image, path):
    var aliases := {"frame": image}
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    aliases["frame"].resize(1920, 1080)
    image.save_png(path)
""",
            "nested_capture_and_invocation": """func capture(image, path):
    var aliases := [{"frames": [image]}]
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    aliases[0]["frames"][0].resize(1920, 1080)
    image.save_png(path)
""",
            "property_escape_and_invocation": """func capture(image, path):
    var holder := {}
    holder.frame = image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.frame.resize(1920, 1080)
    image.save_png(path)
""",
            "index_escape_and_invocation": """func capture(image, path):
    var holder := []
    holder.append(null)
    holder[0] = image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder[0].resize(1920, 1080)
    image.save_png(path)
""",
            "callable_capture_and_invocation": """func capture(image, path):
    var mutate_later := Callable(self, "_mutate_image").bind(image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    mutate_later.call()
    image.save_png(path)
""",
            "callable_receiver_capture_and_invocation": """func capture(image, path):
    var mutate_later := Callable(image, "clear")
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    mutate_later.call()
    image.save_png(path)
""",
            "bound_method_capture_and_invocation": """func capture(image, path):
    var mutate_later := image.clear
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    mutate_later.call()
    image.save_png(path)
""",
            "bound_callable_capture_and_invocation": """func capture(image, path):
    var mutate_later := mutate.bind(image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    mutate_later.call()
    image.save_png(path)
""",
            "constructor_capture_and_invocation": """func capture(image, path):
    var holder := Holder.new(image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.frame.resize(1920, 1080)
    image.save_png(path)
""",
            "lambda_capture_and_invocation": """func capture(image, path):
    var mutate_later := func() -> void:
        image.resize(1920, 1080)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    mutate_later.call()
    image.save_png(path)
""",
            "nested_lambda_capture_and_invocation": """func capture(image, path):
    var outer := func() -> Callable:
        return func() -> void:
            image.resize(1920, 1080)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    outer.call().call()
    image.save_png(path)
""",
            "return_escape": """func capture(image, path, stop):
    if stop:
        return image
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
""",
            "index_initializer_shared_origin": """func capture(box, path):
    var image := box[0]
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    box[0].clear()
    image.save_png(path)
""",
            "property_initializer_shared_origin": """func capture(holder, path):
    var image := holder.frame
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.mutate()
    image.save_png(path)
""",
            "shared_return_initializer": """func capture(holder, path):
    var image := holder.get_image()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.mutate()
    image.save_png(path)
""",
            "shared_return_owner_readback_name": """func capture(holder, path):
    var image := holder.get_image()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.get_size()
    image.save_png(path)
""",
            "unqualified_shared_return_initializer": """func capture(path):
    var image := shared_image()
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
""",
            "parenthesized_shared_return_initializer": """func capture(path):
    var image := (shared_image() as Image)
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    image.save_png(path)
""",
            "transitive_reverse_origin": """func capture(holder, path):
    var source := holder.frame
    var image := source
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    holder.mutate()
    image.save_png(path)
""",
            "parameter_shared_origin": """func capture(image: Image, other: Image, path):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    other.clear()
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

        qualified_decoys = """func capture(first, second, image, path_a, path_b):
    if image.get_size() != FIRST_PLAYABLE_SIZE:
        return
    first.image.save_png(path_a); second.image.save_png(path_b)
"""
        for save in re.finditer(r"save_png\s*\(", qualified_decoys):
            with self.assertRaises(AssertionError):
                assert_exact_guard_before(self, qualified_decoys, save.start())

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
        assert_unconditional_python_retirement(
            self, 'raise SystemExit("DEFERRED_DISPLAY_SUITE")\n'
        )
        assert_unconditional_python_retirement(
            self, 'raise SystemExit("DEFERRED_" "DISPLAY_SUITE")\n'
        )
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
            "extra_constant_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", "unexpected second argument"
)
""",
            "starred_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", *[open(path)]
)
""",
            "open_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", open(path).read()
)
""",
            "write_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", Path(path).write_text("unexpected")
)
""",
            "path_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", Path(path)
)
""",
            "subprocess_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", subprocess.run(command)
)
""",
            "comprehension_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", [open(path) for path in paths]
)
""",
            "set_comprehension_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", {open(path) for path in paths}
)
""",
            "dict_comprehension_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", {path: open(path) for path in paths}
)
""",
            "generator_comprehension_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", (open(path) for path in paths)
)
""",
            "f_string_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", f"unexpected {marker}"
)
""",
            "lambda_call_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", (lambda: open(path))()
)
""",
            "keyword_argument": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", code=open(path)
)
""",
            "double_star_keyword": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE", **{"code": open(path)}
)
""",
            "from_cause": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE"
) from open(path)
""",
            "from_none": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE"
) from None
""",
            "bytes_marker": """raise SystemExit(
    b"DEFERRED_DISPLAY_SUITE"
)
""",
            "computed_marker": """raise SystemExit(
    "DEFERRED_DISPLAY_SUITE" + suffix
)
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
