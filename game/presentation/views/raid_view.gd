class_name RaidView
extends ZReadOnlyView
## Read-only raid/HUD projection. It contains no intent or mutation methods.

enum Lifecycle {
	PREPARING,
	ACTIVE,
	EXTRACTING,
	SETTLING,
	COMPLETED,
	FAILED,
	TORN_DOWN,
}

enum ExtractionStatus {
	LOCKED,
	AVAILABLE,
	IN_RANGE,
	COUNTING_DOWN,
	COMPLETED,
	CANCELLED,
}

enum WeaponStatus {
	HOLSTERED,
	READY,
	RELOADING,
	EMPTY,
	JAMMED,
}

enum FeedKind {
	LOOT,
	KILL,
	TASK,
	INJURY,
	EXTRACTION,
	SYSTEM,
}

class WeaponState extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _weapon_key: String = "":
		set(value):
			if not _sealed:
				_weapon_key = value
	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _status: WeaponStatus = WeaponStatus.HOLSTERED:
		set(value):
			if not _sealed:
				_status = value
	var _magazine_rounds: int = 0:
		set(value):
			if not _sealed:
				_magazine_rounds = value
	var _magazine_capacity: int = 0:
		set(value):
			if not _sealed:
				_magazine_capacity = value
	var _reserve_rounds: int = 0:
		set(value):
			if not _sealed:
				_reserve_rounds = value
	var _fire_mode: StringName = &"":
		set(value):
			if not _sealed:
				_fire_mode = value
	var _reload_progress_millis: int = 0:
		set(value):
			if not _sealed:
				_reload_progress_millis = value

	static func create(
		p_weapon_id: ZWeaponId,
		p_content_id: StringName,
		p_display_name: String,
		p_status: WeaponStatus,
		p_magazine_rounds: int,
		p_magazine_capacity: int,
		p_reserve_rounds: int,
		p_fire_mode: StringName,
		p_reload_progress_millis: int = 0
	) -> WeaponState:
		if p_weapon_id == null or not p_weapon_id.is_initialized():
			return null
		if not ZReadOnlyView.content_id_is_valid(p_content_id) or p_display_name.is_empty():
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_status), WeaponStatus.size()):
			return null
		if p_magazine_rounds < 0 or p_magazine_capacity < p_magazine_rounds \
				or p_reserve_rounds < 0 or p_reload_progress_millis < 0 \
				or p_reload_progress_millis > 1000:
			return null
		var result := WeaponState.new()
		result._weapon_key = p_weapon_id.canonical_key()
		result._content_id = p_content_id
		result._display_name = p_display_name
		result._status = p_status
		result._magazine_rounds = p_magazine_rounds
		result._magazine_capacity = p_magazine_capacity
		result._reserve_rounds = p_reserve_rounds
		result._fire_mode = p_fire_mode
		result._reload_progress_millis = p_reload_progress_millis
		result._seal_record()
		return result

	func weapon_id() -> ZWeaponId:
		return ZWeaponId.parse(_weapon_key)

	func content_id() -> StringName:
		return _content_id

	func display_name() -> String:
		return _display_name

	func status() -> WeaponStatus:
		return _status

	func magazine_rounds() -> int:
		return _magazine_rounds

	func magazine_capacity() -> int:
		return _magazine_capacity

	func reserve_rounds() -> int:
		return _reserve_rounds

	func fire_mode() -> StringName:
		return _fire_mode

	func reload_progress_millis() -> int:
		return _reload_progress_millis

	func snapshot() -> WeaponState:
		return create(weapon_id(), _content_id, _display_name, _status,
			_magazine_rounds, _magazine_capacity, _reserve_rounds,
			_fire_mode, _reload_progress_millis)

