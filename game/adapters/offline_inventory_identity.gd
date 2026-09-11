class_name OfflineInventoryIdentity
extends ZInventoryIdentityPort
## Trusted local identity mapping for the offline product composition.
##
## Inventory System treats its actor integer as opaque. This adapter binds one
## admitted Zerkov actor to one positive native actor value and the exact raid
## inventory owned by that actor. It owns no inventory state and grants no
## profile or world-container ownership.

var _session_key: String = ""
var _actor_key: String = ""
var _authority_epoch: int = 0
var _generation: int = 0
var _owner_generation: int = 0
var _native_actor_id: int = 0
var _owned_inventory_id: int = 0
var _owner: WeakRef


func configure(
	admission: ZSessionAdmission,
	owner: RaidInventoryOwner,
	native_actor_id_value: int
) -> bool:
	release()
	if admission == null or not admission.is_usable() \
			or owner == null or not is_instance_valid(owner) \
			or not owner.is_current_generation(owner.generation()) \
			or native_actor_id_value <= 0 or owner.raid_player_inventory_id <= 0:
		return false
	_session_key = admission.session_id.canonical_key()
	_actor_key = admission.actor_id.canonical_key()
	_authority_epoch = admission.authority_epoch
	_generation = admission.generation
	_owner_generation = owner.generation()
	_native_actor_id = native_actor_id_value
	_owned_inventory_id = owner.raid_player_inventory_id
	_owner = weakref(owner)
	return true


func release() -> void:
	_session_key = ""
	_actor_key = ""
	_authority_epoch = 0
	_generation = 0
	_owner_generation = 0
	_native_actor_id = 0
	_owned_inventory_id = 0
	_owner = null


func native_actor_id(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int
) -> int:
	return _native_actor_id if _matches(
		session_id, actor_id, authority_epoch, generation) else 0


func actor_owns_inventory(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	inventory_id: int,
	authority_epoch: int,
	generation: int
) -> bool:
	return inventory_id == _owned_inventory_id \
		and _matches(session_id, actor_id, authority_epoch, generation)


func _matches(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int
) -> bool:
	if _owner == null or session_id == null or actor_id == null:
		return false
	var owner := _owner.get_ref() as RaidInventoryOwner
	return owner != null and is_instance_valid(owner) \
		and owner.is_current_generation(_owner_generation) \
		and owner.raid_player_inventory_id == _owned_inventory_id \
		and session_id.canonical_key() == _session_key \
		and actor_id.canonical_key() == _actor_key \
		and authority_epoch == _authority_epoch \
		and generation == _generation
