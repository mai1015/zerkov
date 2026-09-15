extends SceneTree
## Task 3.12 Contract: Headless Sawmill validation suite.
##
## Validates the real authored Sawmill Yard level across five check families:
## 1. Required anchors: spawn, 3 objective crates, service cache, corpse,
##    Road Gate extract, and both encounter anchors exist, resolve to the
##    correct typed classes, sit within bounds, and reference valid content.
## 2. Collisions: no anchor or approach cell sits inside blocking geometry;
##    no two anchors illegally overlap; authored structures produce the
##    collision set task 3.6 resolves against.
## 3. Reachable extract: deterministic task 3.9 path seam connects spawn and
##    all objective crates to the Road Gate extraction zone.
## 4. Occluder bounds: baked task 3.10 segments lie within the level rect,
##    convert in Vision space, trace to authored sources, and respect the
##    128-segment budget.
## 5. Duplicate identifiers: unified combined namespace sweep across terrain
##    regions, details, structures, landmarks, anchors, markers, patrol
##    waypoints, routes, and occluder segments.
##
## Also executes exhaustive negative controls with deliberately corrupted inputs
## verifying that all check families reject defects with actionable messages.

const LayoutResource = preload("res://game/world/sawmill/sawmill_yard_layout.tres")

static var REQUIRED_ANCHORS: Dictionary = {
	"zerkov.spawn.sawmill.west_service": {
		"class": ZSpawnMarker,
		"kind": &"spawn",
		"cell": Vector2i(4, 15),
		"approach_cell": Vector2i(5, 15),
	},
	"zerkov.loot.sawmill.crate.log_racks": {
		"class": ZObjectiveMarker,
		"kind": &"objective",
		"cell": Vector2i(9, 5),
		"approach_cell": Vector2i(9, 6),
		"landmark_id": &"zerkov.landmark.sawmill.log_racks",
		"content_profile_id": &"zerkov.profile.raid.world_crate",
	},
	"zerkov.loot.sawmill.crate.saw_house": {
		"class": ZObjectiveMarker,
		"kind": &"objective",
		"cell": Vector2i(21, 4),
		"approach_cell": Vector2i(21, 5),
		"landmark_id": &"zerkov.landmark.sawmill.saw_house",
		"content_profile_id": &"zerkov.profile.raid.world_crate",
	},
	"zerkov.loot.sawmill.crate.settling_dock": {
		"class": ZObjectiveMarker,
		"kind": &"objective",
		"cell": Vector2i(25, 14),
		"approach_cell": Vector2i(25, 15),
		"landmark_id": &"zerkov.landmark.sawmill.settling_dock",
		"content_profile_id": &"zerkov.profile.raid.world_crate",
	},
	"zerkov.loot.sawmill.service_cache": {
		"class": ZLootMarker,
		"kind": &"loot",
		"cell": Vector2i(10, 14),
		"approach_cell": Vector2i(10, 15),
		"is_corpse": false,
		"content_profile_id": &"zerkov.profile.raid.world_crate",
	},
	"zerkov.loot.sawmill.corpse.haul_lane": {
		"class": ZLootMarker,
		"kind": &"corpse",
		"cell": Vector2i(29, 12),
		"approach_cell": Vector2i(29, 11),
		"is_corpse": true,
		"content_profile_id": &"zerkov.profile.raid.corpse",
	},
	"zerkov.extract.sawmill.road_gate": {
		"class": ZExtractionMarker,
		"kind": &"extract",
		"cell": Vector2i(37, 10),
		"approach_cell": Vector2i(36, 10),
		"zone_cells": Rect2i(36, 9, 3, 3),
	},
	"zerkov.encounter.sawmill.scav_cover": {
		"class": ZEncounterMarker,
		"kind": &"encounter",
		"cell": Vector2i(30, 6),
		"approach_cell": Vector2i(31, 6),
	},
	"zerkov.encounter.sawmill.mutant_verge": {
		"class": ZEncounterMarker,
		"kind": &"encounter",
		"cell": Vector2i(15, 17),
		"approach_cell": Vector2i(16, 17),
	},
}

const BODY_HALF_EXTENTS_PX := Vector2(8.0, 8.0)
const PROBE_GENERATION := 0

static var _probe_counter: int = 0

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SAWMILL_CONTRACT: " + message)


