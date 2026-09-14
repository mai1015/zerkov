class_name ZAIAgent
extends RefCounted
## Tasks 6.4-6.6: a small deterministic Scav/mutant state machine.
## Inputs are own-actor facts, permitted knowledge and explicit port receipts.
## No Node, world, target object, native authority, wall clock or global RNG.

enum State { IDLE, PATROL, INVESTIGATE, ENGAGE, SEARCH, RETREAT, DEAD }
const STATE_NAMES: Array[String] = ["idle", "patrol", "investigate", "engage", "search", "retreat", "dead"]
const SELF_KEYS: Array = ["entity_id", "position_raw", "alive", "health_milli", "ammo", "reloading", "can_move", "under_fire", "navigation_revision"]
const MAX_POINTS: int = 64

var last_error: StringName = &""
var _generation: int = 0
var _id: String = ""
var _profile: ZAIProfile
var _state: State = State.IDLE
var _since: int = 0
var _tick: int = 0
var _released: bool = false
var _patrol: Array = []
var _cover: Array = []
var _patrol_index: int = 0
var _search_offset: int = 0
var _target: String = ""
var _last_known: Vector2i = Vector2i.ZERO
var _has_last_known: bool = false
var _reaction_due: int = 0
var _attack_due: int = 0
var _heard_id: String = ""
var _heard_at: int = 0
var _goal: Vector2i = Vector2i.ZERO
var _has_goal: bool = false
var _goal_reason: StringName = &""
var _path: Array = []
var _path_index: int = 0
var _navigation_revision: int = 0
var _path_request: Dictionary = {}
var _path_serial: int = 0
var _retry_at: int = 0
var _action_serial: int = 0
var _pending_actions: Dictionary = {}
var _last_rejection: StringName = &""


func configure(generation: int, entity_id: String, profile: ZAIProfile,
	seed: int, patrol_points: Array = [], cover_points: Array = []) -> bool:
	if _generation != 0 or generation < 1 or not ZAIValues.entity(entity_id) \
		or profile == null or not profile.is_valid() or not _points(patrol_points) or not _points(cover_points):
		return _reject(&"ai_configuration_invalid")
	_generation = generation
	_id = entity_id
	_profile = profile.duplicate(true) as ZAIProfile
	_patrol = patrol_points.duplicate()
	_cover = cover_points.duplicate()
	_cover.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	_search_offset = ("%s:%d" % [entity_id, seed]).sha256_text().substr(0, 8).hex_to_int() % 4
	return true


