"""Source/ownership checks. Not a substitute for native rendering with original PNGs."""
from pathlib import Path
import json
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
WORLD=ROOT/'game/world/northline_native/zone/northline_world.tscn'
VIEW=ROOT/'game/presentation/northline_native/zone_review.gd'

class NativeZoneSourceTests(unittest.TestCase):
    def test_saved_terrain_exists(self):
        text=WORLD.read_text()
        self.assertGreaterEqual(text.count('type="TileMapLayer"'),50)
        self.assertNotIn('type="Script"',text)
        self.assertIn('tile_map_data = PackedByteArray(',text)
    def test_no_runtime_rebuild(self):
        text=VIEW.read_text()
        for banned in ('JSON.parse','FileAccess','set_cell','ResourceSaver','migrate_northline','_draw('):
            self.assertNotIn(banned,text)
    def test_full_map_bounds(self):
        text=WORLD.read_text()
        self.assertIn('Rect2(0, 0, 2688, 1792)',text)
        self.assertEqual(19,text.count('metadata/legacy_building_id'))
        self.assertEqual(541,text.count('metadata/legacy_prop_id'))
        self.assertEqual(153,text.count('metadata/legacy_rect'))
    def test_old_freight_is_retained(self):
        self.assertTrue((ROOT/'game/world/northline_native/freight_sector.tscn').is_file())
        self.assertNotIn('freight_sector.tscn',VIEW.read_text())
    def test_originals_are_not_generated(self):
        text=(ROOT/'tools/install_northline_native_sources.py').read_text()
        self.assertNotIn('from PIL',text)
        self.assertNotIn('.resize(',text)
        self.assertNotIn('.quantize(',text)
        manifest=json.loads((ROOT/'assets/world/northline_native/source_manifest.json').read_text())
        self.assertEqual(11,len(manifest['sources']))
    def test_native_target_and_no_small_viewport(self):
        text=VIEW.read_text()
        self.assertIn('Vector2i(1920,1080)',text)
        self.assertIn('Vector2(3,3)',text)
        self.assertNotIn('SubViewport',text)
    def test_exporter_is_create_only(self):
        text=(ROOT/'tools/migrate_northline_zone_native.gd').read_text()
        self.assertIn('output exists; saved editor work will not be replaced',text)
        self.assertIn('refusing existing authored resource',text)
    def test_native_prop_resources(self):
        files=list((ROOT/'game/world/northline_native/props').glob('*.tscn'))
        self.assertEqual(50,len(files))
        for f in files:
            t=f.read_text()
            self.assertIn('type="StaticBody2D"',t)
            self.assertIn('type="CollisionShape2D"',t)
            self.assertIn('/northline_native/sources/sheet_',t)
    def test_four_routes_are_tested_not_gameplay(self):
        text=(ROOT/'tests/presentation/northline_native_zone_contract.gd').read_text()
        self.assertIn('legacy.native_walk_routes',text)
        self.assertIn('move_and_collide',text)
        self.assertNotIn('RaidAuthority',VIEW.read_text())
    def test_resource_references_resolve_or_are_declared_originals(self):
        m=json.loads((ROOT/'assets/world/northline_native/source_manifest.json').read_text())
        originals={r['path'] for r in m['sources']}
        for folder in ['game/world/northline_native','game/presentation/northline_native']:
            for f in (ROOT/folder).rglob('*'):
                if f.suffix not in ('.tscn','.tres'):continue
                for path in re.findall(r'path="res://([^\"]+)"',f.read_text()):
                    self.assertTrue((ROOT/path).is_file() or path in originals,(f,path))
if __name__=='__main__':unittest.main()
