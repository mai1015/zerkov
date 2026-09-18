class_name ZNavigationGrid
extends RefCounted
## Authored navigation data for one level (task 3.9).
##
## This grid is DERIVED data, never a second blocking truth. The bake builds
## the authoritative collision world through task 3.6's ZMovementWorldBuilder
## (or accepts a ZMovementWorld2D the caller already built) and asks that
## world's own read-only placement predicate whether the navigation body can stand
## at each authored cell centre. No overlap test is re-implemented here and
## no authored structure list is re-interpreted here, so navigation blocking
## cannot drift from authoritative collision.
##
## Pure data module: no scene tree, no engine navigation map or agent API, no
## frame timing, no randomness, no add-on state. A grid is advisory input for
## path requests only; it never participates in a canonical raid digest and
## rebuilding a grid mutates nothing outside this object.

## Navigation body half extents in Godot px. Equals the player body used for
## task 3.6 registration (ZPlayerLocomotion default), so "walkable cell" and
## "an authoritative actor can stand here" are the same statement.
const NAVIGATION_BODY_HALF_EXTENTS_PX: Vector2 = Vector2(8.0, 8.0)
## Generation bound for the throwaway bake-time probe world. The probe world
## is discarded when the bake returns; it never leaves this module.
const PROBE_WORLD_GENERATION: int = 0
## Cells hashed per bounded canonical chunk, so digests never depend on
## Dictionary iteration order and never exceed ZCanonicalValue bounds.
const DIGEST_CHUNK_CELLS: int = 48
const BAKED_CACHE_VERSION: int = 1
const MAX_BAKED_CACHE_CELLS: int = 16_384

const PROBE_WALKABLE: int = 0
const PROBE_BLOCKED: int = 1
const PROBE_ERROR: int = 2

static var last_error: StringName = &""

var _level_id: String = ""
var _size_cells: Vector2i = Vector2i.ZERO
var _revision: int = -1
var _blocked: Dictionary = {}  # Vector2i -> true; never iterated for output
var _source_digest: String = ""
var _edge_masks: Dictionary = {}
var _swept_edges: bool = false
var _body_margin_px: float = 0.0
const STEPS := [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1),Vector2i(1,1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(-1,-1)]


## Bakes the grid from authored Sawmill layout data. The blocking truth is
## task 3.6's: this builds the movement world from the same authored layout
## through ZMovementWorldBuilder and probes it. When navigation_revision is
## negative the authored layout revision is used.
static func bake_from_sawmill_layout(
	layout: Resource,
	navigation_revision: int = -1
) -> ZNavigationGrid:
	last_error = &""
	if layout == null:
		last_error = &"layout_missing"
		return null
	if not layout.has_method("world_bounds"):
		last_error = &"layout_api_invalid"
		return null
	var size_cells_value: Variant = layout.get("size_cells")
	if typeof(size_cells_value) != TYPE_VECTOR2I:
		last_error = &"layout_size_invalid"
		return null
	var size_cells: Vector2i = size_cells_value
	if size_cells.x <= 0 or size_cells.y <= 0:
		last_error = &"layout_size_invalid"
		return null
	var resolved_revision := navigation_revision
	if resolved_revision < 0:
		resolved_revision = int(layout.get("revision"))
	if resolved_revision < 0:
		last_error = &"revision_invalid"
		return null
	var world := ZMovementWorldBuilder.build_from_sawmill_layout(
		layout, PROBE_WORLD_GENERATION
	)
	if world == null:
		last_error = ZMovementWorldBuilder.last_error
		return null
	return bake_from_movement_world(
		world, size_cells, resolved_revision, String(layout.get("level_id"))
	)


