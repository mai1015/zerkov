"""Filesystem/invocation guards only; these do not simulate native discovery."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('probe_import', Path(__file__).with_name('probe_import.py'))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class GuardTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.engine = self.root / 'not-executed-engine'
        self.engine.write_bytes(b'test bytes, not an executable')
        self.library = self.root / 'not-loaded-library'
        self.library.write_bytes(b'test bytes, not a library')
        self.expected = probe.digest(self.engine)
        self.output = self.root / 'fresh-output'

    def prepare(self, library=None, explicit=False, symbol='discovery_probe_init'):
        return probe.prepare(self.engine, self.output, library, symbol, explicit, self.expected)

    def test_wrong_engine_fails_before_output(self):
        with self.assertRaisesRegex(ValueError, 'Engine differs'):
            probe.prepare(self.engine, self.output, None, 'probe', False, '0' * 64)
        self.assertFalse(self.output.exists())

    def test_existing_output_never_deleted(self):
        self.output.mkdir()
        sentinel = self.output / 'keep'
        sentinel.write_bytes(b'keep')
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(b'keep', sentinel.read_bytes())

    def test_checkout_output_rejected(self):
        with patch.object(probe, 'ROOT', self.root):
            with self.assertRaisesRegex(ValueError, 'outside'): self.prepare()
        self.assertFalse(self.output.exists())

    def test_explicit_without_library_rejected(self):
        with self.assertRaises(ValueError): self.prepare(explicit=True)
        self.assertFalse(self.output.exists())

    def test_bad_symbol_rejected(self):
        with self.assertRaises(ValueError): self.prepare(self.library, symbol='bad\nvalue')
        self.assertFalse(self.output.exists())

    def test_auto_project_is_truly_unseeded(self):
        command, env, data = self.prepare(self.library)
        self.assertFalse((self.output / 'project/.godot').exists())
        self.assertEqual(self.library.read_bytes(), (self.output / 'project/control.so').read_bytes())
        self.assertIn('--import', command)
        self.assertIn('--quit', command)
        self.assertNotEqual(env['HOME'], env['XDG_CACHE_HOME'])
        self.assertFalse(data['promotion_approved'])
        self.assertFalse(data['engine_fix_validated'])

    def test_explicit_project_seeds_only_descriptor_list(self):
        _, _, data = self.prepare(self.library, True)
        files = list((self.output / 'project/.godot').iterdir())
        self.assertEqual(['extension_list.cfg'], [p.name for p in files])
        self.assertEqual('res://control.gdextension\n', files[0].read_text())
        self.assertTrue(data['explicit_startup_registration'])
        self.assertFalse(data['preseeded_script_cache'])

    def test_native_errors_are_recognized(self):
        for data in [b'SCRIPT ERROR: x', b'ERROR: x', b'\n  ERROR: x']:
            self.assertIsNotNone(probe.ERRORS.search(data))
        self.assertIsNone(probe.ERRORS.search(b'normal output'))


if __name__ == '__main__':
    unittest.main()
