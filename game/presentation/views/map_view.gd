class_name MapView
extends ZReadOnlyView
## Read-only authored map, zone and marker projection.

enum ZoneState {
	AVAILABLE,
	SELECTED,
	LOCKED,
	FEATURE_GATED,
}

enum MarkerKind {
	PLAYER,
	EXTRACTION,
	TASK,
	LOOT,
	SQUAD,
	THREAT,
}

class Zone extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _zone_id: StringName = &"":
		set(value):
			if not _sealed:
				_zone_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _summary: String = "":
		set(value):
			if not _sealed:
				_summary = value
	var _risk_label: String = "":
		set(value):
			if not _sealed:
				_risk_label = value
	var _duration_ticks: int = 0:
		set(value):
			if not _sealed:
				_duration_ticks = value
	var _minimum_squad_size: int = 1:
		set(value):
			if not _sealed:
				_minimum_squad_size = value
	var _maximum_squad_size: int = 1:
		set(value):
			if not _sealed:
				_maximum_squad_size = value
	var _normalized_position: Vector2 = Vector2.ZERO:
		set(value):
			if not _sealed:
				_normalized_position = value
	var _state: ZoneState = ZoneState.LOCKED:
		set(value):
			if not _sealed:
				_state = value
	var _gate_reason: StringName = &"":
		set(value):
			if not _sealed:
				_gate_reason = value

	static func create(
		p_zone_id: StringName,
		p_display_name: String,
		p_summary: String,
		p_risk_label: String,
		p_duration_ticks: int,
		p_minimum_squad_size: int,
		p_maximum_squad_size: int,
		p_normalized_position: Vector2,
		p_state: ZoneState,
		p_gate_reason: StringName = &""
	) -> Zone:
		if not ZReadOnlyView.content_id_is_valid(p_zone_id) or p_display_name.is_empty() \
				or p_summary.is_empty() or p_risk_label.is_empty() or p_duration_ticks <= 0:
			return null
		if p_minimum_squad_size <= 0 or p_maximum_squad_size < p_minimum_squad_size:
			return null
		if not _normalized_is_valid(p_normalized_position):
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_state), ZoneState.size()):
			return null
		if (p_state == ZoneState.LOCKED or p_state == ZoneState.FEATURE_GATED) \
				and p_gate_reason.is_empty():
			return null
		var result := Zone.new()
		result._zone_id = p_zone_id
		result._display_name = p_display_name
		result._summary = p_summary
		result._risk_label = p_risk_label
		result._duration_ticks = p_duration_ticks
		result._minimum_squad_size = p_minimum_squad_size
		result._maximum_squad_size = p_maximum_squad_size
		result._normalized_position = p_normalized_position
		result._state = p_state
		result._gate_reason = p_gate_reason
		result._seal_record()
		return result

	static func _normalized_is_valid(value: Vector2) -> bool:
		return is_finite(value.x) and is_finite(value.y) \
			and value.x >= 0.0 and value.x <= 1.0 \
			and value.y >= 0.0 and value.y <= 1.0

	func zone_id() -> StringName:
		return _zone_id

	func display_name() -> String:
		return _display_name

	func summary() -> String:
		return _summary

	func risk_label() -> String:
		return _risk_label

	func duration_ticks() -> int:
		return _duration_ticks

	func minimum_squad_size() -> int:
		return _minimum_squad_size

	func maximum_squad_size() -> int:
		return _maximum_squad_size

	func normalized_position() -> Vector2:
		return _normalized_position

	func state() -> ZoneState:
		return _state

	func gate_reason() -> StringName:
		return _gate_reason

	func snapshot() -> Zone:
		return create(_zone_id, _display_name, _summary, _risk_label,
			_duration_ticks, _minimum_squad_size, _maximum_squad_size,
			_normalized_position, _state, _gate_reason)

