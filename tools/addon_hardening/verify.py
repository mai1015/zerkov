#!/usr/bin/env python3
"""Load only newly built addon candidates. No replacements in the source checkout."""
from pathlib import Path
import argparse,json,hashlib,shutil,subprocess,os,re,sys

def execute(args):
 p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150,env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1'})
 print(p.stdout,flush=True)
 if p.returncode or re.search(r'SCRIPT ERROR|(?m:^\s*ERROR:)',p.stdout):raise RuntimeError('native execution failed')
 return p.stdout

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--candidate',type=Path,required=True);p.add_argument('--godot',type=Path,required=True);p.add_argument('--platform',choices=['linux','macos','windows'],required=True);p.add_argument('--arch',required=True);p.add_argument('--target',choices=['template_debug','template_release'],required=True);a=p.parse_args()
 root=a.root.resolve();candidate=a.candidate.resolve();godot=a.godot.resolve()
 lock=json.loads((root/'config/toolchain.lock.json').read_text())
 assert execute([str(godot),'--version']).strip()==lock['engine']['required_version']
 project=candidate/('test-'+a.target)
 if project.exists():shutil.rmtree(project)
 project.mkdir()
 artifacts={}
 ext={'linux':'.so','macos':'.dylib','windows':'.dll'}[a.platform]
 for name in ['weapon_system','gameplay_abilities']:
  lib=candidate/'addons'/name/'bin'/f'lib{name}.{a.platform}.{a.target}.{a.arch}{ext}'
  if not lib.is_file():raise RuntimeError('missing newly-built '+str(lib))
  addon=project/'addons'/name;(addon/'bin').mkdir(parents=True)
  shutil.copyfile(lib,addon/'bin'/lib.name)
  artifacts[str(lib.relative_to(candidate))]=hashlib.sha256(lib.read_bytes()).hexdigest()
  descriptor=f'[configuration]\nentry_symbol = "{name}_library_init"\ncompatibility_minimum = "4.7"\nreloadable = false\n[libraries]\n'
  for target in ['debug','release']:
   key=f'{a.platform}.{target}'+('' if a.platform=='macos' else '.x86_64')
   descriptor+=f'{key} = "res://addons/{name}/bin/{lib.name}"\n'
  (addon/f'{name}.gdextension').write_text(descriptor)
 for path in ['game/combat/content/zerkov_combat_content.gd','game/combat/melee/melee_policy.gd','game/domain/z_world_units.gd','game/domain/z_unit_conversion.gd']:
  out=project/path;out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/path,out)
 (project/'contract.gd').write_text((root/'tools/addon_hardening/tests/bridge_contract.gd.in').read_text())
 (project/'project.godot').write_text('config_version=5\n[application]\nconfig/name="Native addon candidate security contract"\n[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
 base=[str(godot),'--headless','--resolution','1920x1080','--max-fps','120','--path',str(project),'--audio-driver','Dummy']
 execute(base+['--editor','--import','--quit'])
 output=execute(base+['--script','res://contract.gd'])
 if not re.search(r'(?m)^ADDON_HARDENING_RESULT checks=\d+ failures=0 real_enet_peers=3 native=true$',output):raise RuntimeError('missing native pass marker')
 report={'candidate_source':json.loads((candidate/'candidate-source.json').read_text()),'platform':a.platform,'arch':a.arch,'configuration':a.target,'engine':lock['engine']['required_version'],'artifacts':artifacts,'native_output':output,'upstream_signoff':False,'installed':False,'export_tested':False}
 (candidate/(a.target+'-verification.json')).write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':
 try:main()
 except (OSError,ValueError,KeyError,AssertionError,RuntimeError,subprocess.SubprocessError) as e:print('ADDON_HARDENING_FAILED',e,file=sys.stderr);sys.exit(1)
