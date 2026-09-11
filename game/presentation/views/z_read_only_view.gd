class_name ZReadOnlyView
extends RefCounted
## Shared lifecycle metadata for immutable, screen-specific projections.
##
## View contracts expose values through typed accessors only. Collection
## accessors return detached, recursively read-only values, so presentation
## code cannot write back into a projection or an authoritative domain.

enum SyncState {
	UNBOUND,
	LOADING,
	READY,
	RESYNCHRONIZING,
	STALE,
	DISCONNECTED,
}

const SYNC_STATE_NAMES: PackedStringArray = [
	"unbound",
	"loading",
	"ready",
	"resynchronizing",
	"stale",
	"disconnected",
]

var _initialized: bool = false:
	set(value):
		if not _sealed_view:
			_initialized = value
var _sealed_view: bool = false:
	set(value):
		if not _sealed_view:
			_sealed_view = value
var _generation: int = 0:
	set(value):
		if not _sealed_view:
			_generation = value
var _revision: int = 0:
	set(value):
		if not _sealed_view:
			_revision = value
var _source_tick: int = 0:
	set(value):
		if not _sealed_view:
			_source_tick = value
var _sync_state: SyncState = SyncState.UNBOUND:
	set(value):
		if not _sealed_view:
			_sync_state = value
var _diagnostic: StringName = &"":
	set(value):
		if not _sealed_view:
			_diagnostic = value


func _set(property: StringName, value: Variant) -> bool:
	# Declared fields use their setters below; this closes accidental writes to
	# unknown underscore-prefixed storage after construction as well.
	if _sealed_view and String(property).begins_with("_"):
		return true
	return false


func _initialize_view(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_sync_state: SyncState,
	p_diagnostic: StringName = &""
) -> bool:
	if _initialized or _sealed_view or p_generation < 0 or p_revision < 0 or p_source_tick < 0:
		return false
	if int(p_sync_state) < 0 or int(p_sync_state) >= SYNC_STATE_NAMES.size():
		return false
	if p_sync_state == SyncState.READY and p_generation <= 0:
		return false
	if p_sync_state == SyncState.READY and not p_diagnostic.is_empty():
		return false
	if p_sync_state != SyncState.READY and p_diagnostic.is_empty():
		return false
	_generation = p_generation
	_revision = p_revision
	_source_tick = p_source_tick
	_sync_state = p_sync_state
	_diagnostic = p_diagnostic
	if p_sync_state == SyncState.READY and not _ready_payload_is_valid():
		_generation = 0
		_revision = 0
		_source_tick = 0
		_sync_state = SyncState.UNBOUND
		_diagnostic = &""
		return false
	_initialized = true
	_sealed_view = true
	return true


func _ready_payload_is_valid() -> bool:
	# A bare ZReadOnlyView is metadata only and can never masquerade as a ready
	# concrete projection. Every subtype must validate its populated payload.
	return false


func is_initialized() -> bool:
	return _initialized


func generation() -> int:
	return _generation


func revision() -> int:
	return _revision


func source_tick() -> int:
	return _source_tick


func sync_state() -> SyncState:
	return _sync_state


func sync_state_name() -> StringName:
	return StringName(SYNC_STATE_NAMES[int(_sync_state)])


func diagnostic() -> StringName:
	return _diagnostic


func is_ready() -> bool:
	return _initialized and _sync_state == SyncState.READY


func metadata() -> Dictionary:
	var result := {
		"diagnostic": _diagnostic,
		"generation": _generation,
		"revision": _revision,
		"source_tick": _source_tick,
		"sync_state": sync_state_name(),
	}
	make_deep_read_only(result)
	return result


static func content_id_is_valid(value: StringName) -> bool:
	var raw := String(value)
	if raw.is_empty() or raw.to_utf8_buffer().size() > 192:
		return false
	var segments := raw.split(".", true)
	if segments.size() < 3 or segments[0] != "zerkov":
		return false
	for segment in segments:
		if segment.is_empty() or segment.to_utf8_buffer().size() > 48:
			return false
		for index in segment.length():
			var code := segment.unicode_at(index)
			var is_lower := code >= 97 and code <= 122
			var is_digit := code >= 48 and code <= 57
			if not is_lower and not is_digit and code != 95 and code != 45:
				return false
	return true


static func enum_value_is_valid(value: int, count: int) -> bool:
	return value >= 0 and value < count


static func sync_state_requires_subject(value: SyncState) -> bool:
	return value == SyncState.RESYNCHRONIZING or value == SyncState.STALE \
		or value == SyncState.DISCONNECTED


static func make_deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for key in dictionary:
			make_deep_read_only(dictionary[key])
		dictionary.make_read_only()
	elif value is Array:
		var array := value as Array
		for child in array:
			make_deep_read_only(child)
		array.make_read_only()


static func read_only_string_names(values: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(values)
	result.make_read_only()
	return result