func step(generation: int, tick: int, own: Dictionary, knowledge: Dictionary,
	hearing: Array = [], path_result: Dictionary = {}, action_results: Array = []) -> Dictionary:
	last_error = &""
	if _released or generation != _generation or _generation == 0 or tick <= _tick \
		or tick >= ZAIValues.MAX_TICK or not valid_self(own) or own.entity_id != _id \
		or not _valid_knowledge(knowledge, tick) or hearing.size() > 64 or action_results.size() > 8:
		return _error(&"ai_input_invalid")
	for fact: Variant in hearing:
		if not _valid_hearing(fact, tick):
			return _error(&"ai_hearing_invalid")
	if not _valid_path_result(path_result, tick) or not _valid_action_results(action_results, tick):
		return _error(&"ai_receipt_invalid")
	_tick = tick
	var actions: Array = []
	if _state == State.DEAD or not own.alive:
		_enter(State.DEAD, tick)
		_clear_navigation()
		_pending_actions.clear()
		return _result(actions, {})
	_accept_results(path_result, action_results, tick)
	if _navigation_revision != own.navigation_revision:
		_navigation_revision = own.navigation_revision
		_path.clear()
		_path_request = {}
	if not _path_request.is_empty() and tick > int(_path_request.deadline_tick):
		_path_request = {}
		_retry_at = tick + _profile.retry_ticks
		_last_rejection = &"path_timeout"
	var expired: Array = []
	for id: String in _pending_actions:
		if tick > int(_pending_actions[id].deadline_tick):
			expired.append(id)
	for id: String in expired:
		_pending_actions.erase(id)
		_attack_due = maxi(_attack_due, tick + _profile.retry_ticks)
		_last_rejection = &"action_receipt_timeout"
	var visible := _choose_target(knowledge.facts, own.position_raw, &"visible")
	var remembered := _choose_target(knowledge.facts, own.position_raw, &"remembered")
	var heard := _choose_hearing(hearing)
	if not heard.is_empty() and String(heard.observation_id) != _heard_id:
		_heard_id = heard.observation_id
		_heard_at = heard.emitted_tick
		if visible.is_empty() and _state not in [State.ENGAGE, State.RETREAT]:
			var low: Vector2i = heard.origin_min_raw
			var size: Vector2i = heard.origin_size_raw
			_last_known = _bounded_offset(low, Vector2i(int(size.x) / 2, int(size.y) / 2))
			_has_last_known = true
			_target = ""  # Hearing never supplies an entity or a firing solution.
			_enter(State.INVESTIGATE, tick)
	if not visible.is_empty():
		if _target != visible.entity_id or _state != State.ENGAGE:
			_reaction_due = tick + _profile.reaction_ticks
		_target = visible.entity_id
		_last_known = visible.position_raw
		_has_last_known = true
		if _state != State.RETREAT:
			_enter(State.ENGAGE, tick)
	elif _state == State.ENGAGE:
		if not remembered.is_empty():
			_last_known = remembered.position_raw
			_has_last_known = true
		_target = ""
		_reaction_due = 0
		_enter(State.SEARCH, tick)
	if visible.is_empty() and not remembered.is_empty() and _state in [State.IDLE, State.PATROL]:
		_last_known = remembered.position_raw
		_has_last_known = true
		_enter(State.SEARCH, tick)
	if _profile.retreat_health_milli > 0 and own.health_milli <= _profile.retreat_health_milli \
		and _has_last_known and _state != State.RETREAT:
		_enter(State.RETREAT, tick)
	if _state == State.IDLE and not _patrol.is_empty():
		_enter(State.PATROL, tick)
	match _state:
		State.PATROL:
			if not _patrol.is_empty():
				var destination: Vector2i = _patrol[_patrol_index]
				if ZAIValues.within(own.position_raw, destination, _profile.arrival_radius_raw):
					_patrol_index = (_patrol_index + 1) % _patrol.size()
				_set_goal(_patrol[_patrol_index], &"patrol")
		State.INVESTIGATE:
			if tick - _since >= _profile.investigate_ticks:
				_enter(State.SEARCH, tick)
			elif _has_last_known:
				_set_goal(_last_known, &"investigate_noise")
		State.SEARCH:
			if tick - _since >= _profile.search_ticks:
				_has_last_known = false
				_enter(State.PATROL if not _patrol.is_empty() else State.IDLE, tick)
			elif _has_last_known:
				var offset := Vector2i.ZERO
				if ZAIValues.within(own.position_raw, _last_known, _profile.arrival_radius_raw) or _goal_reason == &"search_area":
					var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
					@warning_ignore("integer_division")
					var leg: int = (tick - _since) / maxi(1, _profile.search_ticks / 4)
					offset = directions[(_search_offset + leg) % 4] * _profile.search_radius_raw
				_set_goal(_bounded_offset(_last_known, offset), &"search_area" if offset != Vector2i.ZERO else &"search_last_known")
		State.RETREAT:
			if tick - _since >= _profile.retreat_ticks:
				_enter(State.SEARCH, tick)
			else:
				var cover: Variant = _choose_cover(own.position_raw, _last_known, true)
				_set_goal(cover if cover != null else own.position_raw, &"retreat")
		State.ENGAGE:
			if not visible.is_empty():
				var aim := ZAIValues.direction(own.position_raw, visible.position_raw)
				if aim != Vector2i.ZERO:
					_emit(actions, &"aim", {"direction_milli": aim})
				var in_range := ZAIValues.within(own.position_raw, visible.position_raw, _profile.attack_range_raw)
				if not in_range:
					_set_goal(visible.position_raw, &"chase_visible")
				elif own.under_fire and _profile.archetype == "scav":
					var cover: Variant = _choose_cover(own.position_raw, visible.position_raw, false)
					if cover != null:
						_set_goal(cover, &"seek_cover")
					else:
						_clear_navigation()
				else:
					_clear_navigation()
				if in_range and tick >= _reaction_due and tick >= _attack_due and _pending_actions.is_empty():
					if _profile.archetype == "scav" and not own.reloading:
						_emit(actions, &"fire" if own.ammo > 0 else &"reload", {})
						_attack_due = tick + _profile.attack_request_interval_ticks
					elif _profile.archetype == "mutant":
						_emit(actions, &"melee", {})
						_attack_due = tick + _profile.attack_request_interval_ticks
	var request := _navigate(own, actions)
	return _result(actions, request)


