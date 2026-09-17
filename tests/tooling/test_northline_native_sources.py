import hashlib, importlib.util, json, pathlib, stat, tempfile, unittest, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('source_installer',ROOT/'tools/install_northline_native_sources.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class SourceContracts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)/'repo';self.root.mkdir()
        self.src=pathlib.Path(self.tmp.name)/'input';self.src.mkdir()
        self.data=b'fixture bytes, never used as game artwork'
        self.member='approved/full.png'
        self.out=p.PREFIX+'sheet_1.png'
        self.make_zip([(self.member,self.data)])
    def make_zip(self,members):
        zpath=self.src/'pack.zip'
        with zipfile.ZipFile(zpath,'w') as z:
            for name,data in members:z.writestr(name,data)
        self.manifest={'schema_version':1,'archives':{'pack.zip':p.sha(zpath.read_bytes())},'sources':[{'archive':'pack.zip','member':self.member,'path':self.out,'bytes':len(self.data),'sha256':p.sha(self.data)}]}
    def test_original_bytes_and_idempotence(self):
        p.install(self.root,self.src,self.manifest);p.install(self.root,self.src,self.manifest)
        self.assertEqual(self.data,(self.root/self.out).read_bytes());p.verify(self.root,self.manifest)
    def test_missing_is_blocked(self):
        with self.assertRaises(p.SourceError):p.verify(self.root,self.manifest)
    def test_source_drift_writes_nothing(self):
        self.manifest['sources'][0]['sha256']='a'*64
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
        self.assertFalse((self.root/'assets').exists())
    def test_archive_drift(self):
        (self.src/'pack.zip').write_bytes(b'different')
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
    def test_duplicate_selected_member(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore');self.make_zip([(self.member,self.data)]*2)
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
    def test_selected_link(self):
        info=zipfile.ZipInfo(self.member);info.create_system=3;info.external_attr=(stat.S_IFLNK|0o777)<<16
        self.make_zip([(info,self.data)])
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
    def test_output_link(self):
        target=self.root/self.out;target.parent.mkdir(parents=True);target.symlink_to(self.src/'pack.zip')
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
    def test_existing_different_file(self):
        target=self.root/self.out;target.parent.mkdir(parents=True);target.write_bytes(b'preserve me')
        with self.assertRaises(p.SourceError):p.install(self.root,self.src,self.manifest)
        self.assertEqual(b'preserve me',target.read_bytes())
    def test_forbidden_paths(self):
        for name in ('../a','/a','a//b','a/./b','C:/a','a\\b','DO NOT USE/a'):
            with self.subTest(name=name),self.assertRaises(p.SourceError):p.clean_path(name)
    def test_manifest_and_native_resources(self):
        m=p.manifest_at();self.assertEqual(11,len(m['sources']))
        scene=(ROOT/'game/world/northline_native/freight_sector.tscn').read_text()
        self.assertGreaterEqual(scene.count('type="TileMapLayer"'),8)
        self.assertIn('type="TileSet" path="res://game/world/northline_native/tilesets/ground.tres"',scene)
        self.assertNotIn('script = ',scene)
        view=(ROOT/'game/presentation/northline_native/freight_review.gd').read_text()
        for prohibited in ('JSON.parse','_draw(','.set_cell(','.resize(','.quantize('):self.assertNotIn(prohibited,view)
        self.assertEqual(15,len(list((ROOT/'game/world/northline_native/props').glob('*.tscn'))))
if __name__=='__main__':unittest.main()
