#!/usr/bin/env python3
"""Real offline maps, isolated files and fresh-process receipt verification.

Requires the installed native addon packages and pinned Godot. Graphical mode
requires an exact 1920x1080 drawable; it never substitutes headless captures.
The test driver submits real input and paces canonical ticks for automation.
No frame-rate or cold export qualification is implied by functional success.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTIC = re.compile(r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR:|Parse Error:)|LIVE_MAP_BAD_|LIVE_MAP_\w+_ASSERT")
FLOW = re.compile(r"(?m)^LIVE_MAP_FLOW_RESULT checks=([1-9][0-9]*) failures=0 map=(sawmill|northline|blackwater) case=(\S+)$")
CORE = re.compile(r"(?m)^LIVE_MAP_CONTRACT_RESULT checks=([1-9][0-9]*) failures=0$")
FINGERPRINT = re.compile(r"(?m)^LIVE_MAP_FINGERPRINT ([a-f0-9]{64})$")


def validate_selection(maps: list[str], scenarios: list[str]) -> None:
    if not maps or len(set(maps)) != len(maps) or set(maps) - {'sawmill','northline','blackwater'}:
        raise ValueError('select distinct known maps')
    if not scenarios or len(set(scenarios)) != len(scenarios) or set(scenarios) - {'launch','extract','death'}:
        raise ValueError('select distinct known scenarios')


def check_output(text: str, code: int, marker: re.Pattern | None = None) -> re.Match | None:
    if code or DIAGNOSTIC.search(text):
        raise RuntimeError(f'native process/diagnostic failure: exit={code}')
    matches = list(marker.finditer(text)) if marker else []
    if marker and len(matches) != 1:
        raise RuntimeError('exactly one zero-failure completion marker required')
    return matches[0] if matches else None


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--maps',nargs='+',default=['sawmill','northline','blackwater'])
    parser.add_argument('--scenarios',nargs='+',default=['extract','death'])
    parser.add_argument('--graphical',action='store_true')
    args=parser.parse_args()
    report: dict={'cases':[],'failures':0,'complete':False,'scope':'real input-driven offline gameplay; not performance or release acceptance'}
    try:
        validate_selection(args.maps,args.scenarios)
        engine=str(args.godot.expanduser().resolve(strict=True))
        output=args.output.absolute()
        if output.exists() or output.is_symlink(): raise ValueError('output must be a new directory')
        output.mkdir(parents=True)
        required=json.loads((ROOT/'config/toolchain.lock.json').read_text())['engine']['required_version']
        env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1'}
        version=subprocess.run([engine,'--version'],env=env,capture_output=True,text=True,timeout=15)
        check_output(version.stdout+version.stderr,version.returncode)
        if version.stdout.strip()!=required:raise ValueError('engine differs from project lock')
        report.update(engine=required,graphical=args.graphical,maps=args.maps,scenarios=args.scenarios)
        def execute(name: str, command: list[str], marker: re.Pattern | None = None, timeout: int = 120) -> tuple[str,re.Match | None]:
            started=time.monotonic()
            print('LIVE_MAP_RUN_START',name,flush=True)
            try:
                p=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
                text,code=p.stdout,p.returncode
            except subprocess.TimeoutExpired as exc:
                data=exc.stdout or b'';text=data.decode(errors='replace') if isinstance(data,bytes) else data;code=124
            (output/(name+'.log')).write_text(text,encoding='utf-8')
            row={'name':name,'exit':code,'seconds':round(time.monotonic()-started,3),'passed':False}
            report['cases'].append(row)
            (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
            match=check_output(text,code,marker)
            row['passed']=True
            if match:row['checks']=int(match[1])
            print('LIVE_MAP_RUN_COMPLETE',json.dumps(row),flush=True)
            return text,match
        with tempfile.TemporaryDirectory(prefix='zerkov-live-map-') as temp:
            project=Path(temp)/'project'
            shutil.copytree(ROOT,project,ignore=shutil.ignore_patterns('.git','.godot','.codegraph','__pycache__','.native-sdk'))
            env['XDG_DATA_HOME']=str(Path(temp)/'user')
            base=[engine,'--path',str(project),'--resolution','1920x1080','--audio-driver','Dummy']
            execute('editor-import',base+['--headless','--editor','--import','--quit'],timeout=180)
            execute('map-contracts',base+['--headless','--script','res://tests/raid/live_maps_contract.gd'],CORE,180)
            mode=[] if args.graphical else ['--headless']
            flow=base+mode+['--script','res://tests/raid/live_maps_flow.gd','--']
            for map_id in args.maps:
                for scenario in args.scenarios:
                    ns='livemaps_'+uuid.uuid4().hex
                    name=map_id+'-'+scenario
                    captures=output/name;captures.mkdir()
                    try:
                        text,match=execute(name,flow+['run',ns,map_id,scenario,str(captures)],FLOW,900)
                        if match[2]!=map_id or match[3]!=scenario:raise RuntimeError('wrong scenario completion')
                        fp=FINGERPRINT.search(text)
                        if fp is None:raise RuntimeError('actual saved fingerprint required')
                        verify_base=base+['--headless','--script','res://tests/raid/live_maps_flow.gd','--']
                        for index in (1,2):
                            _,verified=execute(name+f'-verify{index}',verify_base+['verify',ns,map_id,fp[1]],FLOW)
                            if verified[2]!=map_id or verified[3]!=fp[1]:raise RuntimeError('wrong fresh-process receipt verification')
                        if args.graphical:
                            pngs=list(captures.glob('*.png'))
                            expected=2 if scenario=='launch' else 3
                            if len(pngs)!=expected:raise RuntimeError('missing native graphical evidence')
                            report.setdefault('screenshots',{}).update({p.relative_to(output).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in pngs})
                        report.setdefault('profiles',{})[name]=fp[1]
                    finally:
                        execute(name+'-cleanup',base+['--headless','--script','res://tests/raid/live_maps_flow.gd','--','cleanup',ns,map_id,'cleanup'],FLOW)
        report['complete']=True
        report['checks']=sum(row.get('checks',0) for row in report['cases'])
        (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print('LIVE_MAP_RUNNER_COMPLETE checks=%d failures=0'%report['checks'])
        return 0
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
        report['failures']=1;report['error']=str(exc)
        if 'output' in locals() and output.is_dir():
            (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print('LIVE_MAP_RUNNER_FAILED:',exc,flush=True)
        return 1

if __name__=='__main__':raise SystemExit(main())
