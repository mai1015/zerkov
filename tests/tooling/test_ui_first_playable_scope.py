"""Tests for the bounded exact-1080 repository gate.

All negative controls are in-memory or temporary source text. This suite never
launches Godot, creates a viewport, or writes visual evidence.
"""

from __future__ import annotations

import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict


PROJECT_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = PROJECT_ROOT / "tools/check_first_playable_1080.py"
SPEC = importlib.util.spec_from_file_location("check_first_playable_1080", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load exact-1080 checker")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def minimal_manifest() -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "output_size": [1920, 1080],
        "external_exact_size_symbols": [],
        "project_config": {},
        "active_visual_entrypoints": {},
        "active_command_entrypoints": {},
        "active_reviewed_support": {},
        "active_headless_entrypoints": [],
        "retired_display_entrypoints": {"gdscript": [], "python": []},
        "historical_evidence_entrypoints": {"gdscript": [], "python": []},
        "non_executable_fixture_files": [],
        "allowed_dynamic_output_assignments": {},
        "world_surface": {"size": [640, 360], "scale": 3, "assignment": {}},
        "physical_capture_guard": {"path": "", "guard_anchors": []},
        "sanctioned_capture_writers": {},
    }


class FirstPlayable1080GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = gate.load_manifest()
        cls.paths = gate.repository_paths(PROJECT_ROOT)

    def test_repository_manifest_passes(self) -> None:
        self.assertEqual([], gate.manifest_issues(self.manifest, PROJECT_ROOT, self.paths))

    def test_manifest_inventory_is_complete_and_independent(self) -> None:
        self.assertEqual(
            [], gate.classification_issues(self.manifest, PROJECT_ROOT, self.paths)
        )
        self.assertEqual(30, len(self.manifest["active_visual_entrypoints"]))
        self.assertEqual(56, len(self.manifest["active_headless_entrypoints"]))
        self.assertEqual(
            (14, 2),
            tuple(len(self.manifest["retired_display_entrypoints"][kind])
                  for kind in ("gdscript", "python")),
        )
        self.assertEqual(
            (21, 10),
            tuple(len(self.manifest["historical_evidence_entrypoints"][kind])
                  for kind in ("gdscript", "python")),
        )

    def test_reviewed_hash_tamper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "tests/visual/reviewed.gd"
            path.parent.mkdir(parents=True)
            path.write_text("extends SceneTree\n", encoding="utf-8")
            manifest = minimal_manifest()
            manifest["active_visual_entrypoints"]["tests/visual/reviewed.gd"] = {
                "sha256": gate.sha256(path), "purpose": "test"
            }
            self.assertEqual([], gate.hash_issues(manifest, root))
            path.write_text("extends SceneTree\n# tampered\n", encoding="utf-8")
            self.assertIn(
                "reviewed file hash mismatch: tests/visual/reviewed.gd",
                gate.hash_issues(manifest, root),
            )

    def test_omitted_and_new_runner_are_rejected(self) -> None:
        omitted = copy.deepcopy(self.manifest)
        removed = next(iter(omitted["active_visual_entrypoints"]))
        del omitted["active_visual_entrypoints"][removed]
        self.assertIn(
            "unclassified GDScript entrypoint: " + removed,
            gate.classification_issues(omitted, PROJECT_ROOT, self.paths),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "tests/visual/new_capture.gd"
            path.parent.mkdir(parents=True)
            path.write_text("extends SceneTree\nfunc _initialize():\n    pass\n",
                            encoding="utf-8")
            issues = gate.classification_issues(
                minimal_manifest(), root, ["tests/visual/new_capture.gd"]
            )
            self.assertIn(
                "unclassified GDScript entrypoint: tests/visual/new_capture.gd", issues
            )

    def test_runner_discovery_lexes_inline_comments_and_single_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commented = root / "tests/new_review_runner.gd"
            inherited = root / "tests/new_inherited_runner.gd"
            commented.parent.mkdir(parents=True)
            commented.write_text(
                "extends SceneTree # ordinary inline comment\n"
                "func _initialize():\n"
                "    root.size = Vector2i(1280, 720)\n",
                encoding="utf-8",
            )
            inherited.write_text(
                "extends 'res://tests/inventory_smoke.gd'\n"
                "func _initialize():\n"
                "    root.size = Vector2i(1280, 720)\n",
                encoding="utf-8",
            )
            names = [
                "tests/new_review_runner.gd", "tests/new_inherited_runner.gd",
            ]
            self.assertEqual(
                set(names), gate.discover_gdscript_entrypoints(root, names)
            )
            issues = gate.classification_issues(minimal_manifest(), root, names)
            for name in names:
                self.assertIn("unclassified GDScript entrypoint: " + name, issues)

    def test_combat_execution_entries_cannot_disappear(self) -> None:
        for name in ["tests/combat/native_combat_execution_contract.gd",
                     "tests/combat/combat_execution_values_contract.gd"]:
            omitted = copy.deepcopy(self.manifest)
            omitted["active_headless_entrypoints"].remove(name)
            self.assertIn("unclassified GDScript entrypoint: " + name,
                          gate.classification_issues(omitted, PROJECT_ROOT, self.paths))

    def test_raid_progression_entries_are_required(self) -> None:
        for name in ["tests/raid/native_raid_progression_contract.gd", "tests/raid/raid_progression_contract.gd",
                     "tests/raid/raid_restart_contract.gd"]:
            omitted = copy.deepcopy(self.manifest)
            omitted["active_headless_entrypoints"].remove(name)
            self.assertIn("unclassified GDScript entrypoint: " + name,
                          gate.classification_issues(omitted, PROJECT_ROOT, self.paths))

    def test_tools_contract_drivers_are_independently_discovered(self) -> None:
        names = ["tools/run_combat_input_contracts.py", "tools/run_ai_contracts.py",
                 "tools/run_future_contracts.py", "tools/not_a_driver.py"]
        self.assertEqual(set(names[:3]), gate.discover_python_display_drivers(PROJECT_ROOT, names))
        omitted = copy.deepcopy(self.manifest)
        del omitted["active_command_entrypoints"][names[0]]
        self.assertIn("unclassified Python display driver: " + names[0],
                      gate.classification_issues(omitted, PROJECT_ROOT, self.paths))

    def test_source_only_fixture_has_separate_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "tests/tooling/rejection.source_only"
            path.parent.mkdir(parents=True)
            path.write_text("extends SceneTree\n", encoding="utf-8")
            manifest = minimal_manifest()
            names = ["tests/tooling/rejection.source_only"]
            self.assertIn(
                "unclassified source-only fixture: tests/tooling/rejection.source_only",
                gate.classification_issues(manifest, root, names),
            )
            manifest["non_executable_fixture_files"] = names
            self.assertEqual([], gate.classification_issues(manifest, root, names))

    def test_retired_drivers_must_fail_first(self) -> None:
        good_gdscript = '''extends SceneTree
func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE: retired")
    quit(2)
    return
func historical_body() -> void:
    root.size = Vector2i(1280, 720)
'''
        self.assertEqual(
            [], gate.gdscript_retirement_issues(good_gdscript, "retired.gd")
        )
        bad_gdscript = good_gdscript.replace(
            "    push_error", "    root.size = Vector2i(1280, 720)\n    push_error", 1
        )
        self.assertTrue(gate.gdscript_retirement_issues(bad_gdscript, "bad.gd"))
        eager_load = 'extends SceneTree\nconst BAD = load("res://bad.gd")\n' + \
            good_gdscript.split("\n", 1)[1]
        self.assertTrue(gate.gdscript_retirement_issues(eager_load, "eager.gd"))

        good_python = '"""history"""\nraise SystemExit("DEFERRED_DISPLAY_SUITE: retired")\n'
        self.assertEqual([], gate.python_retirement_issues(good_python, "retired.py"))
        self.assertTrue(gate.python_retirement_issues(
            "import subprocess\n" + good_python, "bad.py"
        ))

    def test_current_entrypoints_cannot_reference_retired_drivers(self) -> None:
        self.assertEqual([], gate.retired_reference_issues(self.manifest, PROJECT_ROOT))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "tests/visual/current.gd"
            retired = root / "tests/visual/retired.gd"
            current.parent.mkdir(parents=True)
            current.write_text(
                'extends "res://tests/visual/retired.gd"\n', encoding="utf-8"
            )
            retired.write_text("extends SceneTree\n", encoding="utf-8")
            manifest = minimal_manifest()
            manifest["active_visual_entrypoints"]["tests/visual/current.gd"] = {}
            manifest["retired_display_entrypoints"]["gdscript"] = [
                "tests/visual/retired.gd"
            ]
            self.assertTrue(gate.retired_reference_issues(manifest, root))

    def test_literal_reference_edges_normalize_relative_and_res_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raid = root / "tests/raid"
            visual = root / "tests/visual"
            raid.mkdir(parents=True)
            visual.mkdir(parents=True)
            retired_path = "tests/visual/retired.gd"
            historical_path = "tests/visual/historical.gd"
            cases = {
                "tests/raid/relative_extends.gd": (
                    "extends '../visual/retired.gd'\n", retired_path),
                "tests/raid/res_extends.gd": (
                    "extends 'res://tests/visual/historical.gd'\n", historical_path),
                "tests/raid/relative_load.gd": (
                    'extends SceneTree\nvar value = load("../visual/retired.gd")\n',
                    retired_path),
                "tests/raid/res_load.gd": (
                    "extends SceneTree\nvar value = load('res://tests/visual/historical.gd')\n",
                    historical_path),
                "tests/raid/relative_preload.gd": (
                    'extends SceneTree\nconst VALUE = preload("../visual/retired.gd")\n',
                    retired_path),
                "tests/raid/res_preload.gd": (
                    "extends SceneTree\nconst VALUE = preload('res://tests/visual/historical.gd')\n",
                    historical_path),
            }
            for name, (source, _blocked_path) in cases.items():
                (root / name).write_text(source, encoding="utf-8")
            inert = "tests/raid/comment_only.gd"
            (root / inert).write_text(
                "extends SceneTree\n"
                "# preload('res://tests/visual/retired.gd') is inert\n",
                encoding="utf-8",
            )
            manifest = minimal_manifest()
            manifest["active_headless_entrypoints"] = list(cases) + [inert]
            manifest["retired_display_entrypoints"]["gdscript"] = [retired_path]
            manifest["historical_evidence_entrypoints"]["gdscript"] = [
                historical_path
            ]
            issues = gate.retired_reference_issues(manifest, root)
            for name, (_source, blocked_path) in cases.items():
                self.assertIn(
                    "current entrypoint references retired or historical display driver: "
                    + name + " -> " + blocked_path,
                    issues,
                )
            self.assertNotIn(
                "current entrypoint references retired or historical display driver: "
                + inert + " -> " + retired_path,
                issues,
            )

    def test_config_and_os_script_edges_are_literal_and_comment_aware(self) -> None:
        blocked = "tests/compact_bunker_smoke.gd"
        manifest = minimal_manifest()
        manifest["retired_display_entrypoints"]["gdscript"] = [blocked]
        expected = (
            "current entrypoint references retired or historical display driver: "
        )
        for label, assignment in (
            ("bare", 'Review="res://%s"' % blocked),
            ("starred", 'Review="*res://%s"' % blocked),
        ):
            with self.subTest(config=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "project.godot").write_text(
                    "[autoload]\n" + assignment + "\n", encoding="utf-8"
                )
                self.assertIn(
                    expected + "project.godot -> " + blocked,
                    gate.retired_reference_issues(manifest, root),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "project.godot").write_text(
                "[autoload]\n"
                '; Review="*res://%s"\n' % blocked
                + '# Review="res://%s"\n' % blocked,
                encoding="utf-8",
            )
            self.assertEqual([], gate.retired_reference_issues(manifest, root))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner_name = "tests/current_runner.gd"
            runner = root / runner_name
            runner.parent.mkdir(parents=True)
            runner.write_text(
                "extends SceneTree\n"
                "func run() -> void:\n"
                '    OS.execute("godot", ["--script", "res://%s"], [])\n'
                '    var explanation := \'load("res://%s") is documentation\'\n'
                '    # OS.execute("godot", ["--script", "res://%s"], [])\n'
                % (blocked, blocked, blocked),
                encoding="utf-8",
            )
            os_manifest = copy.deepcopy(manifest)
            os_manifest["active_headless_entrypoints"] = [runner_name]
            self.assertEqual(
                [expected + runner_name + " -> " + blocked],
                gate.retired_reference_issues(os_manifest, root),
            )

            runner.write_text(
                "extends SceneTree\n"
                "func run() -> void:\n"
                '    OS.execute("godot", ["--path", ".", "--script", "%s"], [])\n'
                % blocked,
                encoding="utf-8",
            )
            self.assertEqual(
                [expected + runner_name + " -> " + blocked],
                gate.retired_reference_issues(os_manifest, root),
            )

            for method in ("execute_with_pipe", "create_process"):
                runner.write_text(
                    "extends SceneTree\n"
                    "func run() -> void:\n"
                    '    OS.%s("godot", ["--script=%s"])\n' % (method, blocked),
                    encoding="utf-8",
                )
                self.assertEqual(
                    [expected + runner_name + " -> " + blocked],
                    gate.retired_reference_issues(os_manifest, root),
                )

        inert = (
            "extends SceneTree\n"
            "func run() -> void:\n"
            '    var explanation := \'load("res://%s") is documentation\'\n'
            % blocked
        )
        self.assertEqual(set(), gate._gdscript_literal_references(inert))

    def test_retired_and_historical_categories_cannot_overlap(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        gdscript = manifest["retired_display_entrypoints"]["gdscript"][0]
        python = manifest["retired_display_entrypoints"]["python"][0]
        manifest["historical_evidence_entrypoints"]["gdscript"].append(gdscript)
        manifest["historical_evidence_entrypoints"]["python"].append(python)
        issues = gate.classification_issues(manifest, PROJECT_ROOT, self.paths)
        self.assertIn(
            "GDScript entrypoint is both retired and historical: " + gdscript, issues
        )
        self.assertIn(
            "GDScript entrypoint has multiple classifications: " + gdscript, issues
        )
        self.assertIn(
            "Python driver is both retired and historical: " + python, issues
        )
        self.assertIn(
            "Python driver has multiple classifications: " + python, issues
        )

    def test_literal_output_operations_reject_other_sizes(self) -> None:
        manifest = minimal_manifest()
        exact = '''extends SceneTree
const EXACT := Vector2i(1920, 1080)
func run():
    root.size = EXACT
    var target := SubViewport.new()
    target.size = EXACT
'''
        self.assertEqual([], gate.output_operation_issues(exact, "exact.gd", manifest))
        forbidden = {
            "root": "root.size = Vector2i(1280, 720)",
            "constant": "const BAD := Vector2i(1600, 900)\nroot.size = BAD",
            "window": "DisplayServer.window_set_size(Vector2i(960, 540))",
            "server_size": "RenderingServer.viewport_set_size(rid, 1280, 720)",
            "server_attach": (
                "RenderingServer.viewport_attach_to_screen("
                "rid, Rect2(0, 0, 1280, 720))"
            ),
            "subviewport": (
                "var target := SubViewport.new()\n"
                "target.size = Vector2i(1280, 720)"
            ),
        }
        for label, source in forbidden.items():
            with self.subTest(label=label):
                self.assertTrue(gate.output_operation_issues(source, label + ".gd", manifest))
        inert_geometry = 'var inventory_cell := Vector2i(1280, 720)\n'
        self.assertEqual(
            [], gate.output_operation_issues(inert_geometry, "geometry.gd", manifest)
        )

    def test_active_command_requires_exact_literal_resolution(self) -> None:
        exact = 'command = ["godot", "--resolution", "1920x1080", "--headless"]\n'
        self.assertEqual([], gate.command_literal_issues(exact, "exact.py"))
        self.assertTrue(gate.command_literal_issues(
            'command = ["godot", "--resolution", "1280x720"]\n', "small.py"
        ))
        self.assertTrue(gate.command_literal_issues(
            'command = ["godot", "--headless"]\n', "implicit.py"
        ))

    def test_project_output_config_is_exact(self) -> None:
        source = (PROJECT_ROOT / "project.godot").read_text(encoding="utf-8")
        self.assertEqual([], gate.project_config_issues(source, self.manifest))
        changed = source.replace("window/size/viewport_width=1920",
                                 "window/size/viewport_width=1280")
        self.assertTrue(gate.project_config_issues(changed, self.manifest))

    def test_capture_writer_inventory_and_guards_are_complete(self) -> None:
        self.assertEqual(
            [], gate.capture_issues(self.manifest, PROJECT_ROOT, self.paths)
        )
        self.assertEqual(13, len(self.manifest["sanctioned_capture_writers"]))

    def test_sanctioned_writer_has_exactly_one_hashed_current_classification(self) -> None:
        omitted = copy.deepcopy(self.manifest)
        del omitted["active_reviewed_support"]["ui/main.gd"]
        self.assertIn(
            "sanctioned PNG writer must have exactly one hashed current "
            "classification: ui/main.gd (found 0)",
            gate.capture_issues(omitted, PROJECT_ROOT, self.paths),
        )

        overlap = copy.deepcopy(self.manifest)
        overlap["active_visual_entrypoints"]["ui/main.gd"] = copy.deepcopy(
            overlap["active_reviewed_support"]["ui/main.gd"]
        )
        self.assertIn(
            "sanctioned PNG writer must have exactly one hashed current "
            "classification: ui/main.gd (found 2)",
            gate.capture_issues(overlap, PROJECT_ROOT, self.paths),
        )

    def test_each_png_write_has_an_immediate_fail_closed_physical_guard(self) -> None:
        call = "Exact1080CaptureGuard.accepts(root, root, image)"
        accepted = '''func write(image: Image) -> void:
    if not Exact1080CaptureGuard.accepts(root, root, image):
        push_error("wrong output")
        return
    image.save_png("res://exact.png")
'''
        self.assertEqual(
            [], gate._guarded_png_write_issues(accepted, "accepted.gd", call)
        )
        rejected = {
            "unprotected": '''func write(image):
    image.save_png("res://bad.png")
''',
            "comment_decoy": '''func write(image):
    # if not Exact1080CaptureGuard.accepts(root, root, image): return
    image.save_png("res://bad.png")
''',
            "wrong_arguments": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, target, image):
        return
    image.save_png("res://bad.png")
''',
            "open_guard": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        push_error("ignored")
    image.save_png("res://bad.png")
''',
            "nested_return": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        if false:
            return
    image.save_png("res://bad.png")
''',
            "compound_guard": '''func write(image):
    if ignored and not Exact1080CaptureGuard.accepts(root, root, image):
        return
    image.save_png("res://bad.png")
''',
            "yield_gap": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    await process_frame
    image.save_png("res://bad.png")
''',
            "wrong_saved_image": '''func write(image, other):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    other.save_png("res://bad.png")
''',
            "same_line_mutation": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    mutate_state(); image.save_png("res://bad.png")
''',
            "same_line_yield": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    await process_frame; image.save_png("res://bad.png")
''',
            "computed_receiver": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    root.get_texture().get_image().save_png("res://bad.png")
''',
            "await_in_argument": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    image.save_png(await next_frame_path())
''',
            "multiline_await_in_argument": '''func write(image):
    if not Exact1080CaptureGuard.accepts(root, root, image):
        return
    image.save_png(
        await next_frame_path()
    )
''',
        }
        for label, source in rejected.items():
            with self.subTest(label=label):
                self.assertTrue(
                    gate._guarded_png_write_issues(source, label + ".gd", call)
                )

        missing_anchor = copy.deepcopy(self.manifest)
        missing_anchor["physical_capture_guard"]["guard_anchors"].append(
            "REVIEW_MISSING_PHYSICAL_GUARD_ANCHOR"
        )
        self.assertIn(
            "physical capture guard lacks exact anchor: "
            "REVIEW_MISSING_PHYSICAL_GUARD_ANCHOR",
            gate.capture_issues(missing_anchor, PROJECT_ROOT, self.paths),
        )

    def test_world_surface_is_only_640x360_at_exact_3x(self) -> None:
        world = self.manifest["world_surface"]
        self.assertEqual([640, 360], world["size"])
        self.assertEqual(3, world["scale"])
        self.assertEqual([1920, 1080],
                         [value * world["scale"] for value in world["size"]])
        wrong = copy.deepcopy(self.manifest)
        wrong["world_surface"]["scale"] = 2
        self.assertIn(
            "manifest world surface must be 640x360 at exact 3x",
            gate.manifest_issues(wrong, PROJECT_ROOT, self.paths),
        )

    def test_existing_inventory_ui_is_the_registered_path(self) -> None:
        active = self.manifest["active_visual_entrypoints"]
        self.assertIn("tests/visual/inventory_loot_ui_4_11/capture.gd", active)
        self.assertIn("tests/visual/live_character_ui_8_6/capture.gd", active)
        source = (PROJECT_ROOT / "tests/visual/inventory_loot_ui_4_11/capture.gd") \
            .read_text(encoding="utf-8")
        self.assertTrue(source.startswith(
            'extends "res://tests/raid/inventory_ui_binding_contract.gd"'
        ))
        self.assertNotIn("tests/visual/inventory_ui_binding/capture.gd", source)

    def test_scope_is_explicitly_bounded(self) -> None:
        self.assertIn("not a general GDScript verifier", self.manifest["policy"])
        self.assertIn("not a GDScript evaluator", gate.__doc__)


if __name__ == "__main__":
    unittest.main()
