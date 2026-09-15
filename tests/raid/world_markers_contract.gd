extends SceneTree
## Task 3.11 contract: Typed world markers, stable identities, deterministic
## patrol waypoints, order-independent lookup, and negative grammar rejection.

const LayoutResource = preload("res://game/world/sawmill/sawmill_yard_layout.tres")
const YardScene = preload("res://game/world/sawmill/sawmill_yard.tscn")

const STABLE_ANCHORS := {
	"zerkov.spawn.sawmill.west_service": Vector2i(4, 15),
	"zerkov.loot.sawmill.crate.log_racks": Vector2i(9, 5),
	"zerkov.loot.sawmill.crate.saw_house": Vector2i(21, 4),
	"zerkov.loot.sawmill.crate.settling_dock": Vector2i(25, 14),
	"zerkov.loot.sawmill.service_cache": Vector2i(10, 14),
	"zerkov.loot.sawmill.corpse.haul_lane": Vector2i(29, 12),
	"zerkov.extract.sawmill.road_gate": Vector2i(37, 10),
	"zerkov.encounter.sawmill.scav_cover": Vector2i(30, 6),
	"zerkov.encounter.sawmill.mutant_verge": Vector2i(15, 17),
}

const EXPECTED_PATROL_WAYPOINTS := {
	"zerkov.patrol.sawmill.haul_lane.0": Vector2i(6, 10),
	"zerkov.patrol.sawmill.haul_lane.1": Vector2i(37, 10),
	"zerkov.patrol.sawmill.south_bypass.0": Vector2i(6, 10),
	"zerkov.patrol.sawmill.south_bypass.1": Vector2i(6, 16),
	"zerkov.patrol.sawmill.south_bypass.2": Vector2i(33, 16),
	"zerkov.patrol.sawmill.south_bypass.3": Vector2i(33, 10),
	"zerkov.patrol.sawmill.mill_approach.0": Vector2i(21, 10),
	"zerkov.patrol.sawmill.mill_approach.1": Vector2i(21, 5),
	"zerkov.patrol.sawmill.log_approach.0": Vector2i(9, 10),
	"zerkov.patrol.sawmill.log_approach.1": Vector2i(9, 5),
}

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("WORLD_MARKERS: " + message)