func run() -> void:
	var layout: ZSawmillYardLayout = LayoutResource
	check(layout != null, "authored layout resource loaded")
	if layout == null:
		print("SAWMILL_CONTRACT_RESULT checks=", checks, " failures=", failures)
		quit(1)
		return

	# 1. Build dependencies
	var movement_world := ZMovementWorldBuilder.build_from_sawmill_layout(layout, PROBE_GENERATION)
	check(movement_world != null, "ZMovementWorldBuilder successfully builds movement world")

	var nav_grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	check(nav_grid != null and nav_grid.is_baked(), "ZNavigationGrid successfully bakes navigation grid")

	var nav_service := ZNavigationPathService.new()
	var nav_configured := nav_service.configure(nav_grid, nav_grid.revision())
	check(nav_configured, "ZNavigationPathService successfully configured with grid")

	var occluder_bake := ZOccluderBake.bake(layout.structures, layout.size_cells)
	check(occluder_bake.get("ok", false) == true, "ZOccluderBake successfully bakes structures")

	# 2. Positive check families against the real Sawmill level
	_run_family_1_required_anchors(layout)
	_run_family_2_collisions(layout, movement_world)
	_run_family_3_reachable_extract(layout, nav_service, nav_grid.revision())
	_run_family_4_occluder_bounds(layout, occluder_bake)
	_run_family_5_duplicate_identifiers(layout, occluder_bake.get("segments", []))

	# 3. Negative controls (broken inputs rejected with actionable diagnostics)
	_run_negative_controls(layout, movement_world, nav_service, nav_grid.revision(), occluder_bake)

	print("SAWMILL_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


# ==============================================================================
# FAMILY 1: Required Anchors
# ==============================================================================

func _run_family_1_required_anchors(layout: ZSawmillYardLayout) -> void:
	var findings := check_required_anchors(layout)
	check(findings.is_empty(), "real layout passes required anchors validation (findings: %s)" % str(findings))

	# Explicit contract guarantees on required anchors
	for anchor_id in REQUIRED_ANCHORS.keys():
		var expected: Dictionary = REQUIRED_ANCHORS[anchor_id]
		var m := layout.marker(anchor_id)
		check(m != null, "anchor exists: " + anchor_id)
		if m == null:
			continue
		var expected_class: Variant = expected["class"]
		check(is_instance_of(m, expected_class),
			"anchor %s is instance of %s" % [anchor_id, (expected_class as GDScript).resource_path.get_file()])
		check(m.cell == expected["cell"],
			"anchor %s cell matches authored position %s" % [anchor_id, str(expected["cell"])])
		check(m.approach_cell == expected["approach_cell"],
			"anchor %s approach_cell matches %s" % [anchor_id, str(expected["approach_cell"])])
		check(_manhattan(m.cell, m.approach_cell) == 1,
			"anchor %s approach_cell is adjacent (manhattan=1)" % anchor_id)
		check(Rect2i(Vector2i.ZERO, layout.size_cells).has_point(m.cell),
			"anchor %s cell sits inside level bounds" % anchor_id)
		check(Rect2i(Vector2i.ZERO, layout.size_cells).has_point(m.approach_cell),
			"anchor %s approach_cell sits inside level bounds" % anchor_id)
		check(m.validate().is_empty(), "anchor %s passes self-validation" % anchor_id)

	# Objective crates landmark reference checks
	var log_racks := layout.marker("zerkov.loot.sawmill.crate.log_racks") as ZObjectiveMarker
	check(log_racks != null and log_racks.landmark_id == &"zerkov.landmark.sawmill.log_racks",
		"log_racks references valid landmark")
	var saw_house := layout.marker("zerkov.loot.sawmill.crate.saw_house") as ZObjectiveMarker
	check(saw_house != null and saw_house.landmark_id == &"zerkov.landmark.sawmill.saw_house",
		"saw_house references valid landmark")
	var settling_dock := layout.marker("zerkov.loot.sawmill.crate.settling_dock") as ZObjectiveMarker
	check(settling_dock != null and settling_dock.landmark_id == &"zerkov.landmark.sawmill.settling_dock",
		"settling_dock references valid landmark")

	# Extraction zone checks
	var extract := layout.marker("zerkov.extract.sawmill.road_gate") as ZExtractionMarker
	check(extract != null, "extraction marker resolved")
	if extract != null:
		check(extract.zone_cells == Rect2i(36, 9, 3, 3), "extraction zone_cells match authored rect")
		check(extract.zone_cells.has_point(extract.cell), "extraction marker cell within zone_cells")
		check(Rect2i(Vector2i.ZERO, layout.size_cells).encloses(extract.zone_cells),
			"extraction zone_cells fully enclosed by level bounds")

	# Derived patrol waypoints checks
	var patrols := layout.patrol_markers()
	check(patrols.size() == 10, "10 derived patrol waypoints exist")
	for pm in patrols:
		check(Rect2i(Vector2i.ZERO, layout.size_cells).has_point(pm.cell),
			"patrol marker %s cell inside level bounds" % pm.marker_id)
		check(Rect2i(Vector2i.ZERO, layout.size_cells).has_point(pm.approach_cell),
			"patrol marker %s approach inside level bounds" % pm.marker_id)


static func check_required_anchors(layout: ZSawmillYardLayout) -> Array[String]:
	var findings: Array[String] = []
	var level_rect := Rect2i(Vector2i.ZERO, layout.size_cells)

	for req_id in REQUIRED_ANCHORS.keys():
		var expected: Dictionary = REQUIRED_ANCHORS[req_id]
		var m := layout.marker(req_id)
		if m == null:
			findings.append("missing_required_anchor: %s" % req_id)
			continue

		var expected_class: Variant = expected["class"]
		if not is_instance_of(m, expected_class):
			findings.append("wrong_class: %s expected %s but was %s" % [
				req_id,
				(expected_class as GDScript).resource_path.get_file(),
				m.get_class()
			])

		if not level_rect.has_point(m.cell):
			findings.append("out_of_bounds: %s cell %s outside level bounds %s" % [
				req_id, str(m.cell), str(level_rect)
			])

		if not level_rect.has_point(m.approach_cell):
			findings.append("approach_out_of_bounds: %s approach_cell %s outside level bounds %s" % [
				req_id, str(m.approach_cell), str(level_rect)
			])

		var val_errors := m.validate()
		if not val_errors.is_empty():
			findings.append("validation_failed: %s errors=%s" % [req_id, str(val_errors)])

		# Content reference checks
		if m is ZObjectiveMarker:
			var om := m as ZObjectiveMarker
			var l_found := false
			for lm in layout.landmarks:
				if lm.get("id", "") == String(om.landmark_id):
					l_found = true
					break
			if not l_found:
				findings.append("missing_landmark: %s references unknown landmark '%s'" % [req_id, om.landmark_id])
			if om.content_profile_id.is_empty():
				findings.append("missing_content_profile: %s content_profile_id is empty" % req_id)

		elif m is ZLootMarker:
			var lm := m as ZLootMarker
			if lm.content_profile_id.is_empty():
				findings.append("missing_content_profile: %s content_profile_id is empty" % req_id)

		elif m is ZExtractionMarker:
			var em := m as ZExtractionMarker
			if not level_rect.encloses(em.zone_cells):
				findings.append("zone_out_of_bounds: %s zone_cells %s outside bounds %s" % [
					req_id, str(em.zone_cells), str(level_rect)
				])
			if not em.zone_cells.has_point(em.cell):
				findings.append("zone_does_not_contain_cell: %s zone_cells %s does not contain cell %s" % [
					req_id, str(em.zone_cells), str(em.cell)
				])

	return findings


# ==============================================================================
# FAMILY 2: Collisions
# ==============================================================================

func _run_family_2_collisions(layout: ZSawmillYardLayout, world: ZMovementWorld2D) -> void:
	var findings := check_collisions(layout, world)
	check(findings.is_empty(), "real layout passes collision validation (findings: %s)" % str(findings))

	# Assert against task 3.6 authoritative geometry
	var canonical := world.canonical_record()
	var colliders: Array = canonical.get("colliders", [])
	check(colliders.size() == 23, "movement world contains exactly 23 static colliders from Obstacles layer")

	# Check that every Obstacles structure is registered as a collider
	var obstacle_count := 0
	for row in layout.structures:
		if row.get("layer") == "Obstacles":
			obstacle_count += 1
			var s_id: String = row.get("id")
			var found := false
			for col in colliders:
				if col.get("id") == s_id:
					found = true
					break
			check(found, "structure %s is registered as static collider in movement world" % s_id)
		elif row.get("layer") == "Canopy":
			var s_id: String = row.get("id")
			var found := false
			for col in colliders:
				if col.get("id") == s_id:
					found = true
					break
			check(not found, "Canopy structure %s is NOT a static collider in movement world" % s_id)

	check(obstacle_count == 23, "layout authored 23 Obstacles structures")
	check(canonical.get("bounds_id") == layout.level_id, "movement world bounds_id matches level_id")


static func check_collisions(layout: ZSawmillYardLayout, world: ZMovementWorld2D) -> Array[String]:
	var findings: Array[String] = []
	_probe_counter += 1
	var run_tag := "run%d" % _probe_counter

	# Check illegal overlaps across all anchors
	var occupied_cells: Dictionary = {} # cell -> anchor_id
	for a in layout.anchors:
		var a_id: String = a.get("id", "")
		var cell: Vector2i = a.get("cell", Vector2i(-999, -999))
		if occupied_cells.has(cell):
			findings.append("illegal_overlap: anchors '%s' and '%s' share cell %s" % [
				occupied_cells[cell], a_id, str(cell)
			])
		else:
			occupied_cells[cell] = a_id

	# Probe all required anchors and their approach cells against task 3.6 collision
	for a_id in REQUIRED_ANCHORS.keys():
		var m := layout.marker(a_id)
		if m == null:
			continue

		var cell_center := ZWorldUnits.tile_center_to_godot(m.cell)
		if not cell_center.ok:
			findings.append("unit_conversion_failed: %s cell %s" % [a_id, str(m.cell)])
			continue

		var probe_cell_id := ZEntityId.from_parts(PackedStringArray(["probe", run_tag, a_id, "cell"]))
		if not world.register_actor(probe_cell_id, cell_center.vector2_value, BODY_HALF_EXTENTS_PX, world.generation()):
			findings.append("anchor_collision: '%s' cell %s in blocking geometry (%s)" % [
				a_id, str(m.cell), world.last_error
			])

		var app_center := ZWorldUnits.tile_center_to_godot(m.approach_cell)
		if not app_center.ok:
			findings.append("unit_conversion_failed: %s approach_cell %s" % [a_id, str(m.approach_cell)])
			continue

		var probe_app_id := ZEntityId.from_parts(PackedStringArray(["probe", run_tag, a_id, "app"]))
		if not world.register_actor(probe_app_id, app_center.vector2_value, BODY_HALF_EXTENTS_PX, world.generation()):
			findings.append("approach_collision: '%s' approach_cell %s in blocking geometry (%s)" % [
				a_id, str(m.approach_cell), world.last_error
			])

	# Also probe all patrol waypoints
	for pm in layout.patrol_markers():
		var p_id := String(pm.marker_id)
		var center := ZWorldUnits.tile_center_to_godot(pm.cell)
		if center.ok:
			var probe_p_id := ZEntityId.from_parts(PackedStringArray(["probe", run_tag, p_id, "cell"]))
			if not world.register_actor(probe_p_id, center.vector2_value, BODY_HALF_EXTENTS_PX, world.generation()):
				findings.append("patrol_collision: '%s' cell %s in blocking geometry (%s)" % [
					p_id, str(pm.cell), world.last_error
				])

	return findings


# ==============================================================================
# FAMILY 3: Reachable Extract
# ==============================================================================

func _run_family_3_reachable_extract(
	layout: ZSawmillYardLayout,
	service: ZNavigationPathService,
	revision: int
) -> void:
	var findings := check_reachable_extract(layout, service, revision)
	check(findings.is_empty(), "real layout passes reachable extract validation (findings: %s)" % str(findings))

	var extract := layout.marker("zerkov.extract.sawmill.road_gate")
	check(extract != null, "extraction marker found for reachability test")
	if extract == null:
		return

	# Specific reachability assertions with concrete costs/cell-counts
	var spawn := layout.marker("zerkov.spawn.sawmill.west_service")
	var r_spawn := service.request_path(spawn.cell, extract.cell, revision)
	check(r_spawn.is_ok(), "spawn -> extract path is ok")
	check(r_spawn.cells.size() == 34, "spawn -> extract path length is exactly 34 cells")
	check(r_spawn.cost == 350, "spawn -> extract path cost is 350")

	var crates := [
		"zerkov.loot.sawmill.crate.log_racks",
		"zerkov.loot.sawmill.crate.saw_house",
		"zerkov.loot.sawmill.crate.settling_dock",
	]
	for c_id in crates:
		var crate := layout.marker(c_id)
		var r_crate := service.request_path(crate.cell, extract.cell, revision)
		check(r_crate.is_ok(), "%s -> extract path is ok" % c_id)
		check(r_crate.cells.size() > 0, "%s -> extract path has cells" % c_id)
		check(r_crate.start == crate.cell and r_crate.goal == extract.cell,
			"%s -> extract path start/goal verified" % c_id)


static func check_reachable_extract(
	layout: ZSawmillYardLayout,
	service: ZNavigationPathService,
	revision: int
) -> Array[String]:
	var findings: Array[String] = []

	var extract_id := "zerkov.extract.sawmill.road_gate"
	var extract := layout.marker(extract_id)
	if extract == null:
		findings.append("missing_extract_marker: %s" % extract_id)
		return findings

	var targets: Array[String] = [
		"zerkov.spawn.sawmill.west_service",
		"zerkov.loot.sawmill.crate.log_racks",
		"zerkov.loot.sawmill.crate.saw_house",
		"zerkov.loot.sawmill.crate.settling_dock",
		"zerkov.loot.sawmill.service_cache",
		"zerkov.loot.sawmill.corpse.haul_lane",
	]

	for start_id in targets:
		var start_marker := layout.marker(start_id)
		if start_marker == null:
			findings.append("missing_start_marker: %s" % start_id)
			continue

		var result := service.request_path(start_marker.cell, extract.cell, revision)
		if not result.is_ok():
			findings.append("unreachable_pair: '%s' (%s) -> '%s' (%s) outcome=%s last_error=%s" % [
				start_id, str(start_marker.cell), extract_id, str(extract.cell),
				result.outcome, service.last_error
			])
		elif result.cells.is_empty() or result.cells[0] != start_marker.cell or result.cells[-1] != extract.cell:
			findings.append("invalid_path: '%s' -> '%s' cell sequence malformed" % [start_id, extract_id])

	return findings


# ==============================================================================
# FAMILY 4: Occluder Bounds
# ==============================================================================

func _run_family_4_occluder_bounds(layout: ZSawmillYardLayout, occluder_bake: Dictionary) -> void:
	var findings := check_occluder_bounds(layout, occluder_bake)
	check(findings.is_empty(), "real layout passes occluder bounds validation (findings: %s)" % str(findings))

	var segments: Array = occluder_bake.get("segments", [])
	check(segments.size() == 98, "real Sawmill layout bakes to exactly 98 occluder segments")
	var budget: int = occluder_bake.get("budget", 128)
	check(segments.size() <= budget, "occluder segment count %d within budget %d" % [segments.size(), budget])


static func check_occluder_bounds(layout: ZSawmillYardLayout, bake_result: Dictionary) -> Array[String]:
	var findings: Array[String] = []

	if not bake_result.get("ok", false):
		for err in bake_result.get("errors", []):
			findings.append("bake_error: source='%s' code=%s message='%s'" % [
				err.get("source_id", ""), err.get("code", ""), err.get("message", "")
			])
		return findings

	var segments: Array = bake_result.get("segments", [])
	var budget: int = bake_result.get("budget", ZOccluderBake.SEGMENT_BUDGET_MAX)
	if segments.size() > budget:
		findings.append("budget_exceeded: baked count %d exceeds budget %d" % [segments.size(), budget])

	var known_structure_ids: Dictionary = {}
	for s in layout.structures:
		known_structure_ids[String(s.get("id", ""))] = true

	# Level bounds in Vision microunits: [0, size.x * 1,000,000] x [0, size.y * 1,000,000]
	var max_vision_x := layout.size_cells.x * ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
	var max_vision_y := layout.size_cells.y * ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT

	for seg_val in segments:
		if not (seg_val is ZerkovOccluderSegment):
			findings.append("invalid_segment_type: expected ZerkovOccluderSegment")
			continue
		var seg := seg_val as ZerkovOccluderSegment

		# Traceable to authored source
		if seg.source_ids.is_empty():
			findings.append("untraceable_segment: segment '%s' has no source_ids" % seg.id)
		for src_id in seg.source_ids:
			if not known_structure_ids.has(src_id):
				findings.append("unknown_source_id: segment '%s' references unknown source '%s'" % [seg.id, src_id])

		# Non-degenerate
		if seg.a == seg.b:
			findings.append("degenerate_segment: segment '%s' has zero length at %s" % [seg.id, str(seg.a)])

		# Vision space bounds
		if seg.a.x < 0 or seg.a.x > max_vision_x or seg.a.y < 0 or seg.a.y > max_vision_y:
			findings.append("segment_a_out_of_bounds: segment '%s' (source '%s') vertex a=%s outside [0..%d, 0..%d]" % [
				seg.id, str(seg.source_ids), str(seg.a), max_vision_x, max_vision_y
			])
		if seg.b.x < 0 or seg.b.x > max_vision_x or seg.b.y < 0 or seg.b.y > max_vision_y:
			findings.append("segment_b_out_of_bounds: segment '%s' (source '%s') vertex b=%s outside [0..%d, 0..%d]" % [
				seg.id, str(seg.source_ids), str(seg.b), max_vision_x, max_vision_y
			])

		# Conversion within Vision coordinate bound
		var conv_a := ZWorldUnits.vision_to_godot(seg.a)
		if not conv_a.ok:
			findings.append("vision_conversion_failed_a: segment '%s' (source '%s') vertex a=%s" % [
				seg.id, str(seg.source_ids), str(seg.a)
			])
		var conv_b := ZWorldUnits.vision_to_godot(seg.b)
		if not conv_b.ok:
			findings.append("vision_conversion_failed_b: segment '%s' (source '%s') vertex b=%s" % [
				seg.id, str(seg.source_ids), str(seg.b)
			])

	return findings


# ==============================================================================
# FAMILY 5: Duplicate Identifiers
# ==============================================================================

func _run_family_5_duplicate_identifiers(layout: ZSawmillYardLayout, segments: Array) -> void:
	var findings := check_duplicate_identifiers(layout, segments)
	check(findings.is_empty(), "real layout passes duplicate identifier sweep (findings: %s)" % str(findings))


static func check_duplicate_identifiers(layout: ZSawmillYardLayout, segments: Array) -> Array[String]:
	var findings: Array[String] = []
	var seen: Dictionary = {} # id -> owner_description

	# 1. Ground regions
	for r in layout.ground_regions:
		_register_id(seen, String(r.get("id", "")), "ground_region", findings)

	# 2. Detail regions
	for d in layout.detail_regions:
		_register_id(seen, String(d.get("id", "")), "detail_region", findings)

	# 3. Structures
	for s in layout.structures:
		_register_id(seen, String(s.get("id", "")), "structure", findings)

	# 4. Landmarks
	for lm in layout.landmarks:
		_register_id(seen, String(lm.get("id", "")), "landmark", findings)

	# 5. Anchors (authored anchors)
	for a in layout.anchors:
		_register_id(seen, String(a.get("id", "")), "anchor", findings)

	# 6. Patrol waypoints (derived)
	for pm in layout.patrol_markers():
		_register_id(seen, String(pm.marker_id), "patrol_marker", findings)

	# 7. Routes
	for rt in layout.routes:
		_register_id(seen, String(rt.get("id", "")), "route", findings)

	# 8. Occluder segments
	for seg in segments:
		var seg_id: String = seg.id if seg is ZerkovOccluderSegment else String(seg.get("id", ""))
		_register_id(seen, seg_id, "occluder_segment", findings)

	return findings


static func _register_id(seen: Dictionary, id: String, owner_category: String, findings: Array[String]) -> void:
	if id.is_empty():
		findings.append("empty_identifier: in category '%s'" % owner_category)
		return
	if seen.has(id):
		findings.append("duplicate_identifier: '%s' owned by '%s' and '%s'" % [
			id, seen[id], owner_category
		])
	else:
		seen[id] = owner_category


# ==============================================================================
# NEGATIVE CONTROLS
# ==============================================================================

func _run_negative_controls(
	layout: ZSawmillYardLayout,
	world: ZMovementWorld2D,
	service: ZNavigationPathService,
	revision: int,
	occluder_bake: Dictionary
) -> void:
	# --------------------------------------------------------------------------
	# Control 1: Missing required anchor fails naming the missing ID
	# --------------------------------------------------------------------------
	var mock_layout_missing_anchor := _clone_layout_shallow(layout)
	var missing_id := "zerkov.loot.sawmill.crate.log_racks"
	var filtered_anchors: Array[Dictionary] = []
	for a in layout.anchors:
		if a.get("id") != missing_id:
			filtered_anchors.append(a.duplicate(true))
	mock_layout_missing_anchor.anchors = filtered_anchors
	mock_layout_missing_anchor.rebuild_markers()

	var findings_missing := check_required_anchors(mock_layout_missing_anchor)
	check(not findings_missing.is_empty(), "negative control: missing required anchor is rejected")
	var found_missing_id_diagnostic := false
	for f in findings_missing:
		if "missing_required_anchor" in f and missing_id in f:
			found_missing_id_diagnostic = true
	check(found_missing_id_diagnostic,
		"negative control diagnostic names missing anchor id '%s' (found: %s)" % [missing_id, str(findings_missing)])

	# --------------------------------------------------------------------------
	# Control 2: Anchor cell outside level bounds fails naming ID and cell
	# --------------------------------------------------------------------------
	var mock_layout_oob_cell := _clone_layout_shallow(layout)
	var oob_anchors: Array[Dictionary] = []
	var oob_cell_id := "zerkov.spawn.sawmill.west_service"
	var bad_cell := Vector2i(-1, 5)
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == oob_cell_id:
			row["cell"] = bad_cell
		oob_anchors.append(row)
	mock_layout_oob_cell.anchors = oob_anchors
	mock_layout_oob_cell.rebuild_markers()

	var findings_oob_cell := check_required_anchors(mock_layout_oob_cell)
	check(not findings_oob_cell.is_empty(), "negative control: anchor cell outside bounds rejected")
	var found_oob_cell_diag := false
	for f in findings_oob_cell:
		if "out_of_bounds" in f and oob_cell_id in f and str(bad_cell) in f:
			found_oob_cell_diag = true
	check(found_oob_cell_diag,
		"negative control diagnostic names out-of-bounds id '%s' and cell %s (found: %s)" % [
			oob_cell_id, str(bad_cell), str(findings_oob_cell)
		])

	# --------------------------------------------------------------------------
	# Control 3: Anchor approach_cell outside level bounds fails naming ID and cell
	# --------------------------------------------------------------------------
	var mock_layout_oob_app := _clone_layout_shallow(layout)
	var oob_app_anchors: Array[Dictionary] = []
	var oob_app_id := "zerkov.loot.sawmill.crate.saw_house"
	var bad_app := Vector2i(21, -2)
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == oob_app_id:
			row["approach_cell"] = bad_app
		oob_app_anchors.append(row)
	mock_layout_oob_app.anchors = oob_app_anchors
	mock_layout_oob_app.rebuild_markers()

	var findings_oob_app := check_required_anchors(mock_layout_oob_app)
	check(not findings_oob_app.is_empty(), "negative control: anchor approach_cell outside bounds rejected")
	var found_oob_app_diag := false
	for f in findings_oob_app:
		if "approach_out_of_bounds" in f and oob_app_id in f and str(bad_app) in f:
			found_oob_app_diag = true
	check(found_oob_app_diag,
		"negative control diagnostic names out-of-bounds approach id '%s' and cell %s (found: %s)" % [
			oob_app_id, str(bad_app), str(findings_oob_app)
		])

	# --------------------------------------------------------------------------
	# Control 4: Objective crate referencing missing landmark fails naming crate & landmark
	# --------------------------------------------------------------------------
	var mock_layout_bad_landmark := _clone_layout_shallow(layout)
	var bad_lm_anchors: Array[Dictionary] = []
	var bad_lm_crate_id := "zerkov.loot.sawmill.crate.settling_dock"
	var missing_lm_id := "zerkov.landmark.sawmill.nonexistent_pad"
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == bad_lm_crate_id:
			row["landmark_id"] = missing_lm_id
		bad_lm_anchors.append(row)
	mock_layout_bad_landmark.anchors = bad_lm_anchors
	mock_layout_bad_landmark.rebuild_markers()

	var findings_bad_lm := check_required_anchors(mock_layout_bad_landmark)
	check(not findings_bad_lm.is_empty(), "negative control: crate referencing missing landmark rejected")
	var found_bad_lm_diag := false
	for f in findings_bad_lm:
		if "missing_landmark" in f and bad_lm_crate_id in f and missing_lm_id in f:
			found_bad_lm_diag = true
	check(found_bad_lm_diag,
		"negative control diagnostic names crate '%s' and missing landmark '%s' (found: %s)" % [
			bad_lm_crate_id, missing_lm_id, str(findings_bad_lm)
		])

	# --------------------------------------------------------------------------
	# Control 5: Extraction zone not containing extract cell fails naming extract ID
	# --------------------------------------------------------------------------
	var mock_layout_bad_zone := _clone_layout_shallow(layout)
	var bad_zone_anchors: Array[Dictionary] = []
	var extract_id := "zerkov.extract.sawmill.road_gate"
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == extract_id:
			row["zone_cells"] = Rect2i(10, 10, 2, 2) # Does not contain cell (37, 10)
		bad_zone_anchors.append(row)
	mock_layout_bad_zone.anchors = bad_zone_anchors
	mock_layout_bad_zone.rebuild_markers()

	var findings_bad_zone := check_required_anchors(mock_layout_bad_zone)
	check(not findings_bad_zone.is_empty(), "negative control: extract zone not containing cell rejected")
	var found_bad_zone_diag := false
	for f in findings_bad_zone:
		if "zone_does_not_contain_cell" in f and extract_id in f:
			found_bad_zone_diag = true
	check(found_bad_zone_diag,
		"negative control diagnostic names extract id on zone mismatch (found: %s)" % str(findings_bad_zone))

	# --------------------------------------------------------------------------
	# Control 6: Required anchor moved into a wall fails naming ID and cell
	# --------------------------------------------------------------------------
	var mock_layout_wall_anchor := _clone_layout_shallow(layout)
	var corrupt_anchors: Array[Dictionary] = []
	var moved_id := "zerkov.spawn.sawmill.west_service"
	var wall_cell := Vector2i(17, 3) # inside mill_west_wall
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == moved_id:
			row["cell"] = wall_cell
		corrupt_anchors.append(row)
	mock_layout_wall_anchor.anchors = corrupt_anchors
	mock_layout_wall_anchor.rebuild_markers()

	var findings_wall := check_collisions(mock_layout_wall_anchor, world)
	check(not findings_wall.is_empty(), "negative control: anchor moved into wall is rejected")
	var found_wall_diagnostic := false
	for f in findings_wall:
		if "anchor_collision" in f and moved_id in f and str(wall_cell) in f:
			found_wall_diagnostic = true
	check(found_wall_diagnostic,
		"negative control diagnostic names colliding id '%s' and cell %s (found: %s)" % [
			moved_id, str(wall_cell), str(findings_wall)
		])

	# --------------------------------------------------------------------------
	# Control 7: Anchor approach_cell moved into a wall fails naming ID and approach cell
	# --------------------------------------------------------------------------
	var mock_layout_wall_app := _clone_layout_shallow(layout)
	var corrupt_app_anchors: Array[Dictionary] = []
	var app_moved_id := "zerkov.loot.sawmill.crate.saw_house"
	var wall_app_cell := Vector2i(17, 2) # inside mill_north_wall
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == app_moved_id:
			row["approach_cell"] = wall_app_cell
		corrupt_app_anchors.append(row)
	mock_layout_wall_app.anchors = corrupt_app_anchors
	mock_layout_wall_app.rebuild_markers()

	var findings_wall_app := check_collisions(mock_layout_wall_app, world)
	check(not findings_wall_app.is_empty(), "negative control: approach_cell moved into wall is rejected")
	var found_app_wall_diagnostic := false
	for f in findings_wall_app:
		if "approach_collision" in f and app_moved_id in f and str(wall_app_cell) in f:
			found_app_wall_diagnostic = true
	check(found_app_wall_diagnostic,
		"negative control diagnostic names colliding approach id '%s' and cell %s (found: %s)" % [
			app_moved_id, str(wall_app_cell), str(findings_wall_app)
		])

	# --------------------------------------------------------------------------
	# Control 8: Illegal anchor overlap fails naming both IDs and cell
	# --------------------------------------------------------------------------
	var mock_layout_overlap := _clone_layout_shallow(layout)
	var overlap_anchors: Array[Dictionary] = []
	var first_overlap_id := "zerkov.spawn.sawmill.west_service"
	var second_overlap_id := "zerkov.loot.sawmill.crate.log_racks"
	var shared_cell := Vector2i(4, 15)
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == second_overlap_id:
			row["cell"] = shared_cell
		overlap_anchors.append(row)
	mock_layout_overlap.anchors = overlap_anchors
	mock_layout_overlap.rebuild_markers()

	var findings_overlap := check_collisions(mock_layout_overlap, world)
	check(not findings_overlap.is_empty(), "negative control: overlapping anchors rejected")
	var found_overlap_diagnostic := false
	for f in findings_overlap:
		if "illegal_overlap" in f and first_overlap_id in f and second_overlap_id in f and str(shared_cell) in f:
			found_overlap_diagnostic = true
	check(found_overlap_diagnostic,
		"negative control diagnostic names both overlapping ids and cell (found: %s)" % str(findings_overlap))

	# --------------------------------------------------------------------------
	# Control 9: Duplicate identifier across structure and occluder segment
	# --------------------------------------------------------------------------
	var dup_id := "zerkov.structure.sawmill.north_fence"
	var fake_segment := ZerkovOccluderSegment.create(
		dup_id, # Exact duplicate of the structure ID!
		1,
		Vector2i(0, 0),
		Vector2i(1000000, 0),
		["zerkov.structure.sawmill.north_fence"]
	)
	var fake_segments: Array = occluder_bake.get("segments", []).duplicate()
	fake_segments.append(fake_segment)

	var findings_dup := check_duplicate_identifiers(layout, fake_segments)
	check(not findings_dup.is_empty(), "negative control: cross-namespace duplicate id rejected")
	var found_dup_diagnostic := false
	for f in findings_dup:
		if "duplicate_identifier" in f and dup_id in f and "structure" in f and "occluder_segment" in f:
			found_dup_diagnostic = true
	check(found_dup_diagnostic,
		"negative control diagnostic names duplicate id and both owners (found: %s)" % str(findings_dup))

	# --------------------------------------------------------------------------
	# Control 10: Duplicate identifier across landmark and route
	# --------------------------------------------------------------------------
	var mock_layout_dup_route := _clone_layout_shallow(layout)
	var dup_route_id := "zerkov.landmark.sawmill.saw_house" # Shares ID with landmark!
	var dup_routes: Array[Dictionary] = []
	for r in layout.routes:
		dup_routes.append(r.duplicate(true))
	dup_routes.append({
		"id": dup_route_id,
		"name": "DUPLICATE ROUTE",
		"width_cells": 3,
		"points": PackedVector2Array([Vector2(6, 10), Vector2(37, 10)]),
	})
	mock_layout_dup_route.routes = dup_routes

	var findings_dup_route := check_duplicate_identifiers(mock_layout_dup_route, occluder_bake.get("segments", []))
	check(not findings_dup_route.is_empty(), "negative control: route duplicating landmark id rejected")
	var found_dup_route_diag := false
	for f in findings_dup_route:
		if "duplicate_identifier" in f and dup_route_id in f and "landmark" in f and "route" in f:
			found_dup_route_diag = true
	check(found_dup_route_diag,
		"negative control diagnostic names duplicate landmark/route id and both owners (found: %s)" % str(findings_dup_route))

	# --------------------------------------------------------------------------
	# Control 11: Out-of-bounds structure in occluder bake fails naming source ID
	# --------------------------------------------------------------------------
	var oob_bake_input: Array[Dictionary] = layout.structures.duplicate(true)
	var oob_struct_id := "zerkov.structure.sawmill.oob_test_box"
	oob_bake_input.append({
		"id": oob_struct_id,
		"tile": "fence",
		"layer": "Obstacles",
		"role": "perimeter",
		"rect": Rect2i(50, 50, 2, 2), # Outside 40x20
	})
	var oob_bake_result := ZOccluderBake.bake(oob_bake_input, layout.size_cells)
	check(oob_bake_result.get("ok", false) == false, "negative control: out-of-bounds structure bake fails")
	var findings_oob := check_occluder_bounds(layout, oob_bake_result)
	check(not findings_oob.is_empty(), "negative control: out-of-bounds occluder rejected")
	var found_oob_diagnostic := false
	for f in findings_oob:
		if oob_struct_id in f and ("rect_outside_level_bounds" in f or "bake_error" in f):
			found_oob_diagnostic = true
	check(found_oob_diagnostic,
		"negative control diagnostic names out-of-bounds source id '%s' (found: %s)" % [
			oob_struct_id, str(findings_oob)
		])

	# --------------------------------------------------------------------------
	# Control 12: Baked occluder segment vertex out of Vision coordinate bounds
	# --------------------------------------------------------------------------
	var fake_oob_segment := ZerkovOccluderSegment.create(
		"zerkov.structure.sawmill.dock_rim.occluder.999",
		1,
		Vector2i(999000000, 999000000), # Outside 40,000,000 x 20,000,000
		Vector2i(999000000, 1000000000),
		["zerkov.structure.sawmill.dock_rim"]
	)
	var fake_oob_bake: Dictionary = {
		"ok": true,
		"budget": 128,
		"segments": [fake_oob_segment],
		"errors": [],
	}
	var findings_seg_oob := check_occluder_bounds(layout, fake_oob_bake)
	check(not findings_seg_oob.is_empty(), "negative control: out-of-bounds segment vertex rejected")
	var found_seg_oob_diagnostic := false
	for f in findings_seg_oob:
		if "segment_a_out_of_bounds" in f and "zerkov.structure.sawmill.dock_rim" in f:
			found_seg_oob_diagnostic = true
	check(found_seg_oob_diagnostic,
		"negative control diagnostic names source id on out-of-bounds vertex (found: %s)" % str(findings_seg_oob))

	# --------------------------------------------------------------------------
	# Control 13: Untraceable occluder segment (unknown source id)
	# --------------------------------------------------------------------------
	var untraceable_source_id := "zerkov.structure.sawmill.phantom_box"
	var fake_untraceable_segment := ZerkovOccluderSegment.create(
		"zerkov.structure.sawmill.phantom_box.occluder.000",
		1,
		Vector2i(1000000, 1000000),
		Vector2i(2000000, 1000000),
		[untraceable_source_id]
	)
	var fake_untraceable_bake: Dictionary = {
		"ok": true,
		"budget": 128,
		"segments": [fake_untraceable_segment],
		"errors": [],
	}
	var findings_untraceable := check_occluder_bounds(layout, fake_untraceable_bake)
	check(not findings_untraceable.is_empty(), "negative control: untraceable segment rejected")
	var found_untraceable_diag := false
	for f in findings_untraceable:
		if "unknown_source_id" in f and untraceable_source_id in f:
			found_untraceable_diag = true
	check(found_untraceable_diag,
		"negative control diagnostic names untraceable source id (found: %s)" % str(findings_untraceable))

	# --------------------------------------------------------------------------
	# Control 14: Degenerate occluder segment (zero length, a == b)
	# --------------------------------------------------------------------------
	var degen_source_id := "zerkov.structure.sawmill.north_fence"
	var fake_degen_segment := ZerkovOccluderSegment.create(
		"zerkov.structure.sawmill.north_fence.occluder.999",
		1,
		Vector2i(1000000, 1000000),
		Vector2i(1000000, 1000000), # a == b !
		[degen_source_id]
	)
	var fake_degen_bake: Dictionary = {
		"ok": true,
		"budget": 128,
		"segments": [fake_degen_segment],
		"errors": [],
	}
	var findings_degen := check_occluder_bounds(layout, fake_degen_bake)
	check(not findings_degen.is_empty(), "negative control: degenerate segment rejected")
	var found_degen_diag := false
	for f in findings_degen:
		if "degenerate_segment" in f and "zerkov.structure.sawmill.north_fence.occluder.999" in f:
			found_degen_diag = true
	check(found_degen_diag,
		"negative control diagnostic names degenerate segment id (found: %s)" % str(findings_degen))

	# --------------------------------------------------------------------------
	# Control 15: Segment count exceeding budget fails naming count and budget
	# --------------------------------------------------------------------------
	var overbudget_bake: Dictionary = {
		"ok": true,
		"budget": 5, # Low budget
		"segments": occluder_bake.get("segments", []), # 98 segments
		"errors": [],
	}
	var findings_overbudget := check_occluder_bounds(layout, overbudget_bake)
	check(not findings_overbudget.is_empty(), "negative control: overbudget segments rejected")
	var found_budget_diagnostic := false
	for f in findings_overbudget:
		if "budget_exceeded" in f and "98" in f and "5" in f:
			found_budget_diagnostic = true
	check(found_budget_diagnostic,
		"negative control diagnostic names actual count and budget (found: %s)" % str(findings_overbudget))

	# --------------------------------------------------------------------------
	# Control 16: Unreachable extract from spawn fails naming unreachable pair
	# --------------------------------------------------------------------------
	var mock_nav_grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var walled_service := ZNavigationPathService.new()
	walled_service.configure(mock_nav_grid, mock_nav_grid.revision())
	var unreachable_spawn_id := "zerkov.spawn.sawmill.west_service"
	var unreachable_extract_id := "zerkov.extract.sawmill.road_gate"

	var mock_layout_unreachable := _clone_layout_shallow(layout)
	var corrupt_extract_anchors: Array[Dictionary] = []
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == unreachable_extract_id:
			row["cell"] = Vector2i(0, 0) # Blocked perimeter fence cell
		corrupt_extract_anchors.append(row)
	mock_layout_unreachable.anchors = corrupt_extract_anchors
	mock_layout_unreachable.rebuild_markers()

	var findings_unreach := check_reachable_extract(mock_layout_unreachable, walled_service, mock_nav_grid.revision())
	check(not findings_unreach.is_empty(), "negative control: blocked extract is rejected")
	var found_unreach_diagnostic := false
	for f in findings_unreach:
		if "unreachable_pair" in f and unreachable_spawn_id in f and unreachable_extract_id in f:
			found_unreach_diagnostic = true
	check(found_unreach_diagnostic,
		"negative control diagnostic names unreachable pair (found: %s)" % str(findings_unreach))

	# --------------------------------------------------------------------------
	# Control 17: Unreachable extract from objective crate fails naming crate & extract
	# --------------------------------------------------------------------------
	var unreachable_crate_id := "zerkov.loot.sawmill.crate.saw_house"
	var mock_layout_crate_blocked := _clone_layout_shallow(layout)
	var corrupt_crate_anchors: Array[Dictionary] = []
	for a in layout.anchors:
		var row: Dictionary = a.duplicate(true)
		if row.get("id") == unreachable_crate_id:
			row["cell"] = Vector2i(17, 2) # Blocked mill wall cell
		corrupt_crate_anchors.append(row)
	mock_layout_crate_blocked.anchors = corrupt_crate_anchors
	mock_layout_crate_blocked.rebuild_markers()

	var findings_crate_unreach := check_reachable_extract(mock_layout_crate_blocked, walled_service, mock_nav_grid.revision())
	check(not findings_crate_unreach.is_empty(), "negative control: blocked crate is rejected")
	var found_crate_unreach_diag := false
	for f in findings_crate_unreach:
		if "unreachable_pair" in f and unreachable_crate_id in f and unreachable_extract_id in f:
			found_crate_unreach_diag = true
	check(found_crate_unreach_diag,
		"negative control diagnostic names unreachable crate and extract (found: %s)" % str(findings_crate_unreach))


static func _clone_layout_shallow(layout: ZSawmillYardLayout) -> ZSawmillYardLayout:
	var clone := ZSawmillYardLayout.new()
	clone.level_id = layout.level_id
	clone.revision = layout.revision
	clone.size_cells = layout.size_cells
	clone.ground_regions = layout.ground_regions.duplicate(true)
	clone.detail_regions = layout.detail_regions.duplicate(true)
	clone.structures = layout.structures.duplicate(true)
	clone.landmarks = layout.landmarks.duplicate(true)
	clone.anchors = layout.anchors.duplicate(true)
	clone.routes = layout.routes.duplicate(true)
	return clone


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)
