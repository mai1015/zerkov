class_name ZWorldCursorAdapter
extends RefCounted
## Input/presentation adapter mapping cursor coordinates and resolving interaction targets.
##
## Maps output-canvas pointer coordinates to world space through the integer
## scale / matte projection, ranks candidate markers deterministically with an
## explicit total tie-break, and emits interaction intents naming candidate IDs.
## Holds no transform authority and performs no eligibility/line/range checks.

const INTENT_KIND_INTERACTION: StringName = &"interaction"
const EXACT_OUTPUT_SIZE := Vector2i(1920, 1080)
const TILE_PIXELS: float = 32.0
const HALF_TILE: float = 16.0

var _session_id: ZSessionId
var _actor_id: ZEntityId
var _authority_epoch: int = 0
var _generation: int = 0
var _next_sequence: int = 0
var _last_error: StringName = &""
var _camera_position_px: Vector2 = Vector2(320.0, 180.0)
var _output_size: Vector2i = EXACT_OUTPUT_SIZE


func configure(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int
) -> bool:
	_last_error = &""
	if session_id == null or not session_id.is_initialized():
		_last_error = &"session_id_invalid"
		return false
	if actor_id == null or not actor_id.is_initialized():
		_last_error = &"actor_id_invalid"
		return false
	if authority_epoch <= 0 or generation <= 0:
		_last_error = &"epoch_or_generation_invalid"
		return false
	_session_id = session_id
	_actor_id = actor_id
	_authority_epoch = authority_epoch
	_generation = generation
	_next_sequence = 0
	return true


func is_configured() -> bool:
	return _session_id != null and _actor_id != null and _authority_epoch > 0 and _generation > 0


func last_error() -> StringName:
	return _last_error


func set_camera_position(cam_pos: Vector2) -> void:
	_camera_position_px = cam_pos


func get_camera_position() -> Vector2:
	return _camera_position_px


func set_output_size(output_size: Vector2i) -> void:
	_output_size = output_size


func get_output_size() -> Vector2i:
	return _output_size


## Maps full-output screen coordinates to world coordinates.
func screen_to_world(
	screen_pos: Vector2,
	cam_pos: Vector2 = Vector2.INF,
	output_size: Vector2i = Vector2i(-1, -1)
) -> ZWorldCursorAimResult:
	var camera := _camera_position_px if is_inf(cam_pos.x) else cam_pos
	var out_size := _output_size if output_size.x <= 0 else output_size
	return ZWorldViewportPolicy.screen_to_world(screen_pos, camera, out_size)


## Maps world coordinates to full-output screen coordinates.
func world_to_screen(
	world_pos: Vector2,
	cam_pos: Vector2 = Vector2.INF,
	output_size: Vector2i = Vector2i(-1, -1)
) -> Vector2:
	var camera := _camera_position_px if is_inf(cam_pos.x) else cam_pos
	var out_size := _output_size if output_size.x <= 0 else output_size
	return ZWorldViewportPolicy.world_to_screen(world_pos, camera, out_size)


## Ranks candidate markers deterministically using explicit total tie-break:
## 1. Distance squared to aim point (closest first)
## 2. Distance squared to actor pose (closest first)
## 3. String representation of marker_id (lexicographical total order)
func rank_candidates(
	aim_world_px: Vector2,
	actor_world_px: Vector2,
	candidates: Array
) -> PackedStringArray:
	if candidates.is_empty():
		return PackedStringArray()

	var records: Array[Dictionary] = []
	for item in candidates:
		var marker_id := _extract_marker_id(item)
		if marker_id.is_empty():
			continue
		var marker_pos := _extract_marker_position(item)
		var aim_d2 := aim_world_px.distance_squared_to(marker_pos)
		var actor_d2 := actor_world_px.distance_squared_to(marker_pos)
		records.append({
			"actor_d2": actor_d2,
			"aim_d2": aim_d2,
			"id": marker_id,
		})

	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var diff_aim: float = float(a["aim_d2"]) - float(b["aim_d2"])
		if absf(diff_aim) > 0.0001:
			return diff_aim < 0.0
		var diff_actor: float = float(a["actor_d2"]) - float(b["actor_d2"])
		if absf(diff_actor) > 0.0001:
			return diff_actor < 0.0
		return String(a["id"]) < String(b["id"])
	)

	var result := PackedStringArray()
	for rec in records:
		result.append(String(rec["id"]))
	return result


## Returns top-ranked candidate target ID, or &"" if no valid candidate.
func select_target_id(
	aim_world_px: Vector2,
	actor_world_px: Vector2,
	candidates: Array
) -> StringName:
	var ranked := rank_candidates(aim_world_px, actor_world_px, candidates)
	return StringName(ranked[0]) if not ranked.is_empty() else &""


## Emits an interaction intent naming a specific target ID.
func build_interaction_intent(
	target_tick: int,
	target_id: Variant,
	request_id: ZRequestId = null
) -> ZRaidIntent:
	_last_error = &""
	if not is_configured():
		_last_error = &"adapter_unconfigured"
		return null
	var target_str := String(target_id)
	if target_str.is_empty():
		_last_error = &"target_id_empty"
		return null

	_next_sequence += 1
	var resolved_request_id := request_id
	if resolved_request_id == null:
		var actor_slot := _actor_id.canonical_key().get_slice(".", 4)
		resolved_request_id = ZRequestId.from_parts(PackedStringArray([
			"interact",
			actor_slot if not actor_slot.is_empty() else "player",
			"%08d" % _next_sequence,
		]))

	var payload := {
		"target_id": target_str,
	}

	return ZRaidIntent.create(
		resolved_request_id,
		ZRaidIntent.Source.PLAYER,
		_session_id,
		_actor_id,
		_authority_epoch,
		_generation,
		target_tick,
		_next_sequence,
		INTENT_KIND_INTERACTION,
		payload
	)


## Maps pointer to world aim, ranks candidates, and emits intent naming top target.
func build_interaction_intent_from_aim(
	target_tick: int,
	screen_pointer_px: Vector2,
	actor_world_px: Vector2,
	candidates: Array,
	cam_pos: Vector2 = Vector2.INF,
	request_id: ZRequestId = null
) -> ZRaidIntent:
	var aim_result := screen_to_world(screen_pointer_px, cam_pos)
	if not aim_result.inside_surface:
		_last_error = &"aim_outside_world_surface"
		return null

	var target_id := select_target_id(aim_result.world_position, actor_world_px, candidates)
	if target_id.is_empty():
		_last_error = &"no_candidate_targets"
		return null

	return build_interaction_intent(target_tick, target_id, request_id)


static func _extract_marker_id(marker: Variant) -> String:
	if marker is Dictionary:
		return String(marker.get("id", marker.get("marker_id", "")))
	if marker is Object:
		if "marker_id" in marker:
			return String(marker.marker_id)
		if "name" in marker:
			return String(marker.name)
	return ""


static func _extract_marker_position(marker: Variant) -> Vector2:
	if marker is Dictionary:
		if marker.has("position"):
			return marker["position"]
		if marker.has("cell"):
			var cell: Vector2i = marker["cell"]
			return Vector2(float(cell.x) * TILE_PIXELS + HALF_TILE, float(cell.y) * TILE_PIXELS + HALF_TILE)
	if marker is Object:
		if "position" in marker:
			return marker.position
		if "cell" in marker:
			var cell: Vector2i = marker.cell
			return Vector2(float(cell.x) * TILE_PIXELS + HALF_TILE, float(cell.y) * TILE_PIXELS + HALF_TILE)
	return Vector2.ZERO
