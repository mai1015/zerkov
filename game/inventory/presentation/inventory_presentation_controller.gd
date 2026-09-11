class_name InventoryPresentationController
extends RefCounted

## Production UI seam for the retained inventory screen.
##
## The controller deliberately has no dependency on the screen scene or on
## app.state.  It turns confirmed bridge snapshots into UI records and turns
## gestures into one, strictly-shaped ZRaidIntent at a time.  A screen may
## still use its fixture controller when this object has not been bound.

const InventoryProjectionBridge = preload("res://game/inventory/presentation/inventory_projection_bridge.gd")
const InventoryIntentAdapter = preload("res://game/inventory/inventory_intent_adapter.gd")
const ZerkovInventoryCatalog = preload("res://game/content/zerkov_inventory_catalog.gd")
const ZRaidIntent = preload("res://game/domain/z_raid_intent.gd")
const ZRequestId = preload("res://game/domain/z_request_id.gd")

signal projection_changed(scope: StringName)
signal pending_changed(scope: StringName)
signal accepted_feedback(info: Dictionary)
signal rejection_feedback(info: Dictionary)
signal status_changed(scope: StringName, status: int)
signal binding_invalidated(reason: StringName)

const SCOPE_PROFILE: StringName = &"profile"
const SCOPE_RAID: StringName = &"raid"

const SOURCE_PLAYER: StringName = &"player"
const SOURCE_POCKETS: StringName = &"pockets"
const SOURCE_RIG: StringName = &"rig"
const SOURCE_BACKPACK: StringName = &"backpack"
const SOURCE_STASH: StringName = &"stash"
const SOURCE_LOOT: StringName = &"loot"
const SOURCE_CRATE: StringName = &"crate"
const SOURCE_CORPSE: StringName = &"corpse"

const OP_MOVE: StringName = &"move"
const OP_ROTATE: StringName = &"rotate"
const OP_SPLIT: StringName = &"split"
const OP_MERGE: StringName = &"merge"
const OP_LOOT: StringName = &"loot"
const OP_QUICK: StringName = &"quick_transfer"

const REASON_UNBOUND: StringName = &"inventory_runtime_unbound"
const REASON_STALE_BINDING: StringName = &"inventory_runtime_stale_binding"
const REASON_MUTATION_UNAVAILABLE: StringName = &"inventory_mutation_unavailable"
const REASON_STALE_DRAG_TARGET: StringName = &"stale_drag_target"
const REASON_INVALID_DESTINATION: StringName = &"invalid_destination"
const REASON_CROSS_AUTHORITY_UNAVAILABLE: StringName = &"cross_authority_unavailable"
const REASON_PROFILE_READ_ONLY: StringName = &"profile_inventory_read_only"
const REASON_INVALID_SPLIT_QUANTITY: StringName = &"invalid_split_quantity"
const REASON_INVALID_MERGE_TARGET: StringName = &"invalid_merge_target"
const REASON_UNKNOWN_SOURCE: StringName = &"unknown_inventory_source"
const REASON_UNSUPPORTED_OPERATION: StringName = &"unsupported_inventory_operation"
const REASON_CATALOG_MISMATCH: StringName = &"inventory_catalog_mismatch"
const REASON_BRIDGE_MISMATCH: StringName = &"inventory_bridge_owner_mismatch"
const REASON_ADAPTER_MISMATCH: StringName = &"inventory_adapter_owner_mismatch"
const REASON_WORLD_CONTAINER_READ_ONLY: StringName = &"world_container_reposition_unavailable"
const REASON_REENTRANT_SUBMISSION: StringName = &"inventory_submission_reentrant"
const REASON_LOOT_CLOSED: StringName = &"loot_container_closed"
const REASON_LOOT_INACCESSIBLE: StringName = &"loot_container_inaccessible"
const REASON_LOOT_STALE: StringName = &"loot_container_stale"
const REASON_LOOT_OVERWEIGHT: StringName = &"loot_container_overweight"
const REASON_LOOT_RESYNCHRONIZING: StringName = &"loot_container_resynchronizing"

# Native Inventory System diagnostics are stable protocol values.  Keep the
# causal classification here at the adapter receipt boundary; presentation
# model feedback intentionally strips these native fields.
const _NATIVE_STATUS_REVISION_STALE: int = 60
const _NATIVE_DIAGNOSTIC_MASS_CAPACITY_EXCEEDED: int = 123
const _NATIVE_DIAGNOSTIC_STALE: Array[int] = [161, 163, 166]

## `closed` is a presentation-only state.  The remaining states are the
## add-on's stable container/item vocabulary, projected through this game-owned
## controller so the retained character workspace never needs to know about
## authority objects or native resource types.
const LOOT_STATE_CLOSED: StringName = &"closed"

# InventoryPresentationModel starts each new instance at 1 << 32. The bridge
# deliberately replaces that model on resync/rebind, while the owner, native
# authority, and adapter replay ledger may all remain alive. Reserve a
# product-wide range above the add-on default and carry it across controller
# instances so a replacement presentation model cannot reuse an earlier native
# command identity. Godot signal callbacks run on the main thread; reserve and
# advance this shared counter before begin_intent can publish any synchronous
# signal, so a nested controller/model cannot observe or reuse the same ID.
const PRODUCT_COMMAND_ID_BASE: int = 1 << 40
# InventoryPresentationModel increments its allocator immediately before it
# publishes pending/model signals. Leave one signed-64 value above the largest
# permitted command so that increment remains representable without wrapping.
const PRODUCT_COMMAND_ID_MAX: int = 9_223_372_036_854_775_806
static var _next_product_command_id: int = PRODUCT_COMMAND_ID_BASE

const _DEFINITIONS := {
	"pockets": "zerkov.container.player.pockets",
	"rig": "zerkov.container.player.rig",
	"backpack": "zerkov.container.player.backpack",
	"stash": "zerkov.container.profile.stash",
	"crate": "zerkov.container.world.crate",
	"corpse": "zerkov.container.world.corpse",
}

## These are display-only labels. Footprints, stack limits, and rotation support
## are read from the same authored catalog resource that builds authority.
const _PRESENTATION := {
	"zerkov.item.weapon.akm": {"name": "AKM", "kind": "weapon", "category": "rifle", "compatibility": "7.62x39"},
	"zerkov.item.weapon.machete": {"name": "Machete", "kind": "weapon", "category": "melee"},
	"zerkov.item.ammo.caliber_762x39_standard": {"name": "7.62x39 mm", "kind": "ammo", "category": "ammo", "compatibility": "7.62x39"},
	"zerkov.item.magazine.akm_30": {"name": "7.62 Magazine", "kind": "magazine", "category": "magazine", "compatibility": "7.62x39"},
	"zerkov.item.medical.bandage": {"name": "Bandage", "kind": "medical", "category": "medical"},
	"zerkov.item.medical.splint": {"name": "Splint", "kind": "medical", "category": "medical"},
	"zerkov.item.quest.supply_crate": {"name": "Supply Crate", "kind": "container", "category": "container"},
	"zerkov.item.quest.sealed_documents": {"name": "Sealed Documents", "kind": "intel", "category": "intel"},
	"zerkov.item.valuable.encrypted_drive": {"name": "Encrypted Drive", "kind": "intel", "category": "intel", "icon_placeholder": true, "icon_accessibility_label": "PLACEHOLDER ART · neutral item placeholder"},
	"zerkov.item.valuable.gold_watch": {"name": "Gold Watch", "kind": "valuable", "category": "valuable", "icon_placeholder": true, "icon_accessibility_label": "PLACEHOLDER ART · neutral item placeholder"},
	"zerkov.item.junk.battery": {"name": "Battery", "kind": "utility", "category": "utility"},
	"zerkov.item.junk.duct_tape": {"name": "Duct Tape", "kind": "utility", "category": "utility"},
	"zerkov.item.junk.bolts": {"name": "Bolts", "kind": "utility", "category": "utility"},
	"zerkov.item.junk.scrap_metal": {"name": "Scrap Metal", "kind": "material", "category": "material"},
	"zerkov.item.gear.rig_basic": {"name": "Rig", "kind": "container", "category": "rig"},
	"zerkov.item.gear.backpack_daypack": {"name": "Backpack", "kind": "container", "category": "backpack"},
}

## Presentation-only artwork registry.  Canonical inventory rows carry stable
## definition identifiers and native facts only; this allowlist is resolved
## after projection and is never copied back into an authority snapshot.
## The handoff sprites are nearest-filtered by the retained native slot.
const _ICON_REGISTRY := {
	"zerkov.item.weapon.akm": "res://assets/handoff/gun_ak.png",
	"zerkov.item.weapon.machete": "res://assets/handoff/gun_machete.png",
	"zerkov.item.ammo.caliber_762x39_standard": "res://assets/original/Ammo/Ammo Bullets-Standard 7.62mm.png",
	"zerkov.item.magazine.akm_30": "res://assets/handoff/ph_mag.png",
	"zerkov.item.medical.bandage": "res://assets/original/Bunker Items/Basic Bandages.png",
	"zerkov.item.medical.splint": "res://assets/original/Bunker Items/Splint.png",
	"zerkov.item.quest.supply_crate": "res://assets/handoff/item_box.png",
	"zerkov.item.quest.sealed_documents": "res://assets/handoff/item_book.png",
	# No approved local art semantically depicts an encrypted drive or a gold
	# watch. Keep the stable item identity/name/category and mark a neutral
	# existing handoff tile as placeholder art instead of mislabeling another
	# object.
	"zerkov.item.valuable.encrypted_drive": "res://assets/handoff/item_box.png",
	"zerkov.item.valuable.gold_watch": "res://assets/handoff/item_box.png",
	"zerkov.item.junk.battery": "res://assets/handoff/item_battery.png",
	"zerkov.item.junk.duct_tape": "res://assets/handoff/item_tape.png",
	"zerkov.item.junk.bolts": "res://assets/handoff/item_parts.png",
	"zerkov.item.junk.scrap_metal": "res://assets/original/inventory items/Metal.png",
	"zerkov.item.gear.rig_basic": "res://assets/handoff/item_rig.png",
	"zerkov.item.gear.backpack_daypack": "res://assets/handoff/ph_backpack.png",
}
const _ICON_FALLBACK := "res://assets/handoff/item_box.png"