class Marker extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _marker_id: StringName = &"":
		set(value):
			if not _sealed:
				_marker_id = value
	var _kind: MarkerKind = MarkerKind.PLAYER:
		set(value):
			if not _sealed:
				_kind = value
	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _label: String = "":
		set(value):
			if not _sealed:
				_label = value
	var _normalized_position: Vector2 = Vector2.ZERO:
		set(value):
			if not _sealed:
				_normalized_position = value
	var _visible: bool = true:
		set(value):
			if not _sealed:
				_visible = value
	var _available: bool = true:
		set(value):
			if not _sealed:
				_available = value
	var _reason: StringName = &"":
		set(value):
			if not _sealed:
				_reason = value

	static func create(
		p_marker_id: StringName,
		p_kind: MarkerKind,
		p_content_id: StringName,
		p_label: String,
		p_normalized_position: Vector2,
		p_visible: bool,
		p_available: bool,
		p_reason: StringName = &""
	) -> Marker:
		if p_marker_id.is_empty() or not ZReadOnlyView.content_id_is_valid(p_content_id) \
				or p_label.is_empty() or not Zone._normalized_is_valid(p_normalized_position):
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_kind), MarkerKind.size()):
			return null
		var result := Marker.new()
		result._marker_id = p_marker_id
		result._kind = p_kind
		result._content_id = p_content_id
		result._label = p_label
		result._normalized_position = p_normalized_position
		result._visible = p_visible
		result._available = p_available
		result._reason = p_reason
		result._seal_record()
		return result

	func marker_id() -> StringName:
		return _marker_id

	func kind() -> MarkerKind:
		return _kind

	func content_id() -> StringName:
		return _content_id

	func label() -> String:
		return _label

	func normalized_position() -> Vector2:
		return _normalized_position

	func is_visible() -> bool:
		return _visible

	func is_available() -> bool:
		return _available

	func reason() -> StringName:
		return _reason

	func snapshot() -> Marker:
		return create(_marker_id, _kind, _content_id, _label,
			_normalized_position, _visible, _available, _reason)

var _map_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_map_id = value
var _display_name: String = "":
	set(value):
		if not _sealed_view:
			_display_name = value
var _selected_zone_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_selected_zone_id = value
var _time_of_day: StringName = &"day":
	set(value):
		if not _sealed_view:
			_time_of_day = value
var _zoom_permille: int = 1000:
	set(value):
		if not _sealed_view:
			_zoom_permille = value
var _zones: Array[Zone] = []:
	set(value):
		if not _sealed_view:
			_zones = value
var _markers: Array[Marker] = []:
	set(value):
		if not _sealed_view:
			_markers = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_map_id: StringName,
	p_display_name: String,
	p_selected_zone_id: StringName,
	p_time_of_day: StringName,
	p_zoom_permille: int,
	p_zones: Array[Zone],
	p_markers: Array[Marker]
) -> MapView:
	if not content_id_is_valid(p_map_id) or p_display_name.is_empty() \
			or p_time_of_day.is_empty() or p_zoom_permille <= 0 or p_zones.is_empty():
		return null
	var zone_ids: Dictionary = {}
	for zone in p_zones:
		if zone == null or zone_ids.has(zone.zone_id()):
			return null
		zone_ids[zone.zone_id()] = true
	if not zone_ids.has(p_selected_zone_id):
		return null
	var marker_ids: Dictionary = {}
	for marker in p_markers:
		if marker == null or marker_ids.has(marker.marker_id()):
			return null
		marker_ids[marker.marker_id()] = true
	var result := MapView.new()
	result._map_id = p_map_id
	result._display_name = p_display_name
	result._selected_zone_id = p_selected_zone_id
	result._time_of_day = p_time_of_day
	result._zoom_permille = p_zoom_permille
	for zone in p_zones:
		result._zones.append(zone.snapshot())
	for marker in p_markers:
		result._markers.append(marker.snapshot())
	result._zones.make_read_only()
	result._markers.make_read_only()
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_map_id: StringName = &""
) -> MapView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) and not content_id_is_valid(p_map_id):
		return null
	var result := MapView.new()
	result._map_id = p_map_id
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


func map_id() -> StringName:
	return _map_id


func _ready_payload_is_valid() -> bool:
	if not content_id_is_valid(_map_id) or _display_name.is_empty() \
			or _time_of_day.is_empty() or _zoom_permille <= 0 or _zones.is_empty():
		return false
	var zone_ids: Dictionary = {}
	for zone in _zones:
		if zone == null or zone.snapshot() == null or zone_ids.has(zone.zone_id()):
			return false
		zone_ids[zone.zone_id()] = true
	if not zone_ids.has(_selected_zone_id):
		return false
	var marker_ids: Dictionary = {}
	for marker in _markers:
		if marker == null or marker.snapshot() == null or marker_ids.has(marker.marker_id()):
			return false
		marker_ids[marker.marker_id()] = true
	return true


func display_name() -> String:
	return _display_name


func selected_zone_id() -> StringName:
	return _selected_zone_id


func time_of_day() -> StringName:
	return _time_of_day


func zoom_permille() -> int:
	return _zoom_permille


func zones() -> Array[Zone]:
	var result: Array[Zone] = []
	for zone in _zones:
		result.append(zone.snapshot())
	result.make_read_only()
	return result


func markers() -> Array[Marker]:
	var result: Array[Marker] = []
	for marker in _markers:
		result.append(marker.snapshot())
	result.make_read_only()
	return result
