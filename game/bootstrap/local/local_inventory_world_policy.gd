class_name LocalInventoryWorldPolicy
extends ZInventoryWorldPolicyPort
## No remembered visibility or UI "open" flag grants loot access. The target
## must be a searched, registered crate in range of the live local actor.
var _session: LocalRaidSession
var _released: bool = false

func configure(session: LocalRaidSession) -> bool:
	if _session != null or session == null or session.raid == null: return false
	_session = session
	return true

func is_world_inventory(actor_id: ZEntityId, inventory_id: int, generation: int) -> bool:
	return _current(actor_id, generation) and not _crate_key(inventory_id).is_empty()

func authoritative_distance_raw(actor_id: ZEntityId, inventory_id: int, generation: int) -> int:
	var result := _evaluate(actor_id, inventory_id, generation)
	return int(result.distance_micro) if result != null else -1

func is_currently_visible(actor_id: ZEntityId, inventory_id: int, generation: int) -> bool:
	var result := _evaluate(actor_id, inventory_id, generation)
	return result != null and result.allowed

func access_state(actor_id: ZEntityId, inventory_id: int, generation: int) -> StringName:
	if not _current(actor_id, generation): return ACCESS_UNAVAILABLE
	return ACCESS_OPEN if _session.progression.was_crate_searched(_crate_key(inventory_id)) else ACCESS_CLOSED

func allows_transfer(actor_id: ZEntityId, source_inventory_id: int, destination_inventory_id: int,
		_item_id: int, generation: int) -> bool:
	if not _current(actor_id, generation): return false
	var player_id: int = _session.deployment.inventory.raid_player_inventory_id
	var world_id: int = destination_inventory_id if source_inventory_id == player_id else source_inventory_id
	if source_inventory_id != player_id and destination_inventory_id != player_id: return false
	return access_state(actor_id, world_id, generation) == ACCESS_OPEN \
		and is_currently_visible(actor_id, world_id, generation)

func release() -> void:
	_released = true
	_session = null

func _crate_key(inventory_id: int) -> String:
	if _session == null: return ""
	for key: String in _session.crate_ids:
		if int(_session.crate_ids[key]) == inventory_id: return key
	return ""

func _current(actor: ZEntityId, generation: int) -> bool:
	return not _released and _session != null and is_instance_valid(_session) and _session.raid != null \
		and actor != null and _session.raid.generation() == generation \
		and _session.raid.admission().actor_id.is_equal(actor) \
		and _session.raid.lifecycle in [RaidAuthority.Lifecycle.ACTIVE, RaidAuthority.Lifecycle.EXTRACTING] \
		and _session.combat.health.actor_snapshot(actor).get("alive") == true

func _evaluate(actor: ZEntityId, inventory_id: int, generation: int) -> ZInteractionResult:
	if not _current(actor, generation): return null
	var key := _crate_key(inventory_id)
	if key.is_empty(): return null
	return _session.interaction.evaluate_for_actor(actor, StringName(key), ZInteractionKind.CRATE, generation)
