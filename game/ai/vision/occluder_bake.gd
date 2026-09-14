class_name ZOccluderBake
extends RefCounted
## Deterministic Common Vision occluder bake from explicit level-authoring data.
##
## Task 3.10. Input is exactly the caller-supplied authored `structures` rows
## (`{id, tile, layer, role, rect}`, `rect` in tile/cell units) and the level's
## `size_cells` bound -- this bake never loads the Sawmill scene, queries
## physics, or reads a TileMapLayer. It emits stable line-segment occluders
## (the outline of the authored blocking geometry), not per-tile boxes:
## rects that touch or overlap have their shared internal edges removed, and
## collinear runs on the same line merge into one segment.
##
## Occluder masks come from the sealed `ZerkovVisionConfig` occluder-mask
## domain: `layer == "Obstacles"` rows are structures (bit 0), `layer ==
## "Canopy"` rows are vegetation/canopy (bit 1). See
## `game/ai/vision/README.md` -- "Fixed first-playable values".
##
## Segment ids are derived deterministically from the contributing authored
## `structures` id(s) plus a stable ordinal; two bakes of unchanged input
## always produce identical ids in identical order (segments are sorted
## explicitly, never taken from Dictionary iteration or node order).

const LAYER_STRUCTURE: String = "Obstacles"
const LAYER_VEGETATION: String = "Canopy"

const MASK_STRUCTURE: int = ZerkovVisionConfig.OCCLUDER_LAYER_STRUCTURE
const MASK_VEGETATION: int = ZerkovVisionConfig.OCCLUDER_LAYER_VEGETATION

## `game/ai/vision/README.md` documents 128 authored segments as the
## admission assumption behind the sealed config's 16,384 work-unit Vision
## evaluation budget. This is the explicit budget this bake validates
## against; exceeding it is a fail-closed condition, not something this bake
## silently absorbs by raising the constant.
const SEGMENT_BUDGET_MAX: int = 128

const ID_INFIX: String = ".occluder."

const _CARDINAL_DELTAS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
]


## Bakes `structures` rows (as authored on `ZSawmillYardLayout.structures`)
## against a level bound of `size_cells` tiles.
##
## Returns `{"ok": bool, "segments": Array[ZerkovOccluderSegment], "errors":
## Array[Dictionary], "budget": int}`. `errors` entries are
## `{"source_id": String, "code": StringName, "message": String}`. On any
## error the bake fails closed: `segments` is empty even if some rows were
## individually valid.
static func bake(structures: Array, size_cells: Vector2i) -> Dictionary:
	var errors: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var valid_rows: Array[Dictionary] = []
	var bounds := Rect2i(Vector2i.ZERO, size_cells)

	for index in structures.size():
		var row: Dictionary = structures[index]
		var label := "structures[%d]" % index

		if not row.has("id"):
			errors.append(_error(label, &"missing_id", "structure row has no id field"))
			continue
		var id_text := String(row["id"])
		if id_text.is_empty():
			errors.append(_error(label, &"missing_id", "structure row id is empty"))
			continue
		if seen_ids.has(id_text):
			errors.append(_error(id_text, &"duplicate_id", "duplicate structure id"))
			continue
		seen_ids[id_text] = true

		var layer_text := String(row.get("layer", ""))
		var mask := 0
		if layer_text == LAYER_STRUCTURE:
			mask = MASK_STRUCTURE
		elif layer_text == LAYER_VEGETATION:
			mask = MASK_VEGETATION
		else:
			errors.append(_error(
				id_text, &"unknown_layer", "unknown structure layer '%s'" % layer_text
			))
			continue

		var rect_value: Variant = row.get("rect")
		if not (rect_value is Rect2i):
			errors.append(_error(id_text, &"rect_invalid", "rect is not a Rect2i"))
			continue
		var rect: Rect2i = rect_value
		if rect.size.x <= 0 or rect.size.y <= 0:
			errors.append(_error(
				id_text, &"rect_zero_or_negative_area",
				"rect has zero or negative area: %s" % str(rect)
			))
			continue
		if not bounds.encloses(rect):
			errors.append(_error(
				id_text, &"rect_outside_level_bounds",
				"rect %s falls outside level bounds %s" % [str(rect), str(bounds)]
			))
			continue

		valid_rows.append({"id": id_text, "mask": mask, "rect": rect})

	if not errors.is_empty():
		return _failure(errors)

	var segments: Array[ZerkovOccluderSegment] = []
	for mask in [MASK_STRUCTURE, MASK_VEGETATION]:
		var rows_for_mask: Array[Dictionary] = []
		for row in valid_rows:
			if int(row["mask"]) == mask:
				rows_for_mask.append(row)
		if rows_for_mask.is_empty():
			continue
		var group := _bake_group(rows_for_mask, mask)
		errors.append_array(group["errors"])
		segments.append_array(group["segments"])

	if not errors.is_empty():
		return _failure(errors)

	segments.sort_custom(func(a: ZerkovOccluderSegment, b: ZerkovOccluderSegment) -> bool:
		return a.id < b.id
	)

	if segments.size() > SEGMENT_BUDGET_MAX:
		errors.append(_error(
			"", &"segment_budget_exceeded",
			"baked segment count %d exceeds budget %d" % [segments.size(), SEGMENT_BUDGET_MAX]
		))
		return _failure(errors)

	return {"ok": true, "segments": segments, "errors": [], "budget": SEGMENT_BUDGET_MAX}


