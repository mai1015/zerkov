#!/usr/bin/env python3
"""Pack eight explicitly selected supplied idle/walk sheets; no invented frames.
This fixed review outfit is not an equipped-inventory projection or a license grant.
"""
from __future__ import annotations
import argparse, hashlib, io, json, zipfile
from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parents[1]
MEMBERS = [
    'skins legs/idle-legs_brown_jeans.png',
    'skins torso/idle-torso_green_hoodie.png',
    'Skins arms/idle-arms_green_hoodie.png',
    'Animations/Idle/idle_head.png',
    'skins legs/walk_legs_brown_jeans.png',
    'skins torso/walk_torso_green_hoodiepng.png',
    'Skins arms/walk-arms_green_hoodies.png',
    'Animations/Walk/walk-head.png',
]
EXPECTED_ARCHIVE = 'ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006'
def build(archive: Path, output: Path) -> None:
    with archive.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != EXPECTED_ARCHIVE:
            raise ValueError('Wrong source archive')
    atlas = Image.new('RGBA', (384, 512))
    records = []
    with zipfile.ZipFile(archive) as source:
        for row, relative in enumerate(MEMBERS):
            member = 'zerkov/Main character/' + relative
            entries = [info for info in source.infolist() if info.filename == member]
            if len(entries) != 1 or entries[0].file_size > 1024 * 1024:
                raise ValueError('Missing/duplicate/oversized source: ' + member)
            raw = source.read(entries[0])
            with Image.open(io.BytesIO(raw)) as frame:
                if frame.format != 'PNG' or frame.size != (384, 64):
                    raise ValueError('Sheet geometry mismatch: ' + member)
                rgba = frame.convert('RGBA')
                atlas.paste(rgba, (0, row * 64))
                records.append({'member': member, 'sha256': hashlib.sha256(raw).hexdigest(),
                                'rgba_sha256': hashlib.sha256(rgba.tobytes()).hexdigest(), 'row': row})
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'review_outfit.webp'
    atlas.save(target, 'WEBP', lossless=True, exact=True, method=6)
    with Image.open(target) as check:
        if check.convert('RGBA').tobytes() != atlas.tobytes():
            raise ValueError('Lossless RGBA round-trip failed')
    record = {'schema_version': 1, 'source_archive_sha256': EXPECTED_ARCHIVE,
              'purpose': 'fixed clothed review actor; not inventory-backed equipment',
              'license_status': 'user_supplied_internal_development_no_distribution_grant_claimed',
              'frame_size': [64, 64], 'frame_count': 6, 'feet_pivot': [32, 48],
              'atlas_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
              'atlas_rgba_sha256': hashlib.sha256(atlas.tobytes()).hexdigest(), 'sources': records}
    (output/'review_outfit.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'review_outfit.webp.import').write_text('[remap]\nimporter="texture"\ntype="CompressedTexture2D"\n\n[deps]\nsource_file="res://assets/world/northline_zone/review_outfit.webp"\n\n[params]\ncompress/mode=0\nmipmaps/generate=false\nprocess/size_limit=0\nprocess/fix_alpha_border=true\n')
    print('REVIEW_OUTFIT_RESULT sheets=8 frames_per_clip=6 rgba_lossless=true')
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'assets/world/northline_zone')
    args = parser.parse_args()
    build(args.archive, args.output)
