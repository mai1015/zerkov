class_name RaidNoiseService
extends RefCounted
## Task 6.7: authority-owned hearing, independent of Vision and cosmetic audio.
## Feed committed events during tick T; resolve after world consequences using
## tick-T listener poses. AI consumes only the frozen facts on tick T + 1.
## The composition owns this service; never give it to UI or individual AI.

const PROPAGATION: StringName = &"radial_distance_v1"
const MAX_EVENTS_PER_TICK: int = 64
const MAX_LISTENERS: int = 64
const MAX_EVENT_HISTORY: int = 8192
## Retain this many resolved ticks plus the current pending tick, not a raid's
## lifetime event count. Smaller configured histories shorten the retry window.
const DEFAULT_RETRY_WINDOW_TICKS: int = 120
const MAX_TICK: int = 2_147_483_647
const MAX_INTENSITY: int = 1000
const ORIGIN_CELL_RAW: int = ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
const COORDINATE_LIMIT: int = ZWorldUnits.MAX_VISION_CANONICAL_RAW

var last_error: StringName = &""
var _configured: bool = false
var _released: bool = false
var _raid_key: String = ""
var _generation: int = 0
var _resolved_tick: int = 0
var _event_limit: int = MAX_EVENTS_PER_TICK
var _listener_limit: int = MAX_LISTENERS
var _history_limit: int = MAX_EVENT_HISTORY
var _pending: Dictionary = {}
var _fingerprints: Dictionary = {}
var _history_ticks: Dictionary = {}
var _retry_window_ticks: int = DEFAULT_RETRY_WINDOW_TICKS
var _observations: Dictionary = {}
var _last_pair_checks: int = 0


func configure(
	raid_key: String,
	generation: int,
	events_per_tick: int = MAX_EVENTS_PER_TICK,
	listeners: int = MAX_LISTENERS,
	history: int = MAX_EVENT_HISTORY,
	retry_window_ticks: int = -1
) -> bool:
	last_error = &""
	if _configured or _released:
		return _reject(&"noise_already_configured_or_released")
	if not ZIdentityRules.is_valid(raid_key, &"raid") or generation <= 0 \
			or events_per_tick < 1 or events_per_tick > MAX_EVENTS_PER_TICK \
			or listeners < 1 or listeners > MAX_LISTENERS \
			or history < events_per_tick or history > MAX_EVENT_HISTORY \
			or retry_window_ticks < -1 or retry_window_ticks > DEFAULT_RETRY_WINDOW_TICKS:
		return _reject(&"noise_configuration_invalid")
	@warning_ignore("integer_division")
	var capacity_window: int = history / events_per_tick - 1
	var window: int = mini(DEFAULT_RETRY_WINDOW_TICKS, capacity_window) \
		if retry_window_ticks == -1 else retry_window_ticks
	if window > capacity_window:
		return _reject(&"noise_retry_window_exceeds_history")
	_retry_window_ticks = window
	_raid_key = raid_key
	_generation = generation
	_event_limit = events_per_tick
	_listener_limit = listeners
	_history_limit = history
	_configured = true
	return true


## Canonical identities come from the existing ID types' canonical_key().
## Caller must have committed the gameplay action and captured its real pose.
## This is not an intent ingress, audio callback, or source of authentication.
func record_committed(
	generation: int,
	event_key: String,
	source_key: String,
	tick: int,
	position_raw: Vector2i,
	category: StringName,
	intensity_milli: int,
	propagation: StringName = PROPAGATION
) -> bool:
	last_error = &""
	if not _accept_generation(generation):
		return false
	var radius := radius_for_category(category)
	if not ZIdentityRules.is_valid(event_key, &"consequence") \
			or not ZIdentityRules.is_valid(source_key, &"entity") \
			or tick < 1 or tick >= MAX_TICK \
			or not _valid_position(position_raw) or radius == 0 \
			or intensity_milli < 1 or intensity_milli > MAX_INTENSITY \
			or propagation != PROPAGATION:
		return _reject(&"noise_event_invalid")
	# Expired retries never re-enter pending work even after their IDs are pruned.
	if tick < maxi(1, _resolved_tick - _retry_window_ticks + 1) or tick > _resolved_tick + 1:
		return _reject(&"noise_event_tick_invalid")
	# Only flat scalar data is retained; no live source object or caller-owned
	# dictionary can update a past noise. Identity is scoped by this raid owner.
	var fingerprint := JSON.stringify([
		source_key, tick, int(position_raw.x), int(position_raw.y),
		String(category), intensity_milli, String(propagation), radius,
	]).sha256_text()
	if _fingerprints.has(event_key):
		if _fingerprints[event_key] == fingerprint:
			return true  # Exact retry, including after publication: no re-emission.
		return _reject(&"noise_event_identity_conflict")
	if tick != _resolved_tick + 1:
		return _reject(&"noise_event_tick_invalid")
	if _pending.size() >= _event_limit:
		return _reject(&"noise_tick_capacity_exhausted")
	if _fingerprints.size() >= _history_limit:
		return _reject(&"noise_history_capacity_exhausted")
	_pending[event_key] = {
		"source_key": source_key, "tick": tick, "position_raw": position_raw,
		"category": category, "intensity_milli": intensity_milli,
		"propagation": propagation, "radius_raw": radius,
	}
	_fingerprints[event_key] = fingerprint
	if not _history_ticks.has(tick):
		_history_ticks[tick] = []
	_history_ticks[tick].append(event_key)
	return true


