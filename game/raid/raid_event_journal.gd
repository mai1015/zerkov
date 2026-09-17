class_name RaidEventJournal
extends RefCounted
## Append-only bounded journal. Full or malformed input fails closed.

const DEFAULT_MAX_EVENTS: int = 8192

var last_error: StringName = &""
var _raid_id: ZRaidId
var _max_events: int = DEFAULT_MAX_EVENTS
var _next_sequence: int = 1
var _last_tick: int = 0
var _events: Array[ZRaidEvent] = []
var _seen_event_ids: Dictionary = {}
var _sealed: bool = false


func configure(raid_id: ZRaidId, max_events: int = DEFAULT_MAX_EVENTS) -> bool:
	if (
		_sealed
		or _raid_id != null
		or raid_id == null
		or ZRaidId.parse(raid_id.canonical_key()) == null
		or max_events <= 0
		or max_events > DEFAULT_MAX_EVENTS
	):
		last_error = &"journal_configuration_invalid"
		return false
	_raid_id = ZRaidId.parse(raid_id.canonical_key())
	_max_events = max_events
	last_error = &""
	return true


func append(
	kind: ZRaidEvent.EventKind,
	event_id: ZConsequenceId,
	tick: int,
	actor_id: ZEntityId,
	payload: Dictionary = {}
) -> bool:
	last_error = &""
	if not _validate_append(kind, event_id, tick, actor_id, payload):
		return false

	var event_key := event_id.canonical_key()
	var event := ZRaidEvent.new()
	event.event_id = ZConsequenceId.parse(event_key)
	event.raid_id = _raid_id
	event.actor_id = ZEntityId.parse(actor_id.canonical_key()) if actor_id != null else null
	event.kind = kind
	event.tick = tick
	event.sequence = _next_sequence
	event.payload = payload.duplicate(true)
	_events.append(event)
	_seen_event_ids[event_key] = true
	_next_sequence += 1
	_last_tick = tick
	return true


## Capacity/collision preflight for fail-atomic cross-domain adapters.  This
## performs the exact append validation without reserving or publishing state;
## synchronous single-writer callers may then complete their world query and
## append without an intervening yield.
func can_append(
	kind: ZRaidEvent.EventKind,
	event_id: ZConsequenceId,
	tick: int,
	actor_id: ZEntityId,
	payload: Dictionary = {}
) -> bool:
	last_error = &""
	return _validate_append(kind, event_id, tick, actor_id, payload)


func _validate_append(
	kind: ZRaidEvent.EventKind,
	event_id: ZConsequenceId,
	tick: int,
	actor_id: ZEntityId,
	payload: Dictionary
) -> bool:
	if _sealed:
		return _reject(&"journal_sealed")
	if _raid_id == null:
		return _reject(&"journal_not_configured")
	if _events.size() >= _max_events:
		return _reject(&"journal_full")
	if int(kind) < 0 or int(kind) >= ZRaidEvent.KIND_NAMES.size():
		return _reject(&"event_kind_invalid")
	if event_id == null or ZConsequenceId.parse(event_id.canonical_key()) == null:
		return _reject(&"event_id_invalid")
	if tick < _last_tick:
		return _reject(&"event_tick_regressed")
	if actor_id != null and ZEntityId.parse(actor_id.canonical_key()) == null:
		return _reject(&"event_actor_invalid")
	if not ZCanonicalValue.is_bounded(payload):
		return _reject(&"event_payload_invalid_or_unbounded")
	var event_key := event_id.canonical_key()
	if _seen_event_ids.has(event_key):
		return _reject(&"duplicate_event")
	return true


func records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in _events:
		result.append(event.canonical_record())
	return result


## Returns one canonical retained record without rebuilding the complete journal.
## Invalid indices are non-authorizing and return an empty value.
func record_at(index: int) -> Dictionary:
	if index < 0 or index >= _events.size():
		return {}
	var record := (_events[index] as ZRaidEvent).canonical_record()
	record.make_read_only()
	return record


func digest() -> String:
	# Preserve the compact canonical digest for small journals, then switch to a
	# framed streaming digest once aggregate collection/node limits are reached.
	if _events.size() <= ZCanonicalValue.DEFAULT_MAX_COLLECTION:
		var direct := ZCanonicalValue.sha256(records())
		if not direct.is_empty():
			return direct
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update("zerkov.raid_journal.v1\n".to_utf8_buffer()) != OK:
		return ""
	for event in _events:
		var payload_digest := ZCanonicalValue.sha256(event.payload)
		if payload_digest.is_empty():
			return ""
		var encoded := ZCanonicalValue.encode({
			"actor_id": event.actor_id.canonical_key() if event.actor_id != null else "",
			"event_id": event.event_id.canonical_key(),
			"kind": ZRaidEvent.KIND_NAMES[int(event.kind)],
			"payload_sha256": payload_digest,
			"raid_id": event.raid_id.canonical_key(),
			"sequence": event.sequence,
			"tick": event.tick,
		})
		if encoded.is_empty():
			return ""
		var bytes := encoded.to_utf8_buffer()
		if context.update(("%d:" % bytes.size()).to_utf8_buffer()) != OK:
			return ""
		if context.update(bytes) != OK:
			return ""
	return context.finish().hex_encode()


func size() -> int:
	return _events.size()


## Read-only capacity evidence for adapters that must preflight a multi-event
## consequence before mutating another authoritative domain.
func remaining_capacity() -> int:
	return maxi(0, _max_events - _events.size()) if not _sealed else 0


func seal() -> void:
	_sealed = true


func is_sealed() -> bool:
	return _sealed


func _reject(code: StringName) -> bool:
	last_error = code
	return false
