class_name ZAITestFixtures
extends RefCounted
## TEST DOUBLES. This is not Common Vision, movement, combat or production AI.

const SCAV: String = "zerkov.entity.scav.one"
const PLAYER: String = "zerkov.entity.player.one"
const MUTANT: String = "zerkov.entity.mutant.one"

static func actor(id: String, archetype: String = "scav", position: Vector2i = Vector2i.ZERO) -> Dictionary:
	return {"entity_id": id, "revision": 1, "position_raw": position,
		"facing_raw": Vector2i(1_000_000, 0), "archetype": archetype, "alive": true}


static func own(id: String = SCAV, position: Vector2i = Vector2i.ZERO) -> Dictionary:
	return {"entity_id": id, "position_raw": position, "alive": true,
		"health_milli": 1000, "ammo": 10, "reloading": false, "can_move": true,
		"under_fire": false, "navigation_revision": 1}


static func knowledge(id: String, tick: int, facts: Array = []) -> Dictionary:
	return {"ok": true, "generation": 1, "recipient": id, "tick": tick,
		"completed_tick": tick, "fresh": true, "facts": facts}


static func fact(id: String, tick: int, position: Vector2i, kind: StringName = &"visible") -> Dictionary:
	return {"entity_id": id, "kind": kind, "position_raw": position,
		"last_seen_tick": tick, "confidence_milli": 1000 if kind == &"visible" else 500,
		"target_revision": 1}


static func native_projection(observer: int, target: int, tick: int, revision: int,
	position: Vector2i, state: int = 2, last_seen: int = -1) -> Dictionary:
	return {"ok": true, "observer_id": observer, "world_revision": revision,
		"geometry_revision": 1, "observer_revision": revision, "result_revision": revision,
		"completed_tick": tick, "work_units": 1, "records": [{"target_id": target,
			"state": state, "transition": 1 if state == 2 else 3,
			"first_seen_tick": 1, "last_seen_tick": tick if last_seen < 0 else last_seen,
			"has_last_known_position": state != 0, "last_known_position": ZAIValues.encode_point(position),
			"geometry_revision": 1, "target_revision": 1}]}


class VisionDouble extends RefCounted:
	var targets: Dictionary = {}
	var observers: Dictionary = {}
	var projections: Dictionary = {}
	var calls: Array = []
	var fail_method: StringName = &""
	var segments: Array = []
	var geometry_revision: int = 0

	func set_occluder_segments(value: Array, revision: int) -> Dictionary:
		calls.append([&"set_occluder_segments", revision])
		if fail_method == &"set_occluder_segments" or revision <= geometry_revision:
			return {"ok": false, "code": 6}
		segments = value.duplicate(true)
		geometry_revision = revision
		return {"ok": true}

	func register_target(row: Dictionary) -> Dictionary:
		return _register(targets, row, &"register_target")

	func register_observer(row: Dictionary) -> Dictionary:
		return _register(observers, row, &"register_observer")

	func update_target(row: Dictionary, expected: int) -> Dictionary:
		return _update(targets, row, expected, &"update_target")

	func update_observer(row: Dictionary, expected: int) -> Dictionary:
		return _update(observers, row, expected, &"update_observer")

	func remove_target(id: int) -> Dictionary:
		calls.append([&"remove_target", id])
		if fail_method == &"remove_target" or not targets.has(id):
			return {"ok": false, "code": 2}
		targets.erase(id)
		return {"ok": true}

	func remove_observer(id: int) -> Dictionary:
		calls.append([&"remove_observer", id])
		if fail_method == &"remove_observer" or not observers.has(id):
			return {"ok": false, "code": 2}
		observers.erase(id)
		projections.erase(id)
		return {"ok": true}

	func get_projection(id: int) -> Dictionary:
		if fail_method == &"get_projection":
			return {"ok": false, "code": 10}
		return projections.get(id, {"ok": false, "code": 2}).duplicate(true)

	func _register(table: Dictionary, row: Dictionary, method: StringName) -> Dictionary:
		calls.append([method, row.id, row.revision])
		if fail_method == method or table.has(row.id) or row.revision != 1:
			return {"ok": false, "code": 3}
		table[row.id] = row.duplicate(true)
		return {"ok": true}

	func _update(table: Dictionary, row: Dictionary, expected: int, method: StringName) -> Dictionary:
		calls.append([method, row.id, expected, row.revision])
		if fail_method == method or not table.has(row.id) or table[row.id].revision != expected or row.revision != expected + 1:
			return {"ok": false, "code": 6}
		table[row.id] = row.duplicate(true)
		return {"ok": true}


