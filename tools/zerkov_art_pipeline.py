#!/usr/bin/env python3
"""Verified task-9 asset selection, slicing and create-only runtime overlays.

Inputs are explicit recipes and user-authorized archives. This compiler never
infers frame geometry from filenames or recursively extracts a source archive.
It preserves the existing registry's identities and distribution blockers.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import unicodedata
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RECIPE = ROOT / "game/content/art/slice_recipe.json"
MAX_ARCHIVE_ENTRIES = 10_000
MAX_MEMBER_BYTES = 16 * 1024 * 1024
MAX_SELECTED_BYTES = 128 * 1024 * 1024
MAX_IMAGE_PIXELS = 16_777_216
MAX_REGIONS = 4096
FORBIDDEN = ("do not use", "ui/steam exports", "ui/ux", "implementation-guide")
ID = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*$")
SHA = re.compile(r"^[a-f0-9]{64}$")
LICENSE_REFERENCE = "config/distribution_licenses.json#asset_families.zerkov-handoff-and-original-art"


class PipelineError(ValueError):
    """Invalid or unverified input; never a successful skipped import."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise PipelineError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise PipelineError(f"non-finite JSON value: {value}")


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"),
                           object_pairs_hook=_unique_object, parse_constant=_reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PipelineError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PipelineError("manifest must be a JSON object")
    return value


def safe_path(value: object) -> str:
    """Reject escapes, alternate separators, forbidden families and path aliases."""
    if not isinstance(value, str) or not value or value != value.strip():
        raise PipelineError(f"invalid relative path: {value!r}")
    normalized = unicodedata.normalize("NFKC", value).casefold()
    if any(token in normalized for token in FORBIDDEN):
        raise PipelineError(f"forbidden source path: {value}")
    if "\\" in value or ":" in value or any(ord(c) < 32 for c in value):
        raise PipelineError(f"non-portable path: {value}")
    if any(p in ("", ".", "..") or p.endswith((" ", ".")) for p in value.split("/")):
        raise PipelineError(f"non-canonical relative path: {value}")
    if PurePosixPath(value).is_absolute():
        raise PipelineError(f"absolute path: {value}")
    return value


def _int(value: object, minimum: int, maximum: int, field: str) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise PipelineError(f"{field}: expected integer in [{minimum}, {maximum}], got {value!r}")
    return value


def _vector(value: object, length: int, minimum: int, maximum: int, field: str) -> list[int]:
    if not isinstance(value, list) or len(value) != length:
        raise PipelineError(f"{field}: expected {length} integer components")
    return [_int(v, minimum, maximum, field) for v in value]


