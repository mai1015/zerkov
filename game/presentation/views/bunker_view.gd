class_name BunkerView
extends ZReadOnlyView
## Read-only bunker/profile shell projection. Unimplemented meta actions remain gated.

enum StationState {
	AVAILABLE,
	UPGRADABLE,
	LOCKED,
	FEATURE_GATED,
}

class Station extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _station_id: StringName = &"":
		set(value):
			if not _sealed:
				_station_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _level: int = 0:
		set(value):
			if not _sealed:
				_level = value
	var _maximum_level: int = 0:
		set(value):
			if not _sealed:
				_maximum_level = value
	var _state: StationState = StationState.LOCKED:
		set(value):
			if not _sealed:
				_state = value
	var _summary: String = "":
		set(value):
			if not _sealed:
				_summary = value
	var _action_id: StringName = &"":
		set(value):
			if not _sealed:
				_action_id = value
	var _gate_reason: StringName = &"":
		set(value):
			if not _sealed:
				_gate_reason = value

	static func create(
		p_station_id: StringName,
		p_display_name: String,
		p_level: int,
		p_maximum_level: int,
		p_state: StationState,
		p_summary: String,
		p_action_id: StringName,
		p_gate_reason: StringName = &""
	) -> Station:
		if not ZReadOnlyView.content_id_is_valid(p_station_id) or p_display_name.is_empty() \
				or p_level < 0 or p_maximum_level < p_level or p_maximum_level <= 0 \
				or p_summary.is_empty():
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_state), StationState.size()):
			return null
		if (p_state == StationState.LOCKED or p_state == StationState.FEATURE_GATED) \
				and p_gate_reason.is_empty():
			return null
		var result := Station.new()
		result._station_id = p_station_id
		result._display_name = p_display_name
		result._level = p_level
		result._maximum_level = p_maximum_level
		result._state = p_state
		result._summary = p_summary
		result._action_id = p_action_id
		result._gate_reason = p_gate_reason
		result._seal_record()
		return result

	func station_id() -> StringName:
		return _station_id

	func display_name() -> String:
		return _display_name

	func level() -> int:
		return _level

	func maximum_level() -> int:
		return _maximum_level

	func state() -> StationState:
		return _state

	func summary() -> String:
		return _summary

	func action_id() -> StringName:
		return _action_id

	func gate_reason() -> StringName:
		return _gate_reason

	func snapshot() -> Station:
		return create(_station_id, _display_name, _level, _maximum_level,
			_state, _summary, _action_id, _gate_reason)

var _profile_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_profile_id = value
var _profile_name: String = "":
	set(value):
		if not _sealed_view:
			_profile_name = value
var _character_level: int = 0:
	set(value):
		if not _sealed_view:
			_character_level = value
var _bunker_level: int = 0:
	set(value):
		if not _sealed_view:
			_bunker_level = value
var _currency: int = 0:
	set(value):
		if not _sealed_view:
			_currency = value
var _stash_used: int = 0:
	set(value):
		if not _sealed_view:
			_stash_used = value
var _stash_capacity: int = 0:
	set(value):
		if not _sealed_view:
			_stash_capacity = value
var _deployment_ready: bool = false:
	set(value):
		if not _sealed_view:
			_deployment_ready = value
var _deployment_reason: StringName = &"":
	set(value):
		if not _sealed_view:
			_deployment_reason = value
var _selected_station_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_selected_station_id = value
var _stations: Array[Station] = []:
	set(value):
		if not _sealed_view:
			_stations = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_profile_name: String,
	p_character_level: int,
	p_bunker_level: int,
	p_currency: int,
	p_stash_used: int,
	p_stash_capacity: int,
	p_deployment_ready: bool,
	p_deployment_reason: StringName,
	p_selected_station_id: StringName,
	p_stations: Array[Station],
	p_profile_id: StringName = &"zerkov.profile.local"
) -> BunkerView:
	if not content_id_is_valid(p_profile_id) or p_profile_name.is_empty() \
			or p_character_level <= 0 or p_bunker_level <= 0 \
			or p_currency < 0 or p_stash_used < 0 or p_stash_capacity < p_stash_used:
		return null
	if not p_deployment_ready and p_deployment_reason.is_empty():
		return null
	var station_ids: Dictionary = {}
	for station in p_stations:
		if station == null or station_ids.has(station.station_id()):
			return null
		station_ids[station.station_id()] = true
	if not p_selected_station_id.is_empty() and not station_ids.has(p_selected_station_id):
		return null
	var result := BunkerView.new()
	result._profile_id = p_profile_id
	result._profile_name = p_profile_name
	result._character_level = p_character_level
	result._bunker_level = p_bunker_level
	result._currency = p_currency
	result._stash_used = p_stash_used
	result._stash_capacity = p_stash_capacity
	result._deployment_ready = p_deployment_ready
	result._deployment_reason = p_deployment_reason
	result._selected_station_id = p_selected_station_id
	for station in p_stations:
		result._stations.append(station.snapshot())
	result._stations.make_read_only()
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_profile_id: StringName = &""
) -> BunkerView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) and not content_id_is_valid(p_profile_id):
		return null
	var result := BunkerView.new()
	result._profile_id = p_profile_id
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


func profile_name() -> String:
	return _profile_name


func profile_id() -> StringName:
	return _profile_id


func _ready_payload_is_valid() -> bool:
	if not content_id_is_valid(_profile_id) or _profile_name.is_empty() \
			or _character_level <= 0 or _bunker_level <= 0 or _currency < 0 \
			or _stash_used < 0 or _stash_capacity < _stash_used \
			or (not _deployment_ready and _deployment_reason.is_empty()):
		return false
	var ids: Dictionary = {}
	for station in _stations:
		if station == null or station.snapshot() == null or ids.has(station.station_id()):
			return false
		ids[station.station_id()] = true
	return _selected_station_id.is_empty() or ids.has(_selected_station_id)


func character_level() -> int:
	return _character_level


func bunker_level() -> int:
	return _bunker_level


func currency() -> int:
	return _currency


func stash_used() -> int:
	return _stash_used


func stash_capacity() -> int:
	return _stash_capacity


func is_deployment_ready() -> bool:
	return _deployment_ready


func deployment_reason() -> StringName:
	return _deployment_reason


func selected_station_id() -> StringName:
	return _selected_station_id


func stations() -> Array[Station]:
	var result: Array[Station] = []
	for station in _stations:
		result.append(station.snapshot())
	result.make_read_only()
	return result
