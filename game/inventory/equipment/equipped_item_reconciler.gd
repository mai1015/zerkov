class_name EquippedItemReconciler
extends Node
## Game-owned equipment projection -> stable runtime identity reconciliation.
##
## Inventory System remains the sole owner of item instances and equipment
## locations. This reconciler consumes only the exact immutable raid-player
## snapshot installed by InventoryProjectionBridge. It does not create Weapon
## System instances; task 5.2 may consume the copied mapping outcomes below.
##
## Stable weapon/entity identity deliberately excludes equipment slot,
## inventory revision, and presentation scope generation. Unequipping removes
## the live mapping, while re-equipping the same canonical item in the same
## raid/admission/owner context recreates the same identities.

signal reconciliation_published(outcome: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle {
	UNBOUND,
	BOUND,
	INVALIDATED,
}

const SCOPE_RAID: StringName = &"raid"
const SLOT_PRIMARY: StringName = &"zerkov.slot.weapon_primary"
const SLOT_MELEE: StringName = &"zerkov.slot.weapon_melee"
const WEAPON_SLOTS: Array[StringName] = [SLOT_PRIMARY, SLOT_MELEE]

const WEAPON_KIND_FIREARM: StringName = &"firearm"
const WEAPON_KIND_MELEE: StringName = &"melee"
const IDENTITY_SCHEMA: String = "zerkov.equipment.identity.v1"
const IDENTITY_HASH_SEGMENT_BYTES: int = 48

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _bridge: InventoryProjectionBridge
var _bridge_instance_id: int = 0
var _admission: ZSessionAdmission
var _owner_generation: int = 0
var _scope_generation: int = 0
var _player_inventory_id: int = 0
var _last_revision: int = -1
var _last_snapshot_digest: String = ""
var _mappings_by_slot: Dictionary = {}
var _current_outcome: Dictionary = {}

var _snapshot_callback: Callable
var _model_replaced_callback: Callable
var _status_callback: Callable
var _bridge_invalidated_callback: Callable
var _public_signal_active: bool = false
var _deferred_invalidation_reason: StringName = &""


## Binds one exact inventory owner, authenticated admission, and raid
## projection generation. A previously invalidated reconciler may be rebound;
## a still-live binding must be explicitly released first.
func bind_owner(
	owner: RaidInventoryOwner,
	bridge: InventoryProjectionBridge,
	admission: ZSessionAdmission,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if _public_signal_active:
		return _reject_bind(&"reentrant_binding_change")
	if lifecycle == Lifecycle.BOUND:
		return _reject_bind(&"reconciler_already_bound")
	if owner == null or not is_instance_valid(owner):
		return _reject_bind(&"inventory_owner_invalid")
	if expected_owner_generation <= 0 \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject_bind(&"owner_generation_invalid")
	if bridge == null or not is_instance_valid(bridge) or not bridge.is_bound():
		return _reject_bind(&"projection_bridge_invalid")
	if bridge.owner_generation() != expected_owner_generation:
		return _reject_bind(&"projection_owner_generation_mismatch")
	if expected_scope_generation <= 0 \
			or bridge.scope_generation(SCOPE_RAID) != expected_scope_generation:
		return _reject_bind(&"projection_scope_generation_mismatch")
	if bridge.scope_status(SCOPE_RAID) != InventoryProjectionBridge.ProjectionStatus.READY:
		return _reject_bind(&"raid_projection_not_ready")
	if owner.raid_authority() == null \
			or bridge.authority_for_scope(SCOPE_RAID) != owner.raid_authority():
		return _reject_bind(&"raid_authority_mismatch")
	if owner.raid_player_inventory_id <= 0 \
			or not bridge.inventory_ids(SCOPE_RAID).has(owner.raid_player_inventory_id):
		return _reject_bind(&"raid_player_inventory_outside_scope")
	if admission == null or not admission.is_usable():
		return _reject_bind(&"session_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _reject_bind(&"session_admission_invalid")
	var initial_snapshot := bridge.confirmed_snapshot(
		SCOPE_RAID, owner.raid_player_inventory_id)
	if initial_snapshot == null:
		return _reject_bind(&"raid_player_snapshot_missing")
	if StringName(initial_snapshot.get_profile_identifier()) \
			!= ZerkovInventoryCatalog.PROFILE_PLAYER_RAID:
		return _reject_bind(&"raid_player_profile_mismatch")

	# Validate the complete replacement before discarding an INVALIDATED
	# binding's terminal outcome. A failed rebind must not erase the removal
	# record or generation context consumers may still need to acknowledge.
	_reset_unbound_state()
	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_bridge = bridge
	_bridge_instance_id = bridge.get_instance_id()
	_admission = admission_copy
	_owner_generation = expected_owner_generation
	_scope_generation = expected_scope_generation
	_player_inventory_id = owner.raid_player_inventory_id
	lifecycle = Lifecycle.BOUND
	_connect_bridge_signals()

	var initial_result := reconcile_snapshot(
		SCOPE_RAID,
		initial_snapshot,
		expected_owner_generation,
		expected_scope_generation
	)
	if not bool(initial_result.get("accepted", false)):
		var reason := StringName(initial_result.get("reason", &"initial_reconciliation_failed"))
		_invalidate_binding(reason)
		last_error = reason
		return false
	# Public listeners run synchronously. A listener may deliberately tear down
	# the just-published initial binding; never report a successful bind after
	# that lifecycle boundary has already completed.
	if lifecycle != Lifecycle.BOUND or not _binding_is_current():
		var invalidation_reason := last_error \
			if not last_error.is_empty() else &"initial_reconciliation_invalidated"
		if lifecycle == Lifecycle.BOUND:
			_invalidate_binding(invalidation_reason)
		last_error = invalidation_reason
		return false
	return true


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func owner_generation() -> int:
	return _owner_generation


func scope_generation() -> int:
	return _scope_generation


func player_inventory_id() -> int:
	return _player_inventory_id


func current_revision() -> int:
	return _last_revision


## Returns a detached deep copy. Mutating it cannot alter reconciler state or
## any later outcome delivered to another consumer.
func current_outcome() -> Dictionary:
	return _current_outcome.duplicate(true)


func current_mappings() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in WEAPON_SLOTS:
		if _mappings_by_slot.has(slot):
			result.append((_mappings_by_slot[slot] as Dictionary).duplicate(true))
	return result


func mapping_for_slot(slot_identifier: StringName) -> Dictionary:
	if not _mappings_by_slot.has(slot_identifier):
		return {}
	return (_mappings_by_slot[slot_identifier] as Dictionary).duplicate(true)


func mapping_for_native_item(native_item_id: int) -> Dictionary:
	for mapping in current_mappings():
		if int(mapping.get("native_item_id", 0)) == native_item_id:
			return mapping
	return {}


## Typed accessors keep downstream task 5.2 from treating arbitrary strings as
## authoritative weapon or entity identities.
func weapon_id_for_slot(slot_identifier: StringName) -> ZWeaponId:
	var mapping := mapping_for_slot(slot_identifier)
	return ZWeaponId.parse(String(mapping.get("weapon_id", ""))) \
		if not mapping.is_empty() else null


func entity_id_for_slot(slot_identifier: StringName) -> ZEntityId:
	var mapping := mapping_for_slot(slot_identifier)
	return ZEntityId.parse(String(mapping.get("entity_id", ""))) \
		if not mapping.is_empty() else null


## Public deterministic identity helper for other game-owned adapters and
## collision fixtures. Slot, revision, and projection generation are
## intentionally absent from the signature.
static func derive_identity_keys(
	admission: ZSessionAdmission,
	owner_generation_value: int,
	inventory_id: int,
	native_item_id: int,
	item_definition_identifier: StringName
) -> Dictionary:
	if admission == null or not admission.is_usable() \
			or owner_generation_value <= 0 or inventory_id <= 0 or native_item_id <= 0 \
			or not [
				ZerkovInventoryCatalog.ITEM_AKM,
				ZerkovInventoryCatalog.ITEM_MACHETE,
			].has(item_definition_identifier):
		return {}
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return {}
	var context := {
		"schema": IDENTITY_SCHEMA,
		"raid_id": admission_copy.raid_id.canonical_key(),
		"session_id": admission_copy.session_id.canonical_key(),
		"actor_id": admission_copy.actor_id.canonical_key(),
		"authority_epoch": admission_copy.authority_epoch,
		"admission_generation": admission_copy.generation,
		"owner_generation": owner_generation_value,
		"inventory_id": inventory_id,
		"native_item_id": native_item_id,
		"item_definition_identifier": String(item_definition_identifier),
	}
	var weapon_context := context.duplicate(true)
	weapon_context["identity_kind"] = String(ZWeaponId.KIND)
	var entity_context := context.duplicate(true)
	entity_context["identity_kind"] = String(ZEntityId.KIND)
	var weapon_digest := ZCanonicalValue.sha256(weapon_context)
	var entity_digest := ZCanonicalValue.sha256(entity_context)
	if weapon_digest.length() < IDENTITY_HASH_SEGMENT_BYTES \
			or entity_digest.length() < IDENTITY_HASH_SEGMENT_BYTES:
		return {}
	var weapon_id := ZWeaponId.from_parts(PackedStringArray([
		"equipment", weapon_digest.substr(0, IDENTITY_HASH_SEGMENT_BYTES)]))
	var entity_id := ZEntityId.from_parts(PackedStringArray([
		"equipment", entity_digest.substr(0, IDENTITY_HASH_SEGMENT_BYTES)]))
	if weapon_id == null or entity_id == null:
		return {}
	return {
		"weapon_id": weapon_id.canonical_key(),
		"entity_id": entity_id.canonical_key(),
	}


## Explicit ingress is useful for deterministic replay and tests. Normal local
## runtime updates arrive through InventoryProjectionBridge.snapshot_projected.
func reconcile_snapshot(
	scope: StringName,
	snapshot: InventorySnapshotResource,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> Dictionary:
	last_error = &""
	if _public_signal_active:
		return _rejection(&"reentrant_reconciliation")
	if lifecycle != Lifecycle.BOUND:
		return _rejection(&"reconciler_not_bound")
	if scope != SCOPE_RAID:
		return _rejection(&"scope_mismatch")
	if expected_owner_generation != _owner_generation:
		return _rejection(&"owner_generation_mismatch")
	if expected_scope_generation != _scope_generation:
		return _rejection(&"scope_generation_mismatch")
	if not _binding_is_current():
		_invalidate_binding(&"binding_generation_invalidated")
		return current_outcome()
	if snapshot == null:
		return _rejection(&"snapshot_missing")
	if snapshot.get_inventory_id() != _player_inventory_id:
		return _rejection(&"inventory_mismatch")
	if StringName(snapshot.get_profile_identifier()) \
			!= ZerkovInventoryCatalog.PROFILE_PLAYER_RAID:
		return _rejection(&"profile_mismatch")
	if snapshot.get_visibility() != InventorySnapshotResource.VISIBILITY_OWNER:
		return _rejection(&"snapshot_visibility_invalid")

	var revision := snapshot.get_revision()
	if revision < 0:
		return _rejection(&"snapshot_revision_invalid")
	if revision < _last_revision:
		return _rejection(&"stale_snapshot_revision")
	var digest := _snapshot_digest(snapshot)
	if digest.is_empty():
		return _rejection(&"snapshot_digest_invalid")
	if revision == _last_revision and digest != _last_snapshot_digest:
		return _rejection(&"equal_revision_divergence")
	if not _snapshot_is_current_projection(snapshot):
		return _rejection(&"snapshot_not_current_projection")
	if revision == _last_revision:
		return _duplicate_result()

	var build_result := _build_mappings(snapshot)
	if not bool(build_result.get("ok", false)):
		var build_reason := StringName(build_result.get("reason", &"equipment_snapshot_invalid"))
		_invalidate_binding(build_reason)
		return current_outcome()
	var next_mappings := build_result.get("mappings", {}) as Dictionary
	var previous_mappings := _mappings_by_slot
	var delta := _mapping_delta(previous_mappings, next_mappings)
	var initial := _last_revision < 0
	_mappings_by_slot = _copy_mapping_dictionary(next_mappings)
	_last_revision = revision
	_last_snapshot_digest = digest
	_current_outcome = {
		"accepted": true,
		"changed": bool(delta["changed"]),
		"duplicate": false,
		"initial": initial,
		"invalidated": false,
		"reason": &"",
		"raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(),
		"actor_id": _admission.actor_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"admission_generation": _admission.generation,
		"owner_generation": _owner_generation,
		"scope_generation": _scope_generation,
		"inventory_id": _player_inventory_id,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"mappings": current_mappings(),
		"added": delta["added"],
		"removed": delta["removed"],
		"updated": delta["updated"],
		"retained": delta["retained"],
	}
	var published_outcome := current_outcome()
	_emit_reconciliation(published_outcome)
	return published_outcome


func validate_binding() -> bool:
	last_error = &""
	if lifecycle == Lifecycle.BOUND and _binding_is_current():
		return true
	if lifecycle == Lifecycle.BOUND:
		_invalidate_binding(&"binding_generation_invalidated")
	last_error = &"binding_generation_invalidated"
	return false


func release_binding(reason: StringName = &"reconciler_released") -> void:
	if lifecycle == Lifecycle.BOUND:
		var final_reason := reason if not reason.is_empty() else &"reconciler_released"
		if _public_signal_active:
			if _deferred_invalidation_reason.is_empty():
				_deferred_invalidation_reason = final_reason
			return
		_invalidate_binding(final_reason)


func _exit_tree() -> void:
	release_binding(&"reconciler_tree_exiting")


func _connect_bridge_signals() -> void:
	_snapshot_callback = Callable(self, "_on_snapshot_projected")
	_model_replaced_callback = Callable(self, "_on_model_replaced")
	_status_callback = Callable(self, "_on_projection_status_changed")
	_bridge_invalidated_callback = Callable(self, "_on_bridge_invalidated")
	_bridge.snapshot_projected.connect(_snapshot_callback)
	_bridge.model_replaced.connect(_model_replaced_callback)
	_bridge.projection_status_changed.connect(_status_callback)
	_bridge.binding_invalidated.connect(_bridge_invalidated_callback)


func _disconnect_bridge_signals() -> void:
	if _bridge == null or not is_instance_valid(_bridge):
		_snapshot_callback = Callable()
		_model_replaced_callback = Callable()
		_status_callback = Callable()
		_bridge_invalidated_callback = Callable()
		return
	if _snapshot_callback.is_valid() \
			and _bridge.snapshot_projected.is_connected(_snapshot_callback):
		_bridge.snapshot_projected.disconnect(_snapshot_callback)
	if _model_replaced_callback.is_valid() \
			and _bridge.model_replaced.is_connected(_model_replaced_callback):
		_bridge.model_replaced.disconnect(_model_replaced_callback)
	if _status_callback.is_valid() \
			and _bridge.projection_status_changed.is_connected(_status_callback):
		_bridge.projection_status_changed.disconnect(_status_callback)
	if _bridge_invalidated_callback.is_valid() \
			and _bridge.binding_invalidated.is_connected(_bridge_invalidated_callback):
		_bridge.binding_invalidated.disconnect(_bridge_invalidated_callback)
	_snapshot_callback = Callable()
	_model_replaced_callback = Callable()
	_status_callback = Callable()
	_bridge_invalidated_callback = Callable()


func _on_snapshot_projected(scope: StringName, inventory_id: int, revision: int) -> void:
	if lifecycle != Lifecycle.BOUND or scope != SCOPE_RAID \
			or inventory_id != _player_inventory_id:
		return
	if not _binding_is_current():
		_invalidate_binding(&"late_snapshot_binding_invalidated")
		return
	if _bridge.confirmed_revision(SCOPE_RAID, inventory_id) != revision:
		last_error = &"snapshot_callback_revision_mismatch"
		return
	var snapshot := _bridge.confirmed_snapshot(SCOPE_RAID, inventory_id)
	reconcile_snapshot(
		SCOPE_RAID, snapshot, _owner_generation, _scope_generation)


func _on_model_replaced(
	scope: StringName,
	_model: InventoryPresentationModel,
	replacement_scope_generation: int
) -> void:
	if lifecycle != Lifecycle.BOUND or scope != SCOPE_RAID:
		return
	if replacement_scope_generation != _scope_generation:
		_invalidate_binding(&"raid_projection_generation_replaced")


func _on_projection_status_changed(scope: StringName, status: int) -> void:
	if lifecycle != Lifecycle.BOUND or scope != SCOPE_RAID:
		return
	if status != InventoryProjectionBridge.ProjectionStatus.READY:
		_invalidate_binding(&"raid_projection_not_ready")


func _on_bridge_invalidated(reason: StringName) -> void:
	if lifecycle == Lifecycle.BOUND:
		_invalidate_binding(reason if not reason.is_empty() else &"projection_bridge_invalidated")


func _binding_is_current() -> bool:
	return (
		_owner != null
		and is_instance_valid(_owner)
		and _owner.get_instance_id() == _owner_instance_id
		and _owner.is_current_generation(_owner_generation)
		and _bridge != null
		and is_instance_valid(_bridge)
		and _bridge.get_instance_id() == _bridge_instance_id
		and _bridge.is_bound()
		and _bridge.owner_generation() == _owner_generation
		and _bridge.scope_generation(SCOPE_RAID) == _scope_generation
		and _bridge.authority_for_scope(SCOPE_RAID) == _owner.raid_authority()
		and _bridge.inventory_ids(SCOPE_RAID).has(_player_inventory_id)
	)


func _snapshot_is_current_projection(snapshot: InventorySnapshotResource) -> bool:
	if not _binding_is_current():
		return false
	var confirmed := _bridge.confirmed_snapshot(SCOPE_RAID, _player_inventory_id)
	# Byte equality alone cannot prove provenance: a separate native authority
	# can deterministically produce byte-identical ids, revisions, and allocator
	# state. Only the immutable Resource instance installed by the exact bound
	# bridge is trusted at this seam; the full value comparison below remains a
	# corruption guard for that installed value.
	return confirmed != null \
		and snapshot.get_instance_id() == confirmed.get_instance_id() \
		and _snapshots_exactly_equal(snapshot, confirmed)


func _snapshots_exactly_equal(
	left: InventorySnapshotResource,
	right: InventorySnapshotResource
) -> bool:
	if left == null or right == null:
		return left == right
	return left.get_inventory_id() == right.get_inventory_id() \
		and left.get_profile_identifier() == right.get_profile_identifier() \
		and left.get_revision() == right.get_revision() \
		and left.get_manifest_fingerprint() == right.get_manifest_fingerprint() \
		and left.get_manifest_algorithm() == right.get_manifest_algorithm() \
		and left.get_visibility() == right.get_visibility() \
		and left.get_containers() == right.get_containers() \
		and left.get_items() == right.get_items() \
		and left.get_references() == right.get_references() \
		and left.hash() == right.hash() \
		and left.canonical_bytes() == right.canonical_bytes()


func _build_mappings(snapshot: InventorySnapshotResource) -> Dictionary:
	var equipment_container_id := 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if StringName(container.get("container_definition_identifier", "")) \
				!= ZerkovInventoryCatalog.CONTAINER_EQUIPMENT:
			continue
		if int(container.get("provider_item", 0)) != 0 or equipment_container_id != 0:
			return {"ok": false, "reason": &"equipment_container_invalid"}
		equipment_container_id = int(container.get("id", 0))
	if equipment_container_id <= 0:
		return {"ok": false, "reason": &"equipment_container_missing"}

	var result: Dictionary = {}
	var seen_native_items: Dictionary = {}
	var seen_weapon_ids: Dictionary = {}
	var seen_entity_ids: Dictionary = {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		var location := item.get("location", {}) as Dictionary
		if String(location.get("kind", "")) != "slot" \
				or int(location.get("container", 0)) != equipment_container_id:
			continue
		var slot := StringName(location.get("slot_identifier", ""))
		if not WEAPON_SLOTS.has(slot):
			continue
		if result.has(slot):
			return {"ok": false, "reason": &"weapon_slot_occupied_multiple_times"}
		var native_item_id := int(item.get("id", 0))
		var item_definition := StringName(item.get("item_definition_identifier", ""))
		if native_item_id <= 0 or int(item.get("quantity", 0)) != 1 \
				or seen_native_items.has(native_item_id):
			return {"ok": false, "reason": &"equipped_item_identity_invalid"}
		var content := _content_mapping(slot, item_definition)
		if content.is_empty():
			return {"ok": false, "reason": &"equipped_item_content_invalid"}
		var identities := derive_identity_keys(
			_admission,
			_owner_generation,
			_player_inventory_id,
			native_item_id,
			item_definition
		)
		if identities.is_empty():
			return {"ok": false, "reason": &"equipped_item_identity_derivation_failed"}
		var weapon_id := String(identities["weapon_id"])
		var entity_id := String(identities["entity_id"])
		if seen_weapon_ids.has(weapon_id) or seen_entity_ids.has(entity_id):
			return {"ok": false, "reason": &"equipped_item_identity_collision"}
		seen_native_items[native_item_id] = true
		seen_weapon_ids[weapon_id] = true
		seen_entity_ids[entity_id] = true
		result[slot] = {
			"slot_identifier": slot,
			"native_inventory_id": _player_inventory_id,
			"native_item_id": native_item_id,
			"item_definition_identifier": item_definition,
			"combat_definition_identifier": content["combat_definition_identifier"],
			"weapon_kind": content["weapon_kind"],
			"weapon_id": weapon_id,
			"entity_id": entity_id,
		}
	return {"ok": true, "mappings": result}


func _content_mapping(slot: StringName, item_definition: StringName) -> Dictionary:
	if slot == SLOT_PRIMARY and item_definition == ZerkovInventoryCatalog.ITEM_AKM:
		return {
			"combat_definition_identifier": ZerkovCombatContent.WEAPON_AKM,
			"weapon_kind": WEAPON_KIND_FIREARM,
		}
	if slot == SLOT_MELEE and item_definition == ZerkovInventoryCatalog.ITEM_MACHETE:
		return {
			"combat_definition_identifier": ZerkovCombatContent.WEAPON_MACHETE,
			"weapon_kind": WEAPON_KIND_MELEE,
		}
	return {}


func _mapping_delta(previous: Dictionary, next: Dictionary) -> Dictionary:
	var previous_by_weapon := _index_mappings_by_weapon(previous)
	var next_by_weapon := _index_mappings_by_weapon(next)
	var added: Array[Dictionary] = []
	var removed: Array[Dictionary] = []
	var updated: Array[Dictionary] = []
	var retained: Array[Dictionary] = []
	for slot in WEAPON_SLOTS:
		if not previous.has(slot):
			continue
		var old_mapping := previous[slot] as Dictionary
		var weapon_id := String(old_mapping.get("weapon_id", ""))
		if not next_by_weapon.has(weapon_id):
			removed.append(old_mapping.duplicate(true))
			continue
		var new_mapping := next_by_weapon[weapon_id] as Dictionary
		if old_mapping == new_mapping:
			retained.append(new_mapping.duplicate(true))
		else:
			updated.append({
				"before": old_mapping.duplicate(true),
				"after": new_mapping.duplicate(true),
			})
	for slot in WEAPON_SLOTS:
		if not next.has(slot):
			continue
		var new_mapping := next[slot] as Dictionary
		if not previous_by_weapon.has(String(new_mapping.get("weapon_id", ""))):
			added.append(new_mapping.duplicate(true))
	return {
		"changed": not added.is_empty() or not removed.is_empty() or not updated.is_empty(),
		"added": added,
		"removed": removed,
		"updated": updated,
		"retained": retained,
	}


func _index_mappings_by_weapon(mappings: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for slot in WEAPON_SLOTS:
		if not mappings.has(slot):
			continue
		var mapping := mappings[slot] as Dictionary
		result[String(mapping.get("weapon_id", ""))] = mapping
	return result


func _copy_mapping_dictionary(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for slot in WEAPON_SLOTS:
		if source.has(slot):
			result[slot] = (source[slot] as Dictionary).duplicate(true)
	return result


func _snapshot_digest(snapshot: InventorySnapshotResource) -> String:
	var bytes := snapshot.canonical_bytes()
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _duplicate_result() -> Dictionary:
	var result := current_outcome()
	result["accepted"] = true
	result["changed"] = false
	result["duplicate"] = true
	result["initial"] = false
	result["reason"] = &"duplicate_snapshot"
	result["added"] = []
	result["removed"] = []
	result["updated"] = []
	result["retained"] = current_mappings()
	return result


func _rejection(reason: StringName) -> Dictionary:
	last_error = reason
	return {
		"accepted": false,
		"changed": false,
		"duplicate": false,
		"initial": false,
		"invalidated": false,
		"reason": reason,
		"owner_generation": _owner_generation,
		"scope_generation": _scope_generation,
		"inventory_id": _player_inventory_id,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"mappings": current_mappings(),
		"added": [],
		"removed": [],
		"updated": [],
		"retained": current_mappings(),
	}


func _invalidate_binding(reason: StringName) -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	var final_reason := reason if not reason.is_empty() else &"reconciler_invalidated"
	if _public_signal_active:
		if _deferred_invalidation_reason.is_empty():
			_deferred_invalidation_reason = final_reason
		return
	var removed := current_mappings()
	var previous_revision := _last_revision
	var previous_digest := _last_snapshot_digest
	var context := {
		"raid_id": _admission.raid_id.canonical_key() if _admission != null else "",
		"session_id": _admission.session_id.canonical_key() if _admission != null else "",
		"actor_id": _admission.actor_id.canonical_key() if _admission != null else "",
		"authority_epoch": _admission.authority_epoch if _admission != null else 0,
		"admission_generation": _admission.generation if _admission != null else 0,
		"owner_generation": _owner_generation,
		"scope_generation": _scope_generation,
		"inventory_id": _player_inventory_id,
	}
	_disconnect_bridge_signals()
	lifecycle = Lifecycle.INVALIDATED
	_mappings_by_slot.clear()
	_last_revision = -1
	_last_snapshot_digest = ""
	_current_outcome = {
		"accepted": false,
		"changed": not removed.is_empty(),
		"duplicate": false,
		"initial": false,
		"invalidated": true,
		"reason": final_reason,
		"raid_id": context["raid_id"],
		"session_id": context["session_id"],
		"actor_id": context["actor_id"],
		"authority_epoch": context["authority_epoch"],
		"admission_generation": context["admission_generation"],
		"owner_generation": context["owner_generation"],
		"scope_generation": context["scope_generation"],
		"inventory_id": context["inventory_id"],
		"revision": previous_revision,
		"snapshot_digest": previous_digest,
		"mappings": [],
		"added": [],
		"removed": removed,
		"updated": [],
		"retained": [],
	}
	last_error = final_reason
	# Finish the old binding before notifying arbitrary listeners. A callback is
	# therefore unable to rebind and then have these cleanup writes erase the new
	# owner, bridge, or admission.
	_owner = null
	_owner_instance_id = 0
	_bridge = null
	_bridge_instance_id = 0
	_admission = null
	var published_outcome := current_outcome()
	_emit_reconciliation(published_outcome, final_reason)
	last_error = final_reason


func _reset_unbound_state() -> void:
	_disconnect_bridge_signals()
	lifecycle = Lifecycle.UNBOUND
	_owner = null
	_owner_instance_id = 0
	_bridge = null
	_bridge_instance_id = 0
	_admission = null
	_owner_generation = 0
	_scope_generation = 0
	_player_inventory_id = 0
	_last_revision = -1
	_last_snapshot_digest = ""
	_mappings_by_slot.clear()
	_current_outcome.clear()
	_deferred_invalidation_reason = &""


## Public projection events are recursively read-only. All listeners receive
## the same signal Variant, so a merely detached mutable Dictionary would let
## one listener corrupt what later listeners observe even though private state
## remained safe.
func _emit_reconciliation(
	outcome: Dictionary,
	invalidation_reason: StringName = &""
) -> void:
	var publication := outcome.duplicate(true)
	_make_deep_read_only(publication)
	_public_signal_active = true
	reconciliation_published.emit(publication)
	if not invalidation_reason.is_empty():
		binding_invalidated.emit(invalidation_reason)
	_public_signal_active = false

	if lifecycle == Lifecycle.BOUND and not _deferred_invalidation_reason.is_empty():
		var deferred_reason := _deferred_invalidation_reason
		_deferred_invalidation_reason = &""
		_invalidate_binding(deferred_reason)
	elif lifecycle != Lifecycle.BOUND:
		_deferred_invalidation_reason = &""


static func _make_deep_read_only(value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			for key in dictionary.keys():
				_make_deep_read_only(dictionary[key])
			dictionary.make_read_only()
		TYPE_ARRAY:
			var array := value as Array
			for entry in array:
				_make_deep_read_only(entry)
			array.make_read_only()


func _reject_bind(reason: StringName) -> bool:
	last_error = reason
	return false
