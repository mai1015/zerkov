from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class RoofedClinicSourceTests(unittest.TestCase):
    def test_live_map_instances_roof_without_new_gameplay_geometry(self):
        live = (ROOT / "game/world/live_maps/northline_live.tscn").read_text()
        self.assertIn("northline_clinic_cutaway.tscn", live)
        self.assertIn("position = Vector2(992, 1200)", live)
        clinic = (ROOT / "game/world/buildings/northline_clinic_cutaway.tscn").read_text()
        self.assertNotIn('type="StaticBody2D"', clinic)
        self.assertNotIn('type="Area2D"', clinic)
        self.assertNotIn("metadata/gameplay_id", clinic)
        self.assertNotIn("script = ", clinic)

    def test_roof_has_explicit_cutaway_contract_and_landmarks(self):
        clinic = (ROOT / "game/world/buildings/northline_clinic_cutaway.tscn").read_text()
        self.assertIn('metadata/cutaway_id = "northline.clinic.main"', clinic)
        self.assertIn("PackedVector2Array(0, 0, 352, 0, 352, 216, 0, 216)", clinic)
        for landmark in ("CutawayVisuals", "Helipad", "SkylightGlass", "HVACWest", "EntranceCanopy"):
            self.assertIn(f'name="{landmark}"', clinic)

    def test_controller_is_event_driven_and_presentation_only(self):
        source = (ROOT / "game/presentation/local/local_roof_cutaway_controller.gd").read_text()
        self.assertNotIn("func _process", source)
        self.assertNotIn("func _physics_process", source)
        self.assertIn('tween_property(visual, "modulate:a"', source)
        for forbidden in ("collision_layer =", ".disabled =", "enqueue_intent", "ProfileStore", "RaidAuthority", "inventory."):
            self.assertNotIn(forbidden, source)

    def test_raid_session_updates_from_authoritative_position(self):
        source = (ROOT / "game/bootstrap/local/local_raid_session.gd").read_text()
        self.assertIn("LocalRoofCutawayController.new()", source)
        self.assertIn("_roof_cutaway.update_position(player_movement.position_px)", source)
        self.assertIn("_roof_cutaway.release()", source)

if __name__ == "__main__":
    unittest.main()
