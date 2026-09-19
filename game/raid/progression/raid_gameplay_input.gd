class_name RaidGameplayInput
extends ZCombatInputAdapter
## Use this SAME encoder for combat/movement/progression, never another per-
## actor sequence owner. Admission stays in RaidAuthority; no profile access.
func build_progression_intent(target_tick: int, kind: StringName, payload: Dictionary,
	request_id: ZRequestId = null) -> ZRaidIntent:
	if not _preflight(target_tick, request_id): return null
	if not valid_payload(kind,payload):
		_last_error = &"progression_payload_invalid"
		return null
	var id := _request_id(request_id)
	_next_sequence += 1
	return ZRaidIntent.create(id,_source,_session_id,_actor_id,_authority_epoch,
		_generation,target_tick,_next_sequence,kind,payload)
static func valid_payload(kind: StringName, payload: Dictionary) -> bool:
	if kind == &"raid_cancel": return payload.is_empty()
	return kind == &"interaction" and payload.size() == 1 \
		and typeof(payload.get("target_id")) == TYPE_STRING \
		and (SupplyRunGraph.accepts_target(String(payload.target_id)) \
			or RaidPopulationCatalog.accepts_target(String(payload.target_id)))
