extends SceneTree
## Task 3.10 contract: deterministic Common Vision occluder bake from explicit
## level-authoring data (ZOccluderBake). Covers stable identifiers, edge
## cancellation/merge, mask assignment, malformed-source validation, the
## Vision point bound, the authored-segment budget, and the real Sawmill
## layout.
## Run with: godot --headless --path . --resolution 1920x1080
##   --audio-driver Dummy --script res://tests/ai/occluder_bake_contract.gd

const Bake = preload("res://game/ai/vision/occluder_bake.gd")
const Segment = preload("res://game/ai/vision/zerkov_occluder_segment.gd")
const RealLayout = preload("res://game/world/sawmill/sawmill_yard_layout.tres")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("OCCLUDER_BAKE_CONTRACT: " + message)


func run() -> void:
	_test_isolated_rect_yields_four_segments()
	_test_adjacent_rects_collapse_shared_edge()
	_test_collinear_line_merges_into_one_perimeter()
	_test_masks_assigned_per_layer_and_domains_stay_separate()
	_test_malformed_missing_id()
	_test_malformed_duplicate_id()
	_test_malformed_unknown_layer()
	_test_malformed_zero_area_rect()
	_test_malformed_negative_size_rect()
	_test_malformed_rect_outside_bounds()
	_test_degenerate_segment_guard()
	_test_out_of_vision_range_rejected()
	_test_segment_budget_exceeded()
	_test_real_sawmill_layout_within_budget()
	_test_double_bake_determinism_and_stable_ids()

	print("OCCLUDER_BAKE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_isolated_rect_yields_four_segments() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.rect_a", "Obstacles", Rect2i(2, 2, 3, 2)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(result.ok, "single isolated rect bakes without error")
	if not result.ok:
		return
	var segments: Array = result.segments
	check(segments.size() == 4,
		"single isolated rect yields exactly 4 segments, got %d" % segments.size())
	for segment in segments:
		var s: Segment = segment
		check(s.mask == Bake.MASK_STRUCTURE, "isolated rect segment carries the structure mask")
		check(not s.is_degenerate(), "isolated rect segment is not degenerate")
		check(s.id.begins_with("zerkov.test.rect_a.occluder."),
			"isolated rect segment id traces back to its own authored row")
		check(s.source_ids.size() == 1 and s.source_ids[0] == "zerkov.test.rect_a",
			"isolated rect segment names exactly its own contributing row")


func _test_adjacent_rects_collapse_shared_edge() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.adjacent_a", "Obstacles", Rect2i(0, 0, 2, 1)),
		_row("zerkov.test.adjacent_b", "Obstacles", Rect2i(2, 0, 2, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(result.ok, "two edge-adjacent rects bake without error")
	if not result.ok:
		return
	check(result.segments.size() == 4,
		"adjacent rects collapse their shared internal edge into one 4-segment outline, got %d"
			% result.segments.size())
	check(_has_segment(result.segments, _tile_point(Vector2i(0, 0)), _tile_point(Vector2i(4, 0))),
		"merged top run spans the full combined width")
	check(_has_segment(result.segments, _tile_point(Vector2i(0, 1)), _tile_point(Vector2i(4, 1))),
		"merged bottom run spans the full combined width")
	check(_has_segment(result.segments, _tile_point(Vector2i(0, 0)), _tile_point(Vector2i(0, 1))),
		"left edge remains a single unit run")
	check(_has_segment(result.segments, _tile_point(Vector2i(4, 0)), _tile_point(Vector2i(4, 1))),
		"right edge remains a single unit run")
	# The count check above (== 4) combined with these four exact-endpoint
	# matches already pins down the full segment set: no fifth segment can
	# remain on the canceled internal x=2 boundary between the two rects.


func _test_collinear_line_merges_into_one_perimeter() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.line_a", "Obstacles", Rect2i(5, 5, 1, 1)),
		_row("zerkov.test.line_b", "Obstacles", Rect2i(6, 5, 1, 1)),
		_row("zerkov.test.line_c", "Obstacles", Rect2i(7, 5, 1, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(result.ok, "three collinear 1x1 rects bake without error")
	if not result.ok:
		return
	check(result.segments.size() == 4,
		"a row of three 1x1 authored cells in a line yields one perimeter (4 segments), got %d"
			% result.segments.size())
	var top_a := _tile_point(Vector2i(5, 5))
	var top_b := _tile_point(Vector2i(8, 5))
	check(_has_segment(result.segments, top_a, top_b), "top run merges across all three source rects")
	check(_has_segment(result.segments, _tile_point(Vector2i(5, 6)), _tile_point(Vector2i(8, 6))),
		"bottom run merges across all three source rects")
	check(_has_segment(result.segments, top_a, _tile_point(Vector2i(5, 6))),
		"left edge is a single unit run")
	check(_has_segment(result.segments, top_b, _tile_point(Vector2i(8, 6))),
		"right edge is a single unit run")
	var found_merged_top := false
	for segment in result.segments:
		var s: Segment = segment
		if (s.a == top_a and s.b == top_b) or (s.a == top_b and s.b == top_a):
			found_merged_top = true
			check(s.source_ids.size() == 3, "merged top run credits all three contributing rows")
			check(
				s.source_ids.has("zerkov.test.line_a")
					and s.source_ids.has("zerkov.test.line_b")
					and s.source_ids.has("zerkov.test.line_c"),
				"merged run names every contributing source id"
			)
	check(found_merged_top, "the merged top run was located for source-id inspection")


func _test_masks_assigned_per_layer_and_domains_stay_separate() -> void:
	check(Bake.MASK_STRUCTURE == 1 and Bake.MASK_VEGETATION == 2,
		"masks match the sealed occluder-mask domain bits (structure=bit0, vegetation=bit1)")
	var structures: Array[Dictionary] = [
		_row("zerkov.test.wall", "Obstacles", Rect2i(1, 1, 1, 1)),
		_row("zerkov.test.tree", "Canopy", Rect2i(2, 1, 1, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(result.ok, "one structure row and one touching canopy row bake without error")
	if not result.ok:
		return
	check(result.segments.size() == 8,
		"touching rows in different mask domains never merge: 4+4 segments, got %d"
			% result.segments.size())
	var structure_count := 0
	var vegetation_count := 0
	for segment in result.segments:
		var s: Segment = segment
		if s.mask == Bake.MASK_STRUCTURE:
			structure_count += 1
		elif s.mask == Bake.MASK_VEGETATION:
			vegetation_count += 1
	check(structure_count == 4 and vegetation_count == 4,
		"masks are assigned per authored layer (Obstacles=structure, Canopy=vegetation)")


func _test_malformed_missing_id() -> void:
	var structures: Array[Dictionary] = [
		{"tile": "fence", "layer": "Obstacles", "role": "cover", "rect": Rect2i(0, 0, 1, 1)},
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "a structure row with no id fails closed")
	check(_has_error_code(result.errors, &"missing_id"), "missing id is named as the failure code")


func _test_malformed_duplicate_id() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.dup", "Obstacles", Rect2i(0, 0, 1, 1)),
		_row("zerkov.test.dup", "Obstacles", Rect2i(5, 5, 1, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "a duplicate structure id fails closed")
	check(_error_named(result.errors, "zerkov.test.dup", &"duplicate_id"),
		"duplicate id error names the offending source id")


func _test_malformed_unknown_layer() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.badlayer", "Trees", Rect2i(0, 0, 1, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "an unknown layer fails closed")
	check(_error_named(result.errors, "zerkov.test.badlayer", &"unknown_layer"),
		"unknown layer error names the offending source id")


func _test_malformed_zero_area_rect() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.zeroarea", "Obstacles", Rect2i(0, 0, 0, 3)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "a zero-area rect fails closed")
	check(_error_named(result.errors, "zerkov.test.zeroarea", &"rect_zero_or_negative_area"),
		"zero-area error names the offending source id")


func _test_malformed_negative_size_rect() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.negsize", "Obstacles", Rect2i(5, 5, -2, 3)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "a negative-size rect fails closed")
	check(_error_named(result.errors, "zerkov.test.negsize", &"rect_zero_or_negative_area"),
		"negative-size error names the offending source id")


func _test_malformed_rect_outside_bounds() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.outside", "Obstacles", Rect2i(18, 0, 5, 1)),
	]
	var result := Bake.bake(structures, Vector2i(20, 20))
	check(not result.ok, "a rect outside level bounds fails closed")
	check(_error_named(result.errors, "zerkov.test.outside", &"rect_outside_level_bounds"),
		"out-of-bounds error names the offending source id")


func _test_degenerate_segment_guard() -> void:
	# A zero-length resulting segment cannot occur through bake() once every
	# row has passed the zero/negative-area guard (adjacent integer tile
	# boundaries never convert to identical Vision points). The guard is
	# still validated directly as defense in depth; see the docstring on
	# ZOccluderBake.is_degenerate_segment.
	check(Bake.is_degenerate_segment(Vector2i(5, 5), Vector2i(5, 5)),
		"identical endpoints are recognized as degenerate")
	check(not Bake.is_degenerate_segment(Vector2i(5, 5), Vector2i(5, 6)),
		"distinct endpoints are not degenerate")


func _test_out_of_vision_range_rejected() -> void:
	var structures: Array[Dictionary] = [
		_row("zerkov.test.far", "Obstacles", Rect2i(3000, 0, 1, 1)),
	]
	# A large custom level bound so the row passes the level-bounds check and
	# specifically exercises the narrower +/-65,536 px Vision point bound.
	var result := Bake.bake(structures, Vector2i(4000, 10))
	check(not result.ok, "geometry beyond the Vision point bound fails closed")
	check(_error_named(result.errors, "zerkov.test.far", &"vision_conversion_out_of_range"),
		"out-of-Vision-range conversion names the source object")


func _test_segment_budget_exceeded() -> void:
	var structures: Array[Dictionary] = []
	for i in 33:
		structures.append(
			_row("zerkov.test.budget.rect_%02d" % i, "Obstacles", Rect2i(i * 2, 0, 1, 1))
		)
	var result := Bake.bake(structures, Vector2i(80, 10))
	check(not result.ok, "exceeding the authored segment budget fails closed")
	check(result.segments.is_empty(), "a budget failure returns no partial segments")
	var found_budget_error := false
	for error in result.errors:
		if error.code == &"segment_budget_exceeded":
			found_budget_error = true
			check(
				error.message.find("132") != -1
					and error.message.find(str(Bake.SEGMENT_BUDGET_MAX)) != -1,
				"budget error reports both the actual baked count and the budget"
			)
	check(found_budget_error, "segment budget violation is reported")


func _test_real_sawmill_layout_within_budget() -> void:
	var result := Bake.bake(RealLayout.structures, RealLayout.size_cells)
	check(result.ok, "the real Sawmill layout bakes without malformed-source errors")
	if not result.ok:
		return
	var actual: int = result.segments.size()
	print(
		"OCCLUDER_BAKE_SAWMILL_SEGMENTS count=", actual,
		" budget=", Bake.SEGMENT_BUDGET_MAX,
		" authored_rows=", RealLayout.structures.size()
	)
	check(actual <= Bake.SEGMENT_BUDGET_MAX,
		"the real Sawmill layout's baked segment count (%d) stays within the 128 budget" % actual)
	check(actual < RealLayout.structures.size() * 4,
		"merging reduces the naive per-rect segment count (%d rows * 4)"
			% RealLayout.structures.size())
	for segment in result.segments:
		var s: Segment = segment
		check(s.mask == Bake.MASK_STRUCTURE or s.mask == Bake.MASK_VEGETATION,
			"every real baked segment carries a known occluder mask")
		check(not s.is_degenerate(), "every real baked segment has non-zero length")


func _test_double_bake_determinism_and_stable_ids() -> void:
	var first := Bake.bake(RealLayout.structures, RealLayout.size_cells)
	var second := Bake.bake(RealLayout.structures, RealLayout.size_cells)
	check(first.ok and second.ok, "double bake of unchanged real input succeeds both times")
	if not (first.ok and second.ok):
		return
	check(first.segments.size() == second.segments.size(),
		"double bake produces the same segment count")

	var digest_a := Bake.segments_digest(first.segments)
	var digest_b := Bake.segments_digest(second.segments)
	check(not digest_a.is_empty(), "aggregate segment digest is computable")
	check(digest_a == digest_b,
		"double bake produces a byte-identical canonical digest across all segments")

	var identical_ids := true
	var count: int = min(first.segments.size(), second.segments.size())
	for i in count:
		var a: Segment = first.segments[i]
		var b: Segment = second.segments[i]
		if a.id != b.id:
			identical_ids = false
			break
	check(identical_ids, "double bake produces identical ids in identical order")

	# A structurally-unchanged but freshly duplicated structures array must
	# still be byte-identical: identifiers are never derived from Dictionary
	# iteration order or node/scene-tree order.
	var third := Bake.bake(RealLayout.structures.duplicate(true), RealLayout.size_cells)
	check(third.ok and Bake.segments_digest(third.segments) == digest_a,
		"bake is stable against a duplicated copy of the same structures data")

	if not first.segments.is_empty():
		var sample: Segment = first.segments[0]
		check(ZCanonicalValue.is_bounded(sample.canonical_record()),
			"a segment's canonical record is a bounded canonical value")
		check(not sample.digest().is_empty(), "a segment's own digest is non-empty")


func _row(id: String, layer: String, rect: Rect2i) -> Dictionary:
	return {"id": id, "tile": "fence", "layer": layer, "role": "cover", "rect": rect}


func _tile_point(cell: Vector2i) -> Vector2i:
	var px := ZWorldUnits.tile_origin_to_godot(cell)
	var vision := ZWorldUnits.godot_to_vision(px.vector2_value)
	return vision.vector2i_value


func _has_segment(segments: Array, a: Vector2i, b: Vector2i) -> bool:
	for segment in segments:
		var s: Segment = segment
		if (s.a == a and s.b == b) or (s.a == b and s.b == a):
			return true
	return false


func _has_error_code(errors: Array, code: StringName) -> bool:
	for error in errors:
		if error.code == code:
			return true
	return false


func _error_named(errors: Array, source_id: String, code: StringName) -> bool:
	for error in errors:
		if String(error.source_id) == source_id and error.code == code:
			return true
	return false
