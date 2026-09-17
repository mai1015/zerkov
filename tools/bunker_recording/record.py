#!/usr/bin/env python3
"""Record the real PR #26 campaign in an outside copy; no game edits or fake UI.

Movie Maker fixes frame pacing. This is a UX demonstration, not realtime/FPS
acceptance. Only the output viewport layout and a recording cursor are added.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile, uuid

BASE = 'e904645661452a8e3329b445077546195e862283'
ROOT = Path(__file__).resolve().parents[2]

def execute(command, env, log, timeout=900):
    with log.open('w', encoding='utf-8') as stream:
        p = subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = log.read_text(encoding='utf-8')
    print(output, flush=True)
    if p.returncode or re.search(r'SCRIPT ERROR|(?:^|\n)\s*ERROR:|BUNKER_MOVIE_TIMEOUT', output):
        raise RuntimeError(f'Native process failed ({p.returncode}); see {log.name}')
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    a = parser.parse_args()
    engine, out = a.godot.resolve(strict=True), a.output.resolve()
    if out.exists() or out.is_relative_to(ROOT) or ROOT.is_relative_to(out):
        raise ValueError('Recording output must be new and outside the checkout')
    out.mkdir(parents=True)
    env = {**os.environ, 'GODOT_SILENCE_ROOT_WARNING':'1'}
    pin = json.loads((ROOT/'config/toolchain.lock.json').read_text())['engine']['required_version']
    if execute([str(engine),'--version'], env, out/'engine-version.log', 20).strip() != pin:
        raise ValueError('Engine version differs from the game lock')
    source_commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    native_changes = subprocess.check_output(['git','diff','--name-only',BASE,'HEAD','--','addons','game','ui','config','project.godot'],cwd=ROOT,text=True).strip()
    if native_changes:
        raise ValueError('Capture branch changed the recorded game: '+native_changes)
    with tempfile.TemporaryDirectory(prefix='zerkov-footage-') as temp:
        project = Path(temp)/'project'
        shutil.copytree(ROOT,project,ignore=shutil.ignore_patterns('.git','.godot','.codegraph','__pycache__'))
        env['XDG_DATA_HOME'] = str(Path(temp)/'user')
        # Documented native movie output policy, applied only to the isolated copy.
        # It permits a full-resolution viewport on a smaller CI display. No image
        # is resized and no authored UI, scene, resource, or native addon is changed.
        settings = project/'project.godot'
        original = settings.read_text()
        if original.count('window/stretch/mode="canvas_items"') != 1:
            raise ValueError('Unexpected production output policy')
        settings.write_text(original.replace('window/stretch/mode="canvas_items"','window/stretch/mode="viewport"'))
        (project/'record_bunker.gd').write_bytes((ROOT/'tools/bunker_recording/walkthrough.gd.in').read_bytes())
        base = [str(engine),'--path',str(project),'--resolution','1920x1080']
        execute(base+['--headless','--editor','--import','--quit'],env,out/'import.log',180)
        namespace = 'localflow_'+uuid.uuid4().hex
        raw = out/'bunker-native.avi'
        log = execute(base+['--write-movie',str(raw),'--fixed-fps','30','--script','res://record_bunker.gd','--',namespace],env,out/'recording.log')
        markers = re.findall(r'(?m)^BUNKER_MOVIE_RESULT checks=([1-9][0-9]*) failures=0 native=true fixed_fps=30$',log)
        if len(markers)!=1: raise RuntimeError('Missing unique successful recording result')
        chapter_line = re.findall(r'(?m)^BUNKER_MOVIE_CHAPTERS (.+)$',log)
        if len(chapter_line)!=1: raise RuntimeError('Missing recorded navigation chapters')
        chapters = json.loads(chapter_line[0])
    movie = out/'zerkov-bunker-walkthrough.mp4'
    execute(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(raw),'-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-movflags','+faststart',str(movie)],env,out/'encoding.log',600)
    probe = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(movie)],text=True))
    video = next(s for s in probe['streams'] if s['codec_type']=='video')
    if (video['width'],video['height']) != (1920,1080) or video['avg_frame_rate']!='30/1' or float(probe['format']['duration'])<40:
        raise RuntimeError('Movie dimensions/rate/duration differ from the recording contract')
    report = {'recorded_game_commit':BASE,'capture_tool_commit':source_commit,'engine':pin,
              'mode':'native Godot Movie Maker, scripted viewport mouse/keyboard input; not realtime benchmark',
              'capture_only_changes':['temporary viewport stretch mode','desktop output layout','visible recording cursor'],
              'native_substitutes':False,'fixture_ui':False,'checks':int(markers[0]),'failures':0,
              'chapters':chapters,'video':probe,'sha256':hashlib.sha256(movie.read_bytes()).hexdigest()}
    (out/'recording.json').write_text(json.dumps(report,indent=2)+'\n')
    raw.unlink()
    print('BUNKER_RECORDING_COMPLETE '+str(movie),flush=True)

if __name__=='__main__': main()