## Aggregate deterministic digest across every segment's canonical record.
## Always uses a framed streaming hash (rather than a single
## `ZCanonicalValue.sha256` call on the whole array) so it stays correct past
## `ZCanonicalValue.DEFAULT_MAX_COLLECTION` entries -- see
## `game/raid/raid_event_journal.gd` for the same framing idiom.
static func segments_digest(segments: Array) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update("zerkov.vision_occluder_bake.v1\n".to_utf8_buffer()) != OK:
		return ""
	for segment in segments:
		var record: Dictionary = (segment as ZerkovOccluderSegment).canonical_record()
		var encoded := ZCanonicalValue.encode(record)
		if encoded.is_empty():
			return ""
		var bytes := encoded.to_utf8_buffer()
		if context.update(("%d:" % bytes.size()).to_utf8_buffer()) != OK:
			return ""
		if context.update(bytes) != OK:
			return ""
	var digest := context.finish()
	if digest.is_empty():
		return ""
	return digest.hex_encode()


## Exposed for direct unit coverage of the degeneracy guard. In the full
## `bake()` pipeline a zero-length resulting segment cannot occur once every
## row has already passed the zero/negative-area guard above (integer tile
## boundaries a tile apart never convert to identical Vision points -- see
## `ZWorldUnits`), so this check is deliberate defense in depth rather than a
## reachable path; it is still validated directly.
static func is_degenerate_segment(a: Vector2i, b: Vector2i) -> bool:
	return a == b


static func _bake_group(rows: Array[Dictionary], mask: int) -> Dictionary:
	var occupancy: Dictionary = {}
	for row in rows:
		var rect: Rect2i = row["rect"]
		var id_text: String = row["id"]
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var cell := Vector2i(x, y)
				if occupancy.has(cell):
					if id_text < String(occupancy[cell]):
						occupancy[cell] = id_text
				else:
					occupancy[cell] = id_text

	var cell_keys: Array = occupancy.keys()
	cell_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	)

	var errors: Array[Dictionary] = []
	var segments: Array[ZerkovOccluderSegment] = []
	var visited: Dictionary = {}

	for start_cell in cell_keys:
		if visited.has(start_cell):
			continue
		var blob_cells: Array[Vector2i] = []
		var stack: Array[Vector2i] = [start_cell]
		visited[start_cell] = true
		while not stack.is_empty():
			var current: Vector2i = stack.pop_back()
			blob_cells.append(current)
			for delta in _CARDINAL_DELTAS:
				var neighbor := current + delta
				if occupancy.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					stack.append(neighbor)

		var blob_id := ""
		for cell in blob_cells:
			var owner_id: String = occupancy[cell]
			if blob_id.is_empty() or owner_id < blob_id:
				blob_id = owner_id

		var blob_result := _boundary_segments_for_blob(blob_cells, occupancy, mask, blob_id)
		errors.append_array(blob_result["errors"])
		segments.append_array(blob_result["segments"])

	return {"errors": errors, "segments": segments}


