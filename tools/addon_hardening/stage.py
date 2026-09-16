#!/usr/bin/env python3
"""Reproduce a hash-pinned addon candidate in a NEW outside directory.
Never edits the checkout, its addons, manifests or lock. No remote downloads.
"""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, sys
ALLOWED = {
 'addons/weapon_system/native/godot/weapon_network_bridge.cpp',
 'addons/weapon_system/native/godot/weapon_network_bridge.h',
 'addons/weapon_system/native/protocol/wpn_replica.cpp',
 'addons/weapon_system/native/protocol/wpn_replica.h',
 'addons/gameplay_abilities/native/godot/gameplay_ability_network_bridge.cpp',
 'addons/gameplay_abilities/native/godot/gameplay_ability_network_bridge.h',
}
def sha(data): return hashlib.sha256(data).hexdigest()
def safe(root, name):
 path=Path(name)
 if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name: raise ValueError('invalid path '+name)
 p=root
 for part in path.parts:
  p=p/part
  if p.is_symlink(): raise ValueError('symlink rejected '+name)
 return p

def stage(root, out):
 root=root.resolve(); out=out.resolve()
 if out.is_relative_to(root) or root.is_relative_to(out) or out.exists(): raise ValueError('candidate must be a NEW outside directory')
 manifest=json.loads((root/'tools/addon_hardening/changes.json').read_text())
 if {r['path'] for r in manifest['changes']}!=ALLOWED or len(manifest['changes'])!=len(ALLOWED): raise ValueError('unexpected changes')
 files={}
 for row in manifest['changes']:
  before=safe(root,row['path']).read_bytes()
  if sha(before)!=row['before']: raise ValueError('source base differs: '+row['path'])
  if 'replacement' in row:
   source='tools/addon_hardening/source/'+row['replacement']
   after=safe(root,source).read_bytes()
  else:
   after=before.decode()
   for edit in row['edits']:
    if not edit['old'] or after.count(edit['old'])!=1: raise ValueError('nonunique edit '+row['path'])
    after=after.replace(edit['old'],edit['new'],1)
   after=after.encode()
  if sha(after)!=row['after']: raise ValueError('candidate checksum differs '+row['path'])
  files[row['path']]=after
 # Copy source only, excluding machine outputs and the old native libraries.
 for addon in ['weapon_system','gameplay_abilities']:
  base=safe(root,'addons/'+addon)
  for source in sorted(base.rglob('*')):
   if source.is_symlink(): raise ValueError('addon contains symlink')
   if source.is_file() and source.suffix in {'.cpp','.h','.hpp','.gd','.uid','.tscn','.tres','.json','.gdextension','.md','.cfg'}:
    target=out/source.relative_to(root);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
 for path,data in files.items(): (out/path).write_bytes(data)
 (out/'candidate-source.json').write_text(json.dumps({'schema_version':1,'status':'candidate_not_installed',
  'base_addon_lock_sha256':sha((root/'config/addons.lock.json').read_bytes()),
  'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
  'changed_files':{name:sha(data) for name,data in files.items()},'upstream_signoff':False},indent=2)+'\n')
 return files

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 try:
  stage(a.root,a.output);print('ADDON_CANDIDATE_STAGED installed=false')
 except (OSError,ValueError,KeyError,subprocess.SubprocessError) as e: print(str(e),file=sys.stderr);sys.exit(1)
