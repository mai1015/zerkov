#!/usr/bin/env python3
"""One-time publication of an exact locally authored pre-raid patch.

No arbitrary archives, source generation or remote execution. Checksums and
Git's old-file checks protect the approved file inventory. Removed after use.
"""
import base64
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
PARTS = [ROOT / 'tools/offline-transfer' / ('%02d.part' % i) for i in range(4)]
EXPECTED = '''config/first_playable_1080_gate.json
docs/spec/changes/add-offline-bunker-entry-2026-09-15/design.md
docs/spec/changes/add-offline-bunker-entry-2026-09-15/proposal.md
docs/spec/changes/add-offline-bunker-entry-2026-09-15/specs/offline-bunker/spec.md
docs/spec/changes/add-offline-bunker-entry-2026-09-15/tasks.md
game/bootstrap/offline_application.gd
game/bootstrap/offline_application.tscn
game/offline/offline_bunker_catalog.gd
game/offline/offline_bunker_session.gd
game/offline/offline_bunker_ui.gd
game/offline/offline_character_runtime.gd
game/offline/offline_inventory_controller.gd
project.godot
tests/presentation/offline_bunker_flow.gd
tests/tooling/run_offline_bunker_gate.py
tests/tooling/test_ui_first_playable_scope.py
tools/register_offline_bunker.py
ui/core/screen.gd
ui/core/ui_context.gd
ui/screens/bunker/bunker_hideout_screen.gd
ui/screens/character/character_screen.gd
ui/screens/frontflow/main_menu.gd
ui/screens/frontflow/title.gd
ui/screens/raid/pause.gd
ui/screens/utilities/settings.gd'''.splitlines()
encoded = ''.join(path.read_text() for path in PARTS)
raw = base64.b64decode(encoded, validate=True)
if len(raw) != 21612 or hashlib.sha256(raw).hexdigest() != 'a5203654546ff687babc5efb1f736750ae3968228d192d54b2167f517b5d96a0':
    raise RuntimeError('source patch transport mismatch')
patch = zlib.decompress(raw)
if len(patch) != 74255:
    raise RuntimeError('source patch size mismatch')
paths = re.findall(r'^diff --git a/(.+) b/(.+)$', patch.decode(), re.M)
if len(paths) != len(EXPECTED) or {a for a,b in paths} != set(EXPECTED) or any(a != b for a,b in paths):
    raise RuntimeError('unexpected source patch paths')
for name in EXPECTED:
    path = ROOT / name
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise RuntimeError('symlink destination')
with tempfile.NamedTemporaryFile(suffix='.patch') as file:
    file.write(patch); file.flush()
    subprocess.run(['git','apply','--check','--index',file.name], cwd=ROOT, check=True)
    subprocess.run(['git','apply','--index',file.name], cwd=ROOT, check=True)
print('OFFLINE_SOURCE_PUBLICATION files=25 sha256=verified')
