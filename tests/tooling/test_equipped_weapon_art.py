"""Source-provenance controls; native presentation and gameplay are separate."""
from pathlib import Path
import copy
import importlib.util
import json
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('weapon_art', ROOT/'tools/verify_equipped_weapon_art.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SourceTests(unittest.TestCase):
    def test_original_selection(self):
        self.assertEqual(module.verify(), 30)

    def test_corruption_is_rejected(self):
        for kind in ['missing', 'modified', 'duplicate', 'escape', 'forbidden', 'clearance', 'dimensions']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                data = json.loads((ROOT/module.MANIFEST).read_text())
                data['sources'] = data['sources'][:1]
                row = data['sources'][0]
                path = root/row['path'];path.parent.mkdir(parents=True)
                shutil.copy2(ROOT/row['path'], path)
                if kind == 'missing': path.unlink()
                elif kind == 'modified': path.write_bytes(path.read_bytes() + b'bad')
                elif kind == 'duplicate': data['sources'].append(copy.deepcopy(row))
                elif kind == 'escape': row['path'] = 'assets/original/../outside.png'
                elif kind == 'forbidden': row['member'] = 'zerkov/DO NOT USE/a.png'
                elif kind == 'clearance': data['distribution_status'] = 'cleared'
                elif kind == 'dimensions': row['size'] = [1, 1]
                manifest = root/module.MANIFEST;manifest.parent.mkdir(parents=True)
                manifest.write_text(json.dumps(data))
                with self.assertRaises(ValueError): module.verify(root)

    def test_no_handoff_icon_or_procedural_muzzle(self):
        source = (ROOT/'game/presentation/local/local_weapon_presenter.gd').read_text()
        self.assertNotIn('assets/handoff/', source)
        self.assertNotIn('draw_circle(', source)
        self.assertIn('FX.get_frame_texture', source)
        self.assertIn('event.get("damage_confirmed", false) and event.hit', source)

    def test_native_profiles_and_forbidden_family_exclusion(self):
        rifle = (ROOT/'game/content/art/weapon_art/akm.tres').read_text()
        self.assertIn('res://assets/original/ally/arms+ak.png', rifle)
        self.assertIn('includes_arms = true', rifle)
        blade = (ROOT/'game/content/art/weapon_art/machete.tres').read_text()
        self.assertIn('Weapons_inventory_MACHETTE.png', blade)
        self.assertIn('knife-attack-knife.png', blade)
        self.assertIn('attack_pivot = Vector2(32, 48)', blade)
