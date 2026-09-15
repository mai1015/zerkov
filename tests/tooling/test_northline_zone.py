"""Full-zone data contracts, including negative topology and source integrity."""
from __future__ import annotations
import copy,hashlib,json,sys,unittest
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import review_northline_routes as nav
DATA=json.loads((ROOT/'game/presentation/northline_zone/zone.json').read_text())
ASSETS=json.loads((ROOT/'assets/world/map_studies/atlas.json').read_text())['assets']

class NorthlineZoneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.grid,cls.width,cls.height=nav.occupancy(DATA)
        cls.seen=nav.flood(cls.grid,nav.nearest(DATA['spawn'],cls.grid))
    def test_actual_area_increases_not_art_scale(self):
        self.assertEqual([2688,1792],DATA['size'])
        self.assertEqual(16,DATA['tile_size'])
        self.assertEqual(16,(2688*1792)//(672*448))
        self.assertFalse(DATA['comparison']['art_scale_changed'])
    def test_all_landmarks_and_interiors_connected(self):
        report=nav.report(DATA)
        self.assertEqual((4,9,19,4),tuple(report[k] for k in ['connected_exits','connected_districts','connected_interiors','connected_spawns']))
        self.assertEqual(DATA['navigation_validation'],report)
    def test_sealed_cross_map_barrier_rejected(self):
        blocked=copy.deepcopy(DATA)
        blocked['collision_rects'].append([1720,0,32,1792])
        with self.assertRaisesRegex(ValueError,'Unreachable'):nav.report(blocked)
    def test_every_authored_route_clear(self):
        for route in DATA['routes']+DATA['native_walk_routes']:
            for a,b in zip(route['points'],route['points'][1:]):
                self.assertTrue(a[0]==b[0] or a[1]==b[1])
                dx,dy=b[0]-a[0],b[1]-a[1];steps=(abs(dx)+abs(dy))//8
                for i in range(steps+1):
                    x=round((a[0]+dx*i/max(1,steps))/8);y=round((a[1]+dy*i/max(1,steps))/8)
                    self.assertFalse(self.grid[y][x],(route.get('id',route.get('name')),x,y))
    def test_exit_targets_are_distinct_and_not_spawn(self):
        self.assertEqual(4,len({tuple(e['at']) for e in DATA['exits']}))
        self.assertTrue(all(DATA['spawn']!=e['at'] for e in DATA['exits']))
    def test_native_geometry_bounded(self):
        for x,y,w,h in DATA['collision_rects']+DATA['cover_rects']:
            self.assertGreater(w,0);self.assertGreater(h,0)
            self.assertGreaterEqual(x,0);self.assertGreaterEqual(y,0)
            self.assertLessEqual(x+w,2688);self.assertLessEqual(y+h,1792)
    def test_wall_solids_are_shared_with_render(self):
        for b in DATA['buildings']:
            self.assertGreaterEqual(len(b['doors']),2)
            for wall in b['walls']:self.assertIn(wall,DATA['collision_rects'])
    def test_props_have_unique_ids_and_physical_footprints(self):
        ids=[p['id'] for p in DATA['props']];self.assertEqual(len(ids),len(set(ids)))
        expected=[]
        for p in DATA['props']:
            w,h=ASSETS[p['asset']]['footprint'];x,y=p['foot']
            if p['solid']:expected.append([x-w/2,y-h,w,h])
        self.assertEqual(expected,DATA['cover_rects'])
        self.assertGreater(len(ids),500)
    def test_no_cover_overlaps_walls(self):
        for x,y,w,h in DATA['cover_rects']:
            for bx,by,bw,bh in DATA['collision_rects']:
                self.assertFalse(x<bx+bw and x+w>bx and y<by+bh and y+h>by)
    def test_camera_points_fit_normal_view(self):
        self.assertEqual(9,len(DATA['camera_points']))
        for p in DATA['camera_points']:
            x,y=p['at'];self.assertTrue(320<=x<=2368 and 180<=y<=1612)
    def test_source_art_remains_separate(self):
        for p in DATA['props']+DATA['decals']:self.assertIn(p['asset'],ASSETS)
        self.assertEqual('connected_environment_walkthrough_not_live_raid',DATA['scope'])
    def test_review_character_hash_and_geometry(self):
        folder=ROOT/'assets/world/northline_zone';record=json.loads((folder/'review_walker.json').read_text())
        self.assertEqual(record['atlas_sha256'],hashlib.sha256((folder/'review_walker.png').read_bytes()).hexdigest())
        with Image.open(folder/'review_walker.png') as image:
            self.assertEqual((384,512),image.size)
        self.assertEqual(8,len(record['sources']))
        self.assertIn('no_distribution_grant_claimed',record['license_status'])
        for entry in record['sources']:
            self.assertNotIn('DO NOT USE',entry['member']);self.assertEqual(64,len(entry['sha256']))
    def test_import_no_mipmaps(self):
        source=(ROOT/'assets/world/northline_zone/review_walker.png.import').read_text()
        self.assertIn('mipmaps/generate=false',source);self.assertIn('compress/mode=0',source)
    def test_no_authority_capabilities(self):
        for path in (ROOT/'game/presentation/northline_zone').glob('*.gd'):
            text=path.read_text()
            self.assertNotIn('Engine.time_scale =',text)
            self.assertNotIn('get_node("RaidAuthority")',text)
            self.assertNotIn('res://game/raid/',text)

if __name__=='__main__':unittest.main()