var _owner: RaidInventoryOwner
var _bridge: InventoryProjectionBridge
var _adapter: InventoryIntentAdapter
var _admission: ZSessionAdmission
var _owner_generation: int = 0
var _active := false
var _loot_source: StringName = SOURCE_CRATE
var _request_serial: int = 1
var _sequence: int = 1
var _target_tick: int = 1
var _model_connections: Dictionary = {}
## Explicit source routing is rebuilt for every owner-generation binding. The
## native inventory allocator may reuse the same integer in profile and raid
## authorities, so a raw inventory id is never used as the routing key.
var _source_bindings: Dictionary = {}
var _container_dimensions: Dictionary = {}
var _item_facts: Dictionary = {}
var _canonical_manifest_fingerprint: int = 0
var _canonical_catalog_ready := false
var _request_namespace: String = ""
## Changes on every bind/unbind boundary. Submission code captures this token
## before invoking any synchronous presentation or authority callback.
var _binding_serial: int = 0
var _submission_active := false
var _loot_open := false
var _loot_state_hint: StringName = &""
var _loot_state_hint_causal: Dictionary = {}

var last_error: StringName = &""


func _init() -> void:
	_request_namespace = str(get_instance_id())
	_load_canonical_catalog_facts()


func bind(owner: RaidInventoryOwner, bridge: InventoryProjectionBridge, adapter: InventoryIntentAdapter, admission: ZSessionAdmission) -> bool:
	unbind()
	last_error = &""
	if owner == null or bridge == null or adapter == null or admission == null:
		return _fail_bind(REASON_UNBOUND)
	if not owner.is_current_generation(owner.generation()):
		return _fail_bind(REASON_STALE_BINDING)
	if not admission.is_usable():
		return _fail_bind(REASON_MUTATION_UNAVAILABLE)
	if not _canonical_catalog_ready or owner.catalog() == null \
			or owner.catalog().manifest_fingerprint() != _canonical_manifest_fingerprint:
		return _fail_bind(REASON_CATALOG_MISMATCH)
	if not _adapter_matches(owner, adapter, admission):
		return _fail_bind(REASON_ADAPTER_MISMATCH)

	_owner = owner
	_bridge = bridge
	_adapter = adapter
	_admission = admission.snapshot()
	_owner_generation = owner.generation()
	_configure_source_bindings()
	_active = true
	_connect_bridge()
	_connect_adapter()

	if not bridge.is_bound():
		if not bridge.bind_owner(owner, _owner_generation):
			unbind()
			return _fail_bind(REASON_STALE_BINDING)
	elif bridge.owner_generation() != _owner_generation:
		unbind()
		return _fail_bind(REASON_STALE_BINDING)
	if not _bridge_matches_owner():
		unbind()
		return _fail_bind(REASON_BRIDGE_MISMATCH)

	_bind_model(SCOPE_PROFILE, bridge.presentation_model(SCOPE_PROFILE))
	_bind_model(SCOPE_RAID, bridge.presentation_model(SCOPE_RAID))
	return true


func unbind() -> void:
	_loot_open = false
	_clear_loot_state_hint()
	_binding_serial += 1
	if _bridge != null:
		_disconnect_bridge()
	if _adapter != null:
		_disconnect_adapter()
	for scope in _model_connections.keys():
		_disconnect_model(StringName(scope))
	_model_connections.clear()
	_owner = null
	_bridge = null
	_adapter = null
	_admission = null
	_owner_generation = 0
	_source_bindings.clear()
	_active = false


func is_bound() -> bool:
	return _active and _owner != null and _bridge != null and _adapter != null and _admission != null


func current_owner_generation() -> int:
	return _owner_generation


func set_loot_container(source: StringName) -> bool:
	if source != SOURCE_CRATE and source != SOURCE_CORPSE:
		return false
	var source_changed := _loot_source != source
	if source_changed and _loot_open:
		close_loot_container()
	if source_changed:
		# A hint is causal to one exact world inventory/generation.  Switching
		# sources is the only presentation action allowed to discard it; closing
		# and reopening the same source must retain an unchanged rejection.
		_clear_loot_state_hint()
	_loot_source = source
	projection_changed.emit(SCOPE_RAID)
	return true


func loot_container() -> StringName:
	return _loot_source


## Opens the selected world container in the existing character workspace.
## This is deliberately presentation-only: it selects a projected source and
## never advances a clock, starts discovery, or mutates an authority.
func open_loot_container() -> bool:
	if _loot_source != SOURCE_CRATE and _loot_source != SOURCE_CORPSE:
		last_error = REASON_UNKNOWN_SOURCE
		return false
	if not _binding_is_current():
		last_error = REASON_STALE_BINDING
		# A retained open screen is allowed to render DISCONNECTED after a live
		# binding is lost, but a new open cannot authorize any interaction.
		return false
	_loot_open = true
	projection_changed.emit(SCOPE_RAID)
	return true


## Closes the selected world container while leaving canonical snapshots and
## the retained character workspace untouched.  The next open must validate a
## fresh source descriptor before any gesture can submit.
func close_loot_container() -> bool:
	var changed := _loot_open
	_loot_open = false
	if changed:
		projection_changed.emit(SCOPE_RAID)
	return true


func is_loot_container_open() -> bool:
	return _loot_open


func loot_container_state() -> StringName:
	if not _loot_open:
		return LOOT_STATE_CLOSED
	if not _binding_is_current() or _bridge == null:
		return InventoryPresentationModel.STATE_DISCONNECTED

	var status := _bridge.scope_status(SCOPE_RAID)
	match status:
		InventoryProjectionBridge.ProjectionStatus.DISCONNECTED, InventoryProjectionBridge.ProjectionStatus.UNBOUND:
			return InventoryPresentationModel.STATE_DISCONNECTED
		InventoryProjectionBridge.ProjectionStatus.RESYNCHRONIZING, InventoryProjectionBridge.ProjectionStatus.LOADING:
			return InventoryPresentationModel.STATE_RESYNCHRONIZING

	var policy := world_policy_state(_inventory_id_for_source(_loot_source))
	if not bool(policy.get("available", false)):
		return InventoryPresentationModel.STATE_INACCESSIBLE
	if _loot_carry_overweight():
		return InventoryPresentationModel.STATE_OVERWEIGHT
	# Live policy and canonical mass facts outrank a historical rejection hint.
	# The hint is only a presentation hold while every causal source/destination
	# snapshot remains the exact generation/revision observed by the native
	# receipt.
	if status == InventoryProjectionBridge.ProjectionStatus.STALE:
		return InventoryPresentationModel.STATE_STALE_CORRECTED
	if not _loot_state_hint.is_empty():
		if _loot_hint_is_current():
			return _loot_state_hint
		_clear_loot_state_hint()
	var descriptor_value := descriptor(SOURCE_LOOT)
	if not bool(descriptor_value.get("available", false)):
		return InventoryPresentationModel.STATE_INACCESSIBLE
	return InventoryPresentationModel.STATE_NORMAL


func loot_status_text() -> String:
	if not _loot_open:
		return "STASH"
	match loot_container_state():
		InventoryPresentationModel.STATE_NORMAL:
			return "READY · %s OPEN" % String(_loot_source).to_upper()
		InventoryPresentationModel.STATE_INACCESSIBLE:
			return "INACCESSIBLE · ACCESS NOT CONFIRMED"
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "STALE · REFRESH REQUIRED"
		InventoryPresentationModel.STATE_OVERWEIGHT:
			return "OVERWEIGHT · CARRY CAPACITY EXCEEDED"
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "DISCONNECTED · AUTHORITY UNAVAILABLE"
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "RESYNC · WAITING FOR CONFIRMED SNAPSHOT"
		InventoryPresentationModel.STATE_LOADING:
			return "LOADING · WAITING FOR SNAPSHOT"
	return "LOOT · PRESENTATION ONLY"


func loot_status_detail() -> String:
	if not _loot_open:
		return "Stash remains in the retained character workspace."
	match loot_container_state():
		InventoryPresentationModel.STATE_NORMAL:
			return "Confirmed raid projection · search and inspection are presentation-only."
		InventoryPresentationModel.STATE_INACCESSIBLE:
			return "Range, visibility, access, or world-container liveness is not confirmed."
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "The previous gesture was stale; wait for a newer confirmed projection."
		InventoryPresentationModel.STATE_OVERWEIGHT:
			return "Carry capacity is exceeded; no item was removed or partially transferred."
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "Inventory authority is disconnected; existing UI data is informational only."
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "Waiting for a coherent replacement snapshot; mutations are paused."
	return "Loot presentation is read-only until a confirmed state is available."