func _navigate(own: Dictionary, actions: Array) -> Dictionary:
	var request: Dictionary = {}
	var direction := Vector2i.ZERO
	if not own.can_move or not _has_goal or ZAIValues.within(own.position_raw, _goal, _profile.arrival_radius_raw):
		_emit(actions, &"move", {"direction_milli": direction})
		return request
	while _path_index < _path.size() and ZAIValues.within(own.position_raw, _path[_path_index], _profile.arrival_radius_raw):
		_path_index += 1
	if _path_index < _path.size():
		direction = ZAIValues.direction(own.position_raw, _path[_path_index])
	elif _path_request.is_empty() and _tick >= _retry_at:
		_path_serial += 1
		_path_request = {"request_id": "%s.g%d.path%d" % [_id, _generation, _path_serial],
			"generation": _generation, "actor_id": _id, "requested_tick": _tick,
			"deadline_tick": _tick + _profile.path_timeout_ticks, "navigation_revision": _navigation_revision,
			"origin_raw": own.position_raw, "destination_raw": _goal, "reason": _goal_reason}
		request = _path_request
	_emit(actions, &"move", {"direction_milli": direction})
	return request


func _emit(actions: Array, kind: StringName, payload: Dictionary) -> void:
	_action_serial += 1
	var id := "%s.g%d.action%d" % [_id, _generation, _action_serial]
	actions.append({"request_id": id, "generation": _generation, "actor_id": _id,
		"decision_tick": _tick, "target_tick": _tick + 1, "kind": kind, "payload": payload})
	if kind in [&"fire", &"reload", &"melee"]:
		_pending_actions[id] = {"target_tick": _tick + 1, "deadline_tick": _tick + _profile.path_timeout_ticks}


func _accept_results(path_result: Dictionary, actions: Array, tick: int) -> void:
	if not path_result.is_empty() and not _path_request.is_empty() \
		and path_result.request_id == _path_request.request_id \
		and path_result.navigation_revision == _navigation_revision \
		and tick <= int(_path_request.deadline_tick) \
		and int(path_result.resolved_tick) >= int(_path_request.requested_tick):
		if path_result.ok and not path_result.points.is_empty() \
			and ZAIValues.within(path_result.points[-1], _path_request.destination_raw, _profile.arrival_radius_raw):
			_path = path_result.points.duplicate()
			_path_index = 0
		else:
			_path.clear()
			_retry_at = tick + _profile.retry_ticks
			_last_rejection = &"path_failed"
		_path_request = {}
	for receipt: Dictionary in actions:
		if not _pending_actions.has(receipt.request_id):
			continue  # Stale, already resolved, or another actor's correlation.
		if receipt.accepted and int(receipt.resolved_tick) < int(_pending_actions[receipt.request_id].target_tick):
			continue  # An early enqueue acknowledgement is not a committed action.
		_pending_actions.erase(receipt.request_id)
		if not receipt.accepted:
			_attack_due = maxi(_attack_due, tick + _profile.retry_ticks)
			_last_rejection = &"action_rejected"


