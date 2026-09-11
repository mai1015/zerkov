"""Generate immutable audit indexes and derived contact sheets for this gate."""
raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: historical multi-resolution QA finalizer is retired; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

import hashlib
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageChops, ImageDraw

ROOT = Path('/Volumes/Data/codes/games/zerkov')
OUT = ROOT / 'docs/qa/inventory_ui_binding/astra_final_accept'
REFERENCE = Path('/Volumes/Data/codes/games/zerkov-ui-backup.pdqYzi/after')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)

def sheet(name, paths, columns=2, width=640):
    height = int(width * 9 / 16)
    rows = (len(paths) + columns - 1) // columns
    result = Image.new('RGB', (columns * width, rows * (height + 25)), '#151515')
    draw = ImageDraw.Draw(result)
    for index, (label, path) in enumerate(paths):
        source = Image.open(path).convert('RGB')
        source.thumbnail((width, height))
        x, y = (index % columns) * width, (index // columns) * (height + 25)
        result.paste(source, (x, y + 25))
        draw.text((x + 6, y + 6), label, fill='white')
    result.save(OUT / name)

results = []
for name in ['headless_results.json', 'native_results.json', 'challenge_results.json', 'promoted_results.json']:
    results.extend(json.loads((OUT / name).read_text()))

for resolution in ['1920x1080', '1600x900', '1280x720', '960x540']:
    states = ['ready', 'focused_tooltip', 'pending', 'accepted_split_50_10', 'accepted_merge_60', 'rejected_restored', 'filter_search', 'no_match', 'resynchronizing', 'disconnected']
    sheet(resolution + '_states.png', [(resolution + ' ' + state, OUT / 'core' / (resolution + '_' + state + '.png')) for state in states])

flow = sorted((OUT / 'flow').glob('1280x720_live_flow_*.png'))
sheet('native_flow_sheet.png', [(p.stem, p) for p in flow], 3)
sheet('findings_sheet.png', [(p.stem, p) for p in [OUT/'flow/960x540_live_sections_health.png', OUT/'flow/960x540_live_sections_stats.png', OUT/'flow/960x540_tooltip_refresh_before_unrelated_loot.png', OUT/'flow/960x540_tooltip_refresh_after_unrelated_loot.png']])

reference_stats = []
reference_pairs = []
for width, height in [(1920,1080),(1600,900),(1280,720),(960,540)]:
    resolution = f'{width}x{height}'
    reference = REFERENCE / resolution / 'inventory.png'
    current = OUT / 'core' / (resolution + '_ready.png')
    before = Image.open(reference).convert('RGB')
    after = Image.open(current).convert('RGB')
    chrome_height = round(56 * width/1920) if width >= 1280 else 56
    difference = ImageChops.difference(before.crop((0,0,width,chrome_height)), after.crop((0,0,width,chrome_height)))
    pixels = difference.tobytes()
    changed = sum(pixels[index:index+3] != bytes(3) for index in range(0, len(pixels), 3))
    reference_stats.append(dict(resolution=resolution, reference=str(reference), reference_sha256=digest(reference), current=str(current.relative_to(OUT)), chrome_height=chrome_height, changed_pixels=changed, compared_pixels=width*chrome_height))
    reference_pairs += [(resolution+' approved fixture reference', reference),(resolution+' current live ready',current)]
sheet('reference_comparison.png',reference_pairs)
(OUT / 'reference_comparison.json').write_text(json.dumps(reference_stats,indent=2)+'\n')

paths = [
    'game/inventory/presentation/inventory_presentation_controller.gd',
    'ui/screens/character/character_screen.gd',
    'ui/screens/character/character_workspace.tscn',
    'ui/screens/character/components/character_layout.gd',
    'ui/screens/character/components/inventory_grid.gd',
    'ui/screens/character/components/health_section.tscn',
    'ui/screens/character/components/stats_section.tscn',
    'ui/screens/character/inventory_actions.gd',
    'tests/raid/inventory_multi_controller_contract.gd',
    'tests/raid/inventory_ui_binding_contract.gd',
]
paths += [str(p.relative_to(ROOT)) for p in sorted((ROOT/'tests/visual/inventory_ui_binding').glob('*.gd'))]
source_hashes = {path:digest(ROOT/path) for path in paths}
(OUT/'reviewed_sources.sha256').write_text(''.join(f'{value}  {key}\n' for key,value in source_hashes.items()))
(OUT/'reviewed_production.diff').write_text(git('diff','--','ui/screens/character').stdout)
(OUT/'git_status.txt').write_text(git('status','--short').stdout)
diff_check = git('diff','--check')
(OUT/'logs/git_diff_check.log').write_text(diff_check.stdout + diff_check.stderr)
spec_diff = git('diff','--','docs/spec','DESIGN.md')
(OUT/'logs/spec_and_design_diff.log').write_text(spec_diff.stdout + spec_diff.stderr)
processes = subprocess.run(['ps','-axo','pid,ppid,etime,command'],capture_output=True,text=True).stdout
(OUT/'process_snapshot.txt').write_text(processes)
owned = [line for line in processes.splitlines() if 'Godot --path /Volumes/Data/codes/games/zerkov --script res://docs/qa/inventory_ui_binding/astra_final_accept/' in line]
images = []
for path in sorted(OUT.rglob('*.png')):
    with Image.open(path) as image:
        images.append(dict(path=str(path.relative_to(OUT)),dimensions=list(image.size),bytes=path.stat().st_size,sha256=digest(path),derived=path.parent==OUT))
manifest = dict(human_approval=False, images=images, source_hashes=source_hashes)
(OUT/'evidence_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
attempts = []
for filename in ['challenge_authoring_results.json','challenge_setup_v1_results.json']:
    attempts.extend(json.loads((OUT/filename).read_text()))
summary = dict(authoring_attempts=attempts, total_invocations=len(results)+len(attempts), total_executed_checks=sum(r['checks'] or 0 for r in results+attempts), total_executed_failures=sum(r['failures'] or 0 for r in results+attempts), verdict='ACCEPT CHECKPOINT',human_approval=False,head=git('rev-parse','HEAD').stdout.strip(),unique_suite_ids=len({r['name'] for r in results}),executions=len(results),checks=sum(r['checks'] or 0 for r in results),failures=sum(r['failures'] or 0 for r in results),results=results,native_pngs=sum(not i['derived'] for i in images),derived_pngs=sum(i['derived'] for i in images),diff_check_exit=diff_check.returncode,spec_design_unchanged=not spec_diff.stdout,lingering_owned_godot=owned)
(OUT/'audit_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if k!='results'},indent=2))

sealed_comparisons = {}
for name in ['live_sections_probe.gd','compact_tooltip_refresh_probe.gd']:
    previous=ROOT/'docs/qa/inventory_ui_binding/astra_acceptance'/name
    current=OUT/name
    normalized=current.read_text().replace('astra_final_accept','astra_acceptance')
    sealed_comparisons[name] = dict(source_sha256=digest(previous), current_sha256=digest(current), assertion_source_unchanged=previous.read_text()==normalized)
(OUT/'sealed_probe_comparison.json').write_text(json.dumps(sealed_comparisons,indent=2)+'\n')
sheet('section_and_overlay_sheet.png',[(p.stem,p) for p in sorted((OUT/'flow').glob('*section_challenge*.png'))]+[(p.stem,p) for p in sorted((OUT/'flow').glob('*overlay_challenge*.png'))],2)
