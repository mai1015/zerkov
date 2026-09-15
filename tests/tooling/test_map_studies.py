"""Authored-source, geometry and topology contracts; no live raid is simulated."""
import copy, hashlib, json, unittest
from collections import deque
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
M=json.loads((ROOT/'game/presentation/map_studies/maps.json').read_text())
A=json.loads((ROOT/'assets/world/map_studies/atlas.json').read_text())

def walkable(m,x,y):
    if not 2<x<m['size'][0]-2 or not 2<y<m['size'][1]-2:return False
    return not any(rx-3<=x<=rx+w+3 and ry-3<=y<=ry+h+3 for rx,ry,w,h in m['collision_rects']+m['cover_rects'])

def reachable(m):
    start=tuple(m['spawn']);q=deque([start]);seen={start}
    while q:
        x,y=q.popleft()
        for dx,dy in [(0,4),(0,-4),(4,0),(-4,0)]:
            p=(x+dx,y+dy)
            if p not in seen and walkable(m,*p):seen.add(p);q.append(p)
    return seen

class MapStudyTests(unittest.TestCase):
    def test_source_atlas_hash(self):
        self.assertEqual(A['atlas_sha256'],hashlib.sha256((ROOT/'assets/world/map_studies/atlas.webp').read_bytes()).hexdigest())
    def test_atlas_shape(self):
        with Image.open(ROOT/'assets/world/map_studies/atlas.webp') as image:
            self.assertEqual(tuple(A['atlas_size']),image.size)
            for key,a in A['assets'].items():
                x,y,w,h=a['rect'];self.assertGreater(w*h,0,key);self.assertGreaterEqual(x,0);self.assertGreaterEqual(y,0)
                self.assertLessEqual(x+w,image.width);self.assertLessEqual(y+h,image.height)
                self.assertIsNotNone(image.crop((x,y,x+w,y+h)).getchannel('A').getbbox(),key)
    def test_source_regions_explicit_and_bounded(self):
        for a in A['assets'].values():
            source=A['sources'][str(a['source_index'])];x,y,w,h=a['source_rect']
            self.assertTrue(all(type(v)is int for v in [x,y,w,h]))
            self.assertLessEqual(x+w,source['size'][0]);self.assertLessEqual(y+h,source['size'][1])
            self.assertEqual('nearest 1/3',a['normalization'])
    def test_both_new_packs_used(self):
        self.assertEqual({'abandoned-assets(1).zip','post-apocalyptic-assets(1).zip'},set(A['archives']))
        for row in A['sources'].values():
            self.assertNotIn('..',row['member'].split('/'));self.assertNotIn('do not use',row['member'].lower())
    def test_world_and_floor_scale(self):
        self.assertEqual(16,A['study_tile_size'])
        for a in A['assets'].values():
            if a['kind']=='floor':self.assertEqual([16,16],a['size'])
        for m in M['maps']:self.assertEqual([672,448],m['size'])
    def test_unique_layout_identities(self):
        self.assertEqual({'northline','mercury'},{m['id'] for m in M['maps']})
        for m in M['maps']:
            ids=[p['id'] for p in m['props']];self.assertEqual(len(ids),len(set(ids)))
            for p in m['props']+m['decals']:self.assertIn(p['asset'],A['assets'])
    def test_native_colliders_bounded(self):
        for m in M['maps']:
            for x,y,w,h in m['collision_rects']+m['cover_rects']:
                self.assertGreater(w,0);self.assertGreater(h,0);self.assertGreaterEqual(x,0);self.assertGreaterEqual(y,0)
                self.assertLessEqual(x+w,m['size'][0]);self.assertLessEqual(y+h,m['size'][1])
    def test_collision_footprints_follow_final_prop_placement(self):
        for m in M['maps']:
            expected=[]
            for p in m['props']:
                if p['solid']:
                    w,h=A['assets'][p['asset']]['footprint'];x,y=p['foot'];expected.append([x-w/2,y-h,w,h])
            self.assertEqual(expected,m['cover_rects'])
    def test_no_spawn_on_extract(self):
        for m in M['maps']:
            for e in m['exits']:self.assertGreater(abs(m['spawn'][0]-e['at'][0])+abs(m['spawn'][1]-e['at'][1]),40)
    def test_exits_connected(self):
        for m in M['maps']:
            seen=reachable(m)
            for e in m['exits']:
                self.assertTrue(any(abs(x-e['at'][0])<=10 and abs(y-e['at'][1])<=10 for x,y in seen),(m['id'],e['name']))
    def test_guide_routes_do_not_cut_through_colliders(self):
        for m in M['maps']:
            for route in m['routes']:
                for (ax,ay),(bx,by) in zip(route['points'],route['points'][1:]):
                    self.assertTrue(ax==bx or ay==by)
                    distance=abs(ax-bx)+abs(ay-by)
                    for t in range(0,distance+1,2):
                        x=ax+(bx-ax)*t/max(1,distance);y=ay+(by-ay)*t/max(1,distance)
                        self.assertTrue(walkable(m,x,y),(m['id'],route['name'],x,y))
    def test_negative_sealed_corridor_is_not_reachable(self):
        m=copy.deepcopy(M['maps'][0]);m['collision_rects'].append([430,0,20,448])
        self.assertFalse(any(x>451 for x,y in reachable(m)))
    def test_camera_points_honor_exact_surface(self):
        for m in M['maps']:
            for point in m['camera_points']:
                x,y=point['at'];self.assertTrue(320<=x<=352 and 180<=y<=268)
    def test_no_false_gameplay_or_license_claim(self):
        self.assertEqual('environment_study_not_live_raid',M['scope'])
        self.assertIn('no_distribution_grant_claimed',A['license_status'])
        for p in (ROOT/'game/presentation/map_studies').glob('*.gd'):
            code=p.read_text();self.assertNotIn('Engine.time_scale =',code);self.assertNotIn('get_node("RaidAuthority")',code)
    def test_import_flags(self):
        code=(ROOT/'assets/world/map_studies/atlas.webp.import').read_text()
        self.assertIn('mipmaps/generate=false',code);self.assertIn('compress/mode=0',code)

if __name__=='__main__':unittest.main()