func run() -> void:
	var layout: ZSawmillYardLayout = LayoutResource
	check(layout != null, "authored layout loaded")
	if layout == null:
		print("WORLD_MARKERS_RESULT checks=", checks, " failures=", failures)
		quit(1)
		return

	_test_legacy_ids_preserved(layout)
	_test_authored_anchors_typed_resolution(layout)
	_test_patrol_markers_derivation_and_determinism(layout)
	_test_extraction_zone_cells(layout)
	_test_order_independence(layout)
	_test_kind_filtering(layout)
	_test_identifier_validation_rejections()

	print("WORLD_MARKERS_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_legacy_ids_preserved(layout: ZSawmillYardLayout) -> void:
	check(layout.anchors.size() == STABLE_ANCHORS.size(), "exact 9 authored anchors preserved in array")
	for id in STABLE_ANCHORS.keys():
		var row: Dictionary = layout.anchor(id)
		check(not row.is_empty(), "legacy anchor dictionary lookup preserved: " + id)
		check(row.get("cell") == STABLE_ANCHORS[id], "legacy anchor cell preserved: " + id)
		var m := layout.marker(id)
		check(m != null, "typed marker resolves for legacy id: " + id)
		if m != null:
			check(String(m.marker_id) == id, "marker_id matches legacy id: " + id)
			check(m.cell == STABLE_ANCHORS[id], "marker cell matches legacy position: " + id)


func _test_authored_anchors_typed_resolution(layout: ZSawmillYardLayout) -> void:
	# 1. Spawn marker
	var spawn := layout.marker("zerkov.spawn.sawmill.west_service")
	check(spawn is ZSpawnMarker, "spawn resolves to ZSpawnMarker")
	check(spawn.marker_kind() == &"spawn", "spawn kind is spawn")
	check(spawn.cell == Vector2i(4, 15), "spawn cell is (4, 15)")
	check(spawn.approach_cell == Vector2i(5, 15), "spawn approach_cell is (5, 15)")
	check(spawn.display_name == "WEST SERVICE / SPAWN", "spawn display_name preserved")
	check(spawn.validate().is_empty(), "spawn passes validation")

	# 2. Objective crates (3 crates)
	var obj_keys := [
		"zerkov.loot.sawmill.crate.log_racks",
		"zerkov.loot.sawmill.crate.saw_house",
		"zerkov.loot.sawmill.crate.settling_dock",
	]
	for obj_id in obj_keys:
		var obj := layout.marker(obj_id)
		check(obj is ZObjectiveMarker, "objective resolves to ZObjectiveMarker: " + obj_id)
		check(obj.marker_kind() == &"objective", "objective kind is objective: " + obj_id)
		var obj_marker := obj as ZObjectiveMarker
		check(not String(obj_marker.landmark_id).is_empty(), "objective carries landmark_id: " + obj_id)
		check(not String(obj_marker.content_profile_id).is_empty(), "objective carries content_profile_id: " + obj_id)
		check(obj_marker.validate().is_empty(), "objective passes validation: " + obj_id)

	# 3. Service cache loot marker
	var cache := layout.marker("zerkov.loot.sawmill.service_cache")
	check(cache is ZLootMarker, "cache resolves to ZLootMarker")
	check(cache.marker_kind() == &"loot", "cache kind is loot")
	var cache_marker := cache as ZLootMarker
	check(not cache_marker.is_corpse, "cache is not a corpse")
	check(cache_marker.content_profile_id == &"zerkov.profile.raid.world_crate", "cache has world crate profile")
	check(cache_marker.validate().is_empty(), "cache passes validation")

	# 4. Corpse loot marker
	var corpse := layout.marker("zerkov.loot.sawmill.corpse.haul_lane")
	check(corpse is ZLootMarker, "corpse resolves to ZLootMarker")
	check(corpse.marker_kind() == &"corpse", "corpse kind is corpse")
	var corpse_marker := corpse as ZLootMarker
	check(corpse_marker.is_corpse, "corpse flag is true")
	check(corpse_marker.content_profile_id == &"zerkov.profile.raid.corpse", "corpse has corpse profile")
	check(corpse_marker.validate().is_empty(), "corpse passes validation")

	# 5. Extraction marker
	var extract := layout.marker("zerkov.extract.sawmill.road_gate")
	check(extract is ZExtractionMarker, "extract resolves to ZExtractionMarker")
	check(extract.marker_kind() == &"extract", "extract kind is extract")
	var extract_marker := extract as ZExtractionMarker
	check(extract_marker.zone_cells == Rect2i(36, 9, 3, 3), "extract zone_cells preserved")
	check(extract_marker.zone_cells.has_point(extract_marker.cell), "extract cell inside zone_cells")
	check(extract_marker.validate().is_empty(), "extract passes validation")

	# 6. Encounter staging markers
	var scav := layout.marker("zerkov.encounter.sawmill.scav_cover")
	check(scav is ZEncounterMarker, "scav cover resolves to ZEncounterMarker")
	check(scav.marker_kind() == &"encounter", "scav kind is encounter")
	check(scav.validate().is_empty(), "scav passes validation")

	var mutant := layout.marker("zerkov.encounter.sawmill.mutant_verge")
	check(mutant is ZEncounterMarker, "mutant verge resolves to ZEncounterMarker")
	check(mutant.marker_kind() == &"encounter", "mutant kind is encounter")
	check(mutant.validate().is_empty(), "mutant passes validation")


func _test_patrol_markers_derivation_and_determinism(layout: ZSawmillYardLayout) -> void:
	var patrols := layout.patrol_markers()
	check(patrols.size() == EXPECTED_PATROL_WAYPOINTS.size(), "exact 10 patrol waypoints derived")

	for wp_id in EXPECTED_PATROL_WAYPOINTS.keys():
		var m := layout.marker(wp_id)
		check(m is ZPatrolMarker, "patrol marker resolves: " + wp_id)
		if m is ZPatrolMarker:
			var pm := m as ZPatrolMarker
			check(pm.cell == EXPECTED_PATROL_WAYPOINTS[wp_id], "patrol waypoint cell matches expected: " + wp_id)
			check(pm.marker_kind() == &"patrol", "patrol marker kind is patrol")
			check(not String(pm.route_id).is_empty(), "patrol marker has route_id")
			check(pm.ordinal >= 0, "patrol marker ordinal is non-negative")
			var manhattan := absi(pm.cell.x - pm.approach_cell.x) + absi(pm.cell.y - pm.approach_cell.y)
			check(manhattan == 1, "patrol waypoint approach cell is adjacent (manhattan 1): " + wp_id)
			check(pm.validate().is_empty(), "patrol waypoint passes validation: " + wp_id)

	# Deterministic construction proof: two separate instantiations yield identical waypoints
	var fresh_layout := ZSawmillYardLayout.new()
	fresh_layout.level_id = layout.level_id
	fresh_layout.revision = layout.revision
	fresh_layout.size_cells = layout.size_cells
	fresh_layout.anchors = layout.anchors.duplicate(true)
	fresh_layout.routes = layout.routes.duplicate(true)

	var fresh_patrols := fresh_layout.patrol_markers()
	check(fresh_patrols.size() == patrols.size(), "re-derivation has identical count across two constructions")
	for i in patrols.size():
		var a := patrols[i]
		var b := fresh_patrols[i]
		check(a.marker_id == b.marker_id, "waypoint %d id matches across constructions: %s" % [i, a.marker_id])
		check(a.cell == b.cell, "waypoint %d cell matches across constructions: %s" % [i, a.marker_id])
		check(a.approach_cell == b.approach_cell, "waypoint %d approach matches: %s" % [i, a.marker_id])
		check(a.route_id == b.route_id, "waypoint %d route_id matches: %s" % [i, a.marker_id])
		check(a.ordinal == b.ordinal, "waypoint %d ordinal matches: %s" % [i, a.marker_id])
		check(a.display_name == b.display_name, "waypoint %d display_name matches: %s" % [i, a.marker_id])


func _test_extraction_zone_cells(layout: ZSawmillYardLayout) -> void:
	var extract := layout.marker("zerkov.extract.sawmill.road_gate") as ZExtractionMarker
	check(extract != null, "extraction marker found")
	check(extract.zone_cells == Rect2i(36, 9, 3, 3), "exact authored zone_cells: Rect2i(36, 9, 3, 3)")
	check(extract.zone_cells.has_point(extract.cell), "extraction marker cell is inside zone_cells")

	# Negative control: extraction marker with cell outside zone_cells fails validation
	var bad_extract := ZExtractionMarker.new()
	bad_extract.marker_id = &"zerkov.extract.sawmill.test_bad"
	bad_extract.display_name = "BAD EXTRACT"
	bad_extract.cell = Vector2i(0, 0)
	bad_extract.approach_cell = Vector2i(1, 0)
	bad_extract.zone_cells = Rect2i(10, 10, 2, 2)
	var problems := bad_extract.validate()
	check(not problems.is_empty(), "extraction marker with cell outside zone fails validation")
	var has_containment_issue := false
	for p in problems:
		if "does not contain" in p:
			has_containment_issue = true
	check(has_containment_issue, "diagnostic contains containment failure message")

	# Negative control: non-positive zone size fails validation
	bad_extract.cell = Vector2i(10, 10)
	bad_extract.zone_cells = Rect2i(10, 10, 0, 2)
	check(not bad_extract.validate().is_empty(), "non-positive zone size fails validation")


func _test_order_independence(layout: ZSawmillYardLayout) -> void:
	# 1. Shuffled source order test:
	# Create layout with reverse anchors order and reversed routes order
	var reversed_layout := ZSawmillYardLayout.new()
	reversed_layout.level_id = layout.level_id
	reversed_layout.anchors = layout.anchors.duplicate(true)
	reversed_layout.anchors.reverse()
	reversed_layout.routes = layout.routes.duplicate(true)
	reversed_layout.routes.reverse()

	for id in STABLE_ANCHORS.keys():
		var original := layout.marker(id)
		var resolved := reversed_layout.marker(id)
		check(resolved != null, "lookup succeeds under reversed source order: " + id)
		check(resolved.cell == original.cell, "resolved cell matches under reversed order: " + id)
		check(resolved.approach_cell == original.approach_cell, "resolved approach matches: " + id)
		check(resolved.marker_kind() == original.marker_kind(), "resolved kind matches: " + id)

	# 2. Scene-tree node order independence
	var yard := YardScene.instantiate() as ZSawmillYard
	root.add_child(yard)
	var anchor_root := yard.get_node("Anchors")
	# Move first child to last
	anchor_root.move_child(anchor_root.get_child(0), anchor_root.get_child_count() - 1)

	for id in STABLE_ANCHORS.keys():
		var m := yard.marker(id)
		check(m != null, "yard lookup is independent of node order: " + id)
		check(m.cell == STABLE_ANCHORS[id], "yard marker position is correct after child reorder: " + id)

	yard.free()


func _test_kind_filtering(layout: ZSawmillYardLayout) -> void:
	check(layout.markers_of_kind(&"spawn").size() == 1, "kind 'spawn' returns 1 marker")
	check(layout.markers_of_kind(&"objective").size() == 3, "kind 'objective' returns 3 markers")
	check(layout.markers_of_kind(&"objective_crate").size() == 3, "kind 'objective_crate' returns 3 markers")
	check(layout.markers_of_kind(&"corpse").size() == 1, "kind 'corpse' returns 1 marker")
	check(layout.markers_of_kind(&"extract").size() == 1, "kind 'extract' returns 1 marker")
	check(layout.markers_of_kind(&"extraction").size() == 1, "kind 'extraction' returns 1 marker")
	check(layout.markers_of_kind(&"patrol").size() == 10, "kind 'patrol' returns 10 waypoints")
	check(layout.markers_of_kind(&"encounter").size() == 2, "kind 'encounter' returns 2 markers")
	check(layout.all_markers().size() == 19, "all_markers returns 19 total markers (9 anchors + 10 patrol)")

	# Typed class query
	check(layout.markers_of_kind(ZSpawnMarker).size() == 1, "filtering by ZSpawnMarker class returns 1")
	check(layout.markers_of_kind(ZObjectiveMarker).size() == 3, "filtering by ZObjectiveMarker class returns 3")
	check(layout.markers_of_kind(ZPatrolMarker).size() == 10, "filtering by ZPatrolMarker class returns 10")
	check(layout.markers_of_kind(ZExtractionMarker).size() == 1, "filtering by ZExtractionMarker class returns 1")


func _test_identifier_validation_rejections() -> void:
	# 1. Empty ID
	var empty_m := ZSpawnMarker.new()
	empty_m.marker_id = &""
	empty_m.display_name = "EMPTY"
	var p_empty := empty_m.validate()
	check(not p_empty.is_empty(), "empty marker_id is rejected")
	check(_problems_contain(p_empty, "empty"), "empty diagnostic present")

	# 2. Uppercase ID
	var upper_m := ZSpawnMarker.new()
	upper_m.marker_id = &"zerkov.spawn.sawmill.WEST_SERVICE"
	upper_m.display_name = "UPPERCASE"
	var p_upper := upper_m.validate()
	check(not p_upper.is_empty(), "uppercase ID is rejected: zerkov.spawn.sawmill.WEST_SERVICE")
	check(_problems_contain(p_upper, "upper-case") and _problems_contain(p_upper, "WEST_SERVICE"),
		"uppercase diagnostic contains offending ID: zerkov.spawn.sawmill.WEST_SERVICE")

	# 3. Whitespace ID
	var white_m := ZSpawnMarker.new()
	white_m.marker_id = &"zerkov.spawn.sawmill.west service"
	white_m.display_name = "WHITESPACE"
	var p_white := white_m.validate()
	check(not p_white.is_empty(), "whitespace ID is rejected: zerkov.spawn.sawmill.west service")
	check(_problems_contain(p_white, "whitespace") and _problems_contain(p_white, "west service"),
		"whitespace diagnostic contains offending ID: zerkov.spawn.sawmill.west service")

	# 4. Malformed grammar (too few segments)
	var malformed_m := ZSpawnMarker.new()
	malformed_m.marker_id = &"bad_id_without_namespace"
	malformed_m.display_name = "MALFORMED"
	var p_malformed := malformed_m.validate()
	check(not p_malformed.is_empty(), "malformed ID is rejected: bad_id_without_namespace")
	check(_problems_contain(p_malformed, "bad_id_without_namespace"),
		"malformed diagnostic contains offending ID: bad_id_without_namespace")

	# 5. Wrong kind namespace in typed marker
	var wrong_kind_m := ZSpawnMarker.new()
	wrong_kind_m.marker_id = &"zerkov.loot.sawmill.crate.test"
	wrong_kind_m.display_name = "WRONG KIND"
	var p_wrong := wrong_kind_m.validate()
	check(not p_wrong.is_empty(), "spawn marker with loot ID is rejected")
	check(_problems_contain(p_wrong, "zerkov.loot.sawmill.crate.test"),
		"wrong kind diagnostic contains offending ID: zerkov.loot.sawmill.crate.test")

	# 6. Duplicate ID detection across ALL marker kinds fails loudly
	var dup_layout := ZSawmillYardLayout.new()
	dup_layout.anchors = [
		{
			"id": "zerkov.spawn.sawmill.west_service",
			"kind": "spawn",
			"name": "FIRST SPAWN",
			"cell": Vector2i(4, 15),
			"approach_cell": Vector2i(5, 15),
		},
		{
			"id": "zerkov.spawn.sawmill.west_service", # Exact duplicate!
			"kind": "spawn",
			"name": "DUPLICATE SPAWN",
			"cell": Vector2i(4, 15),
			"approach_cell": Vector2i(5, 15),
		},
	]
	var dup_problems := dup_layout.validate_markers()
	check(not dup_problems.is_empty(), "duplicate ID in layout is rejected")
	check(_problems_contain(dup_problems, "duplicate_marker_id: zerkov.spawn.sawmill.west_service"),
		"duplicate diagnostic contains exact offending identifier: zerkov.spawn.sawmill.west_service")


func _problems_contain(problems: Array[String], fragment: String) -> bool:
	for p in problems:
		if fragment in p:
			return true
	return false