func loot_mutation_available() -> bool:
	return _loot_open and loot_container_state() == InventoryPresentationModel.STATE_NORMAL \
		and mutation_available(SOURCE_LOOT)


func loot_search_available() -> bool:
	return _loot_open


## Read-only policy projection used by the retained UI.  It is deliberately
## separate from `_world_policy_rejection`, which also checks a specific item
## and destination for an authoritative mutation.
func world_policy_state(inventory_id: int) -> Dictionary:
	if not is_bound() or _adapter == null or inventory_id <= 0:
		return {
			"available": false,
			"reason": REASON_UNBOUND,
			"inventory_id": inventory_id,
			"distance_raw": -1,
			"access": ZInventoryWorldPolicyPort.ACCESS_UNAVAILABLE,
		}
	return _adapter.world_policy_state(inventory_id)


func _loot_carry_overweight() -> bool:
	if _owner == null or not is_instance_valid(_owner):
		return false
	var authority := _owner.raid_authority()
	if authority == null or not is_instance_valid(authority) \
		or not authority.has_method(&"container_mass") \
		or not authority.has_method(&"container_mass_capacity"):
		return false
	# Mass/capacity are read-only authority queries.  A container is considered
	# overweight only when the canonical mass already exceeds its authored
	# capacity; this never predicts a transfer or removes an item locally.
	for source in [SOURCE_POCKETS, SOURCE_RIG, SOURCE_BACKPACK]:
		var target := descriptor(source)
		if int(target.get("inventory_id", 0)) <= 0 or int(target.get("container_id", 0)) <= 0:
			continue
		var mass: Dictionary = authority.container_mass(
			int(target.inventory_id), int(target.container_id))
		var capacity: Dictionary = authority.container_mass_capacity(
			int(target.inventory_id), int(target.container_id))
		if bool(mass.get("ok", false)) and bool(capacity.get("ok", false)) \
			and int(capacity.get("mass_capacity_mg", 0)) > 0 \
			and int(mass.get("mass_mg", 0)) > int(capacity.get("mass_capacity_mg", 0)):
			return true
	return false


func _loot_source_block_reason(source: StringName) -> StringName:
	if source != SOURCE_LOOT:
		return &""
	match loot_container_state():
		LOOT_STATE_CLOSED:
			return REASON_LOOT_CLOSED
		InventoryPresentationModel.STATE_INACCESSIBLE:
			return REASON_LOOT_INACCESSIBLE
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return REASON_LOOT_STALE
		InventoryPresentationModel.STATE_OVERWEIGHT:
			return REASON_LOOT_OVERWEIGHT
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return REASON_LOOT_RESYNCHRONIZING
		InventoryPresentationModel.STATE_DISCONNECTED:
			return REASON_UNBOUND
	return &""


func scope_for_source(source: StringName) -> StringName:
	var key := _canonical_source(source)
	var binding: Variant = _source_bindings.get(String(key), null)
	if binding is Dictionary:
		return StringName((binding as Dictionary).get("scope", ""))
	# Keep pre-bind routing deterministic for diagnostics. Usable paths still
	# require the explicit binding table created by bind().
	if key == SOURCE_STASH:
		return SCOPE_PROFILE
	if key == SOURCE_POCKETS or key == SOURCE_RIG or key == SOURCE_BACKPACK or key == SOURCE_CRATE or key == SOURCE_CORPSE:
		return SCOPE_RAID
	return &""


func descriptor(source: StringName) -> Dictionary:
	var key := _canonical_source(source)
	var scope := scope_for_source(key)
	var result := {
		"source": key,
		"scope": scope,
		"inventory_id": 0,
		"container_id": 0,
		"container_definition_identifier": String(_DEFINITIONS.get(String(key), "")),
		"columns": 0,
		"rows": 0,
		"owner_generation": _owner_generation,
		"scope_generation": 0,
		"mapping_key": "",
		"available": false,
		"reason": REASON_UNBOUND,
	}
	if not is_bound() or scope == &"":
		return result
	if not _binding_is_current():
		result.reason = REASON_STALE_BINDING
		return result
	var binding: Dictionary = _source_bindings.get(String(key), {}) as Dictionary
	var inventory_id := int(binding.get("inventory_id", 0))
	result.inventory_id = inventory_id
	result.scope_generation = _bridge.scope_generation(scope)
	result.mapping_key = _mapping_key(scope, _owner_generation, inventory_id, 0)
	var dimensions := _container_size(String(result.container_definition_identifier))
	result.columns = dimensions.x
	result.rows = dimensions.y
	if inventory_id <= 0:
		result.reason = REASON_UNKNOWN_SOURCE
		return result
	if binding.is_empty() or StringName(binding.get("scope", "")) != scope:
		result.reason = REASON_UNKNOWN_SOURCE
		return result
	var snapshot: InventorySnapshotResource = _bridge.confirmed_snapshot(scope, inventory_id)
	var container_definition := String(binding.get("container_definition_identifier", _DEFINITIONS.get(String(key), "")))
	result.container_definition_identifier = container_definition
	var container_id := _find_container_id(snapshot, container_definition)
	result.container_id = container_id
	result.mapping_key = _mapping_key(scope, _owner_generation, inventory_id, container_id)
	if container_id <= 0:
		result.reason = REASON_UNKNOWN_SOURCE
		return result
	var status := _bridge.scope_status(scope)
	result.available = status == InventoryProjectionBridge.ProjectionStatus.READY
	result.reason = &"" if result.available else _status_reason(status)
	return result


func grid_size(source: StringName) -> Vector2i:
	var key := _canonical_source(source)
	return _container_size(String(_DEFINITIONS.get(String(key), "")))


func mutation_available(source: StringName) -> bool:
	var scope := scope_for_source(source)
	if scope == &"" or not _binding_is_current():
		return false
	if scope == SCOPE_PROFILE:
		# The approved adapter is raid-authority scoped.  Profile inventory is
		# still projected for inspection, but never receives a raid command.
		return false
	return _bridge.scope_status(scope) == InventoryProjectionBridge.ProjectionStatus.READY


func split_available(source: StringName, target: StringName) -> bool:
	var source_key := _canonical_source(source)
	var target_key := _canonical_source(target)
	var source_desc := descriptor(source_key)
	var target_desc := descriptor(target_key)
	return _can_submit(source_desc, target_desc) \
		and source_desc.scope == SCOPE_RAID \
		and source_desc.scope == target_desc.scope \
		and int(source_desc.inventory_id) == int(target_desc.inventory_id) \
		and _is_actor_owned_source(source_key) \
		and _is_actor_owned_source(target_key)


func quick_transfer_available(source: StringName) -> bool:
	if source == SOURCE_LOOT and not loot_mutation_available():
		return false
	var source_key := _canonical_source(source)
	var source_desc := descriptor(source_key)
	var player_desc := descriptor(SOURCE_PLAYER)
	return _can_submit(source_desc, player_desc) \
		and source_desc.scope == SCOPE_RAID \
		and player_desc.scope == SCOPE_RAID \
		and int(source_desc.inventory_id) != int(player_desc.inventory_id) \
		and (source_key == SOURCE_CRATE or source_key == SOURCE_CORPSE)


func scope_ready(source: StringName) -> bool:
	var scope := scope_for_source(source)
	if scope == &"" or not _binding_is_current():
		return false
	return _bridge.scope_status(scope) == InventoryProjectionBridge.ProjectionStatus.READY


func status_reason(source: StringName) -> StringName:
	var scope := scope_for_source(source)
	if scope == &"":
		return REASON_UNKNOWN_SOURCE
	if not is_bound():
		return REASON_UNBOUND
	if not _binding_is_current():
		return REASON_STALE_BINDING
	if scope == SCOPE_PROFILE and _bridge.scope_status(scope) == InventoryProjectionBridge.ProjectionStatus.READY:
		return REASON_PROFILE_READ_ONLY
	return _status_reason(_bridge.scope_status(scope))