static func _boundary_segments_for_blob(
	blob_cells: Array[Vector2i],
	occupancy: Dictionary,
	mask: int,
	blob_id: String
) -> Dictionary:
	# Horizontal edges keyed by their grid line y; vertical edges keyed by
	# their grid line x. Each unit edge only exists when the cell that would
	# expose it has no same-mask-group neighbor on that side.
	var horizontal_lines: Dictionary = {}
	var vertical_lines: Dictionary = {}

	for cell in blob_cells:
		var x := cell.x
		var y := cell.y
		var owner_id: String = occupancy[cell]

		if not occupancy.has(Vector2i(x, y - 1)):
			_append_unit(horizontal_lines, y, x, owner_id)
		if not occupancy.has(Vector2i(x, y + 1)):
			_append_unit(horizontal_lines, y + 1, x, owner_id)
		if not occupancy.has(Vector2i(x - 1, y)):
			_append_unit(vertical_lines, x, y, owner_id)
		if not occupancy.has(Vector2i(x + 1, y)):
			_append_unit(vertical_lines, x + 1, y, owner_id)

	# {orientation, line, start, end, owners} in tile-space, pre-conversion.
	var raw_runs: Array[Dictionary] = []
	for line in horizontal_lines.keys():
		for run in _merge_units(horizontal_lines[line]):
			raw_runs.append({
				"a": Vector2i(run["start"], line), "b": Vector2i(run["end"], line),
				"owners": run["owners"],
			})
	for line in vertical_lines.keys():
		for run in _merge_units(vertical_lines[line]):
			raw_runs.append({
				"a": Vector2i(line, run["start"]), "b": Vector2i(line, run["end"]),
				"owners": run["owners"],
			})

	raw_runs.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		var pa: Vector2i = p["a"]
		var pb: Vector2i = p["b"]
		var qa: Vector2i = q["a"]
		var qb: Vector2i = q["b"]
		if pa.x != qa.x:
			return pa.x < qa.x
		if pa.y != qa.y:
			return pa.y < qa.y
		if pb.x != qb.x:
			return pb.x < qb.x
		return pb.y < qb.y
	)

	var errors: Array[Dictionary] = []
	var segments: Array[ZerkovOccluderSegment] = []
	for ordinal in raw_runs.size():
		var run: Dictionary = raw_runs[ordinal]
		var a_tile: Vector2i = run["a"]
		var b_tile: Vector2i = run["b"]

		var a_px := ZWorldUnits.tile_origin_to_godot(a_tile)
		if not a_px.ok:
			errors.append(_error(
				blob_id, &"vision_conversion_out_of_range",
				"occluder vertex %s failed world conversion" % str(a_tile)
			))
			continue
		var b_px := ZWorldUnits.tile_origin_to_godot(b_tile)
		if not b_px.ok:
			errors.append(_error(
				blob_id, &"vision_conversion_out_of_range",
				"occluder vertex %s failed world conversion" % str(b_tile)
			))
			continue

		var a_vision := ZWorldUnits.godot_to_vision(a_px.vector2_value)
		if not a_vision.ok:
			errors.append(_error(
				blob_id, &"vision_conversion_out_of_range",
				"occluder vertex %s exceeds the Vision point bound" % str(a_px.vector2_value)
			))
			continue
		var b_vision := ZWorldUnits.godot_to_vision(b_px.vector2_value)
		if not b_vision.ok:
			errors.append(_error(
				blob_id, &"vision_conversion_out_of_range",
				"occluder vertex %s exceeds the Vision point bound" % str(b_px.vector2_value)
			))
			continue

		if is_degenerate_segment(a_vision.vector2i_value, b_vision.vector2i_value):
			errors.append(_error(
				blob_id, &"degenerate_segment", "baked segment has zero length"
			))
			continue

		var owners: Array = run["owners"]
		var segment_id := "%s%s%03d" % [blob_id, ID_INFIX, ordinal]
		segments.append(ZerkovOccluderSegment.create(
			segment_id, mask, a_vision.vector2i_value, b_vision.vector2i_value, owners
		))

	return {"errors": errors, "segments": segments}


static func _append_unit(lines: Dictionary, line: int, pos: int, owner_id: String) -> void:
	if not lines.has(line):
		lines[line] = []
	(lines[line] as Array).append({"pos": pos, "owner": owner_id})


## Merges contiguous unit positions on one grid line into runs, collecting
## the distinct (sorted) owner ids that contributed to each run.
static func _merge_units(units: Array) -> Array[Dictionary]:
	var sorted_units: Array = units.duplicate()
	sorted_units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["pos"]) < int(b["pos"])
	)

	var runs: Array[Dictionary] = []
	var current: Dictionary = {}
	for unit in sorted_units:
		var pos: int = unit["pos"]
		var owner_id: String = unit["owner"]
		if not current.is_empty() and pos == int(current["end"]):
			current["end"] = pos + 1
			var owners: Array = current["owners"]
			if not owners.has(owner_id):
				owners.append(owner_id)
		else:
			if not current.is_empty():
				runs.append(current)
			current = {"start": pos, "end": pos + 1, "owners": [owner_id]}
	if not current.is_empty():
		runs.append(current)

	for run in runs:
		var owners: Array = run["owners"]
		owners.sort()

	return runs


static func _error(source_id: String, code: StringName, message: String) -> Dictionary:
	return {"source_id": source_id, "code": code, "message": message}


static func _failure(errors: Array[Dictionary]) -> Dictionary:
	return {"ok": false, "segments": [], "errors": errors, "budget": SEGMENT_BUDGET_MAX}