## Bakes the grid from an already-built authoritative movement world. Every
## cell is probed through the movement world's own read-only placement predicate, so
## the blocked set IS the collision truth at navigation-body scale.
static func bake_from_movement_world(
	world: ZMovementWorld2D,
	size_cells: Vector2i,
	navigation_revision: int,
	level_id: String = "",
	sweep_edges: bool = false,
	body_margin_px: float = 0.0
) -> ZNavigationGrid:
	last_error = &""
	if world == null:
		last_error = &"movement_world_missing"
		return null
	if not world.is_configured():
		last_error = &"movement_world_unconfigured"
		return null
	if size_cells.x <= 0 or size_cells.y <= 0:
		last_error = &"grid_size_invalid"
		return null
	if navigation_revision < 0:
		last_error = &"revision_invalid"
		return null
	var grid_rect := Rect2(
		Vector2.ZERO, Vector2(size_cells * ZWorldUnits.SOURCE_TILE_PIXELS)
	)
	if not world.bounds_px().grow(0.01).encloses(grid_rect):
		last_error = &"grid_exceeds_collision_bounds"
		return null
	if not is_finite(body_margin_px) or body_margin_px<0 or body_margin_px>8:
		last_error=&"navigation_margin_invalid"
		return null
	var half:=NAVIGATION_BODY_HALF_EXTENTS_PX+Vector2.ONE*body_margin_px
	var grid := ZNavigationGrid.new()
	grid._body_margin_px=body_margin_px
	grid._size_cells = size_cells
	grid._revision = navigation_revision
	grid._level_id = level_id
	# Only geometry belongs to this advisory identity, never live actors/ticks.
	grid._source_digest = world.geometry_digest()
	if grid._source_digest.is_empty():
		last_error = &"movement_geometry_digest_invalid"
		return null
	for y in size_cells.y:
		for x in size_cells.x:
			var cell := Vector2i(x, y)
			var probe := _probe_cell(world, cell, half)
			if probe == PROBE_ERROR:
				return null
			if probe == PROBE_BLOCKED:
				grid._blocked[cell] = true
	if sweep_edges:
		grid._swept_edges=true
		# Off-grid thin walls can lie between two free cell centres. Validate the
		# whole centre-to-centre corridor through the SAME collision owner. The
		# bounding box is exact for cardinal steps, conservative for diagonals.
		for y in size_cells.y:
			for x in size_cells.x:
				var cell:=Vector2i(x,y)
				if not grid.is_walkable(cell):continue
				var mask:int=0
				var a:=ZWorldUnits.tile_center_to_godot(cell).vector2_value
				for i in STEPS.size():
					var next:Vector2i=cell+STEPS[i]
					if not grid.is_walkable(next):continue
					var b:=ZWorldUnits.tile_center_to_godot(next).vector2_value
					var query:=world.query_placement_px((a+b)/2,half+(b-a).abs()/2)
					if query.ok:mask|=(1<<i)
				grid._edge_masks[cell]=mask
	return grid


func is_baked() -> bool:
	return _revision >= 0 and _size_cells.x > 0 and _size_cells.y > 0


func revision() -> int:
	return _revision


func size_cells() -> Vector2i:
	return _size_cells


func level_id() -> String:
	return _level_id


## Digest of the collision world this grid was baked from (inspection only).
func source_digest() -> String:
	return _source_digest


func has_cell(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
			and cell.x < _size_cells.x and cell.y < _size_cells.y


func is_blocked(cell: Vector2i) -> bool:
	return _blocked.has(cell)


func is_walkable(cell: Vector2i) -> bool:
	return has_cell(cell) and not _blocked.has(cell)


func can_traverse(a: Vector2i, b: Vector2i) -> bool:
	if not is_walkable(a) or not is_walkable(b):return false
	var index:int=STEPS.find(b-a)
	return index>=0 and (not _swept_edges or (int(_edge_masks.get(a,0)) & (1<<index))!=0)

func _edge_digest() -> String:
	var context:=HashingContext.new()
	if context.start(HashingContext.HASH_SHA256)!=OK:return ""
	for y in _size_cells.y:
		for x in _size_cells.x:
			if context.update(("%d,"%int(_edge_masks.get(Vector2i(x,y),0))).to_utf8_buffer())!=OK:return ""
	return context.finish().hex_encode()

func blocked_cell_count() -> int:
	return _blocked.size()


func walkable_cell_count() -> int:
	return _size_cells.x * _size_cells.y - _blocked.size()


## Explicit (y, then x) ordering. This is the only sanctioned ordering for
## cell collections in this package; Dictionary iteration order is never used.
func blocked_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell in _blocked.keys():
		cells.append(cell)
	sort_cells(cells)
	return cells


static func sort_cells(cells: Array[Vector2i]) -> void:
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)


