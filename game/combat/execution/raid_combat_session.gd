class_name RaidCombatSession
extends Node
## Root-owned offline combat composition. Takes EXISTING raid inventory and
## movement owners; does not seed loot, create a profile, or start a raid clock.
## Task 7 deployment calls this after preparing the loadout/world/actor roster.
var last_error: StringName = &""
var execution: RaidCombatExecution
var health: HealthConsequenceAdapter
var weapons: WeaponAuthority
var fire: WeaponCombatAdapter
var hitboxes: BodyHitboxWorld2D
var _raid: RaidAuthority
var _generation: int = 0
var _rows: Array[Dictionary] = []
var _obstructions: Array[Dictionary] = []
var _publisher_registration: String = ""
var _started: bool = false
var _released: bool = false
const PUBLISHER: StringName = &"combat_world_snapshot"

## Each row is actor_id:ZEntityId, source:int, movement:ZPlayerLocomotion,
## movement_handler:StringName, inventory:RaidInventoryOwner, natural_melee:bool.
## Natural melee actors may omit inventory. All actors must be authorized first.
func start(raid: RaidAuthority, roster: Array[Dictionary], obstructions: Array[Dictionary] = []) -> bool:
	if _started or _released or not is_inside_tree() or raid == null \
		or raid.lifecycle != RaidAuthority.Lifecycle.PREPARING or roster.is_empty() \
		or roster.size() > RaidCombatExecution.MAX_ACTORS or obstructions.size() > BodyHitboxWorld2D.MAX_OBSTRUCTIONS:
		return _fail(&"combat_session_configuration_invalid")
	var ids: Dictionary = {}
	for row in roster:
		if not row.get("actor_id") is ZEntityId or not row.get("movement") is ZPlayerLocomotion \
			or row.get("source", -1) not in [0, 1] or typeof(row.get("natural_melee")) != TYPE_BOOL \
			or not raid.has_authorized_actor_source(row.actor_id, row.source, raid.generation()) \
			or not row.movement.actor_id().is_equal(row.actor_id) \
			or not raid.has_phase_handler(row.get("movement_handler", &""), raid.generation()) \
			or ids.has(row.actor_id.canonical_key()) \
			or (not row.natural_melee and (not row.get("inventory") is RaidInventoryOwner \
				or not row.inventory.is_current_generation(row.inventory.generation()))):
			return _fail(&"combat_roster_invalid")
		ids[row.actor_id.canonical_key()] = true
	if not ids.has(raid.admission().actor_id.canonical_key()):
		return _fail(&"combat_local_actor_missing")
	_started = true
	_raid = raid
	_generation = raid.generation()
	_obstructions = obstructions.duplicate(true)
	weapons = WeaponAuthority.new()
	add_child(weapons)
	if not ZerkovCombatContent.configure_authority(weapons).get("ok", false): return _fail(&"combat_catalog_failed")
	health = HealthConsequenceAdapter.new()
	if not health.bind_authority(raid, _generation): return _fail(health.last_error)
	var contexts := PackedStringArray()
	var movements := PackedStringArray()
	var source_rows := roster.duplicate()
	source_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.actor_id.canonical_key() < b.actor_id.canonical_key())
	var ordinal: int = 0
	var local_context: WeaponInstanceContextAdapter
	for source: Dictionary in source_rows:
		ordinal += 1
		var row: Dictionary = source.duplicate()
		var admission := raid.admission()
		admission.actor_id = ZEntityId.parse(row.actor_id.canonical_key())
		row["admission"] = admission
		var component := GameplayAbilityComponent.new()
		component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
		component.entity_id = 100_000 + ordinal
		component.tick_rate = RaidClock.TICK_RATE
		component.definition_catalog = ZerkovGameplayAbilityContent.build_definition_catalog()
		add_child(component)
		row["component"] = component
		_rows.append(row) # Own every allocation even if a later startup step fails.
		if not GameplayDefinitionValidator.is_ok(component.configure()) \
			or not ZerkovGameplayAbilityContent.initialize_component(component).get("accepted", false) \
			or not health.register_actor(row.actor_id, row.source, component, component.entity_id).get("accepted", false):
			return _fail(&"combat_health_actor_startup_failed")
		if not row.movement.bind_combat_health(health, _generation): return _fail(&"combat_movement_health_bind_failed")
		movements.append(String(row.movement_handler))
		if row.natural_melee: continue
		var owner := row.inventory as RaidInventoryOwner
		var bridge := InventoryProjectionBridge.new()
		add_child(bridge)
		row["bridge"] = bridge
		if not bridge.bind_owner(owner, owner.generation()): return _fail(&"combat_inventory_projection_failed")
		var scope := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
		var reconciler := EquippedItemReconciler.new()
		add_child(reconciler)
		row["reconciler"] = reconciler
		if not reconciler.bind_owner(owner, bridge, admission, owner.generation(), scope): return _fail(&"combat_equipment_binding_failed")
		var port := WeaponAuthorityReloadPort.new()
		if not port.configure(weapons): return _fail(&"combat_reload_port_failed")
		var reload := InventoryWeaponAdapter.new()
		add_child(reload)
		row["reload"] = reload
		if not reload.bind_owner(owner, admission, port, owner.generation()): return _fail(&"combat_reload_binding_failed")
		var context := WeaponInstanceContextAdapter.new()
		add_child(context)
		row["context"] = context
		var handler := StringName("combat_weapon_context_%02d" % ordinal)
		if not context.bind_owner(owner, reconciler, admission, raid, weapons, port, reload,
			owner.generation(), scope, _generation, row.source, handler): return _fail(context.last_error)
		contexts.append(String(handler))
		var identity := OfflineInventoryIdentity.new()
		var medical := InventoryMedicalParticipant.new()
		if not identity.configure(admission, owner, component.entity_id) \
			or not medical.configure(owner, admission, identity, owner.generation()) \
			or not health.attach_medical_inventory(row.actor_id, medical, reload): return _fail(&"combat_medical_binding_failed")
		row["medical"] = medical
		if row.actor_id.is_equal(raid.admission().actor_id): local_context = context
	if local_context == null: return _fail(&"combat_local_inventory_required")
	hitboxes = BodyHitboxWorld2D.new()
	var capability := hitboxes.bind_raid_authority(raid, raid.admission().actor_id, ZRaidIntent.Source.PLAYER, _generation)
	if capability == null: return _fail(hitboxes.last_error)
	if not raid.register_phase_handler(RaidAuthority.TickPhase.MOVEMENT, PUBLISHER,
		Callable(self, "_publish_bodies"), _generation, 200, movements): return _fail(raid.last_error)
	_publisher_registration = raid.phase_handler_registration_id(PUBLISHER, _generation)
	if not hitboxes.authorize_phase_publisher(capability, PUBLISHER, _publisher_registration, Callable(self, "_publish_bodies")):
		return _fail(hitboxes.last_error)
	fire = WeaponCombatAdapter.new()
	add_child(fire)
	execution = RaidCombatExecution.new()
	if not execution.bind(raid, weapons, fire, health, hitboxes, capability, _generation, contexts): return _fail(execution.last_error)
	if not fire.bind_context(raid, weapons, local_context, hitboxes, capability,
		_generation, local_context.binding_generation(), 1, 2): return _fail(fire.last_error)
	# No returned/stored bearer: all subsequent world access uses named grants.
	for row in _rows:
		if row.source == ZRaidIntent.Source.AI and row.has("context"):
			if not fire.register_actor_context(row.actor_id, row.source, row.context, row.context.binding_generation()): return _fail(fire.last_error)
		if not execution.register_actor(row.actor_id, row.source, row.get("inventory"), row.get("reconciler"),
			row.get("context"), row.get("reload"), row.natural_melee): return _fail(execution.last_error)
	return true

