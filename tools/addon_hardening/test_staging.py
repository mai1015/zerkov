import importlib.util, json, tempfile, unittest, shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('stage',Path(__file__).with_name('stage.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Staging(unittest.TestCase):
 def test_exact_replacements(self):
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'candidate';files=m.stage(ROOT,out)
   self.assertEqual(len(files),6)
   for path,data in files.items():self.assertEqual((out/path).read_bytes(),data)
   self.assertFalse(json.loads((out/'candidate-source.json').read_text())['upstream_signoff'])
 def test_inside_checkout_rejected(self):
  with self.assertRaises(ValueError):m.stage(ROOT,ROOT/'no-write')
 def test_existing_output_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(ValueError):m.stage(ROOT,Path(d))
 def test_base_mismatch_prevents_output(self):
  with tempfile.TemporaryDirectory() as d:
   r=Path(d)/'root';shutil.copytree(ROOT/'tools/addon_hardening',r/'tools/addon_hardening')
   manifest=json.loads((r/'tools/addon_hardening/changes.json').read_text())
   for row in manifest['changes']:
    p=r/row['path'];p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/row['path']).read_bytes())
   (r/manifest['changes'][0]['path']).write_bytes(b'wrong')
   out=Path(d)/'out'
   with self.assertRaises(ValueError):m.stage(r,out)
   self.assertFalse(out.exists())
 def test_unexpected_paths_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   r=Path(d)/'root';(r/'tools/addon_hardening').mkdir(parents=True)
   (r/'tools/addon_hardening/changes.json').write_text('{"changes":[{"path":"../../secret"}]}')
   with self.assertRaises(ValueError):m.stage(r,Path(d)/'out')
 def test_path_and_symlink_controls(self):
  with tempfile.TemporaryDirectory() as d:
   r=Path(d)
   for name in ['../secret','/secret','x/../../y','C:x','x\\y']:
    with self.assertRaises(ValueError):m.safe(r,name)
   (r/'actual').write_text('x');(r/'link').symlink_to(r/'actual')
   with self.assertRaises(ValueError):m.safe(r,'link')
if __name__=='__main__':unittest.main()
