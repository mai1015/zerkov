class_name LocalRaidAIWorldPort
extends RaidAIWorldPort
## Production composition adapter. Brains receive detached own state and Vision
## observations; these authority handles never leave this root-owned port.
const MAX_PENDING: int = 64
var last_error: StringName = &""
var _raid: RaidAuthority
var _combat: RaidCombatSession
var _rows: Dictionary = {}
var _routers: Dictionary = {}
var _navigation: ZNavigationPathService
var _revision: int = 0
var _segments: Array = []
var _geometry_payload_pending: bool = true
var _vision_frame_captures: int = 0
var _geometry_payload_publications: int = 0
var _paths: Dictionary = {}
var _pending: Dictionary = {}
var _aim: Dictionary = {}
var _hp: Dictionary = {}
var _under_fire_until: Dictionary = {}
var _released: bool = false
var _generation: int = 0

func configure(raid: RaidAuthority, combat: RaidCombatSession, rows: Dictionary,
		routers: Dictionary, navigation: ZNavigationPathService, revision: int, segments: Array) -> bool:
	if _raid != null or raid == null or combat == null or combat.execution == null \
		or navigation == null or revision < 1 or rows.size() < 1 or rows.size() > RaidCombatExecution.MAX_ACTORS:
		return false
	_raid = raid
	_combat = combat
	_rows = rows.duplicate()
	_routers = routers.duplicate()
	_navigation = navigation
	_revision = revision
	_segments = segments.duplicate(true)
	_generation = raid.generation()
	for key: String in _rows:
		_aim[key] = Vector2.RIGHT
	return true

func is_ready(generation: int) -> bool:
	return not _released and _raid != null and generation == _generation \
		and _raid.generation() == generation and _combat.execution != null

func capture_vision_frame(generation: int, tick: int) -> Dictionary:
	if not is_ready(generation): return {}
	_vision_frame_captures += 1
	var actors: Array = []
	var keys := _rows.keys()
	keys.sort()
	for key: String in keys:
		var row: Dictionary = _rows[key]
		var movement: ZPlayerLocomotion = row.movement
		var health := _combat.health.actor_snapshot(row.actor_id)
		if health.is_empty() or movement.last_processed_tick != tick: return {}
		var hp := _health_total(health)
		if _hp.has(key) and hp < int(_hp[key]): _under_fire_until[key] = tick + 120
		_hp[key] = hp
		var position := ZWorldUnits.godot_to_canonical(movement.position_px)
		if not position.ok: return {}
		var facing := Vector2i(movement.facing_direction.normalized() * float(ZAIValues.UNIT))
		if facing == Vector2i.ZERO: facing = Vector2i(ZAIValues.UNIT, 0)
		actors.append({"entity_id": key, "revision": tick, "position_raw": position.vector2i_value,
			"facing_raw": facing, "archetype": row.archetype, "alive": bool(health.alive)})
	var geometry_payload: Array = _segments if _geometry_payload_pending else []
	if _geometry_payload_pending:
		_geometry_payload_publications += 1
	_geometry_payload_pending = false
	return {"actors": actors, "geometry_revision": _revision, "segments": geometry_payload}


func work_counts() -> Dictionary:
	return {
		"vision_frame_captures": _vision_frame_captures,
		"geometry_payload_publications": _geometry_payload_publications,
		"geometry_segment_count": _segments.size(),
	}

func self_state(generation: int, tick: int, actor_id: String) -> Dictionary:
	if not is_ready(generation) or not _rows.has(actor_id): return {}
	var row: Dictionary = _rows[actor_id]
	var health := _combat.health.actor_snapshot(row.actor_id)
	if health.is_empty(): return {}
	var position := ZWorldUnits.godot_to_canonical(row.movement.position_px)
	if not position.ok: return {}
	var maximum: int = 0
	for part: Dictionary in health.body_parts: maximum += int(part.max_health_micros)
	var frame := _combat.execution.frame_for(actor_id)
	var weapon: Dictionary = frame.get("weapon", {})
	return {"entity_id": actor_id, "position_raw": position.vector2i_value, "alive": bool(health.alive),
		"health_milli": clampi(int(1000.0 * _health_total(health) / maxi(1, maximum)), 0, 1000),
		"ammo": int(weapon.get("loaded_rounds", 0)), "reloading": weapon.get("phase") == "reloading",
		"can_move": bool(health.alive), "under_fire": int(_under_fire_until.get(actor_id, 0)) >= tick,
		"navigation_revision": _revision}

func patrol_points(actor_id: String) -> Array:
	return _rows.get(actor_id, {}).get("patrol", []).duplicate()

func cover_points(actor_id: String) -> Array:
	return _rows.get(actor_id, {}).get("cover", []).duplicate()

