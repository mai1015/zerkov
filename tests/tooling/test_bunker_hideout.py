"""Authored kit/layout contracts; no native screenshot is manufactured here."""
import hashlib
import json
import unittest
from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'game/presentation/bunker'

class BunkerHideoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kit = json.loads((DATA / 'bunker_kit.json').read_text())
        cls.layout = json.loads((DATA / 'bunker_layout.json').read_text())
        cls.atlas = Image.open(ROOT / 'assets/world/bunker/bunker_atlas.webp')

    def test_atlas_integrity(self):
        self.assertEqual(self.kit['atlas_sha256'], hashlib.sha256((ROOT / 'assets/world/bunker/bunker_atlas.webp').read_bytes()).hexdigest())
        self.assertEqual((512, 256), self.atlas.size)
        self.assertEqual(72, len(self.kit['assets']))

    def test_native_regions_and_anchors(self):
        occupied = set()
        for key, a in self.kit['assets'].items():
            x,y,w,h = a['rect']; ax,ay = a['anchor']
            self.assertTrue(all(type(v) is int for v in [x,y,w,h,ax,ay]))
            self.assertTrue(0 <= x < x+w <= 512 and 0 <= y < y+h <= 256)
            self.assertTrue(0 <= ax <= w and 0 <= ay <= h)
            pixels = {(i,j) for i in range(x,x+w) for j in range(y,y+h)}
            self.assertFalse(occupied & pixels, key)
            occupied |= pixels

    def test_exact_output_and_wall_contract(self):
        self.assertEqual([640,360],self.layout['world_size'])
        self.assertEqual(40,self.layout['face_height'])
        self.assertEqual(8,self.layout['rim'])
        for r in self.layout['walls']+self.layout['openings']:
            x,y,w,h = r
            self.assertTrue(all(type(v) is int for v in r))
            self.assertTrue(0<=x<x+w<=640 and 0<=y<y+h<=360)

    def test_room_identity_and_sources(self):
        rooms = self.layout['rooms']
        self.assertEqual({'storage','workshop','utilities','medical','rest','kitchen'}, {r['id'] for r in rooms})
        self.assertEqual(6,len(rooms))
        for room in rooms:
            self.assertIn(room['station'],self.kit['assets'])
            self.assertTrue(room['description'])

    def test_placement_identity_and_sources(self):
        seen=set()
        for p in self.layout['props']+self.layout['fixtures']:
            self.assertNotIn(p[0],seen);seen.add(p[0])
            self.assertIn(p[1],self.kit['assets'])
        self.assertEqual(20,len(self.layout['props']))
        self.assertEqual(13,len(self.layout['fixtures']))
        for p in self.layout['overlays']:self.assertIn(p[0],self.kit['assets'])

    def test_fixtures_fit_south_faces(self):
        plan=set()
        for x,y,w,h in self.layout['walls']:plan|={(i,j) for i in range(x,x+w) for j in range(y,y+h)}
        for x,y,w,h in self.layout['openings']:plan-={(i,j) for i in range(x,x+w) for j in range(y,y+h)}
        faces=set()
        for x,y in plan:
            if (x,y+1) in plan:continue
            for row in range(1,41):
                if (x,y+row) in plan:break
                faces.add((x,y+row))
        for name,key,x,top in self.layout['fixtures']:
            _,_,w,h=self.kit['assets'][key]['rect'];left=x-w//2
            rect={(i,j) for i in range(left,left+w) for j in range(top,top+h)}
            self.assertFalse(rect-faces,name)

    def test_physical_prop_footprints_do_not_enter_walls(self):
        walls=set()
        for x,y,w,h in self.layout['walls']:walls|={(i,j) for i in range(x,x+w) for j in range(y,y+h)}
        for x,y,w,h in self.layout['openings']:walls-={(i,j) for i in range(x,x+w) for j in range(y,y+h)}
        for name,key,x,foot in self.layout['props']:
            a=self.kit['assets'][key];fp=a['footprint']
            if not fp:continue
            ax,ay=a['anchor'];fx,fy,w,h=fp;left=x-ax+fx;top=foot-ay+fy
            self.assertFalse({(i,j) for i in range(left,left+w) for j in range(top,top+h)} & walls,name)

    def test_no_silent_gameplay_or_approval(self):
        self.assertFalse(self.layout['systems_available'])
        self.assertTrue(self.layout['inspection_only'])
        self.assertFalse(self.kit['user_visual_approval'])
        for filename in ['bunker_world.gd','bunker_hideout_view.gd']:
            code=(DATA/filename).read_text()
            for forbidden in ['app.state','fixture_set','RaidAuthority.new','InventoryAuthority','apply_damage','OS.execute']:
                self.assertNotIn(forbidden,code)

    def test_import_policy(self):
        text=(ROOT/'assets/world/bunker/bunker_atlas.webp.import').read_text()
        for required in ['compress/mode=0','mipmaps/generate=false','process/size_limit=0']:
            self.assertIn(required,text)

if __name__=='__main__':unittest.main()