func items_for(source: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var desc := descriptor(source)
	if not bool(desc.available) and int(desc.container_id) <= 0:
		return result
	var scope: StringName = desc.scope
	var inventory_id := int(desc.inventory_id)
	var snapshot: InventorySnapshotResource = _bridge.confirmed_snapshot(scope, inventory_id)
	if snapshot == null:
		return result
	var model := _bridge.presentation_model(scope)
	for raw_item in snapshot.get_items():
		if not raw_item is Dictionary:
			continue
		var raw: Dictionary = raw_item
		var item_id := int(raw.get("id", 0))
		var location: Dictionary = raw.get("location", {})
		if item_id <= 0 or String(location.get("kind", "")) != "spatial":
			continue
		if int(location.get("container", 0)) != int(desc.container_id):
			continue
		var definition := String(raw.get("item_definition_identifier", ""))
		var meta := _presentation_for(definition)
		var rotated := bool(location.get("rotated", false))
		var base_size := Vector2i(int(meta.get("w", 1)), int(meta.get("h", 1)))
		var footprint := Vector2i(base_size.y, base_size.x) if rotated else base_size
		var kind := String(meta.get("kind", "item"))
		var category := String(meta.get("category", "item"))
		if kind == "weapon":
			category = "guns"
		elif kind != "ammo" and kind != "armor" and kind != "clothing" and kind != "food":
			category = "util"
		var item := {
			# `id` is intentionally the native integer identity.  The retained
			# fixture UI used strings, but those are never valid in this path.
			"id": item_id,
			"item_id": item_id,
			"inventory_id": inventory_id,
			"container_id": int(desc.container_id),
			"scope": scope,
			"owner_generation": _owner_generation,
			"scope_generation": int(desc.scope_generation),
			"mapping_key": _mapping_key(scope, _owner_generation, inventory_id, int(desc.container_id)),
			"item_definition_identifier": definition,
			"definition_id": definition,
			# Artwork is resolved from the presentation registry above; canonical
			# snapshot rows never carry this display-only field.
			"icon": String(meta.get("icon", _ICON_FALLBACK)),
			"icon_placeholder": bool(meta.get("icon_placeholder", false)),
			"icon_accessibility_label": String(meta.get("icon_accessibility_label", "")),
			"quantity": int(raw.get("quantity", 1)),
			"count": int(raw.get("quantity", 1)),
			"x": int(location.get("x", 0)),
			"y": int(location.get("y", 0)),
			"rotated": rotated,
			"width": footprint.x,
			"height": footprint.y,
			"w": footprint.x,
			"h": footprint.y,
			"base_width": base_size.x,
			"base_height": base_size.y,
			"max_stack": int(meta.get("max_stack", 1)),
			"merge_key": definition,
			"name": String(meta.get("name", definition)),
			"short": String(meta.get("short", meta.get("kind", "item"))).to_upper(),
			"kind": kind,
			"category": category,
			"compatibility": String(meta.get("compatibility", "")),
			"rotatable": bool(meta.get("rotatable", false)),
			"location": {
				"kind": "spatial",
				"container": int(desc.container_id),
				"x": int(location.get("x", 0)),
				"y": int(location.get("y", 0)),
				"rotated": rotated,
			},
		}
		if model != null:
			item["state"] = model.item_state(inventory_id, item_id)
		result.append(item)
	return result


func select(source: StringName, item_id: int) -> bool:
	var desc := descriptor(source)
	if int(desc.inventory_id) <= 0 or _bridge == null:
		return false
	var model := _bridge.presentation_model(desc.scope)
	if model == null:
		return false
	model.select(int(desc.inventory_id), item_id)
	return true


func hover(source: StringName, item_id: int, hovering: bool = true) -> bool:
	var desc := descriptor(source)
	if int(desc.inventory_id) <= 0 or _bridge == null:
		return false
	var model := _bridge.presentation_model(desc.scope)
	if model == null:
		return false
	var current := model.get_hover()
	var matches := int(current.get("inventory_id", -1)) == int(desc.inventory_id) \
		and int(current.get("item_id", -1)) == item_id
	if hovering:
		# Native Controls can publish mouse_entered synchronously while their
		# presentation is being reconciled. An unchanged hover is not a model
		# transition and must not recursively refresh the retained screen.
		if matches:
			return true
		model.set_hover(int(desc.inventory_id), item_id)
	elif matches:
		# A late leave from an older slot must not clear a newer slot's hover.
		model.clear_hover()
	return true


func submit_drop(source: StringName, target: StringName, item: Dictionary, destination: Vector2i, mode: StringName = OP_MOVE, merge_target_item_id: int = 0, split_quantity: int = 0) -> Dictionary:
	if _submission_active:
		return _rejection_result(REASON_REENTRANT_SUBMISSION, mode)
	last_error = &""
	var presentation_reason := _loot_source_block_reason(source)
	if not presentation_reason.is_empty():
		return _reject(presentation_reason, mode)
	var source_key := _canonical_source(source)
	var target_key := _canonical_source(target)
	var source_desc := descriptor(source_key)
	var target_desc := descriptor(target_key)
	if not _can_submit(source_desc, target_desc):
		return _reject(_reason_for_unavailable(source_desc, target_desc), mode)
	if source_desc.scope != target_desc.scope:
		return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, mode)
	if mode != OP_MOVE and mode != OP_SPLIT and mode != OP_MERGE:
		return _reject(REASON_UNSUPPORTED_OPERATION, mode)
	if not _valid_live_item(item, source_desc):
		return _reject(REASON_STALE_DRAG_TARGET, mode)
	if destination.x < 0 or destination.y < 0 or destination.x >= int(target_desc.columns) or destination.y >= int(target_desc.rows):
		return _reject(REASON_INVALID_DESTINATION, mode)

	var source_inventory := int(source_desc.inventory_id)
	var target_inventory := int(target_desc.inventory_id)
	var source_item_id := int(item.get("item_id", item.get("id", 0)))
	var current_item := _item_for_source(source_key, source_item_id)
	if current_item.is_empty():
		return _reject(REASON_STALE_DRAG_TARGET, mode)
	var expected_source_revision := _bridge.confirmed_revision(source_desc.scope, source_inventory)
	var same_inventory: bool = source_inventory == target_inventory and source_desc.scope == target_desc.scope
	# World inventories are transferable sources, not actor-owned workspaces.
	# Reposition/rotate/split/merge in-place would inevitably fail the adapter's
	# ownership gate, so reject before creating a pending ghost or request.
	if same_inventory and source_desc.scope == SCOPE_RAID and not _is_actor_owned_source(source_key):
		return _reject(REASON_WORLD_CONTAINER_READ_ONLY, mode)
	if mode == OP_MERGE:
		var merge_target := _item_for_source(target_key, merge_target_item_id)
		if not same_inventory or not _merge_candidate(current_item, merge_target, destination):
			return _reject(REASON_INVALID_MERGE_TARGET, mode)
		return _submit(source_desc.scope, InventoryIntentAdapter.INTENT_KIND_MERGE, {
			"inventory_command_id": 0,
			"inventory_id": source_inventory,
			"source_item_id": source_item_id,
			"destination_item_id": merge_target_item_id,
			"expected_revision": expected_source_revision,
		}, [source_item_id, merge_target_item_id], mode, source_inventory)

	if mode == OP_SPLIT:
		var quantity := split_quantity
		var current_quantity := int(current_item.get("quantity", current_item.get("count", 0)))
		if not same_inventory or quantity <= 0 or quantity >= current_quantity:
			return _reject(REASON_INVALID_SPLIT_QUANTITY, mode)
		if not _fits_target(target_key, current_item, destination, source_item_id):
			return _reject(REASON_INVALID_DESTINATION, mode)
		var split_location := _location(target_desc, destination, bool(current_item.get("rotated", false)))
		return _submit(source_desc.scope, InventoryIntentAdapter.INTENT_KIND_SPLIT, {
			"inventory_command_id": 0,
			"inventory_id": source_inventory,
			"item_id": source_item_id,
			"quantity": quantity,
			"destination_location": split_location,
			"expected_revision": expected_source_revision,
		}, [source_item_id], mode, source_inventory)

	if source_inventory != target_inventory:
		if source_key != SOURCE_CRATE and source_key != SOURCE_CORPSE and source_key != SOURCE_LOOT:
			return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, mode)
		if target_desc.scope != SCOPE_RAID or not _is_actor_owned_source(target_key):
			return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, mode)
		if not _fits_target(target_key, current_item, destination, source_item_id):
			return _reject(REASON_INVALID_DESTINATION, mode)
		var loot_location := _location(target_desc, destination, bool(current_item.get("rotated", false)))
		return _submit(SCOPE_RAID, InventoryIntentAdapter.INTENT_KIND_LOOT, {
			"inventory_command_id": 0,
			"source_inventory_id": source_inventory,
			"destination_inventory_id": target_inventory,
			"item_id": source_item_id,
			"destination_location": loot_location,
			"expected_source_revision": expected_source_revision,
			"expected_destination_revision": _bridge.confirmed_revision(target_desc.scope, target_inventory),
		}, [source_item_id], OP_LOOT, source_inventory)

	if source_desc.scope != SCOPE_RAID and source_desc.scope != SCOPE_PROFILE:
		return _reject(REASON_UNKNOWN_SOURCE, mode)
	if not _fits_target(target_key, current_item, destination, source_item_id):
		return _reject(REASON_INVALID_DESTINATION, mode)
	var location := _location(target_desc, destination, bool(current_item.get("rotated", false)))
	return _submit(source_desc.scope, InventoryIntentAdapter.INTENT_KIND_MOVE, {
		"inventory_command_id": 0,
		"inventory_id": source_inventory,
		"item_id": source_item_id,
		"destination_location": location,
		"expected_revision": expected_source_revision,
	}, [source_item_id], mode, source_inventory)


