"""Registry identities and accepted atlas declarations survive task-9 promotion."""
import copy
import unittest
import test_art_pipeline as fixtures

p = fixtures.p


class ArtRegistryPromotionTests(unittest.TestCase):
    def test_existing_schema_is_preserved(self):
        recipe, _ = fixtures.fixture()
        additions = p.registry_additions(recipe, "a" * 64)
        base = p.merge_registry(fixtures.base_registry(), additions)
        old = base["assets"][0]
        old["atlas"] = {"source_size": [8, 4], "cell_size": [4, 4],
                        "columns": 2, "rows": 1, "frame_count": 2}
        old["family"] = "accepted_family"
        old["kind"] = "atlas"
        old["semantic_manifest"] = "res://game/content/accepted.json"
        new = p.merge_registry(base, additions)["assets"][0]
        for field in ("atlas", "semantic_manifest", "family", "kind"):
            self.assertEqual(old[field], new[field])
        self.assertEqual("blocked", new["license"]["status"])

    def test_curated_ids_reuse_the_accepted_registry(self):
        recipe = p.read_json(p.DEFAULT_RECIPE)
        self.assertEqual("world.exterior_textures", recipe["sources"][20]["id"])
        self.assertEqual("world.exterior.fenches", recipe["sources"][22]["id"])
        self.assertEqual("Exterior/Fenches.png", recipe["sources"][22]["path"])

    def test_malformed_layers_fail_explicitly(self):
        recipe, _ = fixtures.fixture()
        for layers in ([{}], [None], [1], [True], [["fixture.sheet"]]):
            candidate = copy.deepcopy(recipe)
            candidate["clips"]["idle"]["layers"] = layers
            with self.subTest(layers=layers), self.assertRaises(p.PipelineError):
                p.validate_recipe(candidate)


if __name__ == "__main__":
    unittest.main()
