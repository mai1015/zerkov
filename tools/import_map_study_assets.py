#!/usr/bin/env python3
"""Rebuild the map-study atlas from the two user-supplied archives only.
No arbitrary extraction, external downloads, filename-derived geometry or new art.
The source manifest records every rectangle and the declared pixel normalization.
"""
from __future__ import annotations
import argparse, hashlib, io, json, zipfile
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]

def rebuild(source_dir: Path, output: Path) -> None:
    manifest=json.loads((ROOT/'assets/world/map_studies/atlas.json').read_text())
    sheets={}
    for name, expected in manifest['archives'].items():
        source=source_dir/name
        if hashlib.sha256(source.read_bytes()).hexdigest()!=expected:
            raise ValueError('archive hash mismatch: '+name)
    for key,row in manifest['sources'].items():
        with zipfile.ZipFile(source_dir/row['archive']) as zf:
            matches=[i for i in zf.infolist() if i.filename==row['member']]
            if len(matches)!=1 or not 0<matches[0].file_size<16*1024*1024:
                raise ValueError('ambiguous or oversized selected source')
            raw=zf.read(matches[0])
        if hashlib.sha256(raw).hexdigest()!=row['source_sha256']:
            raise ValueError('source hash mismatch: '+row['member'])
        with Image.open(io.BytesIO(raw)) as image:
            if list(image.size)!=row['size']:raise ValueError('source geometry mismatch')
            sheets[key]=image.convert('RGBA')
    atlas=Image.new('RGBA',tuple(manifest['atlas_size']))
    # Keep the original insertion order; the shared-palette pass is deterministic.
    for name,row in manifest['assets'].items():
        x,y,w,h=row['source_rect'];crop=sheets[str(row['source_index'])].crop((x,y,x+w,y+h))
        crop=crop.resize((w//3,h//3),Image.Resampling.NEAREST)
        crop=crop.crop(tuple(row['trim']))
        ax,ay,aw,ah=row['rect']
        if crop.size!=(aw,ah):raise ValueError('compiled size mismatch: '+name)
        atlas.alpha_composite(crop,(ax,ay))
    atlas=atlas.quantize(256,method=Image.Quantize.FASTOCTREE,dither=Image.Dither.NONE).convert('RGBA')
    target=io.BytesIO();atlas.save(target,format='WEBP',lossless=True,exact=True,method=6)
    result=target.getvalue()
    # A different codec can produce a different byte stream: never overwrite it silently.
    if hashlib.sha256(result).hexdigest()!=manifest['atlas_sha256']:
        raise ValueError('compiled hash differs; use the recorded Pillow version or review before replacing')
    if output.exists() and output.read_bytes()!=result:raise ValueError('destination has different bytes')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(result)
    print('MAP_ASSET_BUILD sources=%d regions=%d bytes=%d failures=0' % (len(sheets),len(manifest['assets']),len(result)))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rebuild(args.source_dir,args.output)