## Invoke once in TASKS_AND_AUDIT, after this tick's committed noise producers.
## Each listener is exactly {entity_id: String, position_raw: Vector2i,
## minimum_strength_milli: int}. Supply current authoritative poses, not Vision
## targets or last-known target transforms. Validation precedes all mutation.
func resolve_tick(generation: int, tick: int, listeners: Array) -> bool:
	last_error = &""
	if not _accept_generation(generation):
		return false
	if tick != _resolved_tick + 1 or tick >= MAX_TICK:
		return _reject(&"noise_resolve_tick_invalid")
	if listeners.size() > _listener_limit:
		return _reject(&"noise_listener_capacity_exhausted")
	var by_id: Dictionary = {}
	for candidate: Variant in listeners:
		if not _valid_listener(candidate):
			return _reject(&"noise_listener_invalid")
		var key: String = candidate["entity_id"]
		if by_id.has(key):
			return _reject(&"noise_listener_duplicate")
		by_id[key] = candidate
	var listener_keys := by_id.keys()
	var event_keys := _pending.keys()
	listener_keys.sort()
	event_keys.sort()
	var next_observations: Dictionary = {}
	var pair_checks: int = 0
	for listener_key: String in listener_keys:
		var listener: Dictionary = by_id[listener_key]
		var facts: Array[Dictionary] = []
		for event_key: String in event_keys:
			pair_checks += 1
			var event: Dictionary = _pending[event_key]
			if event["source_key"] == listener_key:
				continue  # An entity's own action is not a new hearing observation.
			var strength := _received_strength(event, listener["position_raw"])
			if strength < int(listener["minimum_strength_milli"]):
				continue
			facts.append(_audible_fact(event_key, event, strength))
		facts.make_read_only()
		next_observations[listener_key] = facts
	next_observations.make_read_only()
	_observations = next_observations
	_last_pair_checks = pair_checks
	_resolved_tick = tick
	_pending.clear()
	# Consecutive resolves expire at most one bounded bucket, including on quiet
	# ticks. Capacity is reserved for a full next tick at configuration time.
	var expired_tick: int = tick - _retry_window_ticks
	for event_key: String in _history_ticks.get(expired_tick, []):
		_fingerprints.erase(event_key)
	_history_ticks.erase(expired_tick)
	return true


## The caller distributes these values to the matching AI, never the service.
## A frame is valid only for the immediately following decision tick. Retained
## hearing memory (if desired) belongs to the AI state model, not a live query.
func observations_for(generation: int, listener_key: String, ai_tick: int) -> Array:
	last_error = &""
	if not _accept_generation(generation):
		return _empty_facts()
	if not ZIdentityRules.is_valid(listener_key, &"entity"):
		_reject(&"noise_listener_invalid")
		return _empty_facts()
	if ai_tick != _resolved_tick + 1 or ai_tick > MAX_TICK:
		_reject(&"noise_observation_tick_invalid")
		return _empty_facts()
	return _observations.get(listener_key, _empty_facts())


func release(generation: int) -> bool:
	last_error = &""
	if not _configured or generation != _generation:
		return _reject(&"noise_generation_invalid")
	_released = true
	_pending.clear()
	_fingerprints.clear()
	_history_ticks.clear()
	_observations = {}
	_last_pair_checks = 0
	return true


