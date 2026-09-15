"""Presentation-only additions must leave the source art and topology intact."""
from pathlib import Path
import hashlib
import json
import unittest
from PIL import Image
ROOT = Path(__file__).resolve().parents[2]

class FreightPolishTests(unittest.TestCase):
    def test_topology_is_unchanged(self):
        path = ROOT/'game/presentation/northline_zone/zone.json'
        self.assertEqual('53a3960f6d4b8df6129b36c0feb3c7e08ce745bee44f563ba6d93799eac6cba1', hashlib.sha256(path.read_bytes()).hexdigest())
    def test_original_environment_atlas_is_unchanged(self):
        path = ROOT/'assets/world/map_studies/atlas.webp'
        self.assertEqual('d2b018bd1fe2bfed07554c7e13c1aa2bbb7bd2d569698cf471539dfdb963179c',hashlib.sha256(path.read_bytes()).hexdigest())
    def test_outfit_rgba_integrity(self):
        folder = ROOT/'assets/world/northline_zone'
        data = json.loads((folder/'review_outfit.json').read_text())
        path = folder/'review_outfit.webp'
        self.assertEqual(data['atlas_sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        with Image.open(path) as image:
            rgba = image.convert('RGBA')
            self.assertEqual((384,512), rgba.size)
            self.assertEqual(data['atlas_rgba_sha256'],hashlib.sha256(rgba.tobytes()).hexdigest())
            for row, source in enumerate(data['sources']):
                self.assertEqual(row,source['row'])
                pixels=rgba.crop((0,row*64,384,row*64+64)).tobytes()
                self.assertEqual(source['rgba_sha256'],hashlib.sha256(pixels).hexdigest())
    def test_outfit_provenance_is_not_equipment_state(self):
        data = json.loads((ROOT/'assets/world/northline_zone/review_outfit.json').read_text())
        self.assertEqual(8,len(data['sources']))
        self.assertIn('not inventory',data['purpose'])
        self.assertIn('no_distribution_grant',data['license_status'])
        for source in data['sources']:
            self.assertNotIn('DO NOT USE',source['member'])
            self.assertEqual(64,len(source['sha256']))
    def test_import_policy(self):
        source=(ROOT/'assets/world/northline_zone/review_outfit.webp.import').read_text()
        self.assertIn('compress/mode=0',source)
        self.assertIn('mipmaps/generate=false',source)
    def test_wind_is_atlas_safe_and_freezable(self):
        source=(ROOT/'game/presentation/northline_zone/polish/anchored_wind.gdshader').read_text()
        self.assertNotIn('texture(',source)
        self.assertIn('uniform float visual_seconds',source)
        self.assertIn('VERTEX.y',source)
        self.assertIn('round(gust',source)
    def test_no_authority_writes_or_animation_callbacks(self):
        for path in (ROOT/'game/presentation/northline_zone/polish').glob('*.gd'):
            text=path.read_text()
            for banned in ('get_node("RaidAuthority")', 'res://game/raid/', 'Engine.time_scale =', '.apply_damage(', '.move_and_slide('):
                self.assertNotIn(banned,text)
    def test_walk_selection_follows_resolved_distance(self):
        source=(ROOT/'game/presentation/northline_zone/review_walker.gd').read_text()
        self.assertIn('position.distance_to(previous_position)',source)
        self.assertIn('pose.advance(resolved_distance',source)
        self.assertNotIn('show_frame(input !=',source)
    def test_snapshot_freeze_is_used_by_capture(self):
        source=(ROOT/'tests/presentation/northline_zone_contract.gd').read_text()
        self.assertIn('world.freeze_effects(3.0)',source)
        self.assertIn('Exact1080CaptureGuard.accepts(root, root, image)',source)
if __name__=='__main__':unittest.main()