def regions_for(source: dict) -> list[dict]:
    """Expand an explicitly authored grid or retain explicitly authored rects."""
    size = _vector(source.get("size"), 2, 1, 4096, "source.size")
    if ("grid" in source) == ("regions" in source):
        raise PipelineError("source requires exactly one of grid or regions")
    if "grid" in source:
        grid = source["grid"]
        if not isinstance(grid, dict):
            raise PipelineError("grid must be an object")
        cell = _vector(grid.get("cell"), 2, 1, 4096, "grid.cell")
        origin = _vector(grid.get("origin"), 2, 0, 4096, "grid.origin")
        columns = _int(grid.get("columns"), 1, MAX_REGIONS, "grid.columns")
        rows = _int(grid.get("rows"), 1, MAX_REGIONS, "grid.rows")
        if columns * rows > MAX_REGIONS:
            raise PipelineError("grid exceeds region budget")
        if origin[0] + columns * cell[0] > size[0] or origin[1] + rows * cell[1] > size[1]:
            raise PipelineError("grid exceeds source bounds")
        indices = grid.get("indices")
        if not isinstance(indices, list) or not 1 <= len(indices) <= MAX_REGIONS:
            raise PipelineError("grid.indices must explicitly select at least one frame")
        result, seen = [], set()
        for index in indices:
            i = _int(index, 0, columns * rows - 1, "grid.indices")
            if i in seen:
                raise PipelineError("duplicate grid index")
            seen.add(i)
            result.append({"name": f"frame_{i:04d}", "rect": [
                origin[0] + (i % columns) * cell[0],
                origin[1] + (i // columns) * cell[1], cell[0], cell[1]]})
    else:
        result = copy.deepcopy(source["regions"])
        if not isinstance(result, list) or not 1 <= len(result) <= MAX_REGIONS:
            raise PipelineError("regions must be a non-empty bounded list")
    names = set()
    for region in result:
        if not isinstance(region, dict):
            raise PipelineError("region must be an object")
        name = region.get("name")
        if not isinstance(name, str) or not ID.fullmatch(name) or name in names:
            raise PipelineError(f"invalid/duplicate region name: {name!r}")
        names.add(name)
        x, y, w, h = _vector(region.get("rect"), 4, 0, 4096, "region.rect")
        if not w or not h or x + w > size[0] or y + h > size[1]:
            raise PipelineError(f"region outside source: {name}")
    return result


def validate_recipe(recipe: dict) -> dict:
    if not isinstance(recipe, dict) or type(recipe.get("schema_version")) is not int or recipe["schema_version"] != 1:
        raise PipelineError("unsupported recipe schema")
    if recipe.get("distribution_status") != "blocked_pending_provenance":
        raise PipelineError("this recipe cannot clear the existing distribution gate")
    sources = recipe.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= 128:
        raise PipelineError("sources must be a non-empty bounded list")
    ids, paths = {}, set()
    for source in sources:
        if not isinstance(source, dict):
            raise PipelineError("source must be an object")
        sid = source.get("id")
        if not isinstance(sid, str) or not ID.fullmatch(sid) or sid in ids:
            raise PipelineError(f"invalid/duplicate source id: {sid!r}")
        path = safe_path(source.get("path"))
        folded = unicodedata.normalize("NFKC", path).casefold()
        if folded in paths or not path.lower().endswith(".png"):
            raise PipelineError(f"duplicate/non-PNG source: {path}")
        paths.add(folded)
        sha = source.get("sha256")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise PipelineError(f"invalid source digest: {sid}")
        if source.get("filter") not in ("nearest", "linear"):
            raise PipelineError(f"missing explicit filtering: {sid}")
        if source.get("kind") not in ("sheet", "prop_sheet", "sprite", "background"):
            raise PipelineError(f"invalid source kind: {sid}")
        if source["kind"] != "background" and source["filter"] != "nearest":
            raise PipelineError(f"pixel source must use nearest: {sid}")
        if source.get("mipmaps") is not False:
            raise PipelineError(f"first-playable sources must disable mipmaps: {sid}")
        regions_for(source)
        ids[sid] = source
    clips = recipe.get("clips", {})
    if not isinstance(clips, dict) or len(clips) > 16:
        raise PipelineError("clips must be a bounded object")
    for name, clip in clips.items():
        if not isinstance(name, str) or not ID.fullmatch(name) or not isinstance(clip, dict):
            raise PipelineError("invalid clip")
        _int(clip.get("ticks_per_frame"), 1, 120, "ticks_per_frame")
        if type(clip.get("loop")) is not bool:
            raise PipelineError("clip.loop must be boolean")
        _vector(clip.get("pivot"), 2, 0, 4096, "clip.pivot")
        layers = clip.get("layers")
        if (not isinstance(layers, list) or not 1 <= len(layers) <= 8
                or any(not isinstance(sid, str) for sid in layers) or len(set(layers)) != len(layers)):
            raise PipelineError("clip.layers must be a unique ordered list")
        counts, sizes = set(), set()
        for sid in layers:
            if sid not in ids:
                raise PipelineError(f"unknown clip source: {sid}")
            regions = regions_for(ids[sid])
            counts.add(len(regions))
            sizes.update(tuple(r["rect"][2:]) for r in regions)
        if len(counts) != 1 or len(sizes) != 1:
            raise PipelineError(f"layer frame counts/geometry disagree: {name}")
        w, h = next(iter(sizes))
        if clip["pivot"][0] > w or clip["pivot"][1] > h:
            raise PipelineError(f"pivot outside frame: {name}")
    return copy.deepcopy(recipe)


def _verify_pixels(data: bytes, source: dict) -> None:
    if digest(data) != source["sha256"]:
        raise PipelineError(f"source hash mismatch: {source['path']}")
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != "PNG" or list(image.size) != source["size"]:
                raise PipelineError(f"PNG dimensions/format mismatch: {source['path']}")
            if image.width * image.height > MAX_IMAGE_PIXELS:
                raise PipelineError("image pixel budget exceeded")
            image.verify()
    except (OSError, Image.DecompressionBombError) as exc:
        raise PipelineError(f"cannot decode selected image: {source['path']}") from exc


def read_selected(archive: Path, prefix: str, recipe: dict) -> dict[str, bytes]:
    """Never extractall(). Unselected/forbidden ZIP contents are never decoded."""
    recipe = validate_recipe(recipe)
    safe_path(prefix)
    selected = {prefix + "/" + s["path"]: s for s in recipe["sources"]}
    result = {}
    try:
        with zipfile.ZipFile(archive) as zf:
            infos = zf.infolist()
            if len(infos) > MAX_ARCHIVE_ENTRIES:
                raise PipelineError("archive entry budget exceeded")
            index = {}
            for info in infos:
                if info.filename in selected:
                    if info.filename in index:
                        raise PipelineError(f"duplicate selected ZIP member: {info.filename}")
                    index[info.filename] = info
            total = 0
            for name, source in selected.items():
                if name not in index:
                    raise PipelineError(f"missing selected source: {name}")
                info = index[name]
                if stat.S_ISLNK(info.external_attr >> 16) or info.is_dir() or info.flag_bits & 1:
                    raise PipelineError(f"selected source is link/directory/encrypted: {name}")
                if not 0 < info.file_size <= MAX_MEMBER_BYTES:
                    raise PipelineError(f"member size budget exceeded: {name}")
                total += info.file_size
                if total > MAX_SELECTED_BYTES:
                    raise PipelineError("selected source byte budget exceeded")
                data = zf.read(info)
                _verify_pixels(data, source)
                result[source["id"]] = data
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        raise PipelineError(f"cannot read source archive: {exc}") from exc
    return result


def import_preset(runtime_path: str) -> bytes:
    # Filtering is a CanvasItem property in Godot 4, NOT an import flag.
    return ("[remap]\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\n\n"
            f"[deps]\nsource_file={json.dumps(runtime_path)}\n\n[params]\n"
            "compress/mode=0\nmipmaps/generate=false\nprocess/size_limit=0\n"
            "process/fix_alpha_border=true\nprocess/premult_alpha=false\n"
            "detect_3d/compress_to=0\n").encode()


def atlas_resource(runtime_path: str, rect: list[int]) -> bytes:
    return ("[gd_resource type=\"AtlasTexture\" load_steps=2 format=3]\n\n"
            f"[ext_resource type=\"Texture2D\" path={json.dumps(runtime_path, ensure_ascii=False)} id=\"1\"]\n\n"
            "[resource]\natlas = ExtResource(\"1\")\n"
            f"region = Rect2({', '.join(map(str, rect))})\nfilter_clip = true\n").encode()


def registry_additions(recipe: dict, archive_hash: str, prefix: str = "zerkov") -> list[dict]:
    recipe = validate_recipe(recipe)
    safe_path(prefix)
    if not isinstance(archive_hash, str) or not SHA.fullmatch(archive_hash):
        raise PipelineError("invalid archive digest")
    result = []
    for source in sorted(recipe["sources"], key=lambda row: row["id"]):
        path = "assets/original/" + source["path"]
        result.append({
            "id": "zerkov.asset." + source["id"], "aliases": [source["id"]],
            "runtime_path": "res://" + path, "availability": "imported",
            "provenance": {"source_root": "res://", "source_relative_path": path,
                           "source_status": "available", "source_sha256": source["sha256"],
                           "origin_archive_sha256": archive_hash,
                           "origin_member": prefix + "/" + source["path"]},
            "runtime_sha256": source["sha256"], "family": "task9_selected_source",
            "kind": source["kind"],
            "filtering": {"mode": source["filter"], "mipmaps": False},
            "license": {"status": "blocked", "name": None, "reference": LICENSE_REFERENCE,
                        "reason": "User-supplied source for internal development; distribution provenance is still pending."},
            "content_links": [],
            "notes": "Explicit region/pivot semantics: res://game/content/art/slice_recipe.json. No inferred gameplay geometry.",
        })
    return result


def merge_registry(base: dict, additions: list[dict]) -> dict:
    """Promote exact IDs while preserving authoring metadata and license status."""
    if type(base.get("schema_version")) is not int or base["schema_version"] != 1 or base.get("registry_id") != "zerkov.assets":
        raise PipelineError("unsupported base asset registry")
    if not isinstance(base.get("assets"), list) or not isinstance(base.get("distribution_blockers"), list):
        raise PipelineError("malformed base registry")
    candidate = copy.deepcopy(base)
    by_id = {}
    for entry in candidate["assets"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or entry["id"] in by_id:
            raise PipelineError("malformed/duplicate base registry identity")
        by_id[entry["id"]] = entry
    added_ids = set()
    for incoming in additions:
        addition = copy.deepcopy(incoming)
        sid = addition["id"]
        if sid in added_ids:
            raise PipelineError(f"duplicate promotion identity: {sid}")
        added_ids.add(sid)
        old = by_id.get(sid)
        if old is not None:
            old_hash = old.get("runtime_sha256") or old.get("provenance", {}).get("source_sha256")
            if old_hash != addition["runtime_sha256"]:
                raise PipelineError(f"registry identity has different source bytes: {sid}")
            # Start from the whole accepted record; update only materialization
            # fields. In particular keep atlas/frame order, semantic manifests,
            # aliases, content links, family, kind, notes and license evidence.
            promoted = copy.deepcopy(old)
            for field in ("runtime_path", "runtime_sha256", "availability", "provenance"):
                promoted[field] = addition[field]
            promoted["aliases"] = list(dict.fromkeys(old.get("aliases", []) + addition["aliases"]))
            addition = promoted
        by_id[sid] = addition
    aliases, paths = {}, {}
    for sid, entry in by_id.items():
        for alias in entry.get("aliases", []):
            key = unicodedata.normalize("NFKC", alias).casefold()
            if key in aliases and aliases[key] != sid:
                raise PipelineError(f"registry alias collision: {alias}")
            if key in by_id:
                raise PipelineError(f"registry alias/identity collision: {alias}")
            aliases[key] = sid
        path = entry.get("runtime_path", "")
        key = unicodedata.normalize("NFKC", path).casefold()
        if path and key in paths and paths[key] != sid:
            raise PipelineError(f"registry runtime path collision: {path}")
        if path:
            paths[key] = sid
    candidate["assets"] = [by_id[sid] for sid in sorted(by_id)]
    return candidate


def build_plan(recipe: dict, selected: dict[str, bytes], archive_hash: str,
               registry: dict | None = None, prefix: str = "zerkov") -> dict[str, bytes]:
    recipe = validate_recipe(recipe)
    safe_path(prefix)
    if not isinstance(archive_hash, str) or not SHA.fullmatch(archive_hash):
        raise PipelineError("invalid archive digest")
    if set(selected) != {s["id"] for s in recipe["sources"]}:
        raise PipelineError("selected source set must exactly match the recipe")
    plan, runtime_sources = {}, {}
    for source in sorted(recipe["sources"], key=lambda row: row["id"]):
        sid = source["id"]
        data = selected[sid]
        if not isinstance(data, bytes):
            raise PipelineError(f"missing/unverified source bytes: {sid}")
        _verify_pixels(data, source)
        path = "assets/original/" + source["path"]
        plan[path] = data
        plan[path + ".import"] = import_preset("res://" + path)
        regions = regions_for(source)
        runtime_sources[sid] = {"path": "res://" + path, "filter": source["filter"], "regions": regions}
        for region in regions:
            plan[f"game/content/art/slices/{sid}/{region['name']}.tres"] = atlas_resource("res://" + path, region["rect"])
    clips = copy.deepcopy(recipe.get("clips", {}))
    for clip in clips.values():
        clip["frame_count"] = len(runtime_sources[clip["layers"][0]]["regions"])
    runtime = {"schema_version": 1, "sources": runtime_sources, "clips": clips,
               "distribution_status": recipe["distribution_status"]}
    plan["game/content/art/runtime_art.json"] = json_bytes(runtime)
    additions = registry_additions(recipe, archive_hash, prefix)
    plan["game/content/art/registry_additions.json"] = json_bytes({"assets": additions})
    if registry is not None:
        plan["game/content/asset_registry.json"] = json_bytes(merge_registry(registry, additions))
    receipt = {"schema_version": 1, "archive_sha256": archive_hash,
               "recipe_sha256": digest(json_bytes(recipe)), "source_count": len(selected),
               "region_count": sum(len(regions_for(s)) for s in recipe["sources"]),
               "distribution_status": recipe["distribution_status"],
               "files": {path: digest(data) for path, data in sorted(plan.items())}}
    plan["game/content/art/build_receipt.json"] = json_bytes(receipt)
    return plan


def publish_new_directory(plan: dict[str, bytes], output: Path) -> None:
    """Create-only publication; cooperative writers serialized by an exclusive lock.

    Parent directory must be trusted (not shared with hostile local writers).
    This is a development compiler, not a filesystem privilege boundary.
    """
    for path, data in plan.items():
        safe_path(path)
        if not isinstance(data, bytes):
            raise PipelineError(f"non-byte output: {path}")
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise PipelineError(f"output already exists: {output}")
    if not output.parent.is_dir():
        raise PipelineError("output parent must already exist")
    lock = output.parent / ("." + output.name + ".art-lock")
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise PipelineError(f"another build owns output lock: {lock}") from exc
    staging = None
    try:
        os.close(fd)
        staging = Path(tempfile.mkdtemp(prefix=".art-stage-", dir=output.parent))
        for path, data in sorted(plan.items()):
            target = staging / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        if output.exists() or output.is_symlink():
            raise PipelineError("output appeared during build; refusing replacement")
        staging.rename(output)
        staging = None
    finally:
        if staging is not None:
            shutil.rmtree(staging)
        lock.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--prefix", default="zerkov")
    parser.add_argument("--recipe", type=Path, default=DEFAULT_RECIPE)
    parser.add_argument("--registry", type=Path, help="Emit a merged candidate without editing the original registry")
    parser.add_argument("--output", type=Path, help="New directory only; omit for no-write preflight")
    args = parser.parse_args()
    try:
        recipe = validate_recipe(read_json(args.recipe))
        selected = read_selected(args.archive, args.prefix, recipe)
        with args.archive.open("rb") as stream:
            archive_hash = hashlib.file_digest(stream, "sha256").hexdigest()
        registry = read_json(args.registry) if args.registry else None
        plan = build_plan(recipe, selected, archive_hash, registry, args.prefix)
        if args.output:
            publish_new_directory(plan, args.output)
        print(f"ART_PIPELINE_RESULT sources={len(selected)} regions={sum(len(regions_for(s)) for s in recipe['sources'])} "
              f"files={len(plan)} failures=0 wrote={bool(args.output)} distribution=blocked")
        return 0
    except (PipelineError, OSError) as exc:
        print(f"ART_PIPELINE_BLOCKED: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