func _enter(next: State, tick: int) -> void:
	if next == _state:
		return
	_state = next
	_since = tick
	_clear_navigation()


func _set_goal(point: Vector2i, reason: StringName) -> void:
	if _has_goal and reason == _goal_reason and (point == _goal \
		or (reason == &"chase_visible" and ZAIValues.within(point, _goal, ZAIValues.UNIT))):
		return
	_goal = point
	_goal_reason = reason
	_has_goal = true
	_path.clear()
	_path_index = 0
	_path_request = {}


func _clear_navigation() -> void:
	_has_goal = false
	_path.clear()
	_path_index = 0
	_path_request = {}
	_goal_reason = &""


func _choose_target(facts: Array, origin: Vector2i, kind: StringName) -> Dictionary:
	var result: Dictionary = {}
	for fact: Dictionary in facts:
		if fact.kind != kind:
			continue
		if result.is_empty() or ZAIValues.distance_key(origin, fact.position_raw) < ZAIValues.distance_key(origin, result.position_raw) \
			or (ZAIValues.distance_key(origin, fact.position_raw) == ZAIValues.distance_key(origin, result.position_raw) and fact.entity_id < result.entity_id):
			result = fact
	return result


func _choose_hearing(facts: Array) -> Dictionary:
	var result: Dictionary = {}
	for fact: Dictionary in facts:
		if fact.strength_milli < _profile.hearing_threshold_milli or _tick - int(fact.emitted_tick) > _profile.investigate_ticks:
			continue
		if result.is_empty() or fact.emitted_tick > result.emitted_tick \
			or (fact.emitted_tick == result.emitted_tick and fact.strength_milli > result.strength_milli) \
			or (fact.emitted_tick == result.emitted_tick and fact.strength_milli == result.strength_milli and fact.observation_id < result.observation_id):
			result = fact
	return result


func _choose_cover(origin: Vector2i, threat: Vector2i, retreat: bool) -> Variant:
	var selected: Variant = null
	for point: Vector2i in _cover:
		if retreat and ZAIValues.distance_key(point, threat) <= ZAIValues.distance_key(origin, threat):
			continue
		if selected == null or ZAIValues.distance_key(origin, point) < ZAIValues.distance_key(origin, selected):
			selected = point
	# These are authored candidates, not a claim of actual protection. Navigation
	# and combat must still validate geometry; no unseen target is inspected.
	return selected


static func _bounded_offset(origin: Vector2i, offset: Vector2i) -> Vector2i:
	return Vector2i(clampi(int(origin.x) + int(offset.x), -ZAIValues.LIMIT, ZAIValues.LIMIT),
		clampi(int(origin.y) + int(offset.y), -ZAIValues.LIMIT, ZAIValues.LIMIT))


func debug_snapshot() -> Dictionary:
	return ZAIValues.frozen({"entity_id": _id, "state": STATE_NAMES[_state], "since_tick": _since,
		"tick": _tick, "target_id": _target, "has_last_known": _has_last_known,
		"last_known_raw": _last_known if _has_last_known else Vector2i.ZERO,
		"has_goal": _has_goal, "goal_raw": _goal if _has_goal else Vector2i.ZERO,
		"path": _path, "reaction_due_tick": _reaction_due, "last_rejection": _last_rejection})


func release(generation: int) -> bool:
	if generation != _generation:
		return _reject(&"ai_generation_invalid")
	_released = true
	_clear_navigation()
	_pending_actions.clear()
	return true


func _result(actions: Array, request: Dictionary) -> Dictionary:
	return ZAIValues.frozen({"ok": true, "actor_id": _id, "tick": _tick,
		"state": STATE_NAMES[_state], "actions": actions, "path_request": request})