func _publish_bodies(raid: RaidAuthority, phase: int, tick: int, _intents: Array[ZRaidIntent]) -> bool:
	if _released or raid != _raid or not raid.is_dispatching_phase_registration(PUBLISHER,
		_publisher_registration, Callable(self, "_publish_bodies"), phase, tick, _generation):
		return _fail(&"combat_world_publish_out_of_phase")
	var bodies: Array[Dictionary] = []
	for row in _rows:
		var movement := row.movement as ZPlayerLocomotion
		var position := ZWorldUnits.godot_to_canonical(movement.position_px)
		if not position.ok: return _fail(position.error_code)
		var facing: int = 0
		match movement.facing_4:
			ZPlayerFacing.Facing4.EAST: facing = 1
			ZPlayerFacing.Facing4.SOUTH: facing = 2
			ZPlayerFacing.Facing4.WEST: facing = 3
		bodies.append({"entity_id": row.actor_id.canonical_key(), "actor_source": row.source,
			"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1), "body_revision": tick,
			"origin_raw": position.vector2i_value, "facing_quarter_turns": facing,
			"collision_layer": 1, "targetable": health.actor_snapshot(row.actor_id).get("alive", false)})
	if not hitboxes.phase_publisher_publish_snapshot(tick, tick, bodies, _obstructions,
		raid.admission().actor_id, ZRaidIntent.Source.PLAYER, PUBLISHER,
		_publisher_registration, Callable(self, "_publish_bodies")): return _fail(hitboxes.last_error)
	return true

## Release consumers and outstanding reservations before the raid terminalizes.
## Prepared inventory owners are deliberately NOT erased; task 7 settles them.
func release() -> bool:
	if _released: return true
	if execution != null and not execution.release(): return _fail(execution.last_error)
	if not _publisher_registration.is_empty() and _raid.has_phase_handler(PUBLISHER, _generation):
		if not _raid.unregister_phase_handler(PUBLISHER, _generation): return _fail(_raid.last_error)
	if fire != null and fire.lifecycle in [WeaponCombatAdapter.Lifecycle.BOUND, WeaponCombatAdapter.Lifecycle.INVALIDATED]:
		if not fire.release_binding(): return _fail(fire.last_error)
	for index in range(_rows.size() - 1, -1, -1):
		var row := _rows[index]
		if row.has("context") and row.context.lifecycle in [WeaponInstanceContextAdapter.Lifecycle.BOUND, WeaponInstanceContextAdapter.Lifecycle.RECOVERY_REQUIRED]:
			if not row.context.release_binding(&"teardown", _raid.last_processed_tick): return _fail(row.context.last_error)
		if row.has("reload") and row.reload.lifecycle in [InventoryWeaponAdapter.Lifecycle.BOUND, InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED]:
			if not row.reload.release_binding(&"teardown", _raid.last_processed_tick): return _fail(row.reload.last_error)
		if row.has("reconciler"): row.reconciler.release_binding()
		if row.has("bridge"): row.bridge.release_binding()
	if health != null and health.lifecycle in [HealthConsequenceAdapter.Lifecycle.BOUND, HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED, HealthConsequenceAdapter.Lifecycle.INVALIDATED]:
		if not health.release_binding(&"teardown", _raid.last_processed_tick): return _fail(health.last_error)
	_released = true
	return true

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