class WorldDouble extends RaidAIWorldPort:
	var actors: Array = []
	var actions: Array = []
	var paths: Dictionary = {}
	var receipts: Dictionary = {}
	var noises: Array = []
	var reject_actions: bool = false
	var reverse_inputs: bool = false
	var live: bool = true

	func is_ready(generation: int) -> bool:
		return live and generation == 1

	func capture_vision_frame(_generation: int, _tick: int) -> Dictionary:
		var rows := actors.duplicate(true)
		if reverse_inputs:
			rows.reverse()
		return {"actors": rows, "geometry_revision": 1, "segments": []}

	func self_state(_generation: int, _tick: int, id: String) -> Dictionary:
		for row: Dictionary in actors:
			if row.entity_id == id:
				var value := ZAITestFixtures.own(id, row.position_raw)
				value.alive = row.alive
				return value
		return {}

	func patrol_points(id: String) -> Array:
		for row: Dictionary in actors:
			if row.entity_id == id:
				return [row.position_raw + Vector2i(1_000_000, 0)]
		return []

	func submit_path_request(request: Dictionary) -> bool:
		paths[request.actor_id] = {"request_id": request.request_id, "actor_id": request.actor_id,
			"generation": request.generation, "navigation_revision": request.navigation_revision,
			"resolved_tick": request.requested_tick + 1, "ok": true, "points": [request.destination_raw]}
		return true

	func poll_path_result(_generation: int, tick: int, id: String) -> Dictionary:
		if not paths.has(id) or paths[id].resolved_tick > tick:
			return {}
		var result: Dictionary = paths[id]
		paths.erase(id)
		return result

	func submit_action_request(request: Dictionary) -> Dictionary:
		actions.append(request.duplicate(true))
		if not reject_actions and request.kind in [&"fire", &"reload", &"melee"]:
			if not receipts.has(request.actor_id):
				receipts[request.actor_id] = []
			receipts[request.actor_id].append({"request_id": request.request_id, "generation": request.generation,
				"actor_id": request.actor_id, "resolved_tick": request.target_tick, "accepted": true})
		return {"admitted": not reject_actions}

	func take_action_results(_generation: int, tick: int, id: String) -> Array:
		var ready: Array = []
		var later: Array = []
		for value: Dictionary in receipts.get(id, []):
			if value.resolved_tick <= tick:
				ready.append(value)
			else:
				later.append(value)
		receipts[id] = later
		return ZAIValues.frozen(ready)

	func take_committed_noise(_generation: int, tick: int) -> Array:
		var ready: Array = []
		var later: Array = []
		for value: Dictionary in noises:
			if value.tick == tick:
				ready.append(value)
			else:
				later.append(value)
		noises = later
		return ready


class PhaseAuthorityDouble extends RefCounted:
	var last_error: StringName = &""
	var rows: Dictionary = {}
	var serial: int = 0
	var current_id: StringName = &""
	var current_phase: int = -1
	var current_tick: int = 0
	var fail_registration: StringName = &""
	var block_removal: bool = false
	var removal_order: Array = []

	func generation() -> int:
		return 1

	func has_phase_handler(id: StringName, gen: int) -> bool:
		return gen == 1 and (id in [&"raid_vision_world", &"player_movement"] or rows.has(id))

	func register_phase_handler(phase: int, id: StringName, callback: Callable, gen: int,
		priority: int, after: PackedStringArray) -> bool:
		if gen != 1 or id == fail_registration or rows.has(id):
			last_error = &"fixture_registration_rejected"
			return false
		for dependency in after:
			if not has_phase_handler(dependency, gen):
				last_error = &"fixture_dependency_missing"
				return false
		serial += 1
		rows[id] = {"phase": phase, "callback": callback, "registration": "r%d" % serial,
			"priority": priority, "after": after}
		return true

	func phase_handler_registration_id(id: StringName, _gen: int) -> String:
		return rows.get(id, {}).get("registration", "")

	func is_dispatching_phase_registration(id: StringName, registration: String, callback: Callable,
		phase: int, tick: int, gen: int) -> bool:
		return gen == 1 and current_id == id and current_phase == phase and current_tick == tick \
			and rows.has(id) and rows[id].registration == registration and rows[id].callback == callback

	func dispatch(id: StringName, tick: int) -> bool:
		current_id = id
		current_tick = tick
		current_phase = rows[id].phase
		var result: bool = rows[id].callback.call(self, current_phase, tick, [])
		current_id = &""
		current_phase = -1
		return result

	func unregister_phase_handler(id: StringName, gen: int) -> bool:
		if gen != 1 or block_removal:
			return false
		removal_order.append(id)
		rows.erase(id)
		return true
