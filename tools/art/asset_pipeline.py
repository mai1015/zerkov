#!/usr/bin/env python3
"""Task 9.2/9.3 candidate: read-only import audit and explicit atlas compiler.

Standard library only. No downloads, Godot launch, source-art copying, gameplay
mutation, or release-license approval. See docs/qa/art_pipeline/README.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
import unicodedata
import zlib
import xml.etree.ElementTree as ET
from typing import Any

MANIFEST = "game/content/asset_registry.json"
OUTPUT = "game/presentation/generated_art"
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_FRAMES = 4096
MAX_TOTAL_FRAMES = 8192
MAX_ASSETS = 4096
ASSET_ID = re.compile(r"zerkov\.asset\.[a-z0-9_]+(?:\.[a-z0-9_]+)*\Z")
ALIAS = re.compile(r"[a-z0-9][a-z0-9._-]*\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
FORBIDDEN = (
    "do not use", "ui/steam exports", "ui/ux", "implementation-guide",
)
PIXEL_KINDS = {"sprite", "icon", "tile", "atlas", "sheet", "font", "prop_sheet"}
IMPORTED = {"imported", "imported_source_missing"}


class AssetError(ValueError):
    """An actionable, fail-closed asset-pipeline error."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssetError(message)


def strict_json(text: str) -> Any:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result

    def constant(value: str) -> None:
        raise AssetError(f"Non-finite JSON number: {value}")

    try:
        return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)
    except (json.JSONDecodeError, RecursionError) as exc:
        raise AssetError(f"Invalid registry JSON: {exc}") from exc


def normalized(value: str) -> str:
    return unicodedata.normalize("NFKC", value).replace("\\", "/").casefold()


def forbidden(value: str, markers: list[str]) -> bool:
    candidate = normalized(value)
    return any(normalized(marker) in candidate for marker in (*FORBIDDEN, *markers))


def confined(root: Path, relative: str) -> Path:
    """Require a strict relative path and reject every existing symlink component."""
    require(isinstance(relative, str) and bool(relative), "Empty/non-string path")
    require(not any(ord(char) < 32 for char in relative), "Control character in path")
    require("\\" not in relative and ":" not in relative, f"Non-portable path: {relative}")
    parts = relative.split("/")
    require(all(part not in {"", ".", ".."} for part in parts), f"Unsafe path: {relative}")
    current = root
    for part in parts:
        current = current / part
        require(not current.is_symlink(), f"Symlink is not allowed: {relative}")
    require(current.resolve().is_relative_to(root.resolve()), f"Path escapes project: {relative}")
    return current


