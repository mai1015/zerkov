"""Follow-up negative controls for public compiler entrypoints and promotion."""
import copy
from pathlib import Path
import tempfile
import unittest
import test_art_pipeline as f
p = f.p


class ArtHardeningTests(unittest.TestCase):
    def test_read_selected_validates_before_archive_access(self):
        recipe, _ = f.fixture()
        recipe['sources'][0]['path'] = 'Characters (DO NOT USE)/trap.png'
        with self.assertRaisesRegex(p.PipelineError, 'forbidden'):
            p.read_selected(Path('/missing.zip'), 'zerkov', recipe)

    def test_plan_revalidates_pixels_even_without_archive_reader(self):
        recipe, data = f.fixture()
        recipe['sources'][0]['size'] = [16, 4]
        with self.assertRaisesRegex(p.PipelineError, 'dimensions/format'):
            p.build_plan(recipe, {'fixture.sheet': data}, 'a' * 64)

    def test_plan_requires_exact_source_set(self):
        recipe, data = f.fixture()
        with self.assertRaises(p.PipelineError):
            p.build_plan(recipe, {'fixture.sheet': data, 'extra': data}, 'a' * 64)

    def test_promote_preserves_all_authoring_metadata(self):
        recipe, _ = f.fixture()
        additions = p.registry_additions(recipe, 'a' * 64)
        base = p.merge_registry(f.base_registry(), additions)
        old = base['assets'][0]
        old['custom_authored_field'] = {'important': [1, 2, 3]}
        old['license'] = {'status': 'cleared', 'name': 'MIT', 'reference': 'licenses/test.txt'}
        result = p.merge_registry(base, additions)['assets'][0]
        self.assertEqual(old['custom_authored_field'], result['custom_authored_field'])
        self.assertEqual(old['license'], result['license'])
        result['custom_authored_field']['important'].clear()
        self.assertEqual([1, 2, 3], old['custom_authored_field']['important'])

    def test_duplicate_promotion_is_rejected(self):
        recipe, _ = f.fixture()
        additions = p.registry_additions(recipe, 'a' * 64)
        with self.assertRaisesRegex(p.PipelineError, 'duplicate promotion'):
            p.merge_registry(f.base_registry(), additions * 2)

    def test_alias_collision_is_case_insensitive(self):
        recipe, _ = f.fixture()
        additions = p.registry_additions(recipe, 'a' * 64)
        base = p.merge_registry(f.base_registry(), additions)
        other = copy.deepcopy(additions[0])
        other.update(id='zerkov.asset.other', aliases=['FIXTURE.SHEET'], runtime_path='res://assets/other.png')
        with self.assertRaisesRegex(p.PipelineError, 'alias collision'):
            p.merge_registry(base, [other])

    def test_runtime_path_collision_is_case_insensitive(self):
        recipe, _ = f.fixture()
        additions = p.registry_additions(recipe, 'a' * 64)
        base = p.merge_registry(f.base_registry(), additions)
        other = copy.deepcopy(additions[0])
        other.update(id='zerkov.asset.other', aliases=['other'], runtime_path=other['runtime_path'].upper())
        with self.assertRaisesRegex(p.PipelineError, 'runtime path collision'):
            p.merge_registry(base, [other])

    def test_base_boolean_version_is_rejected(self):
        base = f.base_registry()
        base['schema_version'] = True
        with self.assertRaises(p.PipelineError):
            p.merge_registry(base, [])


if __name__ == '__main__':
    unittest.main()
