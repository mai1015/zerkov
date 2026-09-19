class_name ZReplicationRecord
extends RefCounted
## Immutable-by-convention authoritative snapshot/delta prepared for egress.
##
## Stable entity identifiers appearing anywhere in payload keys or values must
## be declared in entity_references. The egress layer then proves every declared
## reference is either the recipient's own actor or currently Vision-visible.

enum Kind {
	SNAPSHOT,
	DELTA,
	TOMBSTONE,
}

enum Scope {
	OWNER,
	VISION,
}

const MAX_REVISION: int = 2_147_483_647
const MAX_ENTITY_REFERENCES: int = 64
const MAX_SUBJECT_BYTES: int = 256

var channel: StringName = &""
var subject_id: String = ""
var owner_actor_id: ZEntityId
var generation: int = 0
var kind: Kind = Kind.SNAPSHOT
var scope: Scope = Scope.OWNER
var revision: int = 0
var base_revision: int = 0
var payload: Dictionary = {}
var entity_references: PackedStringArray = PackedStringArray()
var stream_key: String = ""
var record_digest: String = ""


static func create(
	p_channel: StringName,
	p_subject_id: String,
	p_owner_actor_id: ZEntityId,
	p_generation: int,
	p_kind: Kind,
	p_scope: Scope,
	p_revision: int,
	p_base_revision: int,
	p_payload: Dictionary,
	p_entity_references: PackedStringArray = PackedStringArray()
) -> ZReplicationRecord:
	var normalized_references := _normalize_references(p_entity_references)
	if (
		normalized_references.is_empty()
		and not p_entity_references.is_empty()
	):
		return null
	if not ZCanonicalValue.is_bounded(p_payload):
		return null
	var discovered: Dictionary = {}
	_collect_entity_references(p_payload, discovered)
	for referenced_id in discovered.keys():
		if not normalized_references.has(String(referenced_id)):
			return null

	var actor_copy := (
		ZEntityId.parse(p_owner_actor_id.canonical_key())
		if p_owner_actor_id != null
		else null
	)
	if actor_copy == null:
		return null
	var result := ZReplicationRecord.new()
	result.channel = p_channel
	result.subject_id = p_subject_id
	result.owner_actor_id = actor_copy
	result.generation = p_generation
	result.kind = p_kind
	result.scope = p_scope
	result.revision = p_revision
	result.base_revision = p_base_revision
	result.payload = p_payload.duplicate(true)
	result.entity_references = normalized_references
	result.stream_key = result._calculate_stream_key()
	result.record_digest = result._calculate_digest()
	return result if result.is_usable() else null


func is_usable() -> bool:
	if (
		owner_actor_id == null
		or not owner_actor_id.is_initialized()
		or owner_actor_id.kind() != ZEntityId.KIND
		or not ZReplicationGrant.CHANNELS.has(String(channel))
		or subject_id.is_empty()
		or subject_id.to_utf8_buffer().size() > MAX_SUBJECT_BYTES
		or generation <= 0
		or generation > MAX_REVISION
		or int(kind) < int(Kind.SNAPSHOT)
		or int(kind) > int(Kind.TOMBSTONE)
		or int(scope) < int(Scope.OWNER)
		or int(scope) > int(Scope.VISION)
		or revision <= 0
		or revision > MAX_REVISION
		or entity_references.size() > MAX_ENTITY_REFERENCES
		or not ZCanonicalValue.is_bounded(payload)
	):
		return false
	if channel == ZReplicationGrant.CHANNEL_INVENTORY and scope != Scope.OWNER:
		return false
	if channel == ZReplicationGrant.CHANNEL_VISION and scope != Scope.OWNER:
		return false
	match kind:
		Kind.SNAPSHOT:
			if base_revision != 0:
				return false
		Kind.DELTA:
			if base_revision <= 0 or revision != base_revision + 1:
				return false
		Kind.TOMBSTONE:
			if (
				base_revision <= 0
				or revision != base_revision + 1
				or not payload.is_empty()
			):
				return false
	var previous := ""
	for reference in entity_references:
		var canonical := String(reference)
		if ZEntityId.parse(canonical) == null:
			return false
		if not previous.is_empty() and canonical <= previous:
			return false
		previous = canonical
	var discovered: Dictionary = {}
	_collect_entity_references(payload, discovered)
	for referenced_id in discovered.keys():
		if not entity_references.has(String(referenced_id)):
			return false
	return (
		ZProductCompatibilityManifest.is_sha256(stream_key)
		and stream_key == _calculate_stream_key()
		and ZProductCompatibilityManifest.is_sha256(record_digest)
		and record_digest == _calculate_digest()
	)


func snapshot() -> ZReplicationRecord:
	if not is_usable():
		return null
	return create(
		channel,
		subject_id,
		owner_actor_id,
		generation,
		kind,
		scope,
		revision,
		base_revision,
		payload,
		entity_references
	)


func wire_record() -> Dictionary:
	if not is_usable():
		return {}
	var references: Array = []
	for reference in entity_references:
		references.append(String(reference))
	return {
		"base_revision": base_revision,
		"channel": String(channel),
		"digest": record_digest,
		"entity_references": references,
		"generation": generation,
		"kind": int(kind),
		"owner_actor_id": owner_actor_id.canonical_key(),
		"payload": payload.duplicate(true),
		"revision": revision,
		"scope": int(scope),
		"stream_key": stream_key,
		"subject_id": subject_id,
	}


func _calculate_stream_key() -> String:
	if owner_actor_id == null:
		return ""
	return ZCanonicalValue.sha256({
		"channel": String(channel),
		"owner_actor_id": owner_actor_id.canonical_key(),
		"subject_id": subject_id,
	})


func _calculate_digest() -> String:
	if owner_actor_id == null:
		return ""
	var references: Array = []
	for reference in entity_references:
		references.append(String(reference))
	return ZCanonicalValue.sha256({
		"base_revision": base_revision,
		"channel": String(channel),
		"entity_references": references,
		"generation": generation,
		"kind": int(kind),
		"owner_actor_id": owner_actor_id.canonical_key(),
		"payload": payload,
		"revision": revision,
		"scope": int(scope),
		"subject_id": subject_id,
	})


static func _normalize_references(
	source: PackedStringArray
) -> PackedStringArray:
	if source.size() > MAX_ENTITY_REFERENCES:
		return PackedStringArray()
	var seen: Dictionary = {}
	var result := PackedStringArray()
	for raw_reference in source:
		var reference := String(raw_reference)
		if ZEntityId.parse(reference) == null:
			return PackedStringArray()
		if seen.has(reference):
			continue
		seen[reference] = true
		result.append(reference)
	result.sort()
	return result


static func _collect_entity_references(
	value: Variant,
	result: Dictionary
) -> void:
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME:
			var text := String(value)
			if ZEntityId.parse(text) != null:
				result[text] = true
		TYPE_ARRAY:
			for child in value as Array:
				_collect_entity_references(child, result)
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			for key in dictionary.keys():
				_collect_entity_references(key, result)
				_collect_entity_references(dictionary[key], result)
