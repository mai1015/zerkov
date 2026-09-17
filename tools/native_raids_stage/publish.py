"""One-use exact source transfer. Removed before PR review; never a game importer."""
from pathlib import Path, PurePosixPath
import base64, hashlib, json, lzma, os, re, shutil, subprocess, tempfile
R=Path.cwd()
S=R/'tools/native_raids_stage'
expected_pack='f8a8c821d78661d1dad35d054d62f5960b46d4dbcccf5627aeb52042e4b830ee'
expected_raw='f6a46d791ff4572f7dd01ec374fbdfbe5f41f4e5c2c40faa4d0c71ba1e2bbb05'
encoded=''.join((S/f'{i:02d}.b64').read_text() for i in range(11))
assert len(encoded)==61000
packed=base64.b64decode(encoded,validate=True)
assert hashlib.sha256(packed).hexdigest()==expected_pack
decoder=lzma.LZMADecompressor(memlimit=128*1024*1024)
raw=decoder.decompress(packed,max_length=250000)
assert decoder.eof and not decoder.unused_data and hashlib.sha256(raw).hexdigest()==expected_raw
packet=json.loads(raw)
assert set(packet)=={'version','files','blackwater'} and packet['version']==1
rows=packet['files']; assert len(rows)==39 and len({r['path'] for r in rows})==39
prefixes=('game/','ui/core/local/','tests/','docs/qa/live_maps/','docs/spec/changes/activate-native-raid-maps-2026-09-17/')
single={'tools/run_live_maps_contracts.py','config/first_playable_1080_gate.json'}
plan={}
for row in rows:
    name=row['path'];p=PurePosixPath(name)
    assert not p.is_absolute() and '..' not in p.parts and '\\' not in name
    assert name.startswith(prefixes) or name in single
    assert p.suffix in {'.gd','.tscn','.py','.json','.md'}
    target=R/name
    assert not target.is_symlink() and all(not p.is_symlink() for p in target.parents)
    if row['preimage'] is None:
        assert not target.exists(),name
        if row.get('generate')=='blackwater':continue
        assert 'new' in row and 'edits' not in row
        value=row['new']
    else:
        data=target.read_bytes()
        assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==row['preimage'],name
        lines=data.decode('utf-8').splitlines(True)
        previous=len(lines)+1
        for start,end,replacement in reversed(row['edits']):
            assert type(start)==type(end)==int and 0<=start<=end<previous
            lines[start:end]=replacement.splitlines(True);previous=start
        value=''.join(lines)
    data=value.encode('utf-8');assert hashlib.sha256(data).hexdigest()==row['sha256'],name
    plan[name]=data
# Serialize only the already-reviewed Blackwater environment in a disposable
# native project with real originals. Restore its recorded editor resource IDs
# then require byte-for-byte equality to the locally tested saved scene.
scene='game/world/blackwater_crossing/blackwater_world.tscn'
engine=Path(os.environ['SERIALIZER_GODOT']).resolve(strict=True)
env={**os.environ,'GODOT_SILENCE_ROOT_WARNING':'1'}
assert subprocess.check_output([str(engine),'--version'],env=env,text=True).strip()=='4.7.2.stable.official.ed1daf0bf'
subprocess.run(['python3','tools/install_northline_native_sources.py','--verify'],check=True)
with tempfile.TemporaryDirectory(prefix='exact-blackwater-transfer-') as tmp:
    T=Path(tmp)
    for name in ['game/world/northline_native','assets/world/northline_native','assets/world/map_studies']:
        shutil.copytree(R/name,T/name)
    (T/'tools').mkdir()
    shutil.copyfile(R/'tools/migrate_northline_freight.gd',T/'tools/migrate_northline_freight.gd')
    (T/'tools/author_blackwater_crossing.gd').write_text(packet['blackwater']['author'])
    (T/scene).parent.mkdir(parents=True)
    (T/'project.godot').write_text('config_version=5\n[application]\nconfig/name="Exact native resource transport only"\n[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    base=[str(engine),'--headless','--path',str(T),'--resolution','1920x1080','--audio-driver','Dummy']
    for args in [['--editor','--import','--quit'],['--script','res://tools/author_blackwater_crossing.gd']]:
        result=subprocess.run(base+args,env=env,capture_output=True,text=True,timeout=90)
        text=result.stdout+result.stderr
        if result.returncode or re.search(r'SCRIPT ERROR|ERROR:|Parse Error:',text):
            print(text);raise RuntimeError('native source serialization failed')
    text=(T/scene).read_text()
    recipe=packet['blackwater']
    for kind,call in [('ext','ExtResource'),('sub','SubResource')]:
        found=re.findall(r'^\['+kind+r'_resource[^\n]* id="([^\"]+)"',text,re.M)
        assert len(found)==len(recipe[kind])
        ids=dict(zip(found,recipe[kind]))
        text=re.sub(r'(?m)(^\['+kind+r'_resource[^\n]* id=")([^\"]+)("\])',lambda m:m[1]+ids[m[2]]+m[3],text)
        text=re.sub(call+r'\("([^\"]+)"\)',lambda m:call+'("'+ids[m[1]]+'")',text)
    found=re.findall(r' unique_id=\d+',text)
    assert len(found)==len(recipe['unique_ids'])
    ids=iter(recipe['unique_ids'])
    text=re.sub(r' unique_id=\d+',lambda m:' unique_id='+next(ids),text)
    data=text.encode('utf-8')
    expected=next(r['sha256'] for r in rows if r['path']==scene)
    assert hashlib.sha256(data).hexdigest()==expected
    plan[scene]=data
assert set(plan)=={r['path'] for r in rows}
# No file is published until every preimage and every resulting byte is verified.
for name,data in plan.items():
    p=R/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
subprocess.run(['git','add','--',*sorted(plan)],check=True)
subprocess.run(['git','rm','-r','--','tools/native_raids_stage'],check=True)
changed=set(subprocess.check_output(['git','diff','--cached','--name-only'],text=True).splitlines())
assert changed==set(plan)|{f'tools/native_raids_stage/{i:02d}.b64' for i in range(11)}|{'tools/native_raids_stage/publish.py'}
print('NATIVE_RAID_SOURCE_TRANSFER files=39 verified_bytes=true addon_changes=0 image_changes=0 game_rendered=false')