## Bounds and scheduling diagnostics only; never exposes hidden source data.
func diagnostics() -> Dictionary:
	var result := {
		"generation": _generation, "resolved_tick": _resolved_tick,
		"pending_events": _pending.size(), "history_events": _fingerprints.size(),
		"history_limit": _history_limit, "retry_window_ticks": _retry_window_ticks,
		"oldest_retry_tick": maxi(1, _resolved_tick - _retry_window_ticks + 1),
		"listeners": _observations.size(), "pair_checks": _last_pair_checks,
		"pair_budget": _event_limit * _listener_limit, "released": _released,
	}
	result.make_read_only()
	return result


## Initial policy values, not playtest-approved acoustics. Wall occlusion is
## deliberately not inferred from Vision or physics. Distances are world units.
static func radius_for_category(category: StringName) -> int:
	var world_units: int = 0
	match category:
		&"gunshot": world_units = 24
		&"impact": world_units = 8
		&"sprint": world_units = 6
		&"interaction": world_units = 3
	return world_units * ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT


static func _received_strength(event: Dictionary, listener: Vector2i) -> int:
	var origin: Vector2i = event["position_raw"]
	# Subtract in 64-bit scalar space, not Vector2i (which can overflow here).
	var dx: int = int(origin.x) - int(listener.x)
	var dy: int = int(origin.y) - int(listener.y)
	var radius: int = event["radius_raw"]
	if absi(dx) >= radius or absi(dy) >= radius:
		return 0
	var distance_squared: int = dx * dx + dy * dy
	var radius_squared: int = radius * radius
	if distance_squared >= radius_squared:
		return 0
	# Integer squared-distance falloff. At the largest radius (24 world units),
	# radius^2 * 1000 is 5.76e17, safely inside signed 64-bit arithmetic.
	@warning_ignore("integer_division")
	var strength: int = int(event["intensity_milli"]) \
			* (radius_squared - distance_squared) / radius_squared
	return strength


func _audible_fact(event_key: String, event: Dictionary, strength: int) -> Dictionary:
	var position: Vector2i = event["position_raw"]
	var region_min := Vector2i(_cell_origin(position.x), _cell_origin(position.y))
	# No source/entity identity, exact origin, target handle, or visibility grant
	# crosses this boundary. The region describes the past event, not a target.
	var fact := {
		"observation_id": JSON.stringify([
			_raid_key, _generation, event_key,
		]).sha256_text(),
		"raid_id": _raid_key, "generation": _generation,
		"valid_for_tick": int(event["tick"]) + 1,
		"observation_kind": &"audible", "visual_confirmation": false,
		"emitted_tick": int(event["tick"]), "resolved_tick": int(event["tick"]),
		"category": event["category"], "propagation": event["propagation"],
		"strength_milli": strength, "origin_min_raw": region_min,
		"origin_size_raw": Vector2i(ORIGIN_CELL_RAW, ORIGIN_CELL_RAW),
	}
	fact.make_read_only()
	return fact


static func _cell_origin(coordinate: int) -> int:
	@warning_ignore("integer_division")
	var cell: int = coordinate / ORIGIN_CELL_RAW
	if coordinate < 0 and coordinate % ORIGIN_CELL_RAW != 0:
		cell -= 1  # Integer division truncates toward zero; regions require floor.
	return cell * ORIGIN_CELL_RAW


static func _valid_position(position: Vector2i) -> bool:
	return absi(int(position.x)) <= COORDINATE_LIMIT \
			and absi(int(position.y)) <= COORDINATE_LIMIT


static func _valid_listener(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 3:
		return false
	if typeof(value.get("entity_id")) != TYPE_STRING \
			or typeof(value.get("position_raw")) != TYPE_VECTOR2I \
			or typeof(value.get("minimum_strength_milli")) != TYPE_INT:
		return false
	return ZIdentityRules.is_valid(value["entity_id"], &"entity") \
			and _valid_position(value["position_raw"]) \
			and int(value["minimum_strength_milli"]) >= 1 \
			and int(value["minimum_strength_milli"]) <= MAX_INTENSITY


func _accept_generation(generation: int) -> bool:
	if not _configured or _released or generation != _generation:
		return _reject(&"noise_generation_invalid")
	return true


static func _empty_facts() -> Array:
	var result: Array = []
	result.make_read_only()
	return result


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