class Extraction extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _extract_id: StringName = &"":
		set(value):
			if not _sealed:
				_extract_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _status: ExtractionStatus = ExtractionStatus.LOCKED:
		set(value):
			if not _sealed:
				_status = value
	var _distance_millimeters: int = 0:
		set(value):
			if not _sealed:
				_distance_millimeters = value
	var _progress_ticks: int = 0:
		set(value):
			if not _sealed:
				_progress_ticks = value
	var _required_ticks: int = 0:
		set(value):
			if not _sealed:
				_required_ticks = value
	var _reason: StringName = &"":
		set(value):
			if not _sealed:
				_reason = value

	static func create(
		p_extract_id: StringName,
		p_display_name: String,
		p_status: ExtractionStatus,
		p_distance_millimeters: int,
		p_progress_ticks: int,
		p_required_ticks: int,
		p_reason: StringName = &""
	) -> Extraction:
		if not ZReadOnlyView.content_id_is_valid(p_extract_id) or p_display_name.is_empty():
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_status), ExtractionStatus.size()):
			return null
		if p_distance_millimeters < 0 or p_progress_ticks < 0 \
				or p_required_ticks < p_progress_ticks:
			return null
		if p_status == ExtractionStatus.LOCKED and p_reason.is_empty():
			return null
		var result := Extraction.new()
		result._extract_id = p_extract_id
		result._display_name = p_display_name
		result._status = p_status
		result._distance_millimeters = p_distance_millimeters
		result._progress_ticks = p_progress_ticks
		result._required_ticks = p_required_ticks
		result._reason = p_reason
		result._seal_record()
		return result

	func extract_id() -> StringName:
		return _extract_id

	func display_name() -> String:
		return _display_name

	func status() -> ExtractionStatus:
		return _status

	func distance_millimeters() -> int:
		return _distance_millimeters

	func progress_ticks() -> int:
		return _progress_ticks

	func required_ticks() -> int:
		return _required_ticks

	func reason() -> StringName:
		return _reason

	func snapshot() -> Extraction:
		return create(_extract_id, _display_name, _status, _distance_millimeters,
			_progress_ticks, _required_ticks, _reason)

class FeedEntry extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _event_key: String = "":
		set(value):
			if not _sealed:
				_event_key = value
	var _kind: FeedKind = FeedKind.SYSTEM:
		set(value):
			if not _sealed:
				_kind = value
	var _text: String = "":
		set(value):
			if not _sealed:
				_text = value
	var _tick: int = 0:
		set(value):
			if not _sealed:
				_tick = value

	static func create(
		p_event_id: ZConsequenceId,
		p_kind: FeedKind,
		p_text: String,
		p_tick: int
	) -> FeedEntry:
		if p_event_id == null or not p_event_id.is_initialized() \
				or p_text.is_empty() or p_tick < 0:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_kind), FeedKind.size()):
			return null
		var result := FeedEntry.new()
		result._event_key = p_event_id.canonical_key()
		result._kind = p_kind
		result._text = p_text
		result._tick = p_tick
		result._seal_record()
		return result

	func event_id() -> ZConsequenceId:
		return ZConsequenceId.parse(_event_key)

	func kind() -> FeedKind:
		return _kind

	func text() -> String:
		return _text

	func tick() -> int:
		return _tick

	func snapshot() -> FeedEntry:
		return create(event_id(), _kind, _text, _tick)

var _raid_key: String = "":
	set(value):
		if not _sealed_view:
			_raid_key = value
var _actor_key: String = "":
	set(value):
		if not _sealed_view:
			_actor_key = value
var _lifecycle: Lifecycle = Lifecycle.PREPARING:
	set(value):
		if not _sealed_view:
			_lifecycle = value
var _map_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_map_id = value
var _map_name: String = "":
	set(value):
		if not _sealed_view:
			_map_name = value
var _elapsed_ticks: int = 0:
	set(value):
		if not _sealed_view:
			_elapsed_ticks = value
var _limit_ticks: int = 0:
	set(value):
		if not _sealed_view:
			_limit_ticks = value
var _weapon: WeaponState:
	set(value):
		if not _sealed_view:
			_weapon = value
var _extractions: Array[Extraction] = []:
	set(value):
		if not _sealed_view:
			_extractions = value
