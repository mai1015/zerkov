#!/usr/bin/env python3
"""Verify/rebuild the eight original character sheets into the review atlas.
Only these exact metadata members are read. No archive extraction or license clearance.
"""
from pathlib import Path
import argparse,hashlib,io,json,zipfile
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--archive',type=Path,required=True);parser.add_argument('--output',type=Path)
    args=parser.parse_args();record=json.loads((ROOT/'assets/world/northline_zone/review_walker.json').read_text())
    with args.archive.open('rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest()!=record['source_archive_sha256']:raise ValueError('Source archive mismatch')
    result=Image.new('RGBA',(384,512))
    with zipfile.ZipFile(args.archive) as z:
        names=z.namelist()
        for source in record['sources']:
            name=source['member']
            if names.count(name)!=1 or '..' in name.split('/') or 'do not use' in name.lower():raise ValueError('Invalid or duplicate selected member')
            entry=z.getinfo(name)
            if entry.file_size>2_000_000 or entry.is_dir():raise ValueError('Invalid member size/type')
            raw=z.read(entry)
            if hashlib.sha256(raw).hexdigest()!=source['sha256']:raise ValueError('Source bytes differ')
            with Image.open(io.BytesIO(raw)) as image:
                if image.size!=(384,64) or image.format!='PNG':raise ValueError('Unexpected source geometry')
                result.paste(image.convert('RGBA'),(0,source['row']*64))
    with Image.open(ROOT/'assets/world/northline_zone/review_walker.png') as committed:
        if committed.convert('RGBA').tobytes()!=result.tobytes():raise ValueError('Committed atlas pixels differ')
    if args.output:
        if args.output.exists():raise ValueError('Refusing to overwrite output')
        result.save(args.output,format='PNG',optimize=True)
    print('NORTHLINE_WALKER_SOURCE_RESULT sheets=8 pixels=identical failures=0')
if __name__=='__main__':main()
