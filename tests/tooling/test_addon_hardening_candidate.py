"""Candidate patch confinement tests. Never fake native runtime acceptance."""
from __future__ import annotations
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('candidate',ROOT/'tools/addon_hardening/candidate.py')
candidate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)

class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name);self.source=self.base/'source';self.source.mkdir()
        self.kit=self.base/'kit';self.kit.mkdir();(self.kit/'fixtures').mkdir()
        for name in ['SConstruct','native_network_contract.gd.in']:
            (self.kit/'fixtures'/name).write_text('test fixture, not native code')
        for name in candidate.PACKAGES:
            p=self.source/f'addons/{name}/native/file.cpp';p.parent.mkdir(parents=True);p.write_text('old\n')
        for relative in ['game/combat/content/zerkov_combat_content.gd','game/combat/melee/melee_policy.gd']:
            p=self.source/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('test input')
        subprocess.run(['git','init','-q',str(self.source)],check=True)
        subprocess.run(['git','add','.'],cwd=self.source,check=True)
        subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@local','commit','-qm','fixture'],cwd=self.source,check=True)
        self.path='addons/weapon_system/native/file.cpp'
        self.normal='diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n@@ -1 +1 @@\n-old\n+new\n'.format(p=self.path)
        self.manifest={'installed_update':False,'base_revision':'a'*40,'files':{
            self.path:{'before':hashlib.sha256(b'old\n').hexdigest(),'after':hashlib.sha256(b'new\n').hexdigest()}}}
        self.write(self.normal)
        binding=patch.object(candidate,'KIT',self.kit);binding.start();self.addCleanup(binding.stop)
    def write(self,text):
        (self.kit/'native-hardening.patch').write_text(text)
        self.manifest['patch_sha256']=candidate.sha(self.kit/'native-hardening.patch')
        (self.kit/'manifest.json').write_text(json.dumps(self.manifest))
    def run_stage(self):
        with contextlib.redirect_stdout(io.StringIO()): return candidate.stage(self.source,self.base/'output')
    def test_only_external_candidate_changes(self):
        before=candidate.files(self.source)
        report=self.run_stage()
        self.assertEqual(before,candidate.files(self.source))
        self.assertEqual('new\n',(self.base/'output/project'/self.path).read_text())
        self.assertFalse(report['installed_update'])
    def test_modified_preimage_rejected(self):
        (self.source/self.path).write_text('changed\n')
        with self.assertRaisesRegex(ValueError,'preimage'): self.run_stage()
        self.assertFalse((self.base/'output').exists())
    def test_patch_checksum_rejected_before_execution(self):
        (self.kit/'native-hardening.patch').write_text('something else')
        with self.assertRaisesRegex(ValueError,'checksum'): self.run_stage()
        self.assertFalse((self.base/'output').exists())
    def test_postimage_mismatch_cannot_be_accepted(self):
        self.manifest['files'][self.path]['after']='b'*64;self.write(self.normal)
        with self.assertRaisesRegex(ValueError,'postimage'): self.run_stage()
        self.assertEqual('old\n',(self.source/self.path).read_text())
    def test_pure_rename_not_hidden_by_absent_plus_lines(self):
        text=self.normal+'diff --git a/addons/gameplay_abilities/native/file.cpp b/renamed.cpp\nsimilarity index 100%\nrename from addons/gameplay_abilities/native/file.cpp\nrename to renamed.cpp\n'
        self.write(text)
        with self.assertRaisesRegex(ValueError,'undeclared'): self.run_stage()
        self.assertTrue((self.source/'addons/gameplay_abilities/native/file.cpp').exists())
    def test_deletion_not_hidden_by_dev_null(self):
        text=self.normal+'diff --git a/addons/gameplay_abilities/native/file.cpp b/addons/gameplay_abilities/native/file.cpp\ndeleted file mode 100644\n--- a/addons/gameplay_abilities/native/file.cpp\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n'
        self.write(text)
        with self.assertRaisesRegex(ValueError,'undeclared'): self.run_stage()
    def test_cannot_declare_deletion_as_postimage(self):
        self.manifest['files'][self.path]['after']=None;self.write(self.normal)
        with self.assertRaises((ValueError,TypeError)):self.run_stage()
    def test_undeclared_addition_rejected(self):
        text=self.normal+'diff --git a/extra.txt b/extra.txt\nnew file mode 100644\n--- /dev/null\n+++ b/extra.txt\n@@ -0,0 +1 @@\n+extra\n'
        self.write(text)
        with self.assertRaisesRegex(ValueError,'undeclared'):self.run_stage()
    def test_manifest_outside_addon_native_rejected(self):
        self.manifest['files']={'game/script.gd':next(iter(self.manifest['files'].values()))};self.write(self.normal)
        with self.assertRaisesRegex(ValueError,'outside'):self.run_stage()
    def test_symlink_input_rejected(self):
        p=self.source/self.path;p.unlink();target=self.base/'external';target.write_text('old\n')
        try:p.symlink_to(target)
        except OSError:self.skipTest('host disallows symlink')
        with self.assertRaisesRegex(ValueError,'symlink'):self.run_stage()
    def test_output_inside_source_or_existing_rejected(self):
        for out in [self.source/'new-output',self.source,self.base]:
            with self.subTest(out=out),self.assertRaises(ValueError):candidate.stage(self.source,out)
    def test_path_escapes_rejected(self):
        for value in ['../x','/tmp/x','addons/x/../../../../x','C:/x','addons\\x']:
            with self.subTest(value=value),self.assertRaises(ValueError):candidate.safe(self.source,value)
    def test_nonzero_process_or_engine_error_not_pass(self):
        for result in [subprocess.CompletedProcess([],1,'ADDON_NETWORK_RESULT checks=1 failures=0'),subprocess.CompletedProcess([],0,'SCRIPT ERROR: fail\nADDON_NETWORK_RESULT checks=1 failures=0')]:
            with patch.object(candidate.subprocess,'run',return_value=result),contextlib.redirect_stdout(io.StringIO()),self.assertRaises(RuntimeError):candidate.run(['test'],cwd=self.base,marker='ADDON_NETWORK_RESULT')
    def test_missing_terminal_marker_not_pass(self):
        with patch.object(candidate.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'engine opened')),contextlib.redirect_stdout(io.StringIO()),self.assertRaises(RuntimeError):candidate.run(['test'],cwd=self.base,marker='ADDON_NETWORK_RESULT')

if __name__=='__main__': unittest.main()