## Advisory inspection record, NOT canonical raid state. Nothing in the raid
## digest consumes this value; it exists so a bake can be audited and pinned.
func canonical_record() -> Dictionary:
	var record := {
		"blocked_cell_count": _blocked.size(),
		"blocked_cells_digest": digest_cell_array(blocked_cells()),
		"level_id": _level_id,
		"revision": _revision,
		"size_cells": _size_cells,
		"source_digest": _source_digest,
	}

	if _swept_edges:record["swept_edges"]=_edge_digest()
	if _body_margin_px>0:record["body_margin_micro"]=roundi(_body_margin_px*ZMovementWorld2D.MICRO_PER_PX)
	return record

func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())


## Compact derived-data record for authored-map runtime caches. The collision
## geometry digest remains the authority: a cache is accepted only when it was
## baked from the exact movement world supplied by the caller.
func baked_cache_record() -> Dictionary:
	if not is_baked():
		return {}
	var cell_count: int = _size_cells.x * _size_cells.y
	var blocked_bits := PackedByteArray()
	blocked_bits.resize((cell_count + 7) >> 3)
	var edge_masks := PackedByteArray()
	edge_masks.resize(cell_count)
	for y: int in _size_cells.y:
		for x: int in _size_cells.x:
			var index: int = y * _size_cells.x + x
			var cell := Vector2i(x, y)
			if _blocked.has(cell):
				blocked_bits[index >> 3] = blocked_bits[index >> 3] | (1 << (index & 7))
			edge_masks[index] = int(_edge_masks.get(cell, 0))
	return {
		"version": BAKED_CACHE_VERSION,
		"revision": _revision,
		"level_id": _level_id,
		"size": [_size_cells.x, _size_cells.y],
		"source_digest": _source_digest,
		"grid_digest": digest(),
		"swept_edges": _swept_edges,
		"body_margin_px": _body_margin_px,
		"blocked_bits": Marshalls.raw_to_base64(blocked_bits),
		"edge_masks": Marshalls.raw_to_base64(edge_masks),
	}


