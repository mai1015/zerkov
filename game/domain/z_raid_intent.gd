class_name ZRaidIntent
extends RefCounted
## Validated intent envelope. Mutation remains owned by RaidAuthority.

enum Source {
	PLAYER,
	AI,
	SYSTEM,
}

var request_id: ZRequestId
var source: Source = Source.PLAYER
var session_id: ZSessionId
var actor_id: ZEntityId
var authority_epoch: int = 0
var generation: int = 0
var target_tick: int = 0
var sequence: int = 0
var kind: StringName = &""
var payload: Dictionary = {}


static func create(
	p_request_id: ZRequestId,
	p_source: Source,
	p_session_id: ZSessionId,
	p_actor_id: ZEntityId,
	p_authority_epoch: int,
	p_generation: int,
	p_target_tick: int,
	p_sequence: int,
	p_kind: StringName,
	p_payload: Dictionary = {}
) -> ZRaidIntent:
	var result := ZRaidIntent.new()
	result.request_id = p_request_id
	result.source = p_source
	result.session_id = p_session_id
	result.actor_id = p_actor_id
	result.authority_epoch = p_authority_epoch
	result.generation = p_generation
	result.target_tick = p_target_tick
	result.sequence = p_sequence
	result.kind = p_kind
	# Do not recursively duplicate hostile cyclic/unbounded input before the
	# authority queue has had a chance to reject it.
	result.payload = p_payload.duplicate(true) if ZCanonicalValue.is_bounded(p_payload) else p_payload
	return result


func snapshot() -> ZRaidIntent:
	if (
		request_id == null
		or session_id == null
		or actor_id == null
		or not ZCanonicalValue.is_bounded(payload)
	):
		return null
	var request_copy := ZRequestId.parse(request_id.canonical_key())
	var session_copy := ZSessionId.parse(session_id.canonical_key())
	var actor_copy := ZEntityId.parse(actor_id.canonical_key())
	if request_copy == null or session_copy == null or actor_copy == null:
		return null
	return create(
		request_copy,
		source,
		session_copy,
		actor_copy,
		authority_epoch,
		generation,
		target_tick,
		sequence,
		kind,
		payload
	)


func canonical_record() -> Dictionary:
	return {
		"actor_id": actor_id.canonical_key() if actor_id != null else "",
		"authority_epoch": authority_epoch,
		"generation": generation,
		"kind": String(kind),
		"payload": payload.duplicate(true),
		"request_id": request_id.canonical_key() if request_id != null else "",
		"sequence": sequence,
		"session_id": session_id.canonical_key() if session_id != null else "",
		"source": int(source),
		"target_tick": target_tick,
	}