func submit_rotate(source: StringName, item: Dictionary) -> Dictionary:
	if _submission_active:
		return _rejection_result(REASON_REENTRANT_SUBMISSION, OP_ROTATE)
	last_error = &""
	var source_key := _canonical_source(source)
	var desc := descriptor(source_key)
	if not _can_submit(desc, desc):
		return _reject(_reason_for_unavailable(desc, desc), OP_ROTATE)
	if not _valid_live_item(item, desc):
		return _reject(REASON_STALE_DRAG_TARGET, OP_ROTATE)
	var item_id := int(item.get("item_id", item.get("id", 0)))
	var current_item := _item_for_source(source_key, item_id)
	if current_item.is_empty():
		return _reject(REASON_STALE_DRAG_TARGET, OP_ROTATE)
	if desc.scope == SCOPE_RAID and not _is_actor_owned_source(source_key):
		return _reject(REASON_WORLD_CONTAINER_READ_ONLY, OP_ROTATE)
	if not bool(current_item.get("rotatable", false)):
		return _reject(&"item_not_rotatable", OP_ROTATE)
	return _submit(desc.scope, InventoryIntentAdapter.INTENT_KIND_ROTATE, {
		"inventory_command_id": 0,
		"inventory_id": int(desc.inventory_id),
		"item_id": item_id,
		"rotated": not bool(current_item.get("rotated", false)),
		"expected_revision": _bridge.confirmed_revision(desc.scope, int(desc.inventory_id)),
	}, [item_id], OP_ROTATE, int(desc.inventory_id))


func submit_quick(source: StringName, item: Dictionary) -> Dictionary:
	if _submission_active:
		return _rejection_result(REASON_REENTRANT_SUBMISSION, OP_QUICK)
	last_error = &""
	var presentation_reason := _loot_source_block_reason(source)
	if not presentation_reason.is_empty():
		return _reject(presentation_reason, OP_QUICK)
	var source_key := _canonical_source(source)
	var source_desc := descriptor(source_key)
	if not _can_submit(source_desc, source_desc):
		return _reject(_reason_for_unavailable(source_desc, source_desc), OP_QUICK)
	if source_desc.scope == SCOPE_PROFILE:
		return _reject(REASON_PROFILE_READ_ONLY, OP_QUICK)
	if not _valid_live_item(item, source_desc):
		return _reject(REASON_STALE_DRAG_TARGET, OP_QUICK)
	var player_desc := descriptor(SOURCE_PLAYER)
	if int(player_desc.inventory_id) <= 0:
		player_desc = descriptor(SOURCE_POCKETS)
	if int(player_desc.inventory_id) <= 0 or player_desc.scope != SCOPE_RAID:
		return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, OP_QUICK)
	if source_desc.scope != SCOPE_RAID or int(source_desc.inventory_id) == int(player_desc.inventory_id):
		return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, OP_QUICK)
	var source_inventory := int(source_desc.inventory_id)
	var target_inventory := int(player_desc.inventory_id)
	var item_id := int(item.get("item_id", item.get("id", 0)))
	return _submit(SCOPE_RAID, InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER, {
		"inventory_command_id": 0,
		"source_inventory_id": source_inventory,
		"destination_inventory_id": target_inventory,
		"item_id": item_id,
		"expected_source_revision": _bridge.confirmed_revision(SCOPE_RAID, source_inventory),
		"expected_destination_revision": _bridge.confirmed_revision(SCOPE_RAID, target_inventory),
	}, [item_id], OP_QUICK, source_inventory)


func _submit(scope: StringName, kind: StringName, payload: Dictionary, item_ids: Array, operation: StringName, pending_inventory_id: int) -> Dictionary:
	if _submission_active:
		return _rejection_result(REASON_REENTRANT_SUBMISSION, operation)
	_submission_active = true
	var result := _submit_once(
		scope, kind, payload.duplicate(true), item_ids.duplicate(), operation,
		pending_inventory_id)
	_submission_active = false
	return result


func _submit_once(scope: StringName, kind: StringName, payload: Dictionary, item_ids: Array, operation: StringName, pending_inventory_id: int) -> Dictionary:
	if not _binding_is_current():
		return _reject(REASON_STALE_BINDING, operation)
	if scope == SCOPE_PROFILE:
		return _reject(REASON_PROFILE_READ_ONLY, operation)
	var context := _capture_submission_context(scope)
	var captured_bridge: InventoryProjectionBridge = context.get("bridge")
	var captured_adapter: InventoryIntentAdapter = context.get("adapter")
	var captured_admission: ZSessionAdmission = context.get("admission")
	var captured_model: InventoryPresentationModel = context.get("model")
	var scope_generation := int(context.get("scope_generation", 0))
	if captured_bridge == null or captured_adapter == null or captured_admission == null \
			or captured_model == null:
		return _reject(REASON_STALE_BINDING, operation)
	if captured_bridge.scope_status(scope) != InventoryProjectionBridge.ProjectionStatus.READY:
		return _reject(_status_reason(captured_bridge.scope_status(scope)), operation)
	var pending_id := _begin_product_pending_intent(captured_bridge, captured_model,
		scope, kind, {
		"inventory_id": pending_inventory_id,
		"items": item_ids,
		"ghost_placement": payload.get("destination_location", {}),
	}, int(context.get("owner_generation", 0)), scope_generation)
	if pending_id <= 0:
		return _reject(REASON_MUTATION_UNAVAILABLE, operation)
	# begin_pending_intent emits pending/model signals synchronously. A listener
	# may unbind or replace every controller dependency before control returns.
	# Cancel through the captured model and never continue into the replacement.
	if not _submission_context_is_current(context):
		_cancel_captured_pending(context, pending_id)
		return _lifecycle_rejection(operation, pending_id)
	payload["inventory_command_id"] = pending_id
	# Include the controller Object identity so a newly-created retained screen
	# cannot reuse an earlier screen's request id against the same adapter ledger.
	var request_id := ZRequestId.from_parts(PackedStringArray([
		"ui", "inventory", str(_owner_generation), _request_namespace,
		String(scope), str(_request_serial),
	]))
	_request_serial += 1
	var intent := ZRaidIntent.create(
		request_id,
		ZRaidIntent.Source.PLAYER,
		captured_admission.session_id,
		captured_admission.actor_id,
		captured_admission.authority_epoch,
		captured_admission.generation,
		_target_tick,
		_sequence,
		kind,
		payload,
	)
	_sequence += 1
	_target_tick += 1
	if intent == null or not _submission_context_is_current(context):
		_cancel_captured_pending(context, pending_id)
		return _lifecycle_rejection(operation, pending_id)
	# The adapter reference is captured. If a synchronous authority/result
	# listener replaces the controller binding, this command can only finish on
	# the original adapter/owner and cannot fall through to the replacement.
	var result: Dictionary = captured_adapter.submit_intent(intent)
	if result.is_empty():
		result = _rejection_result(REASON_MUTATION_UNAVAILABLE, operation)
		# Correlate the synthetic failure to the pending record we just created;
		# otherwise an impossible/empty adapter response would leave a ghost alive
		# until its TTL despite the submission already being finished.
		result["inventory_command_id"] = pending_id
		result["command_id"] = pending_id
	else:
		result = result.duplicate(true)
		result["ui_operation"] = operation
		result["ui_scope"] = scope
		result["ui_pending_command_id"] = pending_id
	# Capture native causal metadata before applying the result to the
	# presentation model.  Model feedback is intentionally recipient-safe and
	# strips inventory ids/revision pairs, so it cannot be the source of a
	# persistent loot-state latch.
	_capture_loot_causal_result(result, payload, context, operation)
	if _submission_context_is_current(context) \
			and not bool(result.get("accepted", false)) \
			and not bool(result.get("queued", false)):
		last_error = StringName(result.get("reason", REASON_MUTATION_UNAVAILABLE))
	# Authority-accepted results are resolved by the bridge after every affected
	# snapshot has refreshed.  Only direct adapter validation failures are applied
	# here, and only while this command is still pending; this prevents duplicate
	# success/rejection feedback.
	if not captured_model.get_pending(pending_id).is_empty():
		var accepted := bool(result.get("accepted", false))
		var queued := bool(result.get("queued", false))
		if not accepted or (not queued and not _has_native_command(result)):
			# Adapter validation failures carry their stable reason at the receipt
			# top level while their native-compatible status dictionary contains
			# only numeric status fields. Decorate the presentation copy so the
			# retained UI can render the exact rejection reason; keep the adapter
			# receipt itself byte-for-byte intact for replay/correlation callers.
			var feedback_result := result.duplicate(true)
			if not accepted:
				var feedback_status := (feedback_result.get("status", {}) as Dictionary).duplicate(true)
				if not feedback_status.has("reason"):
					feedback_status["reason"] = StringName(result.get("reason", REASON_MUTATION_UNAVAILABLE))
				feedback_result["status"] = feedback_status
			captured_model.apply_result(feedback_result)
	var binding_current := _submission_context_is_current(context)
	if not binding_current and not captured_model.get_pending(pending_id).is_empty():
		_cancel_captured_pending(context, pending_id)
	var still_pending := not captured_model.get_pending(pending_id).is_empty()
	result["ui_pending"] = still_pending
	result["ui_resolved"] = not still_pending
	result["ui_binding_current"] = binding_current
	return result


func _capture_submission_context(scope: StringName) -> Dictionary:
	return {
		"binding_serial": _binding_serial,
		"owner": _owner,
		"bridge": _bridge,
		"adapter": _adapter,
		"admission": _admission,
		"owner_generation": _owner_generation,
		"scope": scope,
		"scope_generation": _bridge.scope_generation(scope) if _bridge != null else 0,
		"model": _bridge.presentation_model(scope) if _bridge != null else null,
	}


