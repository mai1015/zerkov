#!/usr/bin/env python3
"""Bounded repository gate for Zerkov's current exact-1080 acceptance path.

This checker validates reviewed files, literal launch/output operations, and
fail-first retirement stubs. It intentionally is not a GDScript evaluator or a
proof against arbitrary hostile program semantics.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT_ROOT / "config/first_playable_1080_gate.json"
DEFERRED_MARKER = "DEFERRED_DISPLAY_SUITE"
EXACT_SIZE = (1920, 1080)
WORLD_SIZE = (640, 360)

VECTOR_CONSTANT = re.compile(
    r"(?m)^\s*const\s+(?P<name>[A-Za-z_]\w*)(?:\s*:\s*[^=]+)?\s*(?::=|=)\s*"
    r"Vector2i\(\s*(?P<width>\d+)\s*,\s*(?P<height>\d+)\s*\)"
)
OUTPUT_ASSIGNMENT = re.compile(
    r"(?m)(?P<receiver>[A-Za-z_]\w*|get_window\(\)|get_root\(\)|"
    r"get_tree\(\)\.root)\.(?P<property>size|content_scale_size)\s*=\s*"
    r"(?P<value>Vector2i\(\s*\d+\s*,\s*\d+\s*\)|"
    r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)"
)
VECTOR_LITERAL = re.compile(r"Vector2i\(\s*(\d+)\s*,\s*(\d+)\s*\)")
RESOLUTION_LITERAL = re.compile(
    r"--resolution(?:\s*=\s*|[\"']\s*,\s*[\"'])(\d+)x(\d+)"
)
WINDOW_SIZE_CALL = re.compile(
    r"DisplayServer\.window_set_size\(\s*"
    r"(?P<value>Vector2i\(\s*\d+\s*,\s*\d+\s*\)|[A-Za-z_]\w*)"
)
VIEWPORT_SIZE_CALL = re.compile(
    r"RenderingServer\.viewport_set_size\([^,]+,\s*(\d+)\s*,\s*(\d+)\s*\)"
)
VIEWPORT_ATTACH_CALL = re.compile(
    r"RenderingServer\.viewport_attach_to_screen\([^,]+,\s*"
    r"Rect2i?\([^,]+,\s*[^,]+,\s*(\d+)\s*,\s*(\d+)\s*\)"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest(path: Path = DEFAULT_MANIFEST) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def repository_paths(root: Path) -> List[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return sorted(name for name in result.stdout.split("\0") if name)


def _read(root: Path, name: str) -> str:
    return (root / name).read_text(encoding="utf-8")


def gdscript_literal_tokens(source: str) -> Tuple[str, List[str]]:
    """Mask comments and replace each real string with a numbered token."""
    result: List[str] = []
    literals: List[str] = []
    index = 0
    while index < len(source):
        if source[index] == "#":
            while index < len(source) and source[index] != "\n":
                result.append(" ")
                index += 1
            continue
        if source[index] in ("'", '"'):
            character = source[index]
            quote = character * 3 \
                if source.startswith(character * 3, index) else character
            cursor = index + len(quote)
            escaped = False
            while cursor < len(source):
                if escaped:
                    escaped = False
                    cursor += 1
                    continue
                if source[cursor] == "\\":
                    escaped = True
                    cursor += 1
                    continue
                if source.startswith(quote, cursor):
                    break
                cursor += 1
            value = source[index + len(quote):cursor]
            token = "__ZERKOV_GDSTRING_%d__" % len(literals)
            literals.append(value)
            result.append(token)
            result.append("\n" * value.count("\n"))
            index = min(len(source), cursor + len(quote))
            continue
        result.append(source[index])
        index += 1
    return "".join(result), literals


def _mapping_paths(manifest: Dict[str, Any], key: str) -> Set[str]:
    value = manifest.get(key, {})
    return set(value) if isinstance(value, dict) else set()


def _retired_paths(manifest: Dict[str, Any], key: str, language: str) -> Set[str]:
    section = manifest.get(key, {})
    values = section.get(language, []) if isinstance(section, dict) else []
    return set(values) if isinstance(values, list) else set()


def discover_gdscript_entrypoints(root: Path, names: Sequence[str]) -> Set[str]:
    discovered: Set[str] = set()
    for name in names:
        if not name.endswith(".gd"):
            continue
        if not (name.startswith("tests/") or name.startswith("tools/")
                or name.startswith("docs/qa/")):
            continue
        source, literals = gdscript_literal_tokens(_read(root, name))
        inherited = any(
            literals[int(match.group(1))].endswith(".gd")
            for match in re.finditer(
                r"(?m)^\s*extends\s+__ZERKOV_GDSTRING_(\d+)__\s*$", source
            )
        )
        if (re.search(r"(?m)^\s*extends\s+SceneTree\s*$", source)
                or inherited
                or name.startswith("tests/visual/")
                or name.startswith("docs/qa/")):
            discovered.add(name)
    return discovered


def discover_python_display_drivers(root: Path, names: Sequence[str]) -> Set[str]:
    discovered: Set[str] = set()
    for name in names:
        if not name.endswith(".py"):
            continue
        if (name.startswith("docs/qa/") or name.startswith("tests/visual/")
                or (name.startswith("tests/tooling/run_") and name.endswith("_gate.py"))):
            discovered.add(name)
    return discovered


def _hash_entries(manifest: Dict[str, Any]) -> Dict[str, Dict[str, str]]:
    entries: Dict[str, Dict[str, str]] = {}
    for key in ("active_visual_entrypoints", "active_command_entrypoints",
                "active_reviewed_support"):
        section = manifest.get(key, {})
        if isinstance(section, dict):
            entries.update(section)
    return entries


def hash_issues(manifest: Dict[str, Any], root: Path) -> List[str]:
    issues: List[str] = []
    for name, record in sorted(_hash_entries(manifest).items()):
        path = root / name
        if not path.is_file():
            issues.append("missing reviewed file: " + name)
            continue
        expected = record.get("sha256", "") if isinstance(record, dict) else ""
        actual = sha256(path)
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            issues.append("invalid reviewed sha256: " + name)
        elif actual != expected:
            issues.append("reviewed file hash mismatch: " + name)
    return issues


def classification_issues(
    manifest: Dict[str, Any], root: Path, names: Sequence[str]
) -> List[str]:
    issues: List[str] = []
    active_visual = _mapping_paths(manifest, "active_visual_entrypoints")
    headless = set(manifest.get("active_headless_entrypoints", []))
    support = {
        name for name, record in manifest.get("active_reviewed_support", {}).items()
        if isinstance(record, dict) and record.get("runner_inventory", False)
    }
    retired_only_gd = _retired_paths(
        manifest, "retired_display_entrypoints", "gdscript")
    historical_gd = _retired_paths(
        manifest, "historical_evidence_entrypoints", "gdscript")
    for name in sorted(retired_only_gd & historical_gd):
        issues.append("GDScript entrypoint is both retired and historical: " + name)
    gd_categories = [
        active_visual, headless, support, retired_only_gd, historical_gd,
    ]
    declared_gd = set().union(*gd_categories)
    discovered_gd = discover_gdscript_entrypoints(root, names)
    for name in sorted(discovered_gd - declared_gd):
        issues.append("unclassified GDScript entrypoint: " + name)
    for name in sorted(declared_gd - discovered_gd):
        issues.append("declared GDScript entrypoint was not independently discovered: " + name)
    seen: Set[str] = set()
    for category in gd_categories:
        for name in sorted(category):
            if name in seen:
                issues.append("GDScript entrypoint has multiple classifications: " + name)
            seen.add(name)

    active_commands = _mapping_paths(manifest, "active_command_entrypoints")
    retired_only_py = _retired_paths(manifest, "retired_display_entrypoints", "python")
    historical_py = _retired_paths(manifest, "historical_evidence_entrypoints", "python")
    for name in sorted(retired_only_py & historical_py):
        issues.append("Python driver is both retired and historical: " + name)
    discovered_py = discover_python_display_drivers(root, names)
    py_categories = [active_commands, retired_only_py, historical_py]
    declared_py = set().union(*py_categories)
    for name in sorted(discovered_py - declared_py):
        issues.append("unclassified Python display driver: " + name)
    for name in sorted(declared_py - discovered_py):
        issues.append("declared Python driver was not independently discovered: " + name)
    seen = set()
    for category in py_categories:
        for name in sorted(category):
            if name in seen:
                issues.append("Python driver has multiple classifications: " + name)
            seen.add(name)

    for name in sorted(active_visual):
        if DEFERRED_MARKER in _read(root, name):
            issues.append("active visual entrypoint contains the retirement marker: " + name)
    for name in sorted(headless):
        source = _read(root, name)
        if DEFERRED_MARKER in source or re.search(r"\bsave_png\s*\(", source):
            issues.append("headless entrypoint is not structurally headless: " + name)
    for name in sorted(support):
        source = _read(root, name)
        if re.search(r"(?m)^func\s+_initialize\s*\(", source):
            issues.append("non-entrypoint support defines _initialize: " + name)

    fixture_files = set(manifest.get("non_executable_fixture_files", []))
    discovered_fixtures = {name for name in names if name.endswith(".source_only")}
    if fixture_files != discovered_fixtures:
        for name in sorted(discovered_fixtures - fixture_files):
            issues.append("unclassified source-only fixture: " + name)
        for name in sorted(fixture_files - discovered_fixtures):
            issues.append("declared source-only fixture is absent: " + name)
    return issues


def gdscript_code(source: str) -> str:
    """Mask comments and strings; this is lexical filtering, not evaluation."""
    literal = re.compile(
        r"(?s)(\"\"\"(?:\\.|(?!\"\"\").)*\"\"\"|"
        r"'''(?:\\.|(?!''').)*'''|\"(?:\\.|[^\"\\])*\"|"
        r"'(?:\\.|[^'\\])*'|#[^\n]*)"
    )
    return literal.sub(lambda match: re.sub(r"[^\n]", " ", match.group()), source)


def _vector_value(
    value: str, constants: Dict[str, Tuple[int, int]], external_exact: Set[str]
) -> Optional[Tuple[int, int]]:
    literal = VECTOR_LITERAL.fullmatch(value.strip())
    if literal:
        return int(literal.group(1)), int(literal.group(2))
    if value in constants:
        return constants[value]
    if value in external_exact:
        return EXACT_SIZE
    return None


def output_operation_issues(
    source: str, name: str, manifest: Dict[str, Any]
) -> List[str]:
    code = gdscript_code(source)
    constants = {
        match.group("name"): (int(match.group("width")), int(match.group("height")))
        for match in VECTOR_CONSTANT.finditer(code)
    }
    external_exact = set(manifest.get("external_exact_size_symbols", []))
    output_receivers = {
        "root", "window", "viewport", "output_target", "render_target",
        "production_render_target", "target",
    }
    aliases = re.finditer(
        r"(?m)^\s*var\s+([A-Za-z_]\w*)[^=\n]*:?=\s*(?:SubViewport|Window)\.new\(\)|"
        r"^\s*var\s+([A-Za-z_]\w*)[^=\n]*:?=\s*(?:root|get_window\(\)|"
        r"get_root\(\)|get_tree\(\)\.root)",
        code,
    )
    for alias in aliases:
        output_receivers.add(alias.group(1) or alias.group(2))
    exceptions = set(manifest.get("allowed_dynamic_output_assignments", {}).get(name, []))
    world_binding = manifest.get("world_surface", {}).get("assignment", {})
    issues: List[str] = []
    for match in OUTPUT_ASSIGNMENT.finditer(code):
        receiver = match.group("receiver")
        if receiver not in output_receivers and not receiver.startswith("get_"):
            continue
        statement = re.sub(r"\s+", " ", match.group().strip())
        if statement in exceptions:
            continue
        value = match.group("value")
        resolved = _vector_value(value, constants, external_exact)
        if (name == world_binding.get("path") and receiver == world_binding.get("receiver")
                and match.group("property") == world_binding.get("property")
                and value == world_binding.get("value") and resolved is None):
            continue
        if resolved != EXACT_SIZE:
            issues.append("forbidden or unreviewed output assignment in %s: %s" % (name, statement))
    for match in WINDOW_SIZE_CALL.finditer(code):
        resolved = _vector_value(match.group("value"), constants, external_exact)
        if resolved != EXACT_SIZE:
            issues.append("forbidden window_set_size in " + name)
    for pattern, label in ((VIEWPORT_SIZE_CALL, "viewport_set_size"),
                           (VIEWPORT_ATTACH_CALL, "viewport_attach_to_screen")):
        for match in pattern.finditer(code):
            if (int(match.group(1)), int(match.group(2))) != EXACT_SIZE:
                issues.append("forbidden %s in %s" % (label, name))
    return issues


def command_literal_issues(source: str, name: str) -> List[str]:
    values = [(int(match.group(1)), int(match.group(2)))
              for match in RESOLUTION_LITERAL.finditer(source)]
    issues = ["forbidden --resolution literal in %s: %dx%d" % ((name,) + value)
              for value in values if value != EXACT_SIZE]
    if not values or EXACT_SIZE not in values:
        issues.append("active Godot driver lacks literal --resolution 1920x1080: " + name)
    return issues


def _gdscript_initialize_statements(source: str) -> List[str]:
    match = re.search(
        r"(?ms)^func\s+_initialize\([^\n]*\)[^:]*:\s*\n"
        r"(?P<body>.*?)(?=^(?:static\s+)?func\s+|\Z)", source
    )
    if not match:
        return []
    statements: List[str] = []
    for line in match.group("body").splitlines():
        code = line.split("#", 1)[0].strip()
        if code:
            statements.append(code)
    return statements


def gdscript_retirement_issues(source: str, name: str) -> List[str]:
    statements = _gdscript_initialize_statements(source)
    issues: List[str] = []
    if len(statements) < 3 or not statements[0].startswith("push_error(") \
            or DEFERRED_MARKER not in statements[0] \
            or not re.fullmatch(r"quit\(\s*2\s*\)", statements[1]) \
            or statements[2] != "return":
        issues.append("retired GDScript does not fail first: " + name)
    prefix = source[:source.find("func _initialize")] if "func _initialize" in source else source
    if re.search(r"(?m)^\s*(?:const|var)\b[^\n]*(?:preload|load)\s*\(", prefix):
        issues.append("retired GDScript imports before its guard: " + name)
    return issues


def python_retirement_issues(source: str, name: str) -> List[str]:
    try:
        tree = ast.parse(source, filename=name)
    except SyntaxError:
        return ["retired Python driver does not parse: " + name]
    body = list(tree.body)
    if body and isinstance(body[0], ast.Expr) \
            and isinstance(getattr(body[0], "value", None), ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]
    if body and isinstance(body[0], ast.ImportFrom) \
            and body[0].module == "__future__":
        body = body[1:]
    if not body or not isinstance(body[0], ast.Raise):
        return ["retired Python driver does not fail first: " + name]
    exc = body[0].exc
    if not isinstance(exc, ast.Call) or exc.keywords or len(exc.args) != 1:
        return ["retired Python driver has a nonliteral first exit: " + name]
    function = exc.func
    argument = exc.args[0]
    value = getattr(argument, "value", None)
    if not isinstance(function, ast.Name) or function.id != "SystemExit" \
            or not isinstance(value, str) or not value.startswith(DEFERRED_MARKER):
        return ["retired Python driver has a nonliteral first exit: " + name]
    return []


def project_config_issues(source: str, manifest: Dict[str, Any]) -> List[str]:
    issues: List[str] = []
    expected = manifest.get("project_config", {})
    for key, value in sorted(expected.items()):
        match = re.search(r"(?m)^" + re.escape(key) + r"\s*=\s*([^\n]+)$", source)
        if not match or match.group(1).strip() != str(value):
            issues.append("project.godot exact-output mismatch: %s=%s" % (key, value))
    return issues


def _normalized_reference(owner: str, value: str) -> Optional[str]:
    """Resolve one literal GDScript-style resource reference."""
    normalized_value = value.replace("\\", "/")
    if normalized_value.startswith("res://"):
        candidate = normalized_value[len("res://"):]
    elif normalized_value.startswith(("uid://", "user://", "/")):
        return None
    else:
        candidate = posixpath.join(posixpath.dirname(owner), normalized_value)
    candidate = posixpath.normpath(candidate)
    if candidate in ("", ".", "..") or candidate.startswith("../"):
        return None
    return candidate


def _gdscript_literal_reference_groups(source: str) -> Tuple[Set[str], Set[str]]:
    """Return resource literals and project-relative command literals separately."""
    clean, literals = gdscript_literal_tokens(source)
    resources: Set[str] = set()
    commands: Set[str] = set()
    patterns = (
        re.compile(
            r"(?m)^\s*extends\s+__ZERKOV_GDSTRING_(?P<index>\d+)__\s*$"
        ),
        re.compile(
            r"(?m)\b(?:load|preload)\s*\(\s*"
            r"__ZERKOV_GDSTRING_(?P<index>\d+)__\s*\)"
        ),
    )
    for pattern in patterns:
        resources.update(
            literals[int(match.group("index"))] for match in pattern.finditer(clean)
        )

    command_call = re.compile(
        r"\bOS\.(?:execute|execute_with_pipe|create_process)\s*\("
    )
    token = re.compile(r"__ZERKOV_GDSTRING_(\d+)__")
    for call in command_call.finditer(clean):
        opening = clean.find("(", call.start())
        depth = 0
        closing = -1
        for index in range(opening, len(clean)):
            if clean[index] == "(":
                depth += 1
            elif clean[index] == ")":
                depth -= 1
                if depth == 0:
                    closing = index
                    break
        if closing < 0:
            continue
        indices = [int(match.group(1))
                   for match in token.finditer(clean[opening:closing + 1])]
        for position, literal_index in enumerate(indices):
            value = literals[literal_index]
            if value.startswith("--script="):
                commands.add(value[len("--script="):])
            elif value == "--script" and position + 1 < len(indices):
                commands.add(literals[indices[position + 1]])
    return resources, commands


def _gdscript_literal_references(source: str) -> Set[str]:
    """Return all real literal resource and direct Godot-script command edges."""
    resources, commands = _gdscript_literal_reference_groups(source)
    return resources | commands


def _config_literal_references(source: str) -> Set[str]:
    """Return script-like quoted config values, with INI comments removed."""
    references: Set[str] = set()
    for raw_line in source.splitlines():
        quote = ""
        escaped = False
        end = len(raw_line)
        for index, character in enumerate(raw_line):
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
            elif character in (";", "#"):
                end = index
                break
        line = raw_line[:end]
        if "=" not in line:
            continue
        for match in re.finditer(r'''(["'])(?P<value>(?:\\.|(?!\1).)*)\1''', line):
            value = match.group("value")
            if value.startswith("*"):
                value = value[1:]
            if value.startswith("res://") or value.endswith((".gd", ".py")):
                references.add(value)
    return references


def _python_literal_references(source: str, name: str) -> Set[str]:
    """Return literal script-like strings; no command evaluation is attempted."""
    try:
        tree = ast.parse(source, filename=name)
    except SyntaxError:
        return set()
    references: Set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
            continue
        value = node.value.replace("\\", "/")
        if value.startswith("res://") or value.endswith((".gd", ".py")):
            references.add(value)
    return references


def _current_literal_references(source: str, name: str) -> Set[str]:
    if name.endswith(".gd"):
        values, command_values = _gdscript_literal_reference_groups(source)
    elif name.endswith(".py"):
        values = _python_literal_references(source, name)
        command_values = set()
    else:
        values = _config_literal_references(source)
        command_values = set()
    result: Set[str] = set()
    for value in values:
        normalized = _normalized_reference(name, value)
        if normalized is not None:
            result.add(normalized)
        # Python launchers commonly spell repository-root-relative script
        # paths. Consider that exact literal too, without evaluating code.
        if name.endswith(".py") and not value.startswith(("res://", "../", "./")):
            root_relative = posixpath.normpath(value)
            if root_relative not in ("", ".", "..") \
                    and not root_relative.startswith("../"):
                result.add(root_relative)
    # Direct Godot `--script` arguments are resolved from the command's project
    # working directory, not from the directory containing the GDScript owner.
    for value in command_values:
        normalized_value = value.replace("\\", "/")
        if normalized_value.startswith("res://"):
            normalized_value = normalized_value[len("res://"):]
        elif normalized_value.startswith(("uid://", "user://", "/")):
            continue
        project_relative = posixpath.normpath(normalized_value)
        if project_relative not in ("", ".", "..") \
                and not project_relative.startswith("../"):
            result.add(project_relative)
    return result


def _guarded_png_write_issues(
    source: str, name: str, expected_call: str
) -> List[str]:
    """Require one fail-closed exact-output guard immediately before each save."""
    code = gdscript_code(source)
    lines = code.splitlines()
    compact_expected = re.sub(r"\s+", "", expected_call)
    issues: List[str] = []
    line_starts = [0]
    line_starts.extend(match.end() for match in re.finditer("\n", code))
    expected_image = re.fullmatch(
        r"Exact1080CaptureGuard\.accepts\([^,]+,[^,]+,"
        r"(?P<image>[A-Za-z_]\w*)\)", compact_expected,
    )
    if expected_image is None:
        return ["PNG writer has an invalid physical guard declaration: " + name]
    guarded_image = expected_image.group("image")
    for save_index, save_line in enumerate(lines):
        generic_calls = list(re.finditer(r"\bsave_png\s*\(", save_line))
        save_calls = list(re.finditer(
            r"(?P<image>[A-Za-z_]\w*)\s*\.\s*save_png\s*\(", save_line
        ))
        if len(save_calls) != len(generic_calls):
            issues.append("PNG write must use a direct image receiver in %s:%d"
                          % (name, save_index + 1))
        for save_call in save_calls:
            saved_image = save_call.group("image")
            prefix = save_line[:save_call.start()]
            allowed_prefix = (
                not prefix.strip()
                or re.fullmatch(
                    r"\s*var\s+[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*"
                    r"(?::=|=)\s*", prefix,
                ) is not None
                or re.fullmatch(r"\s*check\s*\(\s*", prefix) is not None
            )
            if not allowed_prefix:
                issues.append("PNG write has same-line work before save in %s:%d"
                              % (name, save_index + 1))
            if saved_image != guarded_image:
                issues.append("PNG write saves a different image than its guard in %s:%d"
                              % (name, save_index + 1))

            opening = line_starts[save_index] + save_call.end() - 1
            depth = 0
            closing = -1
            for index in range(opening, len(code)):
                if code[index] == "(":
                    depth += 1
                elif code[index] == ")":
                    depth -= 1
                    if depth == 0:
                        closing = index
                        break
            if closing < 0:
                issues.append("PNG write has an incomplete direct call in %s:%d"
                              % (name, save_index + 1))
            elif re.search(r"\bawait\b", code[opening:closing + 1]):
                issues.append("PNG write yields while evaluating its call in %s:%d"
                              % (name, save_index + 1))

            save_indent = len(save_line) - len(save_line.lstrip())
            guard_index: Optional[int] = None
            for index in range(save_index - 1, max(-1, save_index - 12), -1):
                compact = re.sub(r"\s+", "", lines[index])
                if compact == "ifnot%s:" % compact_expected:
                    guard_index = index
                    break
            if guard_index is None:
                issues.append("PNG write lacks the reviewed exact-output guard in %s:%d"
                              % (name, save_index + 1))
                continue
            guard_line = lines[guard_index]
            guard_indent = len(guard_line) - len(guard_line.lstrip())
            if save_indent != guard_indent:
                issues.append("PNG write is not the guarded success path in %s:%d"
                              % (name, save_index + 1))
                continue
            branch: List[Tuple[int, str]] = []
            first_dedent = save_index
            for index in range(guard_index + 1, save_index):
                line = lines[index]
                if not line.strip():
                    continue
                indent = len(line) - len(line.lstrip())
                if indent <= guard_indent:
                    first_dedent = index
                    break
                branch.append((indent, line.strip()))
            if first_dedent != save_index:
                issues.append("PNG write is not immediately after its guard in %s:%d"
                              % (name, save_index + 1))
                continue
            branch_indent = min((indent for indent, _line in branch), default=-1)
            if not any(indent == branch_indent and re.match(r"return(?:\s|$)", line)
                       for indent, line in branch):
                issues.append("PNG guard does not fail closed in %s:%d"
                              % (name, save_index + 1))
            if any(re.search(r"\bawait\b", line) for _indent, line in branch):
                issues.append("PNG guard yields before its write in %s:%d"
                              % (name, save_index + 1))
    return issues


def capture_issues(manifest: Dict[str, Any], root: Path, names: Sequence[str]) -> List[str]:
    retired = _retired_paths(manifest, "retired_display_entrypoints", "gdscript")
    retired |= _retired_paths(manifest, "historical_evidence_entrypoints", "gdscript")
    discovered = {
        name for name in names if name.endswith(".gd") and name not in retired
        and re.search(r"\bsave_png\s*\(", gdscript_code(_read(root, name)))
    }
    declared = set(manifest.get("sanctioned_capture_writers", {}))
    issues: List[str] = []
    for name in sorted(discovered - declared):
        issues.append("unreviewed active PNG writer: " + name)
    for name in sorted(declared - discovered):
        issues.append("declared PNG writer was not discovered: " + name)
    hashed_writer_categories = (
        _mapping_paths(manifest, "active_visual_entrypoints"),
        _mapping_paths(manifest, "active_reviewed_support"),
    )
    for name in sorted(declared):
        memberships = sum(name in category for category in hashed_writer_categories)
        if memberships != 1:
            issues.append(
                "sanctioned PNG writer must have exactly one hashed current "
                "classification: %s (found %d)" % (name, memberships)
            )
    physical = manifest.get("physical_capture_guard", {})
    helper_path = physical.get("path", "") if isinstance(physical, dict) else ""
    if helper_path not in _mapping_paths(manifest, "active_reviewed_support"):
        issues.append("physical capture guard is not reviewed support: " + helper_path)
    elif not (root / helper_path).is_file():
        issues.append("physical capture guard is missing: " + helper_path)
    else:
        helper_source = _read(root, helper_path)
        for anchor in physical.get("guard_anchors", []):
            if anchor not in helper_source:
                issues.append("physical capture guard lacks exact anchor: " + anchor)
    for name, record in sorted(manifest.get("sanctioned_capture_writers", {}).items()):
        source = _read(root, name)
        for anchor in record.get("guard_anchors", []):
            if anchor not in source:
                issues.append("missing reviewed capture guard in %s: %s" % (name, anchor))
        expected_call = record.get("physical_guard_call", "")
        if not expected_call:
            issues.append("missing physical guard call declaration: " + name)
        else:
            issues.extend(_guarded_png_write_issues(source, name, expected_call))
    return issues


def retired_reference_issues(manifest: Dict[str, Any], root: Path) -> List[str]:
    blocked = _retired_paths(manifest, "retired_display_entrypoints", "gdscript")
    blocked |= _retired_paths(manifest, "retired_display_entrypoints", "python")
    blocked |= _retired_paths(manifest, "historical_evidence_entrypoints", "gdscript")
    blocked |= _retired_paths(manifest, "historical_evidence_entrypoints", "python")
    current = _mapping_paths(manifest, "active_visual_entrypoints")
    current |= _mapping_paths(manifest, "active_command_entrypoints")
    current |= _mapping_paths(manifest, "active_reviewed_support")
    current |= set(manifest.get("active_headless_entrypoints", []))
    if (root / "project.godot").is_file():
        current.add("project.godot")
    issues: List[str] = []
    for name in sorted(current):
        source = _read(root, name)
        for blocked_path in sorted(_current_literal_references(source, name) & blocked):
            issues.append(
                "current entrypoint references retired or historical display driver: "
                "%s -> %s" % (name, blocked_path)
            )
    return issues


def manifest_issues(
    manifest: Dict[str, Any], root: Path = PROJECT_ROOT,
    names: Optional[Sequence[str]] = None,
) -> List[str]:
    paths = list(names) if names is not None else repository_paths(root)
    issues: List[str] = []
    if manifest.get("schema_version") != 1:
        issues.append("unsupported manifest schema")
    if manifest.get("output_size") != list(EXACT_SIZE):
        issues.append("manifest output must be exactly 1920x1080")
    world = manifest.get("world_surface", {})
    if world.get("size") != list(WORLD_SIZE) or world.get("scale") != 3 \
            or WORLD_SIZE[0] * 3 != EXACT_SIZE[0] \
            or WORLD_SIZE[1] * 3 != EXACT_SIZE[1]:
        issues.append("manifest world surface must be 640x360 at exact 3x")
    for name, anchors in world.get("guard_anchors", {}).items():
        source = _read(root, name)
        for anchor in anchors:
            if anchor not in source:
                issues.append("missing reviewed world/output anchor in %s: %s" % (name, anchor))
    issues.extend(classification_issues(manifest, root, paths))
    issues.extend(hash_issues(manifest, root))

    retired_gd = _retired_paths(manifest, "retired_display_entrypoints", "gdscript")
    retired_gd |= _retired_paths(manifest, "historical_evidence_entrypoints", "gdscript")
    for name in sorted(retired_gd):
        issues.extend(gdscript_retirement_issues(_read(root, name), name))
    retired_py = _retired_paths(manifest, "retired_display_entrypoints", "python")
    retired_py |= _retired_paths(manifest, "historical_evidence_entrypoints", "python")
    for name in sorted(retired_py):
        issues.extend(python_retirement_issues(_read(root, name), name))

    scanned_gd = _mapping_paths(manifest, "active_visual_entrypoints")
    scanned_gd |= set(manifest.get("active_headless_entrypoints", []))
    scanned_gd |= {name for name in _mapping_paths(manifest, "active_reviewed_support")
                   if name.endswith(".gd")}
    for name in sorted(scanned_gd):
        issues.extend(output_operation_issues(_read(root, name), name, manifest))
    for name in sorted(_mapping_paths(manifest, "active_command_entrypoints")):
        issues.extend(command_literal_issues(_read(root, name), name))
    issues.extend(project_config_issues(_read(root, "project.godot"), manifest))
    issues.extend(capture_issues(manifest, root, paths))
    issues.extend(retired_reference_issues(manifest, root))
    return issues


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    issues = manifest_issues(manifest, args.root)
    if issues:
        for issue in issues:
            print("FIRST_PLAYABLE_1080_GATE: " + issue, file=sys.stderr)
        return 1
    print(
        "FIRST_PLAYABLE_1080_GATE passed=true output=1920x1080 "
        "world=640x360 scale=3 general_gdscript_verifier=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