## Restores a grid only when every identity field, bitmap, edge relation, and
## final digest agrees with the exact authoritative movement geometry. Invalid
## or stale caches fail closed; callers may choose to perform a fresh bake.
static func restore_baked_cache(
	record: Dictionary,
	world: ZMovementWorld2D,
	size_cells: Vector2i,
	navigation_revision: int,
	level_id: String,
	sweep_edges: bool,
	body_margin_px: float
) -> ZNavigationGrid:
	last_error = &""
	if world == null or not world.is_configured():
		last_error = &"movement_world_unconfigured"
		return null
	if size_cells.x <= 0 or size_cells.y <= 0 \
			or size_cells.x * size_cells.y > MAX_BAKED_CACHE_CELLS:
		last_error = &"navigation_cache_size_invalid"
		return null
	var size_value: Variant = record.get("size")
	if int(record.get("version", -1)) != BAKED_CACHE_VERSION \
			or not size_value is Array or size_value.size() != 2 \
			or Vector2i(int(size_value[0]), int(size_value[1])) != size_cells \
			or int(record.get("revision", -1)) != navigation_revision \
			or String(record.get("level_id", "")) != level_id \
			or bool(record.get("swept_edges", false)) != sweep_edges \
			or not is_equal_approx(float(record.get("body_margin_px", -1.0)), body_margin_px):
		last_error = &"navigation_cache_identity_invalid"
		return null
	var source_digest := String(record.get("source_digest", ""))
	var expected_grid_digest := String(record.get("grid_digest", ""))
	if source_digest.length() != 64 or expected_grid_digest.length() != 64 \
			or source_digest != world.geometry_digest():
		last_error = &"navigation_cache_source_mismatch"
		return null
	var blocked_bits := Marshalls.base64_to_raw(String(record.get("blocked_bits", "")))
	var edge_masks := Marshalls.base64_to_raw(String(record.get("edge_masks", "")))
	var cell_count: int = size_cells.x * size_cells.y
	if blocked_bits.size() != ((cell_count + 7) >> 3) or edge_masks.size() != cell_count:
		last_error = &"navigation_cache_payload_invalid"
		return null
	if (cell_count & 7) != 0:
		var used_bits: int = cell_count & 7
		var padding_mask: int = 0xff ^ ((1 << used_bits) - 1)
		if (int(blocked_bits[-1]) & padding_mask) != 0:
			last_error = &"navigation_cache_padding_invalid"
			return null
	var grid := ZNavigationGrid.new()
	grid._size_cells = size_cells
	grid._revision = navigation_revision
	grid._level_id = level_id
	grid._source_digest = source_digest
	grid._swept_edges = sweep_edges
	grid._body_margin_px = body_margin_px
	for y: int in size_cells.y:
		for x: int in size_cells.x:
			var index: int = y * size_cells.x + x
			var cell := Vector2i(x, y)
			var blocked: bool = (int(blocked_bits[index >> 3]) & (1 << (index & 7))) != 0
			var mask: int = int(edge_masks[index])
			if blocked:
				if mask != 0:
					last_error = &"navigation_cache_blocked_edge"
					return null
				grid._blocked[cell] = true
			elif sweep_edges:
				grid._edge_masks[cell] = mask
			elif mask != 0:
				last_error = &"navigation_cache_unexpected_edges"
				return null
	if sweep_edges:
		for y: int in size_cells.y:
			for x: int in size_cells.x:
				var cell := Vector2i(x, y)
				if grid._blocked.has(cell):
					continue
				var mask: int = int(grid._edge_masks.get(cell, 0))
				for step_index: int in STEPS.size():
					if (mask & (1 << step_index)) == 0:
						continue
					var next: Vector2i = cell + STEPS[step_index]
					var reverse_index: int = STEPS.find(-STEPS[step_index])
					if not grid.is_walkable(next) or reverse_index < 0 \
							or (int(grid._edge_masks.get(next, 0)) & (1 << reverse_index)) == 0:
						last_error = &"navigation_cache_edge_invalid"
						return null
	if grid.digest() != expected_grid_digest:
		last_error = &"navigation_cache_digest_mismatch"
		return null
	return grid


## Deterministic bounded digest for cell arrays of any length: cells are
## hashed in fixed-size chunks, so the result never depends on collection
## iteration order and never exceeds ZCanonicalValue bounds.
static func digest_cell_array(cells: Array[Vector2i]) -> String:
	var chunk_digests: Array = []
	var chunk: Array = []
	for index in cells.size():
		chunk.append(cells[index])
		if chunk.size() >= DIGEST_CHUNK_CELLS:
			chunk_digests.append(ZCanonicalValue.sha256({"cells": chunk}))
			chunk = []
	if not chunk.is_empty() or chunk_digests.is_empty():
		chunk_digests.append(ZCanonicalValue.sha256({"cells": chunk}))
	return ZCanonicalValue.sha256({
		"cell_count": cells.size(),
		"chunk_digests": chunk_digests,
	})


## One blocking question answered by the collision world's read-only query.
## Expected placement denials mark blocked cells; other failures fail closed.
static func _probe_cell(world: ZMovementWorld2D, cell: Vector2i, half:Vector2=NAVIGATION_BODY_HALF_EXTENTS_PX) -> int:
	var center := ZWorldUnits.tile_center_to_godot(cell)
	if not center.ok:
		last_error = &"cell_center_invalid"
		return PROBE_ERROR
	var placement := world.query_placement_px(
		center.vector2_value, half
	)
	if bool(placement["ok"]):
		return PROBE_WALKABLE
	match placement["reason"]:
		&"actor_spawn_blocked", &"actor_out_of_bounds":
			return PROBE_BLOCKED
		_:
			last_error = placement["reason"]
			return PROBE_ERROR