func _begin_product_pending_intent(
	bridge: InventoryProjectionBridge,
	model: InventoryPresentationModel,
	scope: StringName,
	kind: StringName,
	args: Dictionary,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> int:
	if bridge == null or model == null:
		return 0
	# Reserve and advance the shared allocator BEFORE begin_pending_intent(). The
	# add-on publishes pending/model signals synchronously, and one of those
	# listeners may submit through a different controller and different model
	# against the same adapter. Advancing afterward would let both models publish
	# the same command id and correlate one native result to two unrelated ghosts.
	# A reservation is deliberately burned if binding validation or publication
	# fails; command identities are never reused within the process lifetime.
	var reserved_id := _reserve_product_command_id(model)
	if reserved_id <= 0:
		return 0
	# `_next_pending_id` is the add-on model's documented command-id allocator
	# backing begin_intent(). Setting the exact reserved value preserves its
	# calling convention: the returned pending id is the native command id.
	model.set("_next_pending_id", reserved_id)
	if int(model.get("_next_pending_id")) != reserved_id:
		return 0
	var pending_id := bridge.begin_pending_intent(
		scope, kind, args, expected_owner_generation, expected_scope_generation)
	if pending_id != reserved_id:
		# Fail closed if the model/bridge calling convention ever changes. Never
		# allow a differently numbered pending record to reach the adapter.
		if pending_id > 0 and not model.get_pending(pending_id).is_empty():
			model.cancel_intent(pending_id)
		return 0
	return reserved_id


static func _reserve_product_command_id(model: InventoryPresentationModel) -> int:
	if model == null:
		return 0
	var raw_model_next: Variant = model.get("_next_pending_id")
	if typeof(raw_model_next) != TYPE_INT:
		return 0
	var model_next := int(raw_model_next)
	# A counter below the product base is a normal fresh add-on model. Invalid,
	# exhausted, or already-overflowed counters fail without padding/iteration.
	if _next_product_command_id < PRODUCT_COMMAND_ID_BASE \
			or _next_product_command_id > PRODUCT_COMMAND_ID_MAX \
			or model_next <= 0 or model_next > PRODUCT_COMMAND_ID_MAX:
		return 0
	var reserved_id := maxi(_next_product_command_id, model_next)
	if reserved_id < PRODUCT_COMMAND_ID_BASE or reserved_id > PRODUCT_COMMAND_ID_MAX:
		return 0
	_next_product_command_id = reserved_id + 1
	return reserved_id


func _submission_context_is_current(context: Dictionary) -> bool:
	if int(context.get("binding_serial", -1)) != _binding_serial or not _active:
		return false
	if context.get("owner") != _owner or context.get("bridge") != _bridge \
			or context.get("adapter") != _adapter or context.get("admission") != _admission:
		return false
	if int(context.get("owner_generation", 0)) != _owner_generation:
		return false
	var scope := StringName(context.get("scope", &""))
	if _bridge == null or _bridge.scope_generation(scope) != int(context.get("scope_generation", 0)) \
			or _bridge.presentation_model(scope) != context.get("model"):
		return false
	return _binding_is_current()


func _cancel_captured_pending(context: Dictionary, pending_id: int) -> void:
	var model: InventoryPresentationModel = context.get("model")
	if model != null and not model.get_pending(pending_id).is_empty():
		model.cancel_intent(pending_id)


func _lifecycle_rejection(operation: StringName, pending_id: int) -> Dictionary:
	var result := _rejection_result(REASON_STALE_BINDING, operation)
	result["inventory_command_id"] = pending_id
	result["command_id"] = pending_id
	result["ui_pending_command_id"] = pending_id
	result["ui_pending"] = false
	result["ui_resolved"] = true
	result["ui_binding_current"] = false
	return result


func _has_native_command(result: Dictionary) -> bool:
	return int(result.get("native_command_id", result.get("command_id", 0))) > 0 or int(result.get("request_id", 0)) > 0


func _can_submit(source_desc: Dictionary, target_desc: Dictionary) -> bool:
	return is_bound() and bool(source_desc.get("available", false)) and bool(target_desc.get("available", false)) and int(source_desc.get("inventory_id", 0)) > 0 and int(target_desc.get("inventory_id", 0)) > 0


func _reason_for_unavailable(source_desc: Dictionary, target_desc: Dictionary) -> StringName:
	var reason: Variant = source_desc.get("reason", REASON_UNBOUND)
	if String(reason) != "":
		return StringName(reason)
	reason = target_desc.get("reason", REASON_UNBOUND)
	if String(reason) != "":
		return StringName(reason)
	return REASON_MUTATION_UNAVAILABLE


func _valid_live_item(item: Dictionary, desc: Dictionary) -> bool:
	if item.is_empty() or int(desc.get("inventory_id", 0)) <= 0:
		return false
	var item_id_variant: Variant = item.get("item_id", null)
	if not (item_id_variant is int) or int(item_id_variant) <= 0:
		return false
	if int(item.get("inventory_id", 0)) != int(desc.inventory_id):
		return false
	if int(item.get("container_id", 0)) != int(desc.container_id):
		return false
	if String(item.get("scope", "")) != String(desc.scope):
		return false
	if int(item.get("owner_generation", 0)) != _owner_generation or int(item.get("scope_generation", 0)) != int(desc.scope_generation):
		return false
	if String(item.get("mapping_key", "")) != String(desc.mapping_key):
		return false
	var current := _item_for_source(StringName(desc.source), int(item_id_variant))
	if current.is_empty():
		return false
	# A drag carries a snapshot of canonical facts from its start. Same-id items
	# are not interchangeable: a concurrent move/rotate/merge must make the old
	# gesture stale before it can reach the adapter.
	for key in ["item_definition_identifier", "quantity", "x", "y", "rotated"]:
		if current.get(key, null) != item.get(key, null):
			return false
	var current_location: Dictionary = current.get("location", {}) as Dictionary
	var item_location: Dictionary = item.get("location", {}) as Dictionary
	return current_location == item_location


func _has_item(source: StringName, item_id: int) -> bool:
	return not _item_for_source(source, item_id).is_empty()


func _item_for_source(source: StringName, item_id: int) -> Dictionary:
	if item_id <= 0:
		return {}
	for item in items_for(source):
		if int(item.get("item_id", 0)) == item_id:
			return item
	return {}


func _merge_candidate(source_item: Dictionary, target_item: Dictionary, destination: Vector2i) -> bool:
	if source_item.is_empty() or target_item.is_empty():
		return false
	if String(source_item.get("merge_key", "")) != String(target_item.get("merge_key", "")):
		return false
	var maximum := maxi(1, int(target_item.get("max_stack", 1)))
	if maximum <= 1 or int(source_item.get("quantity", 1)) + int(target_item.get("quantity", 1)) > maximum:
		return false
	var target_x := int(target_item.get("x", -1))
	var target_y := int(target_item.get("y", -1))
	var target_w := maxi(1, int(target_item.get("width", target_item.get("w", 1))))
	var target_h := maxi(1, int(target_item.get("height", target_item.get("h", 1))))
	return destination.x >= target_x and destination.x < target_x + target_w \
		and destination.y >= target_y and destination.y < target_y + target_h


func _fits_target(target_source: StringName, item: Dictionary, destination: Vector2i, ignore_item_id: int) -> bool:
	var target_desc := descriptor(target_source)
	var dimensions := _item_dimensions(item)
	if dimensions.x <= 0 or dimensions.y <= 0:
		return false
	if destination.x < 0 or destination.y < 0 \
			or destination.x + dimensions.x > int(target_desc.columns) \
			or destination.y + dimensions.y > int(target_desc.rows):
		return false
	for other in items_for(target_source):
		var other_id := int(other.get("item_id", 0))
		if other_id == ignore_item_id:
			continue
		var other_dimensions := _item_dimensions(other)
		if _rects_overlap(destination.x, destination.y, dimensions.x, dimensions.y,
				int(other.get("x", 0)), int(other.get("y", 0)), other_dimensions.x, other_dimensions.y):
			return false
	return true


func _item_dimensions(item: Dictionary) -> Vector2i:
	return Vector2i(maxi(1, int(item.get("width", item.get("w", 1)))), maxi(1, int(item.get("height", item.get("h", 1)))))


func _rects_overlap(ax: int, ay: int, aw: int, ah: int, bx: int, by: int, bw: int, bh: int) -> bool:
	return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


func _location(desc: Dictionary, destination: Vector2i, rotated: bool) -> Dictionary:
	return {
		"kind": "spatial",
		"container": int(desc.container_id),
		"x": destination.x,
		"y": destination.y,
		"rotated": rotated,
	}


func _reject(reason: StringName, operation: StringName) -> Dictionary:
	last_error = reason
	return _rejection_result(reason, operation)


func _rejection_result(reason: StringName, operation: StringName) -> Dictionary:
	return {
		"accepted": false,
		"replayed": false,
		"queued": false,
		"reason": reason,
		"operation": operation,
		"ui_operation": operation,
		"status": {"code": &"command_rejected", "reason": reason},
		"inventory_command_id": 0,
		"command_id": 0,
		"native_command_id": 0,
	}


func _canonical_source(source: StringName) -> StringName:
	match source:
		SOURCE_PLAYER:
			return SOURCE_POCKETS
		SOURCE_LOOT:
			return _loot_source
		_:
			return source


func _is_actor_owned_source(source: StringName) -> bool:
	var key := _canonical_source(source)
	return key == SOURCE_POCKETS or key == SOURCE_RIG or key == SOURCE_BACKPACK


func _inventory_id_for_source(source: StringName) -> int:
	var binding: Dictionary = _source_bindings.get(String(source), {}) as Dictionary
	return int(binding.get("inventory_id", 0))


func _configure_source_bindings() -> void:
	_source_bindings = {
		String(SOURCE_STASH): {
			"scope": SCOPE_PROFILE,
			"inventory_id": int(_owner.profile_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["stash"]),
		},
		String(SOURCE_POCKETS): {
			"scope": SCOPE_RAID,
			"inventory_id": int(_owner.raid_player_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["pockets"]),
		},
		String(SOURCE_RIG): {
			"scope": SCOPE_RAID,
			"inventory_id": int(_owner.raid_player_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["rig"]),
		},
		String(SOURCE_BACKPACK): {
			"scope": SCOPE_RAID,
			"inventory_id": int(_owner.raid_player_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["backpack"]),
		},
		String(SOURCE_CRATE): {
			"scope": SCOPE_RAID,
			"inventory_id": int(_owner.world_crate_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["crate"]),
		},
		String(SOURCE_CORPSE): {
			"scope": SCOPE_RAID,
			"inventory_id": int(_owner.corpse_inventory_id),
			"container_definition_identifier": String(_DEFINITIONS["corpse"]),
		},
	}


func _mapping_key(scope: StringName, owner_generation: int, inventory_id: int, container_id: int) -> String:
	return "%s/%d/%d/%d" % [String(scope), owner_generation, inventory_id, container_id]


func _find_container_id(snapshot: InventorySnapshotResource, definition_identifier: String) -> int:
	if snapshot == null:
		return 0
	for raw in snapshot.get_containers():
		if not raw is Dictionary:
			continue
		var container: Dictionary = raw
		if String(container.get("container_definition_identifier", "")) == definition_identifier and int(container.get("provider_item", 0)) == 0:
			return int(container.get("id", 0))
	return 0


func _load_canonical_catalog_facts() -> void:
	_container_dimensions.clear()
	_item_facts.clear()
	_canonical_manifest_fingerprint = 0
	_canonical_catalog_ready = false
	var resource := ZerkovInventoryCatalog.build_resource()
	if resource == null:
		return
	for value in resource.containers:
		var definition := value as InventoryContainerDefinition
		if definition == null:
			continue
		_container_dimensions[String(definition.identifier)] = Vector2i(
			int(definition.grid_width), int(definition.grid_height))
	for value in resource.items:
		var definition := value as InventoryItemDefinition
		if definition == null:
			continue
		_item_facts[String(definition.identifier)] = {
			"w": int(definition.footprint_width),
			"h": int(definition.footprint_height),
			"rotatable": bool(definition.allow_rotation),
			"max_stack": int(definition.max_stack),
		}
	var sealed_catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	if sealed_catalog == null:
		return
	_canonical_manifest_fingerprint = sealed_catalog.manifest_fingerprint()
	_canonical_catalog_ready = not _container_dimensions.is_empty() \
		and not _item_facts.is_empty()


func _container_size(definition_identifier: String) -> Vector2i:
	var value: Variant = _container_dimensions.get(definition_identifier, Vector2i.ZERO)
	return value if value is Vector2i else Vector2i.ZERO


func _presentation_for(definition: String) -> Dictionary:
	var meta: Variant = _PRESENTATION.get(definition, null)
	var result := (meta as Dictionary).duplicate(true) if meta is Dictionary \
		else {"name": definition, "kind": "item", "category": "item"}
	var facts: Variant = _item_facts.get(definition, null)
	if facts is Dictionary:
		result.merge((facts as Dictionary).duplicate(true), true)
	else:
		# A catalog/manifest mismatch is rejected at bind. Keep this fallback
		# presentation-only and non-rotatable in case an unknown redacted row is
		# ever projected by a later recipient-view task.
		result.merge({"w": 1, "h": 1, "rotatable": false, "max_stack": 1}, true)
	# Resolve artwork from the bounded presentation registry only.  Unknown
	# definitions remain readable through their projected identifier/name and
	# receive a safe existing placeholder rather than caller-supplied metadata.
	var registry_has_definition := _ICON_REGISTRY.has(definition)
	var icon_path := String(_ICON_REGISTRY.get(definition, _ICON_FALLBACK))
	if not ResourceLoader.exists(icon_path):
		icon_path = _ICON_FALLBACK
		registry_has_definition = false
	result["icon"] = icon_path
	var icon_placeholder := bool(result.get("icon_placeholder", false)) or not registry_has_definition
	result["icon_placeholder"] = icon_placeholder
	result["icon_accessibility_label"] = String(result.get("icon_accessibility_label", "PLACEHOLDER ART · neutral item placeholder" if icon_placeholder else ""))
	return result


func _status_reason(status: int) -> StringName:
	match status:
		InventoryProjectionBridge.ProjectionStatus.LOADING:
			return &"inventory_loading"
		InventoryProjectionBridge.ProjectionStatus.RESYNCHRONIZING:
			return &"inventory_resynchronizing"
		InventoryProjectionBridge.ProjectionStatus.STALE:
			return &"inventory_stale"
		InventoryProjectionBridge.ProjectionStatus.DISCONNECTED:
			return &"inventory_disconnected"
		InventoryProjectionBridge.ProjectionStatus.UNBOUND:
			return REASON_UNBOUND
	return &""


func _binding_is_current() -> bool:
	if not is_bound():
		return false
	if not _admission.is_usable():
		return false
	if not _owner.is_current_generation(_owner_generation):
		return false
	return _bridge.is_bound() and _bridge.owner_generation() == _owner_generation \
		and _bridge_matches_owner() and _adapter_matches(_owner, _adapter, _admission)


func _bridge_matches_owner() -> bool:
	return _owner != null and _bridge != null \
		and _bridge.authority_for_scope(SCOPE_PROFILE) == _owner.profile_authority() \
		and _bridge.authority_for_scope(SCOPE_RAID) == _owner.raid_authority()


func _adapter_matches(owner: RaidInventoryOwner, adapter: InventoryIntentAdapter, admission: ZSessionAdmission) -> bool:
	return owner != null and adapter != null and admission != null \
		and adapter.matches_binding(owner, admission)


func _connect_bridge() -> void:
	if not _bridge.model_replaced.is_connected(_on_model_replaced):
		_bridge.model_replaced.connect(_on_model_replaced)
	if not _bridge.projection_status_changed.is_connected(_on_projection_status_changed):
		_bridge.projection_status_changed.connect(_on_projection_status_changed)
	if not _bridge.binding_invalidated.is_connected(_on_binding_invalidated):
		_bridge.binding_invalidated.connect(_on_binding_invalidated)
	if not _bridge.snapshot_projected.is_connected(_on_snapshot_projected):
		_bridge.snapshot_projected.connect(_on_snapshot_projected)


func _disconnect_bridge() -> void:
	if _bridge == null:
		return
	if _bridge.model_replaced.is_connected(_on_model_replaced):
		_bridge.model_replaced.disconnect(_on_model_replaced)
	if _bridge.projection_status_changed.is_connected(_on_projection_status_changed):
		_bridge.projection_status_changed.disconnect(_on_projection_status_changed)
	if _bridge.binding_invalidated.is_connected(_on_binding_invalidated):
		_bridge.binding_invalidated.disconnect(_on_binding_invalidated)
	if _bridge.snapshot_projected.is_connected(_on_snapshot_projected):
		_bridge.snapshot_projected.disconnect(_on_snapshot_projected)


func _connect_adapter() -> void:
	if not _adapter.binding_invalidated.is_connected(_on_binding_invalidated):
		_adapter.binding_invalidated.connect(_on_binding_invalidated)


func _disconnect_adapter() -> void:
	if _adapter != null \
			and _adapter.binding_invalidated.is_connected(_on_binding_invalidated):
		_adapter.binding_invalidated.disconnect(_on_binding_invalidated)


func _bind_model(scope: StringName, model: InventoryPresentationModel) -> void:
	_disconnect_model(scope)
	if model == null:
		return
	var changed := Callable(self, "_on_model_changed").bind(scope)
	var pending := Callable(self, "_on_model_pending_changed").bind(scope)
	var rejected := Callable(self, "_on_model_rejection").bind(scope)
	var accepted := Callable(self, "_on_model_acceptance").bind(scope)
	model.model_changed.connect(changed)
	model.pending_changed.connect(pending)
	model.rejection_feedback.connect(rejected)
	model.accepted_feedback.connect(accepted)
	_model_connections[scope] = {"model": model, "changed": changed, "pending": pending, "rejected": rejected, "accepted": accepted}


func _disconnect_model(scope: StringName) -> void:
	var connection: Variant = _model_connections.get(scope, null)
	if not connection is Dictionary:
		return
	var model: InventoryPresentationModel = connection.get("model")
	if model != null:
		for key in ["changed", "pending", "rejected", "accepted"]:
			var callable: Callable = connection.get(key)
			if callable.is_valid() and model.is_connected(_signal_for_key(key), callable):
				model.disconnect(_signal_for_key(key), callable)


func _signal_for_key(key: String) -> StringName:
	match key:
		"changed":
			return &"model_changed"
		"pending":
			return &"pending_changed"
		"rejected":
			return &"rejection_feedback"
	return &"accepted_feedback"


func _on_model_replaced(scope: StringName, model: InventoryPresentationModel, _generation: int) -> void:
	if not _active:
		return
	if scope == SCOPE_RAID:
		# A bridge model replacement advances the scope generation even when the
		# inventory id is reused.  No old receipt can remain causal across it.
		_clear_loot_state_hint()
	_bind_model(scope, model)
	projection_changed.emit(scope)


func _on_projection_status_changed(scope: StringName, status: int) -> void:
	if not _active:
		return
	status_changed.emit(scope, status)
	projection_changed.emit(scope)


func _on_snapshot_projected(scope: StringName, inventory_id: int, revision: int) -> void:
	if not _active:
		return
	if scope == SCOPE_RAID and not _loot_state_hint.is_empty():
		var causal_revisions := _loot_state_hint_causal.get("revisions", {}) as Dictionary
		var causal_revision := int(causal_revisions.get(inventory_id, -1))
		# Destination-only commits are just as causal as source commits.  Clear
		# once either observed inventory advances (or regresses, which is a
		# fail-closed replacement signal); equal revisions retain the hint across
		# a close/open presentation cycle.
		if causal_revision >= 0 and revision != causal_revision:
			_clear_loot_state_hint()
	projection_changed.emit(scope)


func _on_model_changed(scope: StringName) -> void:
	if _active:
		projection_changed.emit(scope)


func _on_model_pending_changed(scope: StringName) -> void:
	if _active:
		pending_changed.emit(scope)


func _on_model_rejection(info: Dictionary, scope: StringName) -> void:
	if not _active:
		return
	var output := info.duplicate(true)
	output["scope"] = scope
	# Do not persist generic model feedback.  Its recipient-safe shape has no
	# causal source/destination ids and revision pairs, so it cannot prove which
	# exact loot projection a rejection observed.  The synchronous adapter
	# receipt is captured by _submit_once before this callback is reached.
	rejection_feedback.emit(output)


func _on_model_acceptance(info: Dictionary, scope: StringName) -> void:
	if not _active:
		return
	var output := info.duplicate(true)
	output["scope"] = scope
	accepted_feedback.emit(output)


func _clear_loot_state_hint() -> void:
	_loot_state_hint = &""
	_loot_state_hint_causal.clear()


func _loot_hint_is_current() -> bool:
	if _loot_state_hint.is_empty() or _loot_state_hint_causal.is_empty():
		return false
	if not _binding_is_current() or _bridge == null:
		return false
	if StringName(_loot_state_hint_causal.get("source", "")) != _loot_source:
		return false
	if int(_loot_state_hint_causal.get("owner_generation", -1)) != _owner_generation:
		return false
	if int(_loot_state_hint_causal.get("binding_serial", -1)) != _binding_serial:
		return false
	if int(_loot_state_hint_causal.get("scope_generation", -1)) \
			!= _bridge.scope_generation(SCOPE_RAID):
		return false
	var source_inventory_id := int(_loot_state_hint_causal.get("source_inventory_id", 0))
	var destination_inventory_id := int(_loot_state_hint_causal.get("destination_inventory_id", 0))
	if source_inventory_id <= 0 or destination_inventory_id <= 0 \
			or source_inventory_id != _inventory_id_for_source(_loot_source):
		return false
	var causal_revisions := _loot_state_hint_causal.get("revisions", {}) as Dictionary
	if causal_revisions.is_empty():
		return false
	for inventory_id_value in [source_inventory_id, destination_inventory_id]:
		var inventory_id := int(inventory_id_value)
		var causal_revision := int(causal_revisions.get(inventory_id, -1))
		if causal_revision < 0 \
				or _bridge.confirmed_revision(SCOPE_RAID, inventory_id) != causal_revision:
			return false
	return true


func _capture_loot_causal_result(
	result: Dictionary,
	payload: Dictionary,
	context: Dictionary,
	operation: StringName
) -> void:
	if operation != OP_LOOT and operation != OP_QUICK:
		return
	if bool(result.get("accepted", false)) or bool(result.get("queued", false)):
		return
	if not _submission_context_is_current(context) or not _loot_open:
		return
	var source_inventory_id := int(payload.get("source_inventory_id", 0))
	var destination_inventory_id := int(payload.get("destination_inventory_id", 0))
	if source_inventory_id <= 0 or destination_inventory_id <= 0 \
			or source_inventory_id != _inventory_id_for_source(_loot_source):
		return
	# The native receipt's revision array is the provenance for both inventory
	# ids.  A model-safe rejection or an adapter validation error that lacks this
	# array is intentionally insufficient for persistent state.
	if not _receipt_has_revision_entry(result, source_inventory_id) \
			or not _receipt_has_revision_entry(result, destination_inventory_id):
		return
	var hint_state := _loot_hint_state_for_receipt(result)
	if hint_state.is_empty():
		return
	var source_revision := _receipt_causal_revision(
		result, "source", source_inventory_id)
	var destination_revision := source_revision if source_inventory_id == destination_inventory_id \
		else _receipt_causal_revision(result, "destination", destination_inventory_id)
	if source_revision < 0 or destination_revision < 0:
		# A generic/adaptor-only rejection has no authoritative causal tuple.  It
		# remains transient feedback but must not poison the persistent loot state.
		return
	var causal := {
		"source": String(_loot_source),
		"source_inventory_id": source_inventory_id,
		"destination_inventory_id": destination_inventory_id,
		"owner_generation": int(context.get("owner_generation", 0)),
		"binding_serial": int(context.get("binding_serial", 0)),
		"scope_generation": int(context.get("scope_generation", 0)),
		"revisions": {
			source_inventory_id: source_revision,
			destination_inventory_id: destination_revision,
		},
	}
	if int(causal.get("owner_generation", 0)) <= 0 \
			or int(causal.get("binding_serial", 0)) <= 0 \
			or int(causal.get("scope_generation", 0)) <= 0:
		return
	if _bridge == null \
			or _bridge.confirmed_revision(SCOPE_RAID, source_inventory_id) != source_revision \
			or _bridge.confirmed_revision(SCOPE_RAID, destination_inventory_id) != destination_revision:
		return
	_loot_state_hint = hint_state
	_loot_state_hint_causal = causal


func _receipt_has_revision_entry(result: Dictionary, inventory_id: int) -> bool:
	var revisions_value: Variant = result.get("revisions", null)
	if not revisions_value is Array:
		return false
	for revision_value in revisions_value as Array:
		if revision_value is Dictionary \
				and int((revision_value as Dictionary).get("inventory", 0)) == inventory_id:
			return true
	return false


func _loot_hint_state_for_receipt(result: Dictionary) -> StringName:
	var status := result.get("status", {}) as Dictionary
	var diagnostic := int(status.get("diagnostic", 0))
	var code := int(status.get("code", -1))
	var reason := String(result.get("reason", "")).to_lower()
	var status_reason := String(status.get("reason", "")).to_lower()
	var reason_token := String(status.get("reason_token", "")).to_lower()
	if diagnostic == _NATIVE_DIAGNOSTIC_MASS_CAPACITY_EXCEEDED \
			or reason.contains("overweight") or reason.contains("capacity") \
			or status_reason.contains("overweight") or status_reason.contains("capacity") \
			or reason_token.contains("overweight") or reason_token.contains("capacity"):
		return InventoryPresentationModel.STATE_OVERWEIGHT
	if code == _NATIVE_STATUS_REVISION_STALE or _NATIVE_DIAGNOSTIC_STALE.has(diagnostic) \
			or reason.contains("stale") or reason.contains("revision") \
			or status_reason.contains("stale") or status_reason.contains("revision") \
			or reason_token.contains("stale") or reason_token.contains("revision"):
		return InventoryPresentationModel.STATE_STALE_CORRECTED
	return &""


func _receipt_causal_revision(
	result: Dictionary,
	prefix: String,
	inventory_id: int
) -> int:
	var revisions_value: Variant = result.get("revisions", null)
	if revisions_value is Array:
		for revision_value in revisions_value as Array:
			if not revision_value is Dictionary:
				continue
			var revision := revision_value as Dictionary
			if int(revision.get("inventory", 0)) != inventory_id:
				continue
			var predecessor: Variant = revision.get("predecessor", -1)
			if typeof(predecessor) == TYPE_INT and int(predecessor) >= 0:
				return int(predecessor)
	var predecessor_key := "%s_predecessor_revision" % prefix
	var predecessor_value: Variant = result.get(predecessor_key, -1)
	if typeof(predecessor_value) == TYPE_INT and int(predecessor_value) >= 0:
		return int(predecessor_value)
	return -1


func _on_binding_invalidated(reason: StringName) -> void:
	if not _active:
		return
	last_error = reason
	_clear_loot_state_hint()
	_binding_serial += 1
	_active = false
	_disconnect_bridge()
	_disconnect_adapter()
	for scope in _model_connections.keys():
		_disconnect_model(StringName(scope))
	_model_connections.clear()
	_owner = null
	_bridge = null
	_adapter = null
	_admission = null
	_owner_generation = 0
	_source_bindings.clear()
	binding_invalidated.emit(reason)


func _fail_bind(reason: StringName) -> bool:
	last_error = reason
	return false
