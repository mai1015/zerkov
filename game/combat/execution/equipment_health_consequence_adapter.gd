class_name EquipmentHealthConsequenceAdapter
extends HealthConsequenceAdapter
## Shared-component composition: equipment owns only its declared passive
## abilities/tags/attribute. Health retains its existing mutation guard for all
## other events. A namespace match alone never authorizes a component change.
const EQUIPMENT = preload("res://game/content/zerkov_equipment_ability_content.gd")
const ADAPTER_SCRIPT = preload("res://game/inventory/equipment/inventory_ability_adapter.gd")
const PORT_SCRIPT = preload("res://game/inventory/equipment/gameplay_ability_equipment_port.gd")
var _equipment_sources: Dictionary = {}


func bind_equipment_source(actor_id: ZEntityId, executor: InventoryAbilityAdapter) -> bool:
	if not is_bound() or _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or actor_id == null or executor == null or executor.get_script() != ADAPTER_SCRIPT:
		return false
	var key := actor_id.canonical_key()
	var actor := _actors.get(key, {}) as Dictionary
	if actor.is_empty() or _equipment_sources.has(key) or not executor._binding_is_current():
		return false
	var port := executor._ability_port as GameplayAbilityEquipmentPort
	if port == null or port.get_script() != PORT_SCRIPT \
			or port.owner_node() != actor.component or executor._raid_authority != _authority \
			or not executor._admission.actor_id.is_equal(actor_id):
		return false
	var handler := InventoryAbilityAdapter.DEFAULT_PHASE_HANDLER_ID
	var registration := _authority.phase_handler_registration_id(handler, _raid_generation)
	if not _authority.has_exact_phase_handler(handler, registration,
			Callable(executor, "handle_raid_phase"),
			RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK, _raid_generation):
		return false
	_equipment_sources[key] = {
		"executor": weakref(executor), "port": weakref(port),
		"port_token": port.identity_token(), "registration": registration,
		"actor_registration": int(actor.actor_registration_generation),
	}
	return true


func _on_component_state_changed(event: Dictionary, actor_key: String,
		actor_registration_generation: int, signal_name: StringName) -> void:
	# Base handles stale actor registrations, ordinary health mutations,
	# snapshot restore/desync, and every unauthorized event exactly as before.
	if _is_owned_equipment_event(event, actor_key, actor_registration_generation, signal_name):
		return
	super._on_component_state_changed(event, actor_key, actor_registration_generation, signal_name)


func _is_owned_equipment_event(event: Dictionary, actor_key: String,
		actor_registration_generation: int, signal_name: StringName) -> bool:
	if lifecycle != Lifecycle.BOUND or not _actors.has(actor_key) \
			or not _equipment_sources.has(actor_key):
		return false
	var source := _equipment_sources[actor_key] as Dictionary
	var actor := _actors[actor_key] as Dictionary
	if int(source.actor_registration) != actor_registration_generation \
			or int(actor.actor_registration_generation) != actor_registration_generation:
		return false
	var executor := (source.executor as WeakRef).get_ref() as InventoryAbilityAdapter
	var port := (source.port as WeakRef).get_ref() as GameplayAbilityEquipmentPort
	var component := actor.component as GameplayAbilityComponent
	if executor == null or port == null or component == null \
			or executor.get_script() != ADAPTER_SCRIPT or port.get_script() != PORT_SCRIPT \
			or executor.lifecycle != InventoryAbilityAdapter.Lifecycle.BOUND \
			or not executor._phase_call_active or not executor._mutation_active \
			or executor._public_signal_active or not port._mutation_active \
			or executor._ability_port != port or port.owner_node() != component \
			or port.identity_token() != String(source.port_token) \
			or not _authority.is_dispatching_phase_registration(
				InventoryAbilityAdapter.DEFAULT_PHASE_HANDLER_ID, String(source.registration),
				Callable(executor, "handle_raid_phase"),
				RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
				_authority.clock.current_tick, _raid_generation):
		return false
	# This scope is deliberately narrower than "another authorized handler ran".
	# Reentrant health damage during an equipment callback is never exempted.
	match signal_name:
		&"attribute_changed":
			return component.resolve_attribute_identifier(int(event.get("attribute", 0))) \
				== String(EQUIPMENT.ATTRIBUTE_READIED_WEAPON_COUNT)
		&"tag_changed":
			return StringName(component.resolve_tag_identifier(int(event.get("tag", 0)))) \
				in [EQUIPMENT.TAG_AKM_EQUIPPED, EQUIPMENT.TAG_MACHETE_EQUIPPED]
		&"effect_lifecycle_changed":
			return int(event.get("target", 0)) == component.entity_id \
				and StringName(event.get("definition_identifier", "")) \
				in [EQUIPMENT.EFFECT_AKM_EQUIPPED, EQUIPMENT.EFFECT_MACHETE_EQUIPPED]
		&"ability_granted", &"ability_revoked", &"activation_requested", \
		&"activation_phase_changed", &"activation_committed", &"activation_ended", \
		&"activation_cancelled", &"activation_failed":
			return int(event.get("owner", 0)) == component.entity_id \
				and StringName(event.get("ability_identifier", "")) \
				in [EQUIPMENT.ABILITY_AKM_EQUIPPED, EQUIPMENT.ABILITY_MACHETE_EQUIPPED]
	return false


func release_binding(reason: StringName = &"teardown", tick: int = -1,
		teardown_components: bool = true) -> bool:
	var released := super.release_binding(reason, tick, teardown_components)
	if released:
		_equipment_sources.clear()
	return released