def read_bytes(path: Path) -> bytes:
    require(path.is_file(), f"Missing regular file: {path}")
    require(path.stat().st_size <= MAX_FILE_BYTES, f"File exceeds byte budget: {path}")
    with path.open("rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    require(len(data) <= MAX_FILE_BYTES, f"File exceeds byte budget: {path}")
    return data


def png_size(data: bytes) -> tuple[int, int]:
    # Header validation is deliberately NOT a native texture-decode claim.
    require(len(data) >= 33 and data[:8] == b"\x89PNG\r\n\x1a\n", "Invalid PNG signature/header")
    require(data[8:16] == b"\x00\x00\x00\rIHDR", "PNG must start with a 13-byte IHDR")
    require(zlib.crc32(data[12:29]) == struct.unpack(">I", data[29:33])[0], "PNG IHDR CRC mismatch")
    width, height = struct.unpack(">II", data[16:24])
    require(0 < width <= 32768 and 0 < height <= 32768, "PNG dimensions exceed budget")
    return width, height


def svg_size(data: bytes) -> tuple[int, int]:
    require(re.search(br"<!\s*(?:DOCTYPE|ENTITY)\b", data, re.IGNORECASE) is None, "SVG entity/doctype declarations are unsupported")
    try:
        svg = ET.fromstring(data)
    except (ET.ParseError, ValueError) as exc:
        raise AssetError(f"Invalid SVG XML: {exc}") from exc
    require(svg.tag in {"svg", "{http://www.w3.org/2000/svg}svg"}, "Expected SVG root")
    dimensions: list[int] = []
    for key in ("width", "height"):
        text = svg.get(key, "")
        require(re.fullmatch(r"[1-9][0-9]{0,4}(?:px)?", text) is not None, "SVG needs explicit positive integer pixel dimensions")
        dimensions.append(positive(int(text.removesuffix("px")), f"SVG {key}"))
    return dimensions[0], dimensions[1]


def positive(value: Any, label: str) -> int:
    require(type(value) is int and 0 < value <= 32768, f"{label} must be a bounded JSON integer")
    return value


def atlas_regions(atlas: Any, size: tuple[int, int]) -> list[tuple[int, int, int, int]]:
    require(isinstance(atlas, dict), "Explicit atlas metadata is required; no filename inference")
    allowed = {"source_size", "cell_size", "columns", "rows", "frame_count", "frame_order"}
    require(not (set(atlas) - allowed), "Unsupported atlas metadata; do not silently ignore offsets/crops")
    pairs: dict[str, tuple[int, int]] = {}
    for key in ("source_size", "cell_size"):
        pair = atlas.get(key)
        require(isinstance(pair, list) and len(pair) == 2, f"{key} must be an integer pair")
        pairs[key] = (positive(pair[0], key), positive(pair[1], key))
    require(pairs["source_size"] == size, "Atlas source_size differs from image dimensions")
    columns = positive(atlas.get("columns"), "columns")
    rows = positive(atlas.get("rows"), "rows")
    count = positive(atlas.get("frame_count"), "frame_count")
    require(count == columns * rows and count <= MAX_FRAMES, "Atlas frame count/budget mismatch")
    width, height = pairs["cell_size"]
    require(columns * width <= size[0] and rows * height <= size[1], "Atlas grid exceeds source bounds")
    order = atlas.get("frame_order", list(range(count)))
    require(isinstance(order, list) and len(order) == count, "frame_order must enumerate every cell")
    require(all(type(frame) is int for frame in order), "frame_order requires exact JSON integers")
    require(set(order) == set(range(count)), "frame_order must be a complete, unique in-range permutation")
    return [((frame % columns) * width, (frame // columns) * height, width, height) for frame in order]


def import_preset(entry: dict[str, Any]) -> dict[str, Any]:
    policy = entry.get("filtering")
    require(isinstance(policy, dict), "Missing filtering policy")
    mode, mipmaps = policy.get("mode"), policy.get("mipmaps")
    require(mode in ("nearest", "linear") and type(mipmaps) is bool, "Invalid filtering policy")
    kind = entry.get("kind")
    require(isinstance(kind, str) and bool(kind), "Invalid asset kind")
    if kind in PIXEL_KINDS:
        require(mode == "nearest" and mipmaps is False, "Pixel assets require nearest and no mipmaps")
    return {
        "canvas_texture_filter": 1 if mode == "nearest" else 2,
        "params": {"compress/mode": "0", "mipmaps/generate": str(mipmaps).lower(), "process/size_limit": "0"},
    }


def inspect_import(text: str, runtime_path: str, preset: dict[str, Any]) -> None:
    """Check exact scalar fields in an editor-generated texture sidecar.

    This is not a general ConfigFile parser or a substitute for Godot import.
    Opaque importer metadata is retained and never evaluated or rewritten.
    """
    section = ""
    sections: set[str] = set()
    values: dict[tuple[str, str], str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(";"):
            continue
        match = re.fullmatch(r"\[([a-zA-Z0-9_]+)\]", stripped)
        if match:
            section = match[1]
            require(section not in sections, f"Duplicate import section: {section}")
            sections.add(section)
        elif "=" in stripped:
            key, value = stripped.split("=", 1)
            identity = (section, key.strip())
            require(identity not in values, f"Duplicate import key: {identity}")
            values[identity] = value.strip()
    expected = {
        ("remap", "importer"): '"texture"',
        ("remap", "type"): '"CompressedTexture2D"',
        ("deps", "source_file"): json.dumps(runtime_path, ensure_ascii=False),
        **{("params", key): value for key, value in preset["params"].items()},
    }
    for key, value in expected.items():
        require(values.get(key) == value, f"Import mismatch {key[0]}/{key[1]}: expected {value}, got {values.get(key)!r}")


class Pipeline:
    def __init__(self, root: Path):
        self.root = root.resolve()
        data = read_bytes(confined(self.root, MANIFEST))
        self.manifest_sha256 = hashlib.sha256(data).hexdigest()
        manifest = strict_json(data.decode("utf-8"))
        require(isinstance(manifest, dict), "Registry must be an object")
        require(type(manifest.get("schema_version")) is int and manifest["schema_version"] == 1, "Unsupported registry schema")
        require(manifest.get("registry_id") == "zerkov.assets", "Wrong registry identity")
        markers = manifest.get("forbidden_paths")
        require(isinstance(markers, list) and all(isinstance(item, str) and item for item in markers), "Invalid forbidden_paths")
        self.markers: list[str] = markers
        entries = manifest.get("assets")
        require(isinstance(entries, list) and 0 < len(entries) <= MAX_ASSETS, "Invalid/empty asset list or asset budget exceeded")
        self.entries: dict[str, dict[str, Any]] = {}
        self.lookup: dict[str, str] = {}
        paths: set[str] = set()
        for entry in entries:
            require(isinstance(entry, dict), "Asset entry must be an object")
            identity = entry.get("id")
            require(isinstance(identity, str) and ASSET_ID.fullmatch(identity) is not None, "Invalid asset ID")
            aliases = entry.get("aliases")
            require(isinstance(aliases, list) and all(isinstance(alias, str) and ALIAS.fullmatch(alias) for alias in aliases), f"Invalid aliases: {identity}")
            for key in [identity, *aliases]:
                require(key not in self.lookup, f"Duplicate/colliding asset ID or alias: {key}")
                self.lookup[key] = identity
            availability = entry.get("availability")
            require(isinstance(availability, str) and availability in IMPORTED | {"pending_unimported"}, f"Unknown availability: {identity}")
            path = entry.get("runtime_path")
            if availability == "pending_unimported":
                require(path == "" and entry.get("runtime_sha256") is None, f"Pending asset has runtime data: {identity}")
            else:
                require(isinstance(path, str) and path.startswith("res://assets/"), f"Runtime path outside assets: {identity}")
                confined(self.root, path[6:])
                require(not forbidden(path, self.markers), f"Forbidden runtime path: {identity}")
                require(normalized(path) not in paths, f"Duplicate/case-colliding runtime path: {path}")
                paths.add(normalized(path))
                digest = entry.get("runtime_sha256")
                require(isinstance(digest, str) and SHA256.fullmatch(digest) is not None, f"Invalid runtime SHA-256: {identity}")
            provenance = entry.get("provenance")
            require(isinstance(provenance, dict), f"Missing provenance: {identity}")
            source_root, source_relative = provenance.get("source_root"), provenance.get("source_relative_path")
            require(isinstance(source_root, str) and isinstance(source_relative, str), f"Invalid provenance paths: {identity}")
            require(not forbidden(source_root + "/" + source_relative, self.markers), f"Forbidden provenance: {identity}")
            import_preset(entry)
            self.entries[identity] = entry
        self.distribution_blockers = manifest.get("distribution_blockers", [])

    def scan_forbidden(self) -> None:
        assets = confined(self.root, "assets")
        require(assets.is_dir(), "Missing runtime assets directory")
        def failed(error: OSError) -> None:
            raise AssetError(f"Cannot inspect runtime assets: {error}") from error
        for parent, directories, filenames in os.walk(assets, followlinks=False, onerror=failed):
            for name in sorted(directories + filenames):
                path = Path(parent) / name
                relative = path.relative_to(self.root).as_posix()
                require(not path.is_symlink(), f"Symlink in runtime assets: {relative}")
                require(not forbidden(relative, self.markers), f"Forbidden runtime asset: {relative}")

    def audit(self) -> dict[str, Any]:
        self.scan_forbidden()
        images: dict[str, dict[str, Any]] = {}
        pending: list[str] = []
        non_texture: list[str] = []
        for identity, entry in sorted(self.entries.items()):
            if entry["availability"] == "pending_unimported":
                pending.append(identity)
                continue
            path = confined(self.root, entry["runtime_path"][6:])
            data = read_bytes(path)
            require(hashlib.sha256(data).hexdigest() == entry["runtime_sha256"], f"Runtime SHA-256 mismatch: {identity}")
            suffix = path.suffix.casefold()
            if suffix not in {".png", ".svg"}:
                non_texture.append(identity)
                continue
            size = png_size(data) if suffix == ".png" else svg_size(data)
            preset = import_preset(entry)
            if suffix == ".svg":
                preset["params"].update({"svg/scale": "1.0", "editor/scale_with_editor_scale": "false", "editor/convert_colors_with_editor_theme": "false"})
            sidecar = confined(self.root, entry["runtime_path"][6:] + ".import")
            inspect_import(read_bytes(sidecar).decode("utf-8"), entry["runtime_path"], preset)
            regions = atlas_regions(entry["atlas"], size) if "atlas" in entry else None
            images[identity] = {"runtime_path": entry["runtime_path"], "runtime_sha256": entry["runtime_sha256"], "size": list(size), "preset": preset, "regions": regions}
        return {
            "schema_version": 1, "manifest_sha256": self.manifest_sha256,
            "textures": images, "pending_unimported": pending,
            "non_texture_hash_checked_only": non_texture,
            "distribution_blockers": self.distribution_blockers,
            "native_validation": "not_run", "distribution_approval": "not_evaluated",
        }

    def compile(self, selectors: list[str]) -> dict[str, bytes]:
        require(bool(selectors), "Select at least one exact asset ID or alias")
        identities: list[str] = []
        for selector in selectors:
            require(selector in self.lookup, f"Unknown exact asset ID/alias: {selector}")
            identity = self.lookup[selector]
            require(identity not in identities, f"Duplicate selection: {identity}")
            require(self.entries[identity]["availability"] in IMPORTED, f"Asset is pending/unimported: {identity}")
            identities.append(identity)
        report = self.audit()  # Complete preflight before generating or writing anything.
        files: dict[str, bytes] = {}
        index: dict[str, Any] = {"schema_version": 1, "manifest_sha256": self.manifest_sha256, "native_validation": "not_run", "distribution_approval": "not_evaluated", "assets": []}
        total = 0
        for identity in sorted(identities):
            image = report["textures"].get(identity)
            require(image is not None and image["regions"] is not None, f"Explicit PNG/SVG atlas metadata is required: {identity}")
            total += len(image["regions"])
            require(total <= MAX_TOTAL_FRAMES, "Total frame budget exceeded")
            frame_paths: list[str] = []
            for number, region in enumerate(image["regions"]):
                stem = f"{identity}/frame_{number:04d}"
                source = json.dumps(image["runtime_path"], ensure_ascii=False)
                rect = ", ".join(map(str, region))
                texture = f'[gd_resource type="AtlasTexture" load_steps=2 format=3]\n\n[ext_resource type="Texture2D" path={source} id="1"]\n\n[resource]\natlas = ExtResource("1")\nregion = Rect2({rect})\nfilter_clip = true\n'
                # Filtering lives on the CanvasItem in Godot 4, not a PNG import flag.
                scene = f'[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Texture2D" path="frame_{number:04d}.tres" id="1"]\n\n[node name="Frame" type="Sprite2D"]\ntexture_filter = {image["preset"]["canvas_texture_filter"]}\ntexture = ExtResource("1")\ncentered = false\n'
                files[stem + ".tres"] = texture.encode("utf-8")
                files[stem + ".tscn"] = scene.encode("utf-8")
                frame_paths.append(stem + ".tscn")
            index["assets"].append({"id": identity, "runtime_sha256": image["runtime_sha256"], "frames": frame_paths, "regions": image["regions"], "preset": image["preset"]})
        files["index.json"] = (json.dumps(index, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        return files


def publish(root: Path, files: dict[str, bytes]) -> bool:
    """Create-only directory publication; identical reruns are read-only.

    Assumes a single local writer. There is no overwrite, deletion, crash-durable
    transaction, or claim of safety against concurrent filesystem replacement.
    """
    require(bool(files), "Cannot publish an empty compilation")
    root = root.resolve()
    destination = confined(root, OUTPUT)
    for relative in files:
        confined(destination, relative)
    if destination.exists():
        require(destination.is_dir(), "Output exists and is not a directory")
        found: dict[str, bytes] = {}
        def failed(error: OSError) -> None:
            raise AssetError(f"Cannot inspect existing output: {error}") from error
        for parent, directories, names in os.walk(destination, followlinks=False, onerror=failed):
            for name in directories + names:
                require(not (Path(parent) / name).is_symlink(), "Symlink in existing output")
            for name in names:
                path = Path(parent) / name
                found[path.relative_to(destination).as_posix()] = read_bytes(path)
        require(found == files, "Output differs; choose an explicit reviewed cleanup before regenerating")
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".art-stage-", dir=destination.parent))
    try:
        for relative, data in sorted(files.items()):
            path = confined(staging, relative)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        require(not destination.exists(), "Output appeared during publication")
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("audit", "compile"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--asset", action="append", default=[], help="Exact registry ID or alias; repeat explicitly")
    parser.add_argument("--write", action="store_true", help=f"Create-only output at {OUTPUT}; default is read-only")
    args = parser.parse_args(argv)
    try:
        require(args.command == "compile" or (not args.write and not args.asset), "audit does not accept --write or --asset")
        pipeline = Pipeline(args.root)
        if args.command == "audit":
            result = pipeline.audit()
        else:
            files = pipeline.compile(args.asset)
            written = publish(args.root, files) if args.write else False
            result = {"written": written, "file_count": len(files), "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())}, "native_validation": "not_run"}
        print(json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2))
        return 0
    except (AssetError, OSError, UnicodeError) as exc:
        print(f"ASSET_PIPELINE_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
