class_name RaidVisionReplicationSource
extends ZAuthorizedVisionProjectionPort
## Product adapter over the value-only RaidVisionActorRegistry projection cache.
##
## The recipient allowlist is server-authored. Identity resolution is additionally
## constrained to a target ID that is VISIBLE in that recipient's current full
## projection, so callers cannot use this port as a hidden native-ID oracle.

const MAX_RECIPIENTS: int = RaidVisionActorRegistry.MAX_OBSERVERS
const VISIBLE: int = 2

var last_error: StringName = &""

var _registry: RaidVisionActorRegistry
var _generation: int = 0
var _authorized_recipients: Dictionary = {}


func configure(
	registry: RaidVisionActorRegistry,
	generation: int,
	authorized_recipient_ids: PackedStringArray
) -> bool:
	last_error = &""
	if (
		_registry != null
		or registry == null
		or not registry.is_active(generation)
		or generation <= 0
		or authorized_recipient_ids.is_empty()
		or authorized_recipient_ids.size() > MAX_RECIPIENTS
	):
		return _reject(&"raid_vision_replication_source_invalid")
	var normalized: Dictionary = {}
	for raw_recipient in authorized_recipient_ids:
		var recipient_key := String(raw_recipient)
		var entity_id := ZEntityId.parse(recipient_key)
		if entity_id == null or normalized.has(recipient_key):
			return _reject(&"raid_vision_replication_recipient_invalid")
		normalized[recipient_key] = true
	_registry = registry
	_generation = generation
	_authorized_recipients = normalized
	return true


func is_authorized_recipient(
	recipient_actor_id: ZEntityId,
	generation: int
) -> bool:
	return (
		_registry != null
		and generation == _generation
		and _registry.is_active(_generation)
		and recipient_actor_id != null
		and _authorized_recipients.has(recipient_actor_id.canonical_key())
	)


func projection_for(
	recipient_actor_id: ZEntityId,
	generation: int
) -> Dictionary:
	if not is_authorized_recipient(recipient_actor_id, generation):
		return {}
	return _registry.projection_for(
		_generation,
		recipient_actor_id.canonical_key()
	).duplicate(true)


func entity_for_visible_native_id(
	recipient_actor_id: ZEntityId,
	native_target_id: int,
	generation: int
) -> ZEntityId:
	if (
		native_target_id <= 0
		or not is_authorized_recipient(recipient_actor_id, generation)
	):
		return null
	var projection := projection_for(recipient_actor_id, generation)
	if projection.get("ok") != true or not projection.get("records") is Array:
		return null
	var visible_occurrences: int = 0
	for raw_record in projection["records"] as Array:
		if not raw_record is Dictionary:
			return null
		var record := raw_record as Dictionary
		if (
			typeof(record.get("target_id", null)) == TYPE_INT
			and int(record["target_id"]) == native_target_id
			and typeof(record.get("state", null)) == TYPE_INT
			and int(record["state"]) == VISIBLE
		):
			visible_occurrences += 1
	if visible_occurrences != 1:
		return null
	var canonical := _registry.entity_for_native_id(
		_generation,
		native_target_id
	)
	return ZEntityId.parse(canonical)


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
