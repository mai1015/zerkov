class_name RaidCombatIntentSink
extends ZCombatIntentSink
## Concrete adapter to the existing RaidAuthority; no second queue or clock.
## Never pass this root-owned adapter or authority to a presentation model.

var _raid: WeakRef
var _actor: ZEntityId
var _source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER
var _generation: int = 0
var _session_key: String = ""
var _epoch: int = 0
var _released: bool = false


func bind(raid: RaidAuthority, actor: ZEntityId, source: ZRaidIntent.Source, generation: int) -> bool:
	if _generation != 0 or _released or raid == null or actor == null \
		or source not in [ZRaidIntent.Source.PLAYER, ZRaidIntent.Source.AI] \
		or generation <= 0 or raid.generation() != generation \
		or not raid.has_authorized_actor_source(actor, source, generation):
		return false
	var admission := raid.admission()
	if admission == null or not admission.is_usable():
		return false
	_actor = ZEntityId.parse(actor.canonical_key())
	_source = source
	_generation = generation
	_session_key = admission.session_id.canonical_key()
	_epoch = admission.authority_epoch
	_raid = weakref(raid)
	return true


func context() -> Dictionary:
	var raid := _current()
	if raid == null:
		return {}
	var admission := raid.admission()
	var result := {"session_id": _session_key, "actor_id": _actor.canonical_key(),
		"source": int(_source), "authority_epoch": _epoch, "generation": _generation,
		"current_tick": raid.clock.current_tick, "lifecycle": String(raid.lifecycle_name())}
	if admission == null or admission.session_id.canonical_key() != _session_key or admission.authority_epoch != _epoch:
		return {}
	result.make_read_only()
	return result


func admit(intent: ZRaidIntent) -> Dictionary:
	var raid := _current()
	if raid == null or intent == null or intent.actor_id == null \
		or not intent.actor_id.is_equal(_actor) or intent.source != _source:
		return {"admitted": false, "reason": &"combat_sink_binding_invalid"}
	# Domain-specific schemas are checked here as well as before construction:
	# another trusted caller cannot enqueue unchecked payloads through this port.
	var validation := UIIntentAdapter.validate_movement_payload(intent.payload) \
		if intent.kind == UIIntentAdapter.INTENT_KIND_MOVEMENT else ZCombatActionCodec.validate_intent(intent)
	if not validation.is_empty():
		return {"admitted": false, "reason": validation}
	var accepted := raid.enqueue_intent(intent, _generation)
	return {"admitted": accepted, "reason": &"" if accepted else raid.last_error}


func release() -> void:
	_released = true
	_raid = null
	_actor = null


func _current() -> RaidAuthority:
	if _released or _raid == null or _actor == null:
		return null
	var raid := _raid.get_ref() as RaidAuthority
	if raid == null or raid.generation() != _generation or raid.lifecycle not in [
		RaidAuthority.Lifecycle.PREPARING, RaidAuthority.Lifecycle.ACTIVE, RaidAuthority.Lifecycle.EXTRACTING] \
		or not raid.has_authorized_actor_source(_actor, _source, _generation):
		return null
	return raid