static func valid_self(value: Dictionary) -> bool:
	return ZAIValues.keys(value, SELF_KEYS) and ZAIValues.entity(value.entity_id) \
		and ZAIValues.position(value.position_raw) and typeof(value.alive) == TYPE_BOOL \
		and ZAIValues.integer(value.health_milli, 0, 1000) and ZAIValues.integer(value.ammo, 0, 10000) \
		and typeof(value.reloading) == TYPE_BOOL and typeof(value.can_move) == TYPE_BOOL \
		and typeof(value.under_fire) == TYPE_BOOL and ZAIValues.integer(value.navigation_revision, 1, ZAIValues.MAX_TICK)


func _valid_knowledge(value: Dictionary, tick: int) -> bool:
	if value.get("ok") != true or value.get("generation") != _generation \
		or value.get("recipient") != _id or value.get("tick") != tick \
		or not value.get("facts") is Array or value.facts.size() > 128:
		return false
	for fact: Variant in value.facts:
		if not fact is Dictionary or not ZAIValues.keys(fact, ["entity_id", "kind", "position_raw", "last_seen_tick", "confidence_milli", "target_revision"]) \
			or not ZAIValues.entity(fact.entity_id) or fact.entity_id == _id \
			or fact.kind not in [&"visible", &"remembered"] or not ZAIValues.position(fact.position_raw) \
			or not ZAIValues.integer(fact.last_seen_tick, 1, tick) \
			or not ZAIValues.integer(fact.confidence_milli, 0, 1000) \
			or not ZAIValues.integer(fact.target_revision, 1, ZAIValues.MAX_TICK):
			return false
	return true


func _valid_hearing(value: Variant, tick: int) -> bool:
	return value is Dictionary and value.get("generation") == _generation \
		and value.get("observation_kind") == &"audible" and value.get("visual_confirmation") == false \
		and typeof(value.get("observation_id")) == TYPE_STRING and value.observation_id.length() == 64 \
		and ZAIValues.integer(value.get("emitted_tick"), 1, tick - 1) \
		and ZAIValues.integer(value.get("valid_for_tick"), int(value.emitted_tick) + 1, tick) \
		and ZAIValues.integer(value.get("strength_milli"), 1, 1000) \
		and ZAIValues.position(value.get("origin_min_raw")) \
		and value.get("origin_size_raw") == Vector2i(ZAIValues.UNIT, ZAIValues.UNIT)


func _valid_path_result(value: Dictionary, tick: int) -> bool:
	if value.is_empty():
		return true
	return ZAIValues.keys(value, ["request_id", "generation", "actor_id", "resolved_tick", "navigation_revision", "ok", "points"]) \
		and typeof(value.request_id) == TYPE_STRING and value.generation == _generation and value.actor_id == _id \
		and ZAIValues.integer(value.resolved_tick, 1, tick) and ZAIValues.integer(value.navigation_revision, 1, ZAIValues.MAX_TICK) \
		and typeof(value.ok) == TYPE_BOOL and value.points is Array and _points(value.points)


func _valid_action_results(values: Array, tick: int) -> bool:
	for value: Variant in values:
		if not value is Dictionary or not ZAIValues.keys(value, ["request_id", "generation", "actor_id", "resolved_tick", "accepted"]) \
			or typeof(value.request_id) != TYPE_STRING or value.generation != _generation or value.actor_id != _id \
			or not ZAIValues.integer(value.resolved_tick, 1, tick) or typeof(value.accepted) != TYPE_BOOL:
			return false
	return true


static func _points(values: Array) -> bool:
	if values.size() > MAX_POINTS:
		return false
	for point: Variant in values:
		if not ZAIValues.position(point):
			return false
	return true


func _error(reason: StringName) -> Dictionary:
	_reject(reason)
	return {"ok": false, "reason": reason}


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
