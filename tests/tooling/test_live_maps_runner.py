"""Runner result/selection gates only; not a substitute for native playthroughs."""
from pathlib import Path
import importlib.util
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('live_runner',ROOT/'tools/run_live_maps_contracts.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class RunnerContracts(unittest.TestCase):
    def test_closed_selection(self):
        m.validate_selection(['sawmill','northline','blackwater'],['launch','extract','death'])
        for maps,scenarios in [([],['launch']),(['northline','northline'],['launch']),(['../map'],['launch']),(['northline'],[]),(['northline'],['launch','launch']),(['blackwater'],['synthetic'])]:
            with self.subTest(maps=maps,scenarios=scenarios),self.assertRaises(ValueError):m.validate_selection(maps,scenarios)
    def test_error_diagnostics_override_zero_exit(self):
        marker='LIVE_MAP_CONTRACT_RESULT checks=1 failures=0\n'
        for error in ['SCRIPT ERROR: bad','ERROR: resource missing','Parse Error: type','LIVE_MAP_BAD_ARGS']:
            with self.subTest(error=error),self.assertRaises(RuntimeError):m.check_output(error+'\n'+marker,0,m.CORE)
    def test_missing_duplicate_failure_markers(self):
        marker='LIVE_MAP_CONTRACT_RESULT checks=1 failures=0\n'
        for text in ['',marker*2,marker.replace('failures=0','failures=1'),marker.replace('checks=1','checks=0')]:
            with self.subTest(text=text),self.assertRaises(RuntimeError):m.check_output(text,0,m.CORE)
    def test_nonzero_process_exit(self):
        with self.assertRaises(RuntimeError):m.check_output('LIVE_MAP_CONTRACT_RESULT checks=1 failures=0\n',1,m.CORE)
    def test_exact_map_flow_marker(self):
        result=m.check_output('LIVE_MAP_FLOW_RESULT checks=42 failures=0 map=blackwater case=extract\n',0,m.FLOW)
        self.assertEqual(('42','blackwater','extract'),result.groups())
    def test_exact_cache_marker(self):
        result=m.check_output('LIVE_MAP_CACHE_RESULT maps=2 mode=check failures=0\n',0,m.CACHE)
        self.assertEqual(('2',),result.groups())
    def test_vendor_files_untouched(self):
        text=(ROOT/'tools/run_live_maps_contracts.py').read_text()
        self.assertNotIn('write_text(PROJECT',text)
        self.assertNotIn('extension_list.cfg',text)
        self.assertNotIn('replace(',text)
        self.assertIn('shutil.copytree(ROOT,project',text)
if __name__=='__main__':unittest.main()
