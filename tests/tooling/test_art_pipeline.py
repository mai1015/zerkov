"""Task-9 adversarial contracts. Generated synthetic PNGs are not source art."""
from __future__ import annotations

import copy
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import zerkov_art_pipeline as p


def fixture():
    image = Image.new("RGBA", (8, 4), (0, 0, 0, 0))
    for x in range(8):
        for y in range(4):
            image.putpixel((x, y), (x * 30, y * 60, 128, 255))
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    data = stream.getvalue()
    source = {"id": "fixture.sheet", "path": "Allowed/sheet.png", "sha256": p.digest(data),
              "size": [8, 4], "kind": "sheet", "filter": "nearest", "mipmaps": False,
              "grid": {"cell": [4, 4], "origin": [0, 0], "columns": 2, "rows": 1, "indices": [0, 1]}}
    recipe = {"schema_version": 1, "distribution_status": "blocked_pending_provenance",
              "sources": [source], "clips": {"idle": {"layers": [source["id"]],
              "pivot": [2, 4], "ticks_per_frame": 5, "loop": True}}}
    return recipe, data


def base_registry():
    return {"schema_version": 1, "registry_id": "zerkov.assets", "assets": [],
            "distribution_blockers": [{"id": "original", "status": "blocked"}]}


class ArtPipelineTests(unittest.TestCase):
    def setUp(self):
        self.recipe, self.data = fixture()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "source.zip"
        self.write_zip()

    def write_zip(self, members=None):
        if members is None:
            members = [("zerkov/Allowed/sheet.png", self.data),
                       ("zerkov/Characters (DO NOT USE)/trap.png", b"not decoded"),
                       ("../escape.png", b"not extracted"), ("__MACOSX/._data", b"ignored")]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w") as zf:
                for name, value in members:
                    zf.writestr(name, value)

    def plan(self):
        selected = p.read_selected(self.archive, "zerkov", p.validate_recipe(self.recipe))
        return p.build_plan(self.recipe, selected, p.digest(self.archive.read_bytes()), base_registry())

    def test_checked_in_recipe_validates(self):
        recipe = p.read_json(p.DEFAULT_RECIPE)
        self.assertEqual(28, len(p.validate_recipe(recipe)["sources"]))
        self.assertNotIn("hit", recipe["clips"])
        self.assertEqual([49, 33], recipe["sources"][16]["grid"]["cell"])

    def test_only_selected_bytes_are_read(self):
        selected = p.read_selected(self.archive, "zerkov", self.recipe)
        self.assertEqual({"fixture.sheet": self.data}, selected)
        self.assertFalse((self.root.parent / "escape.png").exists())

    def test_grid_is_explicit(self):
        self.assertEqual([{"name": "frame_0000", "rect": [0, 0, 4, 4]},
                          {"name": "frame_0001", "rect": [4, 0, 4, 4]}],
                         p.regions_for(self.recipe["sources"][0]))

    def test_authored_order_is_retained(self):
        self.recipe["sources"][0]["grid"]["indices"] = [1, 0]
        self.assertEqual("frame_0001", p.regions_for(self.recipe["sources"][0])[0]["name"])

    def test_irregular_rectangles(self):
        source = self.recipe["sources"][0]
        del source["grid"]
        source["regions"] = [{"name": "prop", "rect": [1, 0, 7, 3]}]
        self.assertEqual(source["regions"], p.regions_for(source))

    def test_integer_rejections(self):
        for value in (True, False, 2.0, 2.000001, "2", None, -1, 0, 10**20):
            with self.subTest(value=value):
                recipe = copy.deepcopy(self.recipe)
                recipe["sources"][0]["grid"]["columns"] = value
                with self.assertRaises(p.PipelineError):
                    p.validate_recipe(recipe)

    def test_forbidden_and_escape_paths(self):
        for path in ("../a.png", "/a.png", "C:/a.png", "a\\b.png", "a//b.png", "./a.png",
                     "a/../b.png", "a/DO NOT USE/b.png", "a/do not use/b.png",
                     "UI/Steam exports/a.png", "UI/UX/a.png", "implementation-guide/a.png",
                     "a/ＤＯ ＮＯＴ ＵＳＥ/b.png", "a\n.png", "a. /b.png", " a.png"):
            with self.subTest(path=path), self.assertRaises(p.PipelineError):
                p.safe_path(path)

    def test_hash_mismatch(self):
        self.recipe["sources"][0]["sha256"] = "a" * 64
        with self.assertRaisesRegex(p.PipelineError, "hash mismatch"):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_missing_member(self):
        self.write_zip([])
        with self.assertRaisesRegex(p.PipelineError, "missing selected"):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_duplicate_member(self):
        self.write_zip([("zerkov/Allowed/sheet.png", self.data)] * 2)
        with self.assertRaisesRegex(p.PipelineError, "duplicate selected"):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_symlink_member(self):
        info = zipfile.ZipInfo("zerkov/Allowed/sheet.png")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_zip([(info, self.data)])
        with self.assertRaisesRegex(p.PipelineError, "link/directory"):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_entry_budget(self):
        with patch.object(p, "MAX_ARCHIVE_ENTRIES", 1), self.assertRaises(p.PipelineError):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_member_budget(self):
        with patch.object(p, "MAX_MEMBER_BYTES", 1), self.assertRaises(p.PipelineError):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_total_budget(self):
        with patch.object(p, "MAX_SELECTED_BYTES", 1), self.assertRaises(p.PipelineError):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_dimensions_mismatch(self):
        self.recipe["sources"][0]["size"] = [16, 4]
        with self.assertRaisesRegex(p.PipelineError, "dimensions/format"):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_invalid_image_bytes(self):
        bad = b"not a PNG"
        self.recipe["sources"][0]["sha256"] = p.digest(bad)
        self.write_zip([("zerkov/Allowed/sheet.png", bad)])
        with self.assertRaises(p.PipelineError):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_malformed_archive(self):
        self.archive.write_bytes(b"invalid ZIP")
        with self.assertRaises(p.PipelineError):
            p.read_selected(self.archive, "zerkov", self.recipe)

    def test_schema_rejections(self):
        for value in (True, 1.0, 2, "1", None):
            candidate = copy.deepcopy(self.recipe)
            candidate["schema_version"] = value
            with self.subTest(value=value), self.assertRaises(p.PipelineError):
                p.validate_recipe(candidate)

    def test_duplicate_json_key(self):
        path = self.root / "recipe.json"
        path.write_text('{"schema_version":1,"schema_version":2}')
        with self.assertRaisesRegex(p.PipelineError, "duplicate JSON key"):
            p.read_json(path)

    def test_nonfinite_json(self):
        path = self.root / "recipe.json"
        for value in ("NaN", "Infinity", "-Infinity"):
            path.write_text('{"x":' + value + '}')
            with self.subTest(value=value), self.assertRaises(p.PipelineError):
                p.read_json(path)

    def test_geometry_mutations(self):
        mutations = [lambda s: s["grid"].update(cell=[5, 4]),
                     lambda s: s["grid"].update(origin=[1, 0]),
                     lambda s: s["grid"].update(indices=[0, 0]),
                     lambda s: s["grid"].update(indices=[2]),
                     lambda s: s["grid"].update(indices=[True]),
                     lambda s: s.update(regions=[]),
                     lambda s: s.pop("grid")]
        for mutation in mutations:
            candidate = copy.deepcopy(self.recipe)
            mutation(candidate["sources"][0])
            with self.subTest(mutation=mutation), self.assertRaises(p.PipelineError):
                p.validate_recipe(candidate)

    def test_pixel_filter_and_mipmaps(self):
        for field, value in [("filter", "linear"), ("filter", "nearest_mipmap"), ("mipmaps", True), ("mipmaps", 0)]:
            candidate = copy.deepcopy(self.recipe)
            candidate["sources"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(p.PipelineError):
                p.validate_recipe(candidate)

    def test_background_linear_allowed(self):
        source = self.recipe["sources"][0]
        source.update(kind="background", filter="linear")
        p.validate_recipe(self.recipe)

    def test_license_cannot_be_cleared(self):
        self.recipe["distribution_status"] = "cleared"
        with self.assertRaises(p.PipelineError):
            p.validate_recipe(self.recipe)

    def test_duplicate_source_identity(self):
        self.recipe["sources"].append(copy.deepcopy(self.recipe["sources"][0]))
        with self.assertRaises(p.PipelineError):
            p.validate_recipe(self.recipe)

    def test_case_colliding_paths(self):
        source = copy.deepcopy(self.recipe["sources"][0])
        source.update(id="fixture.second", path="allowed/SHEET.png")
        self.recipe["sources"].append(source)
        with self.assertRaises(p.PipelineError):
            p.validate_recipe(self.recipe)

    def test_layer_mismatch_and_missing(self):
        self.recipe["clips"]["idle"]["layers"].append("missing")
        with self.assertRaises(p.PipelineError):
            p.validate_recipe(self.recipe)

    def test_bad_pivot(self):
        self.recipe["clips"]["idle"]["pivot"] = [50, 50]
        with self.assertRaises(p.PipelineError):
            p.validate_recipe(self.recipe)

    def test_plan_is_reproducible(self):
        self.assertEqual(self.plan(), self.plan())

    def test_original_bytes_unchanged(self):
        self.assertEqual(self.data, self.plan()["assets/original/Allowed/sheet.png"])

    def test_native_import_preset(self):
        preset = self.plan()["assets/original/Allowed/sheet.png.import"].decode()
        for setting in ("compress/mode=0", "mipmaps/generate=false", "process/size_limit=0", "detect_3d/compress_to=0"):
            self.assertIn(setting, preset)
        self.assertNotIn("flags/filter", preset)

    def test_atlas_resources_are_rect_exact(self):
        plan = self.plan()
        resource = plan["game/content/art/slices/fixture.sheet/frame_0001.tres"].decode()
        self.assertIn("region = Rect2(4, 0, 4, 4)", resource)
        self.assertIn("filter_clip = true", resource)

    def test_receipt_seals_outputs(self):
        plan = self.plan()
        receipt = json.loads(plan["game/content/art/build_receipt.json"])
        self.assertEqual(len(plan) - 1, len(receipt["files"]))
        for name, expected in receipt["files"].items():
            self.assertEqual(expected, p.digest(plan[name]))

    def test_runtime_clip_matches_regions(self):
        runtime = json.loads(self.plan()["game/content/art/runtime_art.json"])
        self.assertEqual(2, runtime["clips"]["idle"]["frame_count"])

    def test_registry_blockers_preserved(self):
        before = base_registry()
        result = p.merge_registry(before, p.registry_additions(self.recipe, "a" * 64))
        self.assertEqual(before["distribution_blockers"], result["distribution_blockers"])
        self.assertEqual("blocked", result["assets"][0]["license"]["status"])
        self.assertEqual([], before["assets"])

    def test_registry_idempotent(self):
        additions = p.registry_additions(self.recipe, "a" * 64)
        once = p.merge_registry(base_registry(), additions)
        self.assertEqual(once, p.merge_registry(once, additions))

    def test_registry_preserves_aliases_and_links(self):
        additions = p.registry_additions(self.recipe, "a" * 64)
        base = p.merge_registry(base_registry(), additions)
        base["assets"][0]["aliases"].append("stable.old.alias")
        base["assets"][0]["content_links"] = ["zerkov.item.weapon.akm"]
        after = p.merge_registry(base, additions)
        self.assertIn("stable.old.alias", after["assets"][0]["aliases"])
        self.assertEqual(base["assets"][0]["content_links"], after["assets"][0]["content_links"])

    def test_registry_collision_and_hash_drift(self):
        additions = p.registry_additions(self.recipe, "a" * 64)
        base = p.merge_registry(base_registry(), additions)
        for field, value in [("id", "zerkov.asset.other"), ("runtime_sha256", "b" * 64)]:
            candidate = copy.deepcopy(base)
            candidate["assets"][0][field] = value
            with self.subTest(field=field), self.assertRaises(p.PipelineError):
                p.merge_registry(candidate, additions)

    def test_publish_create_only(self):
        plan = self.plan()
        output = self.root / "out"
        p.publish_new_directory(plan, output)
        with self.assertRaises(p.PipelineError):
            p.publish_new_directory(plan, output)
        for name, data in plan.items():
            self.assertEqual(data, (output / name).read_bytes())

    def test_publish_rejects_symlink(self):
        output = self.root / "out"
        output.symlink_to(self.root / "missing", target_is_directory=True)
        with self.assertRaises(p.PipelineError):
            p.publish_new_directory(self.plan(), output)

    def test_bad_plan_writes_nothing(self):
        plan = self.plan()
        plan["../escape"] = b"no"
        with self.assertRaises(p.PipelineError):
            p.publish_new_directory(plan, self.root / "out")
        self.assertFalse((self.root / "out").exists())
        self.assertFalse((self.root / ".out.art-lock").exists())

    def test_output_lock(self):
        (self.root / ".out.art-lock").write_text("other writer")
        with self.assertRaises(p.PipelineError):
            p.publish_new_directory(self.plan(), self.root / "out")
        self.assertEqual("other writer", (self.root / ".out.art-lock").read_text())

    def test_write_failure_cleans_staging(self):
        plan = self.plan()
        with patch.object(Path, "write_bytes", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                p.publish_new_directory(plan, self.root / "out")
        self.assertFalse((self.root / "out").exists())
        self.assertFalse(list(self.root.glob(".art-stage-*")))
        self.assertFalse((self.root / ".out.art-lock").exists())

    def test_custom_archive_prefix_in_provenance(self):
        selected = {"fixture.sheet": self.data}
        plan = p.build_plan(self.recipe, selected, "a" * 64, prefix="custom")
        additions = json.loads(plan["game/content/art/registry_additions.json"])
        self.assertEqual("custom/Allowed/sheet.png", additions["assets"][0]["provenance"]["origin_member"])


if __name__ == "__main__":
    unittest.main()
