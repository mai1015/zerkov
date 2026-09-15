"""Synthetic filesystem contracts; NOT native Godot or real-asset acceptance."""
from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

MODULE = Path(__file__).resolve().parents[2] / "tools/art/asset_pipeline.py"
spec = importlib.util.spec_from_file_location("asset_pipeline", MODULE)
assert spec is not None and spec.loader is not None
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)


def png(width: int = 12, height: int = 8) -> bytes:
    def chunk(name: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixels = b"".join(b"\x00" + b"\x70\xa0\x30\xff" * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def sidecar(path: str) -> str:
    return f'''[remap]
importer="texture"
type="CompressedTexture2D"
uid="uid://fixture"
path="res://.godot/imported/fixture.ctex"
metadata={{
"vram_texture": false
}}
[deps]
source_file={json.dumps(path)}
dest_files=["res://.godot/imported/fixture.ctex"]
[params]
compress/mode=0
mipmaps/generate=false
process/size_limit=0
process/fix_alpha_border=true
detect_3d/compress_to=1
'''


class AssetPipelineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = "res://assets/Exact Path/Not_a_64x64_filename.png"
        self.asset = {
            "id": "zerkov.asset.test.sheet", "aliases": ["test.sheet"],
            "runtime_path": self.path, "availability": "imported_source_missing",
            "runtime_sha256": hashlib.sha256(png()).hexdigest(),
            "provenance": {"source_root": "/unmounted/originals", "source_relative_path": "explicit.png", "source_status": "unavailable_external", "source_sha256": None},
            "family": "test", "kind": "sheet",
            "filtering": {"mode": "nearest", "mipmaps": False},
            "license": {"status": "blocked", "reference": "fixture", "reason": "not cleared"},
            "atlas": {"source_size": [12, 8], "cell_size": [4, 4], "columns": 3, "rows": 2, "frame_count": 6},
        }
        self.manifest = {"schema_version": 1, "registry_id": "zerkov.assets", "forbidden_paths": ["private-not-for-import"], "distribution_blockers": [{"id": "art", "status": "blocked"}], "assets": [self.asset]}
        path = self.root / self.path[6:]
        path.parent.mkdir(parents=True)
        path.write_bytes(png())
        Path(str(path) + ".import").write_text(sidecar(self.path), encoding="utf-8")
        self.save()

    def save(self) -> None:
        path = self.root / art.MANIFEST
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.manifest, indent=2), encoding="utf-8")

    def pipeline(self):
        self.save()
        return art.Pipeline(self.root)

    def fails(self, text: str = "."):
        return self.assertRaisesRegex(art.AssetError, text)

    def files(self) -> dict[str, bytes]:
        return {path.relative_to(self.root).as_posix(): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}

    def test_01_audit_reports_pending_native_and_licensing_honestly(self):
        report = self.pipeline().audit()
        self.assertEqual(len(report["textures"]), 1)
        self.assertEqual(report["native_validation"], "not_run")
        self.assertEqual(report["distribution_approval"], "not_evaluated")
        self.assertEqual(report["distribution_blockers"], self.manifest["distribution_blockers"])

    def test_02_audit_is_read_only(self):
        pipeline = self.pipeline()
        before = self.files()
        pipeline.audit()
        self.assertEqual(self.files(), before)

    def test_03_compile_is_read_only_until_publish(self):
        pipeline = self.pipeline()
        before = self.files()
        files = pipeline.compile(["test.sheet"])
        self.assertEqual(len(files), 13)
        self.assertEqual(self.files(), before)

    def test_04_repeated_compilations_are_byte_identical(self):
        pipeline = self.pipeline()
        first = pipeline.compile(["test.sheet"])
        self.assertEqual(first, pipeline.compile([self.asset["id"]]))
        self.assertEqual(first, art.Pipeline(self.root).compile(["test.sheet"]))

    def test_05_frame_geometry_comes_from_metadata_not_filename(self):
        regions = self.pipeline().audit()["textures"][self.asset["id"]]["regions"]
        self.assertEqual(regions, [(0, 0, 4, 4), (4, 0, 4, 4), (8, 0, 4, 4), (0, 4, 4, 4), (4, 4, 4, 4), (8, 4, 4, 4)])

    def test_06_explicit_frame_order_is_preserved(self):
        self.asset["atlas"]["frame_order"] = [5, 4, 3, 2, 1, 0]
        files = self.pipeline().compile(["test.sheet"])
        self.assertIn(b"Rect2(8, 4, 4, 4)", files[self.asset["id"] + "/frame_0000.tres"])

    def test_07_nearest_is_written_on_canvas_item_not_import_flag(self):
        files = self.pipeline().compile(["test.sheet"])
        scene = files[self.asset["id"] + "/frame_0000.tscn"]
        self.assertIn(b"texture_filter = 1\n", scene)
        self.assertNotIn("filter", art.import_preset(self.asset)["params"])

    def test_08_background_retains_explicit_linear_filter(self):
        self.asset["kind"] = "background"
        self.asset["filtering"]["mode"] = "linear"
        files = self.pipeline().compile(["test.sheet"])
        self.assertIn(b"texture_filter = 2\n", files[self.asset["id"] + "/frame_0000.tscn"])

    def test_09_crop_has_filter_clip_and_exact_source_path(self):
        files = self.pipeline().compile(["test.sheet"])
        texture = files[self.asset["id"] + "/frame_0000.tres"]
        self.assertIn(b"filter_clip = true", texture)
        self.assertIn(self.path.encode(), texture)
        self.assertNotIn(b"uid://", texture)

    def test_10_pending_asset_is_reported_but_cannot_be_compiled(self):
        self.asset.update(availability="pending_unimported", runtime_path="", runtime_sha256=None)
        pipeline = self.pipeline()
        self.assertEqual(pipeline.audit()["pending_unimported"], [self.asset["id"]])
        with self.fails("pending/unimported"):
            pipeline.compile(["test.sheet"])

    def test_11_pending_asset_cannot_claim_runtime_bytes(self):
        self.asset["availability"] = "pending_unimported"
        with self.fails("Pending asset has runtime"):
            self.pipeline()

    def test_12_missing_metadata_is_not_guessed(self):
        del self.asset["atlas"]
        pipeline = self.pipeline()
        pipeline.audit()
        with self.fails("Explicit PNG/SVG atlas"):
            pipeline.compile(["test.sheet"])

    def test_13_unknown_selection_and_duplicate_alias_fail(self):
        pipeline = self.pipeline()
        for selectors in ([], ["TEST.SHEET"], ["sheet"], ["test.sheet", self.asset["id"]]):
            with self.subTest(selectors=selectors), self.fails():
                pipeline.compile(selectors)

    def test_14_duplicate_id_alias_and_path_fail(self):
        for mutation in ("id", "alias", "path"):
            candidate = copy.deepcopy(self.asset)
            candidate["id"] = "zerkov.asset.test.other"
            candidate["aliases"] = ["test.other"]
            if mutation == "id":
                candidate["id"] = self.asset["id"]
            elif mutation == "alias":
                candidate["aliases"] = [self.asset["id"]]
            self.manifest["assets"] = [self.asset, candidate]
            with self.subTest(mutation=mutation), self.fails("[Dd]uplicate|collid"):
                self.pipeline()

    def test_15_missing_changed_or_mismatched_runtime_fails(self):
        path = self.root / self.path[6:]
        path.write_bytes(png() + b"changed")
        with self.fails("SHA-256 mismatch"):
            self.pipeline().audit()
        path.unlink()
        with self.fails("Missing regular file"):
            self.pipeline().audit()

    def test_16_missing_sidecar_fails(self):
        Path(str(self.root / self.path[6:]) + ".import").unlink()
        with self.fails("Missing regular file"):
            self.pipeline().audit()

    def test_17_import_preset_mutations_fail(self):
        path = Path(str(self.root / self.path[6:]) + ".import")
        mutations = [("compress/mode=0", "compress/mode=2"), ("mipmaps/generate=false", "mipmaps/generate=true"), ("process/size_limit=0", "process/size_limit=16"), ('importer="texture"', 'importer="image"'), (self.path, "res://assets/wrong.png")]
        for old, new in mutations:
            path.write_text(sidecar(self.path).replace(old, new), encoding="utf-8")
            with self.subTest(key=old), self.fails("Import mismatch"):
                self.pipeline().audit()

    def test_18_duplicate_import_sections_and_keys_fail(self):
        preset = art.import_preset(self.asset)
        for suffix in ("\n[params]\n", "\ncompress/mode=0\n"):
            with self.fails("Duplicate import"):
                art.inspect_import(sidecar(self.path) + suffix, self.path, preset)

    def test_19_import_metadata_is_never_rewritten(self):
        path = Path(str(self.root / self.path[6:]) + ".import")
        before = path.read_bytes()
        self.pipeline().compile(["test.sheet"])
        self.assertEqual(path.read_bytes(), before)

    def test_20_pixel_filter_and_mipmap_violations_fail(self):
        for policy in ({"mode": "linear", "mipmaps": False}, {"mode": "nearest", "mipmaps": True}, {"mode": "nearest", "mipmaps": 0}):
            self.asset["filtering"] = policy
            with self.subTest(policy=policy), self.fails():
                self.pipeline()

    def test_21_forbidden_imported_paths_are_case_insensitive(self):
        for relative in ("DO NOT USE/a.png", "Characters (do not use)/a.png", "UI/UX/a.png", "UI/Steam exports/a.png", "private-not-for-import/a.png"):
            self.asset["runtime_path"] = "res://assets/" + relative
            with self.subTest(relative=relative), self.fails("Forbidden runtime"):
                self.pipeline()

    def test_22_forbidden_external_provenance_is_rejected(self):
        self.asset["provenance"]["source_relative_path"] = "Clothing (DO NOT USE)/sprite.png"
        with self.fails("Forbidden provenance"):
            self.pipeline()

    def test_23_unregistered_forbidden_file_is_detected(self):
        path = self.root / "assets/Characters (Do Not Use)/not_in_registry.png"
        path.parent.mkdir()
        path.write_bytes(png())
        with self.fails("Forbidden runtime asset"):
            self.pipeline().audit()

    def test_24_empty_forbidden_directory_is_detected(self):
        (self.root / "assets/DO NOT USE").mkdir()
        with self.fails("Forbidden runtime asset"):
            self.pipeline().audit()

    def test_25_fullwidth_unicode_forbidden_marker_is_detected(self):
        self.assertTrue(art.forbidden("assets/ＤＯ ＮＯＴ ＵＳＥ/sheet.png", []))

    def test_26_runtime_and_sidecar_symlinks_are_rejected(self):
        for suffix in ("", ".import"):
            target = self.root / (self.path[6:] + suffix)
            saved = target.read_bytes()
            target.unlink()
            external = self.root / "external"
            external.write_bytes(saved)
            target.symlink_to(external)
            with self.subTest(suffix=suffix), self.fails("Symlink"):
                self.pipeline().audit()
            target.unlink()
            target.write_bytes(saved)

    def test_27_parent_and_unregistered_directory_symlinks_fail(self):
        (self.root / "assets/link").symlink_to(self.root, target_is_directory=True)
        with self.fails("Symlink"):
            self.pipeline().audit()

    def test_28_path_traversal_and_nonportable_paths_fail(self):
        for relative in ("../outside", "/absolute", "a//b", "a/./b", "a/../b", "C:/a", "a\\b", "a\nb", ""):
            with self.subTest(relative=relative), self.fails():
                art.confined(self.root, relative)

    def test_29_noninteger_atlas_values_fail_without_rounding(self):
        for value in (True, False, 4.0, 4.0000000001, "4", None, 0, -1):
            atlas = copy.deepcopy(self.asset["atlas"])
            atlas["cell_size"][0] = value
            with self.subTest(value=value), self.fails("JSON integer"):
                art.atlas_regions(atlas, (12, 8))

    def test_30_frame_order_rejects_duplicates_types_missing_and_bounds(self):
        for order in ([0] * 6, [0, 1, 2, 3, 4, 6], [0, 1, 2, 3, 4, -1], [0, 1, 2, 3, 4, True], [0, 1, 2, 3, 4, 5.0], [0, 1], "012345", None):
            atlas = copy.deepcopy(self.asset["atlas"])
            atlas["frame_order"] = order
            with self.subTest(order=order), self.fails():
                art.atlas_regions(atlas, (12, 8))

    def test_31_dimension_grid_and_count_mismatches_fail(self):
        for key, value in (("source_size", [16, 8]), ("cell_size", [8, 4]), ("columns", 4), ("frame_count", 5)):
            atlas = copy.deepcopy(self.asset["atlas"])
            atlas[key] = value
            with self.subTest(key=key), self.fails():
                art.atlas_regions(atlas, (12, 8))

    def test_32_unknown_atlas_offsets_are_not_silently_ignored(self):
        atlas = copy.deepcopy(self.asset["atlas"])
        atlas["offset"] = [1, 1]
        with self.fails("Unsupported atlas metadata"):
            art.atlas_regions(atlas, (12, 8))

    def test_33_header_signature_crc_and_dimension_budgets_fail(self):
        corrupted = bytearray(png())
        corrupted[16] ^= 1
        for data in (b"", b"not png" * 10, bytes(corrupted), png(1, 1)[:32]):
            with self.subTest(length=len(data)), self.fails("PNG"):
                art.png_size(data)

    def test_34_json_duplicate_keys_and_nonfinite_values_fail(self):
        for text in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}', '{'):
            with self.subTest(text=text), self.fails():
                art.strict_json(text)

    def test_35_schema_identity_and_empty_registry_fail(self):
        for key, value in (("schema_version", True), ("schema_version", 1.0), ("registry_id", "wrong"), ("assets", [])):
            original = self.manifest[key]
            self.manifest[key] = value
            with self.subTest(key=key), self.fails():
                self.pipeline()
            self.manifest[key] = original

    def test_36_publish_then_republish_is_byte_identical_and_noop(self):
        files = self.pipeline().compile(["test.sheet"])
        self.assertTrue(art.publish(self.root, files))
        before = self.files()
        self.assertFalse(art.publish(self.root, files))
        self.assertEqual(self.files(), before)

    def test_37_changed_output_is_not_overwritten(self):
        files = self.pipeline().compile(["test.sheet"])
        art.publish(self.root, files)
        output = self.root / art.OUTPUT / "index.json"
        output.write_bytes(b"user-authored-change")
        before = self.files()
        with self.fails("Output differs"):
            art.publish(self.root, files)
        self.assertEqual(self.files(), before)

    def test_38_output_parent_symlink_and_traversal_are_rejected(self):
        files = self.pipeline().compile(["test.sheet"])
        (self.root / "game/presentation").symlink_to(self.root / "assets", target_is_directory=True)
        with self.fails("Symlink"):
            art.publish(self.root, files)
        (self.root / "game/presentation").unlink()
        with self.fails("Unsafe path"):
            art.publish(self.root, {"../escape": b"bad"})
        self.assertFalse((self.root / art.OUTPUT).exists())

    def test_39_failed_write_cleans_staging_without_publishing(self):
        files = self.pipeline().compile(["test.sheet"])
        with mock.patch.object(Path, "write_bytes", side_effect=OSError("injected disk failure")):
            with self.assertRaisesRegex(OSError, "disk failure"):
                art.publish(self.root, files)
        self.assertFalse((self.root / art.OUTPUT).exists())
        self.assertEqual(list((self.root / art.OUTPUT).parent.glob(".art-stage-*")), [])

    def test_40_late_preflight_failure_has_no_output(self):
        self.asset["atlas"]["frame_order"] = [0] * 6
        self.save()
        before = self.files()
        with self.fails():
            files = art.Pipeline(self.root).compile(["test.sheet"])
            art.publish(self.root, files)
        self.assertEqual(self.files(), before)

    def test_41_cli_default_is_read_only_and_rejects_invalid_modes(self):
        for args, expected in ((["audit"], 0), (["compile", "--asset", "test.sheet"], 0), (["compile"], 1), (["audit", "--write"], 1), (["audit", "--asset", "test.sheet"], 1)):
            before = self.files()
            with self.subTest(args=args), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(art.main([*args, "--root", str(self.root)]), expected)
            self.assertEqual(self.files(), before)

    def test_42_cli_write_generates_only_owned_output_and_preserves_png(self):
        before = self.files()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(art.main(["compile", "--root", str(self.root), "--asset", "test.sheet", "--write"]), 0)
        after = self.files()
        self.assertTrue(all(after[key] == value for key, value in before.items()))
        self.assertTrue(all(name.startswith(art.OUTPUT + "/") for name in after.keys() - before.keys()))

    def test_43_generated_scenes_have_no_scripts_or_gameplay_nodes(self):
        for name, data in self.pipeline().compile(["test.sheet"]).items():
            if name.endswith(".tscn"):
                self.assertEqual(data.count(b"[node "), 1)
                self.assertIn(b'type="Sprite2D"', data)
                for forbidden_token in (b"script", b"Collision", b"AnimationPlayer", b"RaidAuthority", b"[connection"):
                    self.assertNotIn(forbidden_token, data)

    def test_44_fonts_are_hash_checked_not_misreported_as_texture_imports(self):
        font = copy.deepcopy(self.asset)
        font.update(id="zerkov.asset.test.font", aliases=["test.font"], runtime_path="res://assets/font.ttf", kind="font", runtime_sha256=hashlib.sha256(b"font fixture").hexdigest())
        del font["atlas"]
        self.manifest["assets"].append(font)
        (self.root / "assets/font.ttf").write_bytes(b"font fixture")
        report = self.pipeline().audit()
        self.assertEqual(report["non_texture_hash_checked_only"], [font["id"]])
        with self.fails("Explicit PNG/SVG atlas"):
            self.pipeline().compile(["test.font"])

    def test_45_per_asset_and_total_frame_budgets_fail(self):
        with mock.patch.object(art, "MAX_FRAMES", 5), self.fails("budget"):
            self.pipeline().audit()
        with mock.patch.object(art, "MAX_TOTAL_FRAMES", 5), self.fails("budget"):
            self.pipeline().compile(["test.sheet"])

    def test_46_file_size_budget_fails(self):
        with mock.patch.object(art, "MAX_FILE_BYTES", 2), self.fails("byte budget"):
            art.read_bytes(self.root / self.path[6:])

    def test_47_bad_hash_and_availability_fail(self):
        for key, value in (("runtime_sha256", "0" * 63), ("availability", "maybe")):
            original = self.asset[key]
            self.asset[key] = value
            with self.subTest(key=key), self.fails():
                self.pipeline()
            self.asset[key] = original

    def test_48_generated_index_records_exact_manifest_digest(self):
        pipeline = self.pipeline()
        index = json.loads(pipeline.compile(["test.sheet"])["index.json"])
        self.assertEqual(index["manifest_sha256"], hashlib.sha256((self.root / art.MANIFEST).read_bytes()).hexdigest())
        self.assertEqual(index["assets"][0]["runtime_sha256"], self.asset["runtime_sha256"])
        self.assertEqual(index["native_validation"], "not_run")


    def test_49_malformed_kind_and_availability_fail_with_typed_error(self):
        for key in ("kind", "availability"):
            for value in ([], {}, None, 1):
                original = self.asset[key]
                self.asset[key] = value
                with self.subTest(key=key, value=value), self.fails():
                    self.pipeline()
                self.asset[key] = original

    def test_50_frame_scene_uses_top_left_pixel_origin(self):
        files = self.pipeline().compile(["test.sheet"])
        self.assertIn(b"centered = false", files[self.asset["id"] + "/frame_0000.tscn"])

    def test_51_existing_output_walk_error_fails_closed(self):
        files = self.pipeline().compile(["test.sheet"])
        art.publish(self.root, files)
        def unreadable(*args, **kwargs):
            kwargs["onerror"](PermissionError("injected unreadable output"))
            return iter(())
        with mock.patch.object(art.os, "walk", side_effect=unreadable), self.fails("Cannot inspect existing output"):
            art.publish(self.root, files)

    def test_52_runtime_scan_error_fails_closed(self):
        pipeline = self.pipeline()
        def unreadable(*args, **kwargs):
            kwargs["onerror"](PermissionError("injected unreadable assets"))
            return iter(())
        with mock.patch.object(art.os, "walk", side_effect=unreadable), self.fails("Cannot inspect runtime assets"):
            pipeline.audit()


    def test_53_explicit_svg_atlas_uses_the_same_geometry_and_compiler(self):
        source = b'<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8" viewBox="0 0 12 8"><rect width="12" height="8" fill="#708090"/></svg>'
        self.asset["runtime_path"] = "res://assets/atlas.svg"
        self.asset["runtime_sha256"] = hashlib.sha256(source).hexdigest()
        (self.root / "assets/atlas.svg").write_bytes(source)
        (self.root / "assets/atlas.svg.import").write_text(sidecar(self.asset["runtime_path"]) + "svg/scale=1.0\neditor/scale_with_editor_scale=false\neditor/convert_colors_with_editor_theme=false\n", encoding="utf-8")
        files = self.pipeline().compile(["test.sheet"])
        self.assertEqual(len(files), 13)
        self.assertIn(b"assets/atlas.svg", files[self.asset["id"] + "/frame_0000.tres"])
        (self.root / "assets/atlas.svg.import").write_text((self.root / "assets/atlas.svg.import").read_text().replace("svg/scale=1.0", "svg/scale=2.0"), encoding="utf-8")
        with self.fails("svg/scale"):
            self.pipeline().audit()

    def test_54_svg_ambiguous_dimensions_and_entities_fail(self):
        for source in (b'<svg width="100%" height="8"/>', b'<svg width="12.5" height="8"/>', b'<svg viewBox="0 0 12 8"/>', b'<html width="12" height="8"/>', b'<!DOCTYPE svg [<!ENTITY x "12">]><svg width="&x;" height="8"/>', b'<svg'):
            with self.subTest(source=source), self.fails():
                art.svg_size(source)
        self.assertEqual(art.svg_size(b'<svg width="12px" height="8px"/>'), (12, 8))


if __name__ == "__main__":
    unittest.main(verbosity=2)