func submit_path_request(request: Dictionary) -> bool:
	var key: String = request.get("actor_id", "")
	if not is_ready(int(request.get("generation", 0))) or not _routers.has(key) or _paths.has(key) \
		or request.get("navigation_revision") != _revision: return false
	var start := ZWorldUnits.canonical_to_godot(request.origin_raw)
	var goal := ZWorldUnits.canonical_to_godot(request.destination_raw)
	if not start.ok or not goal.ok: return false
	var result := _navigation.request_path(ZWorldUnits.godot_to_tile(start.vector2_value).vector2i_value,
		ZWorldUnits.godot_to_tile(goal.vector2_value).vector2i_value, _revision)
	var points: Array = []
	if result.is_ok():
		# Retain corners, not every cell. The native collision owner still resolves
		# each requested movement; this never teleports or guarantees arrival.
		var cells: Array[Vector2i] = result.cells
		for index in range(cells.size()):
			if index > 0 and index + 1 < cells.size() and cells[index] - cells[index - 1] == cells[index + 1] - cells[index]:
				continue
			points.append(ZWorldUnits.godot_to_canonical(ZWorldUnits.tile_center_to_godot(cells[index]).vector2_value).vector2i_value)
		if points.size() < 63: points.append(request.destination_raw)
	var ok: bool = result.is_ok() and not points.is_empty() and points.size() <= 64
	_paths[key] = {"request_id": request.request_id, "generation": _generation, "actor_id": key,
		"resolved_tick": int(request.requested_tick), "navigation_revision": _revision,
		"ok": ok, "points": points if ok else []}
	return true

func poll_path_result(generation: int, _tick: int, actor_id: String) -> Dictionary:
	if not is_ready(generation): return {}
	var result: Dictionary = _paths.get(actor_id, {})
	_paths.erase(actor_id)
	return result

func submit_action_request(request: Dictionary) -> Dictionary:
	var key: String = request.get("actor_id", "")
	if not is_ready(int(request.get("generation", 0))) or not _routers.has(key) \
		or _pending.size() >= MAX_PENDING or _pending.has(request.get("request_id")):
		return {"admitted": false, "reason": &"ai_local_binding_invalid"}
	var router: ZCombatActionRouter = _routers[key]
	var kind: StringName = request.kind
	var aim: Vector2 = _aim[key]
	var accepted: Dictionary
	if kind == &"aim":
		aim = Vector2(request.payload.direction_milli).normalized()
		_aim[key] = aim
		accepted = router.submit_action(kind, {"direction_milli": request.payload.direction_milli,
			"aiming": true}, request.target_tick, _generation)
	elif kind == &"move":
		accepted = router.submit_movement(request.target_tick, _generation,
			Vector2(request.payload.direction_milli) / 1000.0, aim, false, false)
	elif kind in [&"fire", &"reload", &"melee"]:
		var frame := _combat.execution.frame_for(key)
		if frame.is_empty(): return {"admitted": false, "reason": &"ai_combat_frame_not_ready"}
		var payload := ZCombatInputBinding.payload_for(kind, frame, aim, true)
		if ZCombatActionCodec.validate_payload(kind, payload) != &"":
			return {"admitted": false, "reason": &"ai_equipment_unavailable"}
		accepted = router.submit_action(kind, payload, request.target_tick, _generation)
	else:
		return {"admitted": false, "reason": &"ai_action_unsupported"}
	# Preserve ambiguous post-admission truth: the runtime fails closed instead
	# of treating an unknown mutation as a safe retry.
	if accepted.get("admitted") == true and kind != &"aim":
		_pending[request.request_id] = {"actor_id": key, "kind": kind,
			"canonical_id": accepted.request_id, "target_tick": request.target_tick}
	return accepted

func take_action_results(generation: int, tick: int, actor_id: String) -> Array:
	if not is_ready(generation): return []
	var results: Array = []
	var keys := _pending.keys()
	keys.sort()
	for id: String in keys:
		var pending: Dictionary = _pending[id]
		if pending.actor_id != actor_id or int(pending.target_tick) >= tick: continue
		var receipt := _combat.execution.receipt(pending.canonical_id)
		var resolved: bool = receipt.get("terminal", false)
		var accepted: bool = receipt.get("committed", false)
		var resolved_tick: int = int(receipt.get("resolved_tick", pending.target_tick))
		if pending.kind == &"move":
			var movement: ZPlayerLocomotion = _rows[actor_id].movement
			resolved = movement.last_processed_tick >= int(pending.target_tick)
			accepted = resolved and bool(_combat.health.actor_snapshot(_rows[actor_id].actor_id).get("alive", false))
		if not resolved: continue
		results.append({"request_id": id, "generation": generation, "actor_id": actor_id,
			"resolved_tick": resolved_tick, "accepted": accepted})
		_pending.erase(id)
	return results

func take_committed_noise(generation: int, tick: int) -> Array:
	return _combat.execution.committed_noise(tick) if is_ready(generation) else []

func release() -> void:
	_released = true
	_paths.clear()
	_pending.clear()
	_rows.clear()
	_routers.clear()
	_raid = null
	_combat = null

static func _health_total(health: Dictionary) -> int:
	var total: int = 0
	for part: Dictionary in health.get("body_parts", []): total += int(part.health_micros)
	return total