var _feed: Array[FeedEntry] = []:
	set(value):
		if not _sealed_view:
			_feed = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_raid_id: ZRaidId,
	p_actor_id: ZEntityId,
	p_lifecycle: Lifecycle,
	p_map_id: StringName,
	p_map_name: String,
	p_elapsed_ticks: int,
	p_limit_ticks: int,
	p_weapon: WeaponState,
	p_extractions: Array[Extraction],
	p_feed: Array[FeedEntry]
) -> RaidView:
	if p_raid_id == null or not p_raid_id.is_initialized() \
			or p_actor_id == null or not p_actor_id.is_initialized():
		return null
	if not content_id_is_valid(p_map_id) or p_map_name.is_empty() \
			or p_elapsed_ticks < 0 or p_limit_ticks < p_elapsed_ticks:
		return null
	if not enum_value_is_valid(int(p_lifecycle), Lifecycle.size()):
		return null
	var extraction_ids: Dictionary = {}
	for extraction in p_extractions:
		if extraction == null or extraction_ids.has(extraction.extract_id()):
			return null
		extraction_ids[extraction.extract_id()] = true
	var feed_ids: Dictionary = {}
	for entry in p_feed:
		if entry == null or entry.tick() > p_source_tick \
				or feed_ids.has(entry.event_id().canonical_key()):
			return null
		feed_ids[entry.event_id().canonical_key()] = true
	var result := RaidView.new()
	result._raid_key = p_raid_id.canonical_key()
	result._actor_key = p_actor_id.canonical_key()
	result._lifecycle = p_lifecycle
	result._map_id = p_map_id
	result._map_name = p_map_name
	result._elapsed_ticks = p_elapsed_ticks
	result._limit_ticks = p_limit_ticks
	result._weapon = p_weapon.snapshot() if p_weapon != null else null
	for extraction in p_extractions:
		result._extractions.append(extraction.snapshot())
	for entry in p_feed:
		result._feed.append(entry.snapshot())
	result._extractions.make_read_only()
	result._feed.make_read_only()
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_raid_id: ZRaidId = null,
	p_actor_id: ZEntityId = null
) -> RaidView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) and (p_raid_id == null \
			or not p_raid_id.is_initialized() or p_actor_id == null \
			or not p_actor_id.is_initialized()):
		return null
	var result := RaidView.new()
	result._raid_key = p_raid_id.canonical_key() if p_raid_id != null else ""
	result._actor_key = p_actor_id.canonical_key() if p_actor_id != null else ""
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


func _ready_payload_is_valid() -> bool:
	if raid_id() == null or actor_id() == null or not content_id_is_valid(_map_id) \
			or _map_name.is_empty() or _elapsed_ticks < 0 or _limit_ticks < _elapsed_ticks \
			or not enum_value_is_valid(int(_lifecycle), Lifecycle.size()):
		return false
	if _weapon != null and _weapon.snapshot() == null:
		return false
	var extraction_ids: Dictionary = {}
	for extraction in _extractions:
		if extraction == null or extraction.snapshot() == null \
				or extraction_ids.has(extraction.extract_id()):
			return false
		extraction_ids[extraction.extract_id()] = true
	var feed_ids: Dictionary = {}
	for entry in _feed:
		if entry == null or entry.snapshot() == null or entry.tick() > source_tick() \
				or feed_ids.has(entry.event_id().canonical_key()):
			return false
		feed_ids[entry.event_id().canonical_key()] = true
	return true


func raid_id() -> ZRaidId:
	return ZRaidId.parse(_raid_key) if not _raid_key.is_empty() else null


func actor_id() -> ZEntityId:
	return ZEntityId.parse(_actor_key) if not _actor_key.is_empty() else null


func lifecycle() -> Lifecycle:
	return _lifecycle


func map_id() -> StringName:
	return _map_id


func map_name() -> String:
	return _map_name


func elapsed_ticks() -> int:
	return _elapsed_ticks


func limit_ticks() -> int:
	return _limit_ticks


func remaining_ticks() -> int:
	return maxi(_limit_ticks - _elapsed_ticks, 0)


func weapon() -> WeaponState:
	return _weapon.snapshot() if _weapon != null else null


func extractions() -> Array[Extraction]:
	var result: Array[Extraction] = []
	for extraction in _extractions:
		result.append(extraction.snapshot())
	result.make_read_only()
	return result


func feed() -> Array[FeedEntry]:
	var result: Array[FeedEntry] = []
	for entry in _feed:
		result.append(entry.snapshot())
	result.make_read_only()
	return result
