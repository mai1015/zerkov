class_name HealthConsequenceAdapter
extends RefCounted
## Phase-7 damage, injury, treatment, bleed, and death coordinator.
##
## Ordered weapon hit records are consumed from RaidAuthority's append-only
## journal. Gameplay Abilities remains the health/status owner, Inventory
## System remains the medical-item owner, and this adapter owns only stable
## cross-domain identities, deterministic ordering, idempotency, and truthful
## fail-stop recovery.

signal damage_committed(outcome: Dictionary)
signal injury_committed(outcome: Dictionary)
signal treatment_committed(outcome: Dictionary)
signal death_committed(outcome: Dictionary)
signal recovery_latched(reason: StringName, details: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle { UNBOUND, BOUND, RECOVERY_REQUIRED, INVALIDATED, RELEASED }

const PHASE_HANDLER_ID: StringName = &"health_consequence_adapter"
const PHASE_HANDLER_PRIORITY: int = -100
const MAX_ACTORS: int = 64
const MAX_DAMAGE_RESULTS: int = 4096
const MAX_TREATMENT_REQUESTS: int = 512
const MAX_PENDING_TREATMENTS: int = 64
const MAX_BLEED_SCHEDULES: int = 256
const MAX_RESERVED_EVENT_IDS: int = 16_384
const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000
const MAX_COMMAND_SEQUENCE: int = 9_007_199_254_740_000
const MEDICAL_RESERVATION_TTL_TICKS: int = 600

const WEAPON_CONSEQUENCE_SCHEMA: String = "zerkov.combat.weapon_consequence.v1"
const DAMAGE_OUTCOME_SCHEMA: String = "zerkov.combat.health_damage.v1"
const INJURY_EVENT_SCHEMA: String = "zerkov.combat.health_injury_event.v1"
const HEAL_EVENT_SCHEMA: String = "zerkov.combat.health_heal_event.v1"
const DEATH_EVENT_SCHEMA: String = "zerkov.combat.health_death_event.v1"
const KILL_EVENT_SCHEMA: String = "zerkov.combat.health_kill_event.v1"
const TREATMENT_REQUEST_SCHEMA: String = "zerkov.combat.health_treatment_request.v1"

const WEAPON_CONSEQUENCE_KEYS: PackedStringArray = [
	"accepted", "actor_id", "actor_source", "anatomy_group", "authority_epoch",
	"authority_generation", "binding_generation", "blocked", "body_revision",
	"body_zone", "consequence_id", "consumed_profile", "damage_milliunits",
	"entity_id", "hit", "hit_point_raw", "hitbox_id",
	"loaded_rounds_after_commit", "miss_reason", "obstruction_id", "outcome",
	"profile_id", "raid_id", "ray_fraction_denominator",
	"ray_fraction_numerator", "resolution_digest", "schema", "session_id", "tick",
	"weapon_binding_generation", "weapon_consequence_id",
	"weapon_context_binding_generation", "weapon_entity_id", "weapon_id",
	"weapon_instance_id", "weapon_revision", "weapon_version", "world_revision",
	"world_resolution_digest", "world_snapshot_digest",
]

const TREATMENT_REQUEST_KEYS: PackedStringArray = [
	"actor_id", "actor_registration_generation", "adapter_generation",
	"authority_epoch", "authority_generation", "body_zone",
	"expected_health_revision", "expected_inventory_revision", "raid_id",
	"request_id", "schema", "sequence", "session_id", "target_tick", "treatment",
]

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _authority: RaidAuthority
var _authority_instance_id: int = 0
var _raid_generation: int = 0
var _admission: ZSessionAdmission
var _policy_digest: String = ""
var _phase_registration_id: String = ""
var _phase_registered: bool = false
var _generation_counter: int = 0
var _binding_generation: int = 0
var _last_tick: int = 0
var _journal_cursor: int = 0

var _actors: Dictionary = {}
var _native_entity_owners: Dictionary = {}
var _damage_results: Dictionary = {}
var _treatment_records: Dictionary = {}
var _treatment_order: PackedStringArray = PackedStringArray()
var _bleed_schedules: Dictionary = {}
var _phase_cancelled_bleeds: Dictionary = {}
var _reserved_event_ids: Dictionary = {}
var _recovery: Dictionary = {}
var _phase_active: bool = false
var _mutation_active: bool = false
var _public_signal_active: bool = false
var _melee_executor_ref: WeakRef
var _melee_registration: String = ""
var _melee_costs: Dictionary = {}
const MELEE_CONSEQUENCE_SCHEMA: String = "zerkov.combat.melee_consequence.v1"



func bind_authority(
	authority: RaidAuthority,
	expected_generation: int,
	initial_tick: int = 0
) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.UNBOUND or _phase_active \
			or _mutation_active or _public_signal_active:
		return _reject_bool(&"health_adapter_already_bound")
	if authority == null or not is_instance_valid(authority) \
			or expected_generation <= 0 \
			or authority.generation() != expected_generation \
			or authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or authority.last_processed_tick != initial_tick:
		return _reject_bool(&"health_raid_authority_invalid")
	var admission := authority.admission()
	if admission == null or not admission.is_usable():
		return _reject_bool(&"health_raid_admission_invalid")
	var policy := ZerkovHealthConsequencePolicy.validate()
	if not bool(policy.get("ok", false)) \
			or String(policy.get("digest", "")).length() != 64:
		return _reject_bool(&"health_consequence_policy_invalid")
	var journal_records := authority.journal.records()
	if not _journal_records_are_contiguous(journal_records):
		return _reject_bool(&"health_journal_invalid")
	for record_value in journal_records:
		var record := record_value as Dictionary
		if String(record.get("kind", "")) == "hit":
			return _reject_bool(&"health_adapter_bound_after_hit_history")

	var next_generation := _generation_counter + 1
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	_raid_generation = expected_generation
	_admission = admission.snapshot()
	_policy_digest = String(policy["digest"])
	_last_tick = initial_tick
	_journal_cursor = journal_records.size()
	var callback := _phase_callback(next_generation)
	if not authority.register_phase_handler(
			RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
			PHASE_HANDLER_ID, callback, expected_generation,
			PHASE_HANDLER_PRIORITY):
		var registration_error := authority.last_error
		_reset_binding_refs()
		last_error = registration_error
		return false
	_phase_registration_id = authority.phase_handler_registration_id(
		PHASE_HANDLER_ID, expected_generation)
	if _phase_registration_id.is_empty() \
			or not authority.has_exact_phase_handler(
				PHASE_HANDLER_ID, _phase_registration_id, callback,
				RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
				expected_generation):
		authority.unregister_phase_handler(PHASE_HANDLER_ID, expected_generation)
		_reset_binding_refs()
		return _reject_bool(&"health_phase_registration_invalid")
	_phase_registered = true
	_generation_counter = next_generation
	_binding_generation = next_generation
	lifecycle = Lifecycle.BOUND
	return true


## A concrete executor registration, not a general resource mutation port.
func bind_melee_executor(executor: RefCounted, registration: String) -> bool:
	if not is_bound() or _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
		or _melee_executor_ref != null or executor == null \
		or executor.get_script() != load("res://game/combat/execution/raid_combat_execution.gd") \
		or not _authority.has_exact_phase_handler(&"combat_execution_due", registration,
			Callable(executor, "_due"), RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK, _raid_generation):
		return _reject_bool(&"health_melee_binding_invalid")
	_melee_executor_ref = weakref(executor)
	_melee_registration = registration
	return true

## Cost commits only after this tick's damage/bleed/death/treatment processing.
## No caller-provided magnitude and no presentation callback can spend stamina.
func commit_melee_start(executor: RefCounted, actor_id: ZEntityId, request_id: ZRequestId,
	archetype: StringName, tick: int) -> Dictionary:
	if not is_bound() or _phase_active or _mutation_active or _public_signal_active \
		or _melee_executor_ref == null or _melee_executor_ref.get_ref() != executor \
		or actor_id == null or request_id == null or _last_tick != tick \
		or not _authority.is_dispatching_phase_registration(&"combat_execution_due", _melee_registration,
			Callable(executor, "_due"), RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK, tick, _raid_generation):
		return _rejection(&"health_melee_phase_invalid")
	var definition := ZMeleePolicy.definition(archetype)
	var key := actor_id.canonical_key()
	var request_key := request_id.canonical_key()
	if definition.is_empty() or not _actors.has(key):
		return _rejection(&"health_melee_actor_invalid")
	var fingerprint := ZCanonicalValue.sha256([key, request_key, archetype, tick, _raid_generation])
	if _melee_costs.has(request_key):
		var previous: Dictionary = _melee_costs[request_key]
		if previous.fingerprint != fingerprint:
			return _rejection(&"health_melee_identity_conflict")
		return _read_only_copy(previous.receipt)
	var actor: Dictionary = _actors[key]
	if bool(actor.dead): return _rejection(&"health_actor_dead")
	var amount := int(definition.cost_micros)
	var component := actor.component as GameplayAbilityComponent
	var before_stamina := _fixed_micros(component.get_attribute_current(String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)))
	if before_stamina < amount:
		return _rejection(&"stamina_insufficient")
	if amount > 0:
		_mutation_active = true
		var before := component.write_snapshot()
		var sequence := _reserve_actor_sequence(actor)
		var result := ZerkovHealthAbilityContent.apply_bounded_instant(component,
			_actor_spec(actor, ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND),
			ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND, amount, tick, sequence)
		if not _bounded_damage_committed(result, amount) \
			or _fixed_micros(component.get_attribute_current(String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA))) != before_stamina - amount:
			_fail_component_mutation(&"melee_stamina_commit_failed", actor, before, result)
			_mutation_active = false
			return _rejection(&"melee_stamina_commit_failed", {"requires_recovery": true})
		actor.health_revision = int(actor.health_revision) + 1
		actor.state_digest = _health_state_digest(actor)
		_actors[key] = actor
		_mutation_active = false
	var receipt := {"accepted": true, "committed": true, "request_id": request_key,
		"actor_id": key, "tick": tick, "cost_micros": amount, "definition_id": definition.id}
	_melee_costs[request_key] = {"tick": tick, "fingerprint": fingerprint, "receipt": receipt}
	return _read_only_copy(receipt)


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func binding_generation() -> int:
	return _binding_generation


func actor_count() -> int:
	return _actors.size()


func damage_result_count() -> int:
	return _damage_results.size()


func pending_treatment_count() -> int:
	return _pending_treatment_record_count()


func bleed_schedule_count() -> int:
	return _bleed_schedules.size()


func recovery_details() -> Dictionary:
	return _read_only_copy(_recovery)


## Registration owns the component's health runtime for this raid generation.
## It initializes task-5.5 state, grants every dormant transition ability in a
## deterministic order, and publishes initial liveness before ACTIVE begins.
func register_actor(
	actor_id: ZEntityId,
	source: ZRaidIntent.Source,
	component: GameplayAbilityComponent,
	native_entity_id: int,
	initial_tick: int = 0
) -> Dictionary:
	last_error = &""
	if not is_bound() or _phase_active or _mutation_active or _public_signal_active:
		return _rejection(&"health_adapter_not_mutable")
	if _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING:
		return _rejection(&"health_actor_registration_closed")
	if initial_tick != _last_tick \
			or _authority.last_processed_tick != _last_tick:
		return _rejection(&"health_actor_registration_tick_invalid")
	if actor_id == null or ZEntityId.parse(actor_id.canonical_key()) == null \
			or not _authority.has_authorized_actor_source(
				actor_id, source, _raid_generation):
		return _rejection(&"health_actor_identity_invalid")
	var actor_key := actor_id.canonical_key()
	if _actors.has(actor_key) or native_entity_id <= 0 \
			or _native_entity_owners.has(native_entity_id) \
			or _actors.size() >= MAX_ACTORS:
		return _rejection(&"health_actor_identity_collision_or_capacity")
	if component == null or not is_instance_valid(component) \
			or component.entity_id != native_entity_id:
		return _rejection(&"health_component_entity_mismatch")
	var before := component.write_snapshot()
	if before.is_empty():
		return _rejection(&"health_component_snapshot_unavailable")
	# Initialization grants the native alive bootstrap ability and therefore
	# emits callbacks. Fence the entire mutation lifetime, including rollback,
	# before crossing the first callback-producing boundary.
	_mutation_active = true
	var initialized := ZerkovHealthAbilityContent.initialize_component(
		component, initial_tick)
	if not _registration_context_is_current(
			component, native_entity_id, initial_tick):
		return _abort_registration_context(
			component, before, &"initialize_component")
	if not bool(initialized.get("accepted", false)) \
			or StringName(initialized.get("life_state", &"")) != &"alive":
		return _rollback_registration(
			component, before, StringName(initialized.get(
				"reason", &"health_component_initialization_failed")), initialized)
	var abilities := _required_ability_identifiers()
	var existing := _existing_required_grants(component, abilities)
	if not existing.is_empty():
		return _rollback_registration(
			component, before, &"health_ability_provenance_conflict", existing)
	var diagnostics := component.get_diagnostics()
	if int(diagnostics.get("grant_count", ZerkovHealthAbilityContent.MAX_ABILITY_GRANTS)) \
			+ abilities.size() > ZerkovHealthAbilityContent.MAX_ABILITY_GRANTS:
		return _rollback_registration(
			component, before, &"health_ability_grant_capacity", diagnostics)
	for ability_identifier in abilities:
		if component.ability_id_of(String(ability_identifier)) <= 0:
			return _rollback_registration(
				component, before, &"health_ability_definition_missing", {
					"ability_identifier": ability_identifier})

	var specs: Dictionary = {}
	var input_ids: Dictionary = {}
	var actor_registration_generation := 1
	for ability_identifier in abilities:
		var input_id := _grant_input_id(
			actor_key, actor_registration_generation, ability_identifier)
		var granted: Dictionary = component.grant_ability(
			String(ability_identifier), 1, input_id, initial_tick)
		var status := granted.get("status", {}) as Dictionary
		var spec := int(granted.get("spec", 0))
		if not bool(status.get("ok", false)) or bool(granted.get("queued", false)) \
				or spec <= 0:
			return _rollback_registration(
				component, before, &"health_ability_grant_failed", {
					"ability_identifier": ability_identifier,
					"grant": granted,
				})
		specs[String(ability_identifier)] = spec
		input_ids[String(ability_identifier)] = input_id
		if not _registration_context_is_current(
				component, native_entity_id, initial_tick):
			return _abort_registration_context(
				component, before, &"grant_ability")
	if not _authority.publish_weapon_actor_status(
			actor_id, true, true, initial_tick, _raid_generation):
		return _rollback_registration(
			component, before, &"health_initial_liveness_publish_failed", {
				"authority_error": _authority.last_error})
	if not _registration_context_is_current(
			component, native_entity_id, initial_tick):
		return _abort_registration_context(
			component, before, &"publish_initial_liveness")
	var record := {
		"actor_id": actor_key,
		"actor_source": int(source),
		"actor_registration_generation": actor_registration_generation,
		"native_entity_id": native_entity_id,
		"component": component,
		"component_instance_id": component.get_instance_id(),
		"catalog_fingerprint": component.get_content_manifest_fingerprint(),
		"specs": specs,
		"input_ids": input_ids,
		"next_command_sequence": 1,
		"health_revision": 0,
		"dead": false,
		"death_tick": -1,
		"death_operation_id": "",
		"medical_port": null,
		"medical_port_token": "",
		"reload_adapter": null,
		"state_digest": "",
	}
	record["state_digest"] = _health_state_digest(record)
	if String(record["state_digest"]).length() != 64:
		return _rollback_registration(
			component, before, &"health_actor_state_digest_failed", {})
	var callback := Callable(self, "_on_component_tree_exiting").bind(
		actor_key, actor_registration_generation)
	record["tree_exiting_callback"] = callback
	component.tree_exiting.connect(callback)
	_actors[actor_key] = record
	_native_entity_owners[native_entity_id] = actor_key
	_mutation_active = false
	return _read_only_copy({
		"accepted": true,
		"actor_id": actor_key,
		"actor_registration_generation": actor_registration_generation,
		"native_entity_id": native_entity_id,
		"health_revision": 0,
		"state_digest": record["state_digest"],
		"ability_count": abilities.size(),
	})


func attach_medical_inventory(
	actor_id: ZEntityId,
	port: MedicalInventoryParticipantPort,
	reload_adapter: InventoryWeaponAdapter = null
) -> bool:
	last_error = &""
	if not is_bound() or _phase_active or _mutation_active or _public_signal_active \
			or _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or actor_id == null or not _actors.has(actor_id.canonical_key()):
		return _reject_bool(&"medical_binding_context_invalid")
	if port == null or not port.is_ready() \
			or port.actor_id() != actor_id.canonical_key() \
			or port.identity_token().is_empty():
		return _reject_bool(&"medical_inventory_port_invalid")
	if reload_adapter != null:
		if not is_instance_valid(reload_adapter) or not reload_adapter.is_bound() \
				or reload_adapter.inventory_id() != port.inventory_id() \
				or reload_adapter.owner_generation() != port.owner_generation():
			return _reject_bool(&"health_reload_adapter_invalid")
	var actor_key := actor_id.canonical_key()
	var record := _actors[actor_key] as Dictionary
	if record.get("medical_port") != null:
		return _reject_bool(&"medical_inventory_already_bound")
	record["medical_port"] = port
	record["medical_port_token"] = port.identity_token()
	record["reload_adapter"] = reload_adapter
	_actors[actor_key] = record
	return true


## Queue-only admission for task 5.7's future logical-action router. No
## Gameplay Ability or inventory mutation occurs before the phase-7 callback.
func queue_treatment(request: Dictionary) -> Dictionary:
	last_error = &""
	if not is_bound() or _phase_active \
			or _mutation_active or _public_signal_active:
		return _rejection(&"health_treatment_queue_unavailable")
	# Stable identity replay is resolved before time/revision admission. A
	# reconnect may redeliver the exact command after its target tick; treating
	# that as a new stale command would lose exactly-once observability.
	if not _has_exact_keys(request, TREATMENT_REQUEST_KEYS) \
			or not ZCanonicalValue.is_bounded(request) \
			or ZRequestId.parse(String(request.get("request_id", ""))) == null:
		return _rejection(&"health_treatment_envelope_invalid")
	var request_id := String(request["request_id"])
	var fingerprint := ZCanonicalValue.sha256(request)
	if fingerprint.is_empty():
		return _rejection(&"health_treatment_request_invalid")
	if _treatment_records.has(request_id):
		var existing := _treatment_records[request_id] as Dictionary
		if String(existing.get("fingerprint", "")) != fingerprint:
			_latch_recovery(&"health_treatment_request_identity_collision", {
				"request_id": request_id})
			return _rejection(last_error, {"requires_recovery": true})
		return _read_only_copy(existing.get("receipt", {}) as Dictionary)
	var validation := _validate_treatment_request(request)
	if not bool(validation.get("ok", false)):
		return _rejection(StringName(validation.get(
			"reason", &"health_treatment_request_invalid")))
	if _treatment_records.size() >= MAX_TREATMENT_REQUESTS \
			or _pending_treatment_record_count() >= MAX_PENDING_TREATMENTS:
		return _rejection(&"health_treatment_queue_capacity")
	var receipt := {
		"accepted": true,
		"queued": true,
		"terminal": false,
		"committed": false,
		"replayed": false,
		"request_id": request_id,
		"target_tick": int(request["target_tick"]),
		"actor_id": String(request["actor_id"]),
		"body_zone": StringName(request["body_zone"]),
		"treatment": StringName(request["treatment"]),
		"reason": &"",
	}
	_treatment_records[request_id] = {
		"fingerprint": fingerprint,
		"request": request.duplicate(true),
		"receipt": receipt,
		"pending": true,
		"processing": false,
		"mutation_state": MedicalInventoryParticipantPort.MUTATION_NONE,
		"reservation_id": "",
	}
	_treatment_order.append(request_id)
	_sort_treatment_order()
	return _read_only_copy(receipt)


func treatment_receipt(request_id: String) -> Dictionary:
	var record := _treatment_records.get(request_id, {}) as Dictionary
	return _read_only_copy(record.get("receipt", {}) as Dictionary)


func damage_result(operation_id: String) -> Dictionary:
	return _read_only_copy(_damage_results.get(operation_id, {}) as Dictionary)


func actor_snapshot(actor_id: ZEntityId) -> Dictionary:
	if actor_id == null:
		return _read_only_copy({})
	var record := _actors.get(actor_id.canonical_key(), {}) as Dictionary
	if record.is_empty():
		return _read_only_copy({})
	return _read_only_copy(_actor_snapshot_from_record(record))


func actor_snapshots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var actor_ids := PackedStringArray(_actors.keys())
	actor_ids.sort()
	for actor_key in actor_ids:
		result.append(_read_only_copy(
			_actor_snapshot_from_record(_actors[actor_key] as Dictionary)))
	result.make_read_only()
	return result


func handle_raid_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	expected_binding_generation: int
) -> bool:
	last_error = &""
	if lifecycle == Lifecycle.INVALIDATED:
		return true
	if expected_binding_generation != _binding_generation \
			or lifecycle != Lifecycle.BOUND:
		return _reject_bool(&"health_consequence_recovery_required")
	var callback := _phase_callback(expected_binding_generation)
	if authority != _authority \
			or authority.get_instance_id() != _authority_instance_id \
			or phase != RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK \
			or not authority.is_dispatching_phase_registration(
				PHASE_HANDLER_ID, _phase_registration_id, callback,
				phase, tick, _raid_generation):
		return _reject_bool(&"health_phase_dispatch_invalid")
	if _phase_active or _mutation_active or _public_signal_active:
		return _reject_bool(&"health_phase_reentrant")
	_phase_active = true
	var ok := _advance_phase(tick)
	_phase_active = false
	return ok


func release_binding(
	reason: StringName = &"teardown",
	tick: int = -1,
	teardown_components: bool = true
) -> bool:
	last_error = &""
	if _phase_active or _mutation_active or _public_signal_active:
		return _reject_bool(&"health_binding_change_reentrant")
	if lifecycle != Lifecycle.BOUND and lifecycle != Lifecycle.RECOVERY_REQUIRED \
			and lifecycle != Lifecycle.INVALIDATED:
		return _reject_bool(&"health_adapter_not_bound")
	var effective_tick := maxi(_last_tick, tick)
	if effective_tick < 0 or effective_tick > MAX_AUTHORITY_TICK:
		return _reject_bool(&"health_teardown_tick_invalid")
	# Participant clear and component teardown may synchronously emit native
	# callbacks. Fence the complete teardown before crossing either boundary and
	# funnel every guarded exit through this wrapper so a failed release remains
	# retryable without permitting a callback to consume the binding recursively.
	_mutation_active = true
	var released := _release_binding_mutation(
		reason, effective_tick, teardown_components)
	_mutation_active = false
	return released


func _release_binding_mutation(
	reason: StringName,
	effective_tick: int,
	teardown_components: bool
) -> bool:
	if _phase_registered and _authority != null and is_instance_valid(_authority):
		var callback := _phase_callback(_binding_generation)
		if _authority.has_exact_phase_handler(
				PHASE_HANDLER_ID, _phase_registration_id, callback,
				RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
				_raid_generation):
			if not _authority.can_unregister_phase_handler(
					PHASE_HANDLER_ID, _raid_generation) \
					or not _authority.unregister_phase_handler(
						PHASE_HANDLER_ID, _raid_generation):
				return _reject_bool(_authority.last_error)
		elif _authority.generation() == _raid_generation \
				and (_authority.lifecycle == RaidAuthority.Lifecycle.PREPARING \
					or _authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE \
					or _authority.lifecycle == RaidAuthority.Lifecycle.EXTRACTING):
			return _reject_bool(&"health_phase_registration_lost")
	_phase_registered = false
	var actor_ids := PackedStringArray(_actors.keys())
	actor_ids.sort()
	var teardown_plan: Array[Dictionary] = []
	for actor_key in actor_ids:
		var record := _actors.get(actor_key, {}) as Dictionary
		if record.is_empty():
			return _latch_recovery(&"health_teardown_actor_missing", {
				"actor_id": actor_key})
		teardown_plan.append({"actor_id": actor_key, "record": record})
	for entry in teardown_plan:
		var actor_key := String(entry["actor_id"])
		var record := entry["record"] as Dictionary
		_disconnect_actor_callback(record)
		var port := record.get("medical_port") as MedicalInventoryParticipantPort
		if port != null and not port.clear():
			_latch_recovery(&"medical_inventory_release_failed", {
				"actor_id": actor_key, "port": port.recovery_details()})
			return false
		var component := record.get("component") as GameplayAbilityComponent
		if teardown_components and component != null and is_instance_valid(component) \
				and not component.is_torn_down():
			component.queue_teardown(maxi(effective_tick, component.get_current_tick()))
			if not component.is_torn_down() or component.is_owner_valid():
				_latch_recovery(&"health_component_teardown_unproven", {
					"actor_id": actor_key})
				return false
	# A receipt remains pending while participant/component teardown is
	# unproven. Only the completed authoritative boundary may terminalize a
	# dequeued in-flight cross-domain treatment.
	_finalize_pending_treatments(&"health_adapter_released")
	_actors.clear()
	_melee_costs.clear()
	_melee_executor_ref = null
	_melee_registration = ""
	_native_entity_owners.clear()
	_bleed_schedules.clear()
	_phase_cancelled_bleeds.clear()
	_treatment_order.clear()
	_generation_counter += 1
	_binding_generation = _generation_counter
	_reset_binding_refs()
	lifecycle = Lifecycle.RELEASED
	last_error = reason
	_emit_binding_invalidated(reason)
	# A listener can make a rejected nested public call during synchronous delivery.
	last_error = reason
	_disconnect_public_signal_callbacks()
	return true


func recover_by_teardown(tick: int = -1) -> bool:
	if lifecycle != Lifecycle.RECOVERY_REQUIRED:
		return false
	return release_binding(&"recovery_teardown", tick, true)


func _advance_phase(tick: int) -> bool:
	if not _binding_is_current() or tick != _last_tick + 1 \
			or tick <= 0 or tick > MAX_AUTHORITY_TICK:
		return _latch_recovery(&"health_phase_tick_or_binding_invalid", {
			"tick": tick, "last_tick": _last_tick})
	if not _phase_cancelled_bleeds.is_empty():
		return _latch_recovery(&"health_bleed_cancellation_state_stale", {
			"tick": tick, "cancellations": _phase_cancelled_bleeds})
	for key: String in _melee_costs.keys():
		if tick - int(_melee_costs[key].tick) > 120: _melee_costs.erase(key)
	var actor_ids := PackedStringArray(_actors.keys())
	actor_ids.sort()
	for actor_key in actor_ids:
		var actor := _actors[actor_key] as Dictionary
		var audit := _audit_actor_state(actor, tick)
		if not bool(audit.get("ok", false)):
			return _latch_recovery(StringName(audit.get(
				"reason", &"health_actor_state_diverged")), {
					"actor_id": actor_key, "audit": audit})

	var collected := _collect_weapon_hits(tick)
	if not bool(collected.get("ok", false)):
		return _latch_recovery(StringName(collected.get(
			"reason", &"health_hit_stream_invalid")), collected)
	var hits := collected.get("hits", []) as Array
	var due_bleeds := _due_bleed_keys(tick)
	var due_treatments := _due_treatment_ids(tick)
	var budget := _preflight_phase_budget(
		hits.size(), due_bleeds.size(), due_treatments.size())
	if not bool(budget.get("ok", false)):
		return _latch_recovery(StringName(budget.get(
			"reason", &"health_phase_capacity_exceeded")), budget)

	for hit_value in hits:
		if not _apply_weapon_hit(hit_value as Dictionary, tick):
			return false
	for schedule_key in due_bleeds:
		if not _bleed_schedules.has(String(schedule_key)):
			# Due work is snapshotted before hits. An earlier same-phase lethal
			# consequence intentionally cancels every actor bleed, including a due
			# entry. Only that explicitly recorded transition may remove a captured
			# key; any other disappearance remains a fail-stop invariant breach.
			var cancellation := _phase_cancelled_bleeds.get(
				String(schedule_key), {}) as Dictionary
			if cancellation.get("reason") == &"death" \
					and int(cancellation.get("tick", -1)) == tick:
				continue
			return _latch_recovery(&"health_bleed_schedule_disappeared", {
				"schedule_key": schedule_key, "tick": tick})
		if not _apply_bleed_tick(String(schedule_key), tick):
			return false
	for request_id in due_treatments:
		if not _process_treatment(String(request_id), tick):
			return false
	for actor_key in actor_ids:
		if not _actors.has(actor_key):
			continue
		var record := _actors[actor_key] as Dictionary
		var component := record.get("component") as GameplayAbilityComponent
		if component == null or not is_instance_valid(component):
			return _latch_recovery(&"health_component_invalid", {"actor_id": actor_key})
		var advanced: Dictionary = component.advance_to(tick)
		if not bool((advanced.get("status", {}) as Dictionary).get("ok", false)):
			return _latch_recovery(&"health_component_advance_failed", {
				"actor_id": actor_key, "result": advanced})
		record["state_digest"] = _health_state_digest(record)
		if String(record["state_digest"]).length() != 64:
			return _latch_recovery(&"health_state_digest_failed", {"actor_id": actor_key})
		_actors[actor_key] = record
	_journal_cursor = int(collected.get("cursor", _journal_cursor))
	_last_tick = tick
	_phase_cancelled_bleeds.clear()
	return true


func _collect_weapon_hits(tick: int) -> Dictionary:
	var records := _authority.journal.records()
	if not _journal_records_are_contiguous(records) \
			or _journal_cursor < 0 or _journal_cursor > records.size():
		return {"ok": false, "reason": &"health_journal_sequence_invalid"}
	var hits: Array[Dictionary] = []
	var cursor := _journal_cursor
	for index in range(_journal_cursor, records.size()):
		var event := records[index] as Dictionary
		var sequence := int(event.get("sequence", 0))
		if sequence != index + 1 \
				or String(event.get("raid_id", "")) != _admission.raid_id.canonical_key():
			return {"ok": false, "reason": &"health_journal_sequence_invalid"}
		var event_tick := int(event.get("tick", -1))
		if event_tick > tick:
			return {"ok": false, "reason": &"health_journal_future_event"}
		cursor = sequence
		if String(event.get("kind", "")) != "hit":
			continue
		if event_tick != tick:
			return {"ok": false, "reason": &"health_hit_delivery_late"}
		var validation := _validate_weapon_consequence(event, tick)
		if not bool(validation.get("ok", false)):
			return validation
		if bool(validation.get("hit", false)):
			hits.append(validation["input"] as Dictionary)
	return {"ok": true, "hits": hits, "cursor": cursor}


func _validate_weapon_consequence(event: Dictionary, tick: int) -> Dictionary:
	var payload := event.get("payload", {}) as Dictionary
	if payload.get("schema") == MELEE_CONSEQUENCE_SCHEMA:
		return _validate_melee_consequence(event, tick)
	if not _has_exact_keys(payload, WEAPON_CONSEQUENCE_KEYS) \
			or String(payload.get("schema", "")) != WEAPON_CONSEQUENCE_SCHEMA \
			or not bool(payload.get("accepted", false)) \
			or int(payload.get("tick", -1)) != tick \
			or String(payload.get("raid_id", "")) != _admission.raid_id.canonical_key() \
			or String(payload.get("session_id", "")) != _admission.session_id.canonical_key() \
			or int(payload.get("authority_epoch", 0)) != _admission.authority_epoch \
			or int(payload.get("authority_generation", 0)) != _raid_generation \
			or String(payload.get("consequence_id", "")) != String(event.get("event_id", "")) \
			or String(payload.get("actor_id", "")) != String(event.get("actor_id", "")):
		return {"ok": false, "reason": &"health_weapon_consequence_envelope_invalid"}
	var digest_source := payload.duplicate(true)
	var claimed_digest := String(digest_source.get("resolution_digest", ""))
	digest_source.erase("resolution_digest")
	if claimed_digest.length() != 64 \
			or ZCanonicalValue.sha256(digest_source) != claimed_digest:
		return {"ok": false, "reason": &"health_weapon_consequence_digest_invalid"}
	if ZConsequenceId.parse(String(payload["consequence_id"])) == null \
			or ZEntityId.parse(String(payload["actor_id"])) == null:
		return {"ok": false, "reason": &"health_weapon_consequence_identity_invalid"}
	var is_hit := bool(payload.get("hit", false))
	if not is_hit:
		if StringName(payload.get("outcome", &"")) != &"miss" \
				or not String(payload.get("entity_id", "")).is_empty() \
				or not String(payload.get("body_zone", "")).is_empty():
			return {"ok": false, "reason": &"health_weapon_miss_invalid"}
		return {"ok": true, "hit": false}
	var target_key := String(payload.get("entity_id", ""))
	var zone := StringName(payload.get("body_zone", &""))
	if StringName(payload.get("outcome", &"")) != &"hit" \
			or bool(payload.get("blocked", true)) \
			or ZEntityId.parse(target_key) == null \
			or not _actors.has(target_key) \
			or ZerkovHealthAbilityContent.body_zone_declaration(zone).is_empty() \
			or typeof(payload.get("damage_milliunits")) != TYPE_INT \
			or int(payload["damage_milliunits"]) <= 0:
		return {"ok": false, "reason": &"health_weapon_hit_invalid"}
	var operation_id := String(payload["consequence_id"])
	var fingerprint := ZCanonicalValue.sha256(payload)
	if fingerprint.is_empty():
		return {"ok": false, "reason": &"health_weapon_consequence_digest_invalid"}
	if _damage_results.has(operation_id):
		var existing := _damage_results[operation_id] as Dictionary
		if String(existing.get("source_fingerprint", "")) != fingerprint:
			return {"ok": false, "reason": &"health_damage_identity_collision"}
		return {"ok": true, "hit": false}
	return {
		"ok": true,
		"hit": true,
		"input": {
			"operation_id": operation_id,
			"source_fingerprint": fingerprint,
			"source_type": &"weapon_hit",
			"source_event_sequence": int(event["sequence"]),
			"source_consequence": payload.duplicate(true),
			"attacker_id": String(payload["actor_id"]),
			"target_id": target_key,
			"body_zone": zone,
			"damage_milliunits": int(payload["damage_milliunits"]),
		},
	}


func _validate_melee_consequence(event: Dictionary, tick: int) -> Dictionary:
	var payload: Dictionary = event.get("payload", {})
	var names := PackedStringArray(["schema", "raid_id", "session_id", "authority_epoch",
		"authority_generation", "consequence_id", "request_id", "actor_id", "actor_source",
		"tick", "start_tick", "definition_id", "damage_milliunits", "hit", "blocked",
		"entity_id", "body_zone", "world_revision", "world_resolution_digest", "resolution_digest"])
	if not _has_exact_keys(payload, names) or not ZCanonicalValue.is_bounded(payload) \
		or payload.get("tick") != tick or payload.get("raid_id") != _admission.raid_id.canonical_key() \
		or payload.get("session_id") != _admission.session_id.canonical_key() \
		or payload.get("authority_epoch") != _admission.authority_epoch \
		or payload.get("authority_generation") != _raid_generation \
		or payload.get("consequence_id") != event.get("event_id") or payload.get("actor_id") != event.get("actor_id") \
		or not _melee_costs.has(String(payload.get("request_id", ""))):
		return {"ok": false, "reason": &"health_melee_envelope_invalid"}
	var executor: RefCounted = _melee_executor_ref.get_ref() if _melee_executor_ref != null else null
	var digest_source := payload.duplicate(true)
	digest_source.erase("resolution_digest")
	if executor == null or ZCanonicalValue.sha256(digest_source) != payload.resolution_digest \
		or not executor.call("has_contact", String(event.event_id), String(payload.resolution_digest)):
		return {"ok": false, "reason": &"health_melee_contact_uncommitted"}
	var cost: Dictionary = _melee_costs[payload.request_id].receipt
	if cost.actor_id != payload.actor_id or cost.definition_id != payload.definition_id or cost.tick != payload.start_tick:
		return {"ok": false, "reason": &"health_melee_cost_mismatch"}
	if not payload.hit:
		return {"ok": true, "hit": false}
	if not _actors.has(payload.entity_id) or not _actors.has(payload.actor_id) or payload.blocked \
		or ZerkovHealthAbilityContent.body_zone_declaration(StringName(payload.body_zone)).is_empty():
		return {"ok": false, "reason": &"health_melee_target_invalid"}
	return {"ok": true, "hit": true, "input": {
		"operation_id": event.event_id, "source_fingerprint": ZCanonicalValue.sha256(payload),
		"source_type": &"melee_hit", "source_event_sequence": event.sequence,
		"source_consequence": payload.duplicate(true), "attacker_id": payload.actor_id,
		"target_id": payload.entity_id, "body_zone": payload.body_zone,
		"damage_milliunits": payload.damage_milliunits}}


func _apply_weapon_hit(input: Dictionary, tick: int) -> bool:
	# Firearm consequences precede melee contacts in phase 6. A same-tick lethal
	# firearm hit cancels an attacker's melee consequence before health mutation.
	if input.get("source_type") == &"melee_hit" and bool(_actors.get(input.attacker_id, {}).get("dead", true)):
		return true
	var conversion := ZWorldUnits.weapon_damage_to_ability(
		int(input["damage_milliunits"]))
	if not conversion.ok or conversion.integer_value <= 0 \
			or conversion.integer_value \
				> ZerkovHealthAbilityContent.MAX_APPLICATION_AMOUNT_MICROS:
		return _latch_recovery(&"health_damage_conversion_invalid", input)
	return _apply_damage_operation(
		String(input["operation_id"]), String(input["source_fingerprint"]),
		StringName(input["source_type"]), String(input["attacker_id"]),
		String(input["target_id"]), StringName(input["body_zone"]),
		conversion.integer_value, tick, true,
		{"source_event_sequence": int(input["source_event_sequence"]),
		 "source_consequence": input["source_consequence"]})


func _apply_bleed_tick(schedule_key: String, tick: int) -> bool:
	var schedule := _bleed_schedules.get(schedule_key, {}) as Dictionary
	if schedule.is_empty() or int(schedule.get("next_due_tick", -1)) != tick:
		return _latch_recovery(&"health_bleed_schedule_invalid", {
			"schedule_key": schedule_key, "tick": tick})
	var actor_key := String(schedule["actor_id"])
	var zone := StringName(schedule["body_zone"])
	var actor := _actors.get(actor_key, {}) as Dictionary
	if actor.is_empty():
		return _latch_recovery(&"health_bleed_actor_missing", schedule)
	var component := actor.get("component") as GameplayAbilityComponent
	var zone_declaration := ZerkovHealthAbilityContent.body_zone_declaration(zone)
	if bool(actor.get("dead", false)) \
			or not component.has_tag_exact(String(zone_declaration[
				"heavy_bleed_tag_identifier"])):
		_bleed_schedules.erase(schedule_key)
		return true
	var operation_id := _stable_id("bleed_tick", {
		"schedule_id": String(schedule["schedule_id"]),
		"tick": tick,
		"ordinal": int(schedule["ordinal"]),
	})
	if operation_id.is_empty():
		return _latch_recovery(&"health_bleed_identity_invalid", schedule)
	var fingerprint := ZCanonicalValue.sha256({
		"operation_id": operation_id,
		"schedule": schedule,
		"tick": tick,
	})
	var applied := _apply_damage_operation(
		operation_id, fingerprint, &"heavy_bleed_tick",
		String(schedule["attacker_id"]), actor_key, zone,
		int(zone_declaration["heavy_bleed_damage_micros"]), tick, false,
		{"schedule_id": String(schedule["schedule_id"]),
		 "ordinal": int(schedule["ordinal"])})
	if not applied:
		return false
	if _bleed_schedules.has(schedule_key):
		actor = _actors[actor_key] as Dictionary
		if bool(actor.get("dead", false)):
			_bleed_schedules.erase(schedule_key)
		else:
			schedule["ordinal"] = int(schedule["ordinal"]) + 1
			schedule["next_due_tick"] = tick \
				+ int(zone_declaration["heavy_bleed_period_ticks"])
			_bleed_schedules[schedule_key] = schedule
	return true


func _apply_damage_operation(
	operation_id: String,
	source_fingerprint: String,
	source_type: StringName,
	attacker_key: String,
	target_key: String,
	zone: StringName,
	requested_micros: int,
	tick: int,
	evaluate_injuries: bool,
	extra: Dictionary
) -> bool:
	if _damage_results.has(operation_id):
		var replay := _damage_results[operation_id] as Dictionary
		if String(replay.get("source_fingerprint", "")) != source_fingerprint:
			return _latch_recovery(&"health_damage_identity_collision", {
				"operation_id": operation_id})
		return true
	if _damage_results.size() >= MAX_DAMAGE_RESULTS:
		return _latch_recovery(&"health_damage_ledger_capacity", {
			"operation_id": operation_id})
	var actor := _actors.get(target_key, {}) as Dictionary
	if actor.is_empty():
		return _latch_recovery(&"health_damage_target_missing", {
			"target_id": target_key})
	var audit := _audit_actor_state(actor, tick)
	if not bool(audit.get("ok", false)):
		return _latch_recovery(StringName(audit.get(
			"reason", &"health_actor_state_diverged")), audit)
	if bool(actor.get("dead", false)):
		var ignored := _damage_outcome(
			operation_id, source_fingerprint, source_type, attacker_key,
			target_key, zone, requested_micros, 0, tick, actor, [], true, extra)
		if ignored.is_empty():
			return _latch_recovery(&"health_damage_outcome_invalid", {
				"operation_id": operation_id})
		_damage_results[operation_id] = ignored
		_emit_damage(ignored)
		return true
	var component := actor.get("component") as GameplayAbilityComponent
	var zone_declaration := ZerkovHealthAbilityContent.body_zone_declaration(zone)
	var policy := ZerkovHealthConsequencePolicy.zone_rule(zone)
	if zone_declaration.is_empty() or policy.is_empty() \
			or requested_micros <= 0 \
			or requested_micros > ZerkovHealthAbilityContent.MAX_APPLICATION_AMOUNT_MICROS:
		return _latch_recovery(&"health_damage_policy_invalid", {
			"operation_id": operation_id, "body_zone": zone})
	var health_attribute := StringName(zone_declaration["health_attribute_identifier"])
	var current_before := mini(
		_fixed_micros(component.get_attribute_base(String(health_attribute))),
		_fixed_micros(component.get_attribute_current(String(health_attribute))))
	var applied_expected := mini(requested_micros, maxi(0, current_before))
	var lethal := bool(zone_declaration["lethal_at_zero"]) \
		and current_before > 0 and applied_expected >= current_before
	var injuries := PackedStringArray()
	if evaluate_injuries and not lethal:
		for injury in ZerkovHealthConsequencePolicy.injuries_for_damage(
				zone, applied_expected):
			if _injury_transition_needed(component, zone_declaration, StringName(injury)):
				injuries.append(injury)
	if injuries.has(String(ZerkovHealthConsequencePolicy.INJURY_HEAVY_BLEED)) \
			and not _bleed_schedules.has(_bleed_schedule_key(target_key, zone)) \
			and _bleed_schedules.size() >= MAX_BLEED_SCHEDULES:
		return _latch_recovery(&"health_bleed_schedule_capacity", {
			"operation_id": operation_id})
	var event_plan := _damage_event_plan(
		operation_id, attacker_key, target_key, zone, injuries,
		lethal, source_type)
	if not _preflight_event_plan(event_plan, tick):
		return false
	var damage_ability := StringName(zone_declaration["damage_ability_identifier"])
	if not _spec_is_live(actor, damage_ability):
		return _latch_recovery(&"health_damage_ability_invalid", {
			"actor_id": target_key, "ability": damage_ability})
	for injury in injuries:
		var injury_ability := _injury_ability(zone_declaration, StringName(injury))
		if not _spec_is_live(actor, injury_ability):
			return _latch_recovery(&"health_injury_ability_invalid", {
				"actor_id": target_key, "ability": injury_ability})
	if lethal and not _spec_is_live(
			actor, ZerkovHealthAbilityContent.ABILITY_LIFE_DEAD):
		return _latch_recovery(&"health_death_ability_invalid", {
			"actor_id": target_key})

	var before := component.write_snapshot()
	if before.is_empty():
		return _latch_recovery(&"health_component_snapshot_unavailable", {
			"actor_id": target_key})
	_mutation_active = true
	var damage_sequence := _reserve_actor_sequence(actor)
	if damage_sequence <= 0:
		_mutation_active = false
		return _latch_recovery(&"health_command_sequence_exhausted", {
			"actor_id": target_key})
	var damage_result := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, _actor_spec(actor, damage_ability),
		StringName(zone_declaration["damage_effect_identifier"]),
		requested_micros, tick, damage_sequence)
	if not _bounded_damage_committed(damage_result, applied_expected):
		_mutation_active = false
		return _fail_component_mutation(
			&"health_damage_application_failed", actor, before, damage_result)
	var injury_results: Array[Dictionary] = []
	for injury in injuries:
		var injury_ability := _injury_ability(zone_declaration, StringName(injury))
		var activation := _activate_owned(actor, injury_ability, tick)
		if not bool(activation.get("accepted", false)):
			_mutation_active = false
			return _fail_component_mutation(
				&"health_injury_activation_failed", actor, before, activation)
		injury_results.append({
			"injury": StringName(injury),
			"ability_identifier": injury_ability,
			"execution": int(activation.get("execution", 0)),
			"command_sequence": int(activation.get("command_sequence", 0)),
		})
	var death_activation: Dictionary = {}
	if lethal:
		death_activation = _activate_owned(
			actor, ZerkovHealthAbilityContent.ABILITY_LIFE_DEAD, tick)
		if not bool(death_activation.get("accepted", false)):
			_mutation_active = false
			return _fail_component_mutation(
				&"health_death_activation_failed", actor, before, death_activation)
	var advanced: Dictionary = component.advance_to(tick)
	_mutation_active = false
	if not bool((advanced.get("status", {}) as Dictionary).get("ok", false)):
		return _fail_component_mutation(
			&"health_component_advance_failed", actor, before, advanced)
	var base_after := _fixed_micros(
		component.get_attribute_base(String(health_attribute)))
	var current_after := _fixed_micros(
		component.get_attribute_current(String(health_attribute)))
	if base_after != current_before - applied_expected \
			or current_after < 0 or current_after > int(zone_declaration["max_health_micros"]):
		return _fail_component_mutation(
			&"health_damage_postcondition_failed", actor, before, {
				"base_after": base_after, "current_after": current_after})
	for injury in injuries:
		if not _injury_is_active(component, zone_declaration, StringName(injury)):
			return _fail_component_mutation(
				&"health_injury_postcondition_failed", actor, before, {
					"injury": injury})
	if lethal and not _component_is_dead(component):
		return _fail_component_mutation(
			&"health_death_postcondition_failed", actor, before, {})

	if lethal:
		actor["dead"] = true
		actor["death_tick"] = tick
		actor["death_operation_id"] = operation_id
		_remove_actor_bleeds(target_key, tick, operation_id)
		var target_id := ZEntityId.parse(target_key)
		if target_id == null or not _authority.publish_weapon_actor_status(
				target_id, false, false, tick, _raid_generation):
			return _latch_recovery(&"health_death_status_publish_failed", {
				"actor_id": target_key,
				"authority_error": _authority.last_error,
				"mutation_state": &"committed",
			})
		var interrupted := _interrupt_actor_reloads(actor, tick)
		if not bool(interrupted.get("accepted", false)):
			return _latch_recovery(&"health_death_reload_interrupt_failed", {
				"actor_id": target_key, "interruption": interrupted,
				"mutation_state": &"committed",
			})
		extra["reload_interruption"] = interrupted
	for injury in injuries:
		if StringName(injury) == ZerkovHealthConsequencePolicy.INJURY_HEAVY_BLEED:
			_start_bleed_schedule(
				target_key, zone, attacker_key, operation_id, tick, zone_declaration)
	actor["health_revision"] = int(actor["health_revision"]) + 1
	actor["state_digest"] = _health_state_digest(actor)
	_actors[target_key] = actor
	if not _commit_damage_events(
			event_plan, operation_id, attacker_key, target_key, zone,
			requested_micros, applied_expected, tick, injury_results, actor, source_type):
		return false
	var outcome_extra := extra.duplicate(true)
	outcome_extra["death_committed"] = lethal
	outcome_extra["event_ids"] = _event_ids_from_plan(event_plan)
	var outcome := _damage_outcome(
		operation_id, source_fingerprint, source_type, attacker_key,
		target_key, zone, requested_micros, applied_expected, tick,
		actor, injury_results, false, outcome_extra)
	if outcome.is_empty():
		return _latch_recovery(&"health_damage_outcome_invalid", {
			"operation_id": operation_id, "mutation_state": &"committed"})
	_damage_results[operation_id] = outcome
	_emit_damage(outcome)
	if lethal:
		_emit_death(outcome)
	return true


func _process_treatment(request_id: String, tick: int) -> bool:
	var request_record := _treatment_records.get(request_id, {}) as Dictionary
	if request_record.is_empty() or not bool(request_record.get("pending", false)):
		return _latch_recovery(&"health_treatment_queue_corrupted", {
			"request_id": request_id})
	request_record["processing"] = true
	_treatment_records[request_id] = request_record
	_remove_treatment_from_order(request_id)
	var request := request_record["request"] as Dictionary
	var actor_key := String(request["actor_id"])
	var actor := _actors.get(actor_key, {}) as Dictionary
	if actor.is_empty():
		_finalize_treatment(request_id, false, &"health_treatment_actor_missing", {})
		return true
	if int(request["actor_registration_generation"]) \
			!= int(actor["actor_registration_generation"]):
		_finalize_treatment(request_id, false, &"health_treatment_actor_stale", {})
		return true
	if bool(actor.get("dead", false)):
		_finalize_treatment(request_id, false, &"health_actor_not_alive", {})
		return true
	if int(request["expected_health_revision"]) != int(actor["health_revision"]):
		_finalize_treatment(request_id, false, &"health_revision_stale", {})
		return true
	var component := actor.get("component") as GameplayAbilityComponent
	var zone := StringName(request["body_zone"])
	var treatment := StringName(request["treatment"])
	var zone_declaration := ZerkovHealthAbilityContent.body_zone_declaration(zone)
	var medical := ZerkovHealthConsequencePolicy.treatment_declaration(treatment)
	if zone_declaration.is_empty() or medical.is_empty() \
			or not _injury_is_active(
				component, zone_declaration, StringName(medical["injury"])):
		_finalize_treatment(request_id, false, &"health_treatment_not_eligible", {})
		return true
	var port := actor.get("medical_port") as MedicalInventoryParticipantPort
	if port == null or not port.is_ready() \
			or port.identity_token() != String(actor["medical_port_token"]):
		_finalize_treatment(request_id, false, &"medical_inventory_unavailable", {})
		return true
	if port.current_revision() != int(request["expected_inventory_revision"]):
		_finalize_treatment(request_id, false, &"medical_inventory_revision_stale", {})
		return true
	var event_id := _stable_id("heal", {"request_id": request_id})
	var target_id := ZEntityId.parse(actor_key)
	var event_plan: Array[Dictionary] = [{
		"kind": ZRaidEvent.EventKind.HEAL,
		"event_id": event_id,
		"actor_id": target_id,
		"event_type": &"treatment",
	}]
	if event_id.is_empty() or not _preflight_event_plan(event_plan, tick):
		return false
	var reservation_id := _medical_reservation_id(request, actor, port)
	if reservation_id.is_empty() \
			or tick > MAX_AUTHORITY_TICK - MEDICAL_RESERVATION_TTL_TICKS:
		return _latch_recovery(&"medical_reservation_identity_invalid", {
			"request_id": request_id})
	_update_treatment_progress(
		request_id, reservation_id, MedicalInventoryParticipantPort.MUTATION_NONE)
	var prepared := port.prepare_treatment(
		reservation_id, treatment, int(request["expected_inventory_revision"]),
		tick + MEDICAL_RESERVATION_TTL_TICKS)
	_update_treatment_progress(request_id, reservation_id, StringName(prepared.get(
		"mutation_state", MedicalInventoryParticipantPort.MUTATION_AMBIGUOUS)))
	if not bool(prepared.get("accepted", false)):
		if StringName(prepared.get(
				"mutation_state", MedicalInventoryParticipantPort.MUTATION_AMBIGUOUS)) \
				!= MedicalInventoryParticipantPort.MUTATION_NONE:
			return _latch_recovery(&"medical_inventory_prepare_ambiguous", {
				"request_id": request_id, "inventory": prepared})
		_finalize_treatment(request_id, false, StringName(prepared.get(
			"reason", &"medical_inventory_prepare_rejected")), {"inventory": prepared})
		return true
	if not _medical_port_is_current(actor, port):
		return _latch_recovery(&"medical_inventory_prepare_context_lost", {
			"request_id": request_id, "inventory": prepared,
			"reservation_id": reservation_id,
		})
	var before := component.write_snapshot()
	if before.is_empty():
		var released := port.release_treatment(reservation_id)
		if not bool(released.get("accepted", false)):
			return _latch_recovery(&"medical_prepare_release_failed", {
				"request_id": request_id, "release": released})
		_finalize_treatment(request_id, false, &"health_component_snapshot_unavailable", {})
		return true
	var ability := _treatment_ability(zone_declaration, treatment)
	_mutation_active = true
	var activation := _activate_owned(actor, ability, tick)
	var advanced: Dictionary = component.advance_to(tick) \
		if bool(activation.get("accepted", false)) else {}
	_mutation_active = false
	var transition_ok := bool(activation.get("accepted", false)) \
		and bool((advanced.get("status", {}) as Dictionary).get("ok", false)) \
		and not _injury_is_active(
			component, zone_declaration, StringName(medical["injury"])) \
		and component.has_tag_exact(String(_treatment_tag(zone_declaration, treatment)))
	if not transition_ok:
		var rolled_back := _rollback_treatment_pair(component, before, port, reservation_id)
		if not bool(rolled_back.get("accepted", false)):
			return _latch_recovery(&"health_treatment_transition_recovery_required", {
				"request_id": request_id, "activation": activation,
				"advance": advanced, "rollback": rolled_back})
		_finalize_treatment(request_id, false, &"health_treatment_transition_failed", {
			"activation": activation})
		return true
	var committed := port.commit_treatment_silent(reservation_id)
	var commit_mutation := StringName(committed.get(
		"mutation_state", MedicalInventoryParticipantPort.MUTATION_AMBIGUOUS))
	_update_treatment_progress(request_id, reservation_id, commit_mutation)
	if not bool(committed.get("accepted", false)):
		if commit_mutation != MedicalInventoryParticipantPort.MUTATION_NONE:
			return _latch_recovery(&"health_treatment_commit_ambiguous", {
				"request_id": request_id, "commit": committed,
				"mutation_state": commit_mutation,
			})
		var rolled_back := _rollback_treatment_pair(component, before, port, reservation_id)
		if not bool(rolled_back.get("accepted", false)):
			return _latch_recovery(&"health_treatment_commit_recovery_required", {
				"request_id": request_id, "commit": committed,
				"rollback": rolled_back})
		_finalize_treatment(request_id, false, &"medical_inventory_commit_failed", {
			"inventory": committed})
		return true
	if not _medical_port_is_current(actor, port):
		return _latch_recovery(&"medical_inventory_commit_context_lost", {
			"request_id": request_id, "commit": committed,
			"reservation_id": reservation_id,
			"mutation_state": MedicalInventoryParticipantPort.MUTATION_COMMITTED,
		})
	var published := port.publish_treatment(reservation_id)
	var publication_mutation := StringName(published.get(
		"mutation_state", MedicalInventoryParticipantPort.MUTATION_AMBIGUOUS))
	_update_treatment_progress(request_id, reservation_id, publication_mutation)
	if not bool(published.get("accepted", false)):
		if publication_mutation != MedicalInventoryParticipantPort.MUTATION_NONE:
			return _latch_recovery(&"health_treatment_publish_ambiguous", {
				"request_id": request_id, "publication": published,
				"mutation_state": publication_mutation})
		var rolled_back := _rollback_treatment_pair(component, before, port, reservation_id)
		if not bool(rolled_back.get("accepted", false)):
			return _latch_recovery(&"health_treatment_publish_recovery_required", {
				"request_id": request_id, "publication": published,
				"rollback": rolled_back})
		_finalize_treatment(request_id, false, &"medical_inventory_publish_failed", {
			"inventory": published})
		return true
	if not _medical_port_is_current(actor, port):
		return _latch_recovery(&"medical_inventory_publish_context_lost", {
			"request_id": request_id, "publication": published,
			"reservation_id": reservation_id,
			"mutation_state": MedicalInventoryParticipantPort.MUTATION_COMMITTED,
		})
	if treatment == ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE:
		_bleed_schedules.erase(_bleed_schedule_key(actor_key, zone))
	actor["health_revision"] = int(actor["health_revision"]) + 1
	actor["state_digest"] = _health_state_digest(actor)
	_actors[actor_key] = actor
	var payload := _event_payload(HEAL_EVENT_SCHEMA, {
		"request_id": request_id,
		"reservation_id": reservation_id,
		"actor_id": actor_key,
		"body_zone": zone,
		"treatment": treatment,
		"item_identifier": published.get("item_identifier", &""),
		"inventory_id": port.inventory_id(),
		"inventory_predecessor_revision": int(published.get(
			"predecessor_revision", -1)),
		"inventory_successor_revision": int(published.get("revision", -1)),
		"health_revision": int(actor["health_revision"]),
		"tick": tick,
	})
	if payload.is_empty():
		return _latch_recovery(&"health_treatment_event_payload_invalid", {
			"request_id": request_id, "mutation_state": &"committed"})
	if not _record_event(
			ZRaidEvent.EventKind.HEAL, event_id, target_id, payload, tick):
		return false
	var outcome := {
		"accepted": true,
		"committed": true,
		"queued": false,
		"terminal": true,
		"replayed": false,
		"reason": &"",
		"request_id": request_id,
		"event_id": event_id,
		"reservation_id": reservation_id,
		"actor_id": actor_key,
		"body_zone": zone,
		"treatment": treatment,
		"item_identifier": published.get("item_identifier", &""),
		"inventory_predecessor_revision": int(published.get(
			"predecessor_revision", -1)),
		"inventory_successor_revision": int(published.get("revision", -1)),
		"health_revision": int(actor["health_revision"]),
		"tick": tick,
	}
	var outcome_digest := ZCanonicalValue.sha256(outcome)
	if outcome_digest.length() != 64:
		return _latch_recovery(&"health_treatment_outcome_invalid", {
			"request_id": request_id, "mutation_state": &"committed"})
	outcome["outcome_digest"] = outcome_digest
	_finalize_treatment(request_id, true, &"", outcome)
	_emit_treatment(outcome)
	return true


func _rollback_treatment_pair(
	component: GameplayAbilityComponent,
	before: PackedByteArray,
	port: MedicalInventoryParticipantPort,
	reservation_id: String
) -> Dictionary:
	var inventory := port.rollback_treatment(reservation_id)
	var health_restored := component.restore_snapshot(before) \
		and component.write_snapshot() == before
	return {
		"accepted": bool(inventory.get("accepted", false)) and health_restored,
		"inventory": inventory,
		"health_restored": health_restored,
	}


func _damage_event_plan(
	operation_id: String,
	attacker_key: String,
	target_key: String,
	zone: StringName,
	injuries: PackedStringArray,
	lethal: bool,
	source_type: StringName
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var target_id := ZEntityId.parse(target_key)
	for injury in injuries:
		result.append({
			"kind": ZRaidEvent.EventKind.INJURY,
			"event_id": _stable_id("injury", {
				"operation_id": operation_id, "injury": injury,
				"actor_id": target_key, "body_zone": String(zone)}),
			"actor_id": target_id,
			"event_type": StringName(injury),
		})
	if source_type == &"heavy_bleed_tick":
		result.append({
			"kind": ZRaidEvent.EventKind.INJURY,
			"event_id": _stable_id("bleed_damage", {
				"operation_id": operation_id, "actor_id": target_key,
				"body_zone": String(zone)}),
			"actor_id": target_id,
			"event_type": &"heavy_bleed_tick",
		})
	if lethal:
		result.append({
			"kind": ZRaidEvent.EventKind.DEATH,
			"event_id": _stable_id("death", {
				"operation_id": operation_id, "actor_id": target_key}),
			"actor_id": target_id,
			"event_type": &"death",
		})
		var attacker_id := ZEntityId.parse(attacker_key)
		if attacker_id != null:
			result.append({
				"kind": ZRaidEvent.EventKind.KILL,
				"event_id": _stable_id("kill", {
					"operation_id": operation_id,
					"attacker_id": attacker_key, "target_id": target_key}),
				"actor_id": attacker_id,
				"event_type": &"kill",
			})
	return result


func _commit_damage_events(
	plan: Array[Dictionary],
	operation_id: String,
	attacker_key: String,
	target_key: String,
	zone: StringName,
	requested_micros: int,
	applied_micros: int,
	tick: int,
	injury_results: Array[Dictionary],
	actor: Dictionary,
	source_type: StringName
) -> bool:
	for entry in plan:
		var event_type := StringName(entry["event_type"])
		var schema := INJURY_EVENT_SCHEMA
		if event_type == &"death":
			schema = DEATH_EVENT_SCHEMA
		elif event_type == &"kill":
			schema = KILL_EVENT_SCHEMA
		var payload := _event_payload(schema, {
			"operation_id": operation_id,
			"source_type": source_type,
			"event_type": event_type,
			"attacker_id": attacker_key,
			"target_id": target_key,
			"body_zone": zone,
			"requested_damage_micros": requested_micros,
			"applied_damage_micros": applied_micros,
			"health_revision": int(actor["health_revision"]),
			"injuries": injury_results.duplicate(true),
			"tick": tick,
		})
		if payload.is_empty():
			return _latch_recovery(&"health_damage_event_payload_invalid", {
				"operation_id": operation_id, "event_type": event_type,
				"mutation_state": &"committed"})
		if not _record_event(
				entry["kind"] as ZRaidEvent.EventKind,
				String(entry["event_id"]),
				entry["actor_id"] as ZEntityId, payload, tick):
			return false
		if int(entry["kind"]) == ZRaidEvent.EventKind.INJURY:
			_emit_injury(payload)
	return true


func _preflight_event_plan(plan: Array[Dictionary], tick: int) -> bool:
	if _authority.journal.remaining_capacity() < plan.size() \
			or _reserved_event_ids.size() + plan.size() > MAX_RESERVED_EVENT_IDS:
		return _latch_recovery(&"health_event_capacity_exceeded", {
			"required": plan.size(),
			"remaining": _authority.journal.remaining_capacity()})
	var pending: Dictionary = {}
	for entry in plan:
		var event_key := String(entry.get("event_id", ""))
		var event_id := ZConsequenceId.parse(event_key)
		var actor_id := entry.get("actor_id") as ZEntityId
		if event_id == null or actor_id == null \
				or pending.has(event_key) or _reserved_event_ids.has(event_key):
			return _latch_recovery(&"health_event_identity_collision", {
				"event_id": event_key})
		if not _authority.can_record_event(
				entry["kind"] as ZRaidEvent.EventKind, event_id, tick, actor_id,
				{"schema": "health_event_preflight", "event_id": event_key},
				_raid_generation):
			return _latch_recovery(&"health_event_preflight_failed", {
				"event_id": event_key, "authority_error": _authority.last_error})
		pending[event_key] = true
	for event_key in pending.keys():
		_reserved_event_ids[event_key] = true
	return true


func _record_event(
	kind: ZRaidEvent.EventKind,
	event_key: String,
	actor_id: ZEntityId,
	payload: Dictionary,
	tick: int
) -> bool:
	var event_id := ZConsequenceId.parse(event_key)
	if event_id == null or actor_id == null \
			or not _authority.record_event(
				kind, event_id, tick, actor_id, payload, _raid_generation):
		return _latch_recovery(&"health_event_commit_failed", {
			"event_id": event_key,
			"authority_error": _authority.last_error,
			"mutation_state": &"committed",
		})
	return true


func _preflight_phase_budget(
	hit_count: int,
	due_bleed_count: int,
	due_treatment_count: int
) -> Dictionary:
	var new_damage := hit_count + due_bleed_count
	var event_upper_bound := hit_count * 4 + due_bleed_count * 3 + due_treatment_count
	if _damage_results.size() + new_damage > MAX_DAMAGE_RESULTS:
		return {"ok": false, "reason": &"health_damage_ledger_capacity"}
	if _reserved_event_ids.size() + event_upper_bound > MAX_RESERVED_EVENT_IDS:
		return {"ok": false, "reason": &"health_event_identity_capacity"}
	if _authority.journal.remaining_capacity() < event_upper_bound:
		return {
			"ok": false,
			"reason": &"health_event_capacity_exceeded",
			"required_upper_bound": event_upper_bound,
			"remaining": _authority.journal.remaining_capacity(),
		}
	return {"ok": true}


func _audit_actor_state(actor: Dictionary, tick: int) -> Dictionary:
	var component := actor.get("component") as GameplayAbilityComponent
	if component == null or not is_instance_valid(component) \
			or component.get_instance_id() != int(actor["component_instance_id"]) \
			or component.entity_id != int(actor["native_entity_id"]) \
			or not component.is_configured() or component.is_torn_down() \
			or not component.is_owner_valid() \
			or component.get_content_manifest_fingerprint() \
				!= int(actor["catalog_fingerprint"]) \
			or component.get_current_tick() > tick:
		return {"ok": false, "reason": &"health_component_invalid"}
	var preflight := ZerkovHealthAbilityContent.preflight_component(component, tick)
	if not bool(preflight.get("accepted", false)):
		return {"ok": false, "reason": preflight.get(
			"reason", &"health_component_preflight_failed"), "preflight": preflight}
	for ability_key in (actor["specs"] as Dictionary).keys():
		if not _spec_is_live(actor, StringName(ability_key)):
			return {"ok": false, "reason": &"health_owned_grant_invalid",
				"ability_identifier": ability_key}
	var dead := _component_is_dead(component)
	if dead != bool(actor.get("dead", false)):
		return {"ok": false, "reason": &"health_life_state_diverged"}
	var digest := _health_state_digest(actor)
	if digest.length() != 64 or digest != String(actor.get("state_digest", "")):
		return {"ok": false, "reason": &"health_actor_state_diverged",
			"expected_digest": actor.get("state_digest", ""), "actual_digest": digest}
	for zone_value in ZerkovHealthAbilityContent.body_zone_declarations():
		var zone := zone_value as Dictionary
		var schedule_key := _bleed_schedule_key(
			String(actor["actor_id"]), StringName(zone["zone_identifier"]))
		var active := component.has_tag_exact(String(zone[
			"heavy_bleed_tag_identifier"])) and not dead
		if active != _bleed_schedules.has(schedule_key):
			return {"ok": false, "reason": &"health_bleed_schedule_diverged",
				"schedule_key": schedule_key}
	return {"ok": true}


func _health_state_digest(actor: Dictionary) -> String:
	var component := actor.get("component") as GameplayAbilityComponent
	if component == null or not is_instance_valid(component):
		return ""
	var zones: Array[Dictionary] = []
	for zone_value in ZerkovHealthAbilityContent.body_zone_declarations():
		var zone := zone_value as Dictionary
		var attribute := String(zone["health_attribute_identifier"])
		zones.append({
			"zone_identifier": String(zone["zone_identifier"]),
			"base_micros": _fixed_micros(component.get_attribute_base(attribute)),
			"current_micros": _fixed_micros(component.get_attribute_current(attribute)),
			"heavy_bleed": component.has_tag_exact(String(zone[
				"heavy_bleed_tag_identifier"])),
			"fracture": component.has_tag_exact(String(zone[
				"fracture_tag_identifier"])),
			"bandaged": component.has_tag_exact(String(zone[
				"bandaged_tag_identifier"])),
			"splinted": component.has_tag_exact(String(zone[
				"splinted_tag_identifier"])),
		})
	return ZCanonicalValue.sha256({
		"actor_id": String(actor.get("actor_id", "")),
		"native_entity_id": int(actor.get("native_entity_id", 0)),
		"alive": component.has_tag_exact(String(
			ZerkovHealthAbilityContent.TAG_LIFE_ALIVE)),
		"dead": component.has_tag_exact(String(
			ZerkovHealthAbilityContent.TAG_LIFE_DEAD)),
		"life_state_micros": _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_LIFE_STATE))),
		"pain_micros": _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_PAIN))),
		"movement_scale_micros": _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_MOVEMENT_SPEED_SCALE))),
		"stamina_micros": _fixed_micros(component.get_attribute_current(String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA))),
		"zones": zones,
	})


func _actor_snapshot_from_record(actor: Dictionary) -> Dictionary:
	var component := actor.get("component") as GameplayAbilityComponent
	var body_parts: Array[Dictionary] = []
	for zone_value in ZerkovHealthAbilityContent.body_zone_declarations():
		var zone := zone_value as Dictionary
		var attribute := String(zone["health_attribute_identifier"])
		body_parts.append({
			"zone_identifier": StringName(zone["zone_identifier"]),
			"health_micros": _fixed_micros(
				component.get_attribute_current(attribute)),
			"max_health_micros": int(zone["max_health_micros"]),
			"heavy_bleed": component.has_tag_exact(String(zone[
				"heavy_bleed_tag_identifier"])),
			"fractured": component.has_tag_exact(String(zone[
				"fracture_tag_identifier"])),
			"bandaged": component.has_tag_exact(String(zone[
				"bandaged_tag_identifier"])),
			"splinted": component.has_tag_exact(String(zone[
				"splinted_tag_identifier"])),
		})
	return {
		"schema": "zerkov.combat.health_snapshot.v1",
		"raid_id": _admission.raid_id.canonical_key(),
		"authority_generation": _raid_generation,
		"adapter_generation": _binding_generation,
		"actor_id": String(actor["actor_id"]),
		"actor_registration_generation": int(actor["actor_registration_generation"]),
		"native_entity_id": int(actor["native_entity_id"]),
		"health_revision": int(actor["health_revision"]),
		"tick": _last_tick,
		"alive": not bool(actor["dead"]),
		"dead": bool(actor["dead"]),
		"death_tick": int(actor["death_tick"]),
		"pain_micros": _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_PAIN))),
		"movement_scale_micros": _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_MOVEMENT_SPEED_SCALE))),
		"stamina_micros": _fixed_micros(component.get_attribute_current(String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA))),
		"max_stamina_micros": ZerkovHealthAbilityContent.MAX_STAMINA_MICROS,
		"hydration_micros": _fixed_micros(component.get_attribute_current(String(ZerkovHealthAbilityContent.ATTRIBUTE_HYDRATION))),
		"body_parts": body_parts,
		"state_digest": String(actor["state_digest"]),
	}


func _validate_treatment_request(request: Dictionary) -> Dictionary:
	if not _has_exact_keys(request, TREATMENT_REQUEST_KEYS) \
			or String(request.get("schema", "")) != TREATMENT_REQUEST_SCHEMA \
			or not ZCanonicalValue.is_bounded(request) \
			or ZRequestId.parse(String(request.get("request_id", ""))) == null \
			or String(request.get("raid_id", "")) != _admission.raid_id.canonical_key() \
			or String(request.get("session_id", "")) != _admission.session_id.canonical_key() \
			or int(request.get("authority_epoch", 0)) != _admission.authority_epoch \
			or int(request.get("authority_generation", 0)) != _raid_generation \
			or int(request.get("adapter_generation", 0)) != _binding_generation:
		return {"ok": false, "reason": &"health_treatment_envelope_invalid"}
	var actor_key := String(request.get("actor_id", ""))
	var actor := _actors.get(actor_key, {}) as Dictionary
	if actor.is_empty() or int(request.get("actor_registration_generation", 0)) \
			!= int(actor["actor_registration_generation"]):
		return {"ok": false, "reason": &"health_treatment_actor_invalid"}
	var target_tick := int(request.get("target_tick", -1))
	var sequence := int(request.get("sequence", 0))
	if target_tick <= _authority.last_processed_tick \
			or target_tick > MAX_AUTHORITY_TICK \
			or sequence <= 0 or sequence > MAX_COMMAND_SEQUENCE \
			or int(request.get("expected_health_revision", -1)) < 0 \
			or int(request.get("expected_inventory_revision", -1)) < 0 \
			or ZerkovHealthAbilityContent.body_zone_declaration(
				StringName(request.get("body_zone", &""))).is_empty() \
			or ZerkovHealthConsequencePolicy.treatment_declaration(
				StringName(request.get("treatment", &""))).is_empty():
		return {"ok": false, "reason": &"health_treatment_fields_invalid"}
	return {"ok": true}


func _required_ability_identifiers() -> PackedStringArray:
	var result := PackedStringArray([
		String(ZerkovHealthAbilityContent.ABILITY_LIFE_DEAD),
		String(ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND)])
	for zone in ZerkovHealthAbilityContent.body_zone_declarations():
		for key in [
			"damage_ability_identifier", "heavy_bleed_ability_identifier",
			"fracture_ability_identifier", "bandage_ability_identifier",
			"splint_ability_identifier",
		]:
			result.append(String(zone[key]))
	return result


func _existing_required_grants(
	component: GameplayAbilityComponent,
	required: PackedStringArray
) -> Dictionary:
	var result: Dictionary = {}
	for spec in component.granted_specs():
		var grant := component.get_grant(spec)
		var ability := String(grant.get("ability_identifier", ""))
		if not bool(grant.get("revoked", true)) and required.has(ability):
			result[ability] = int(spec)
	return result


func _rollback_registration(
	component: GameplayAbilityComponent,
	before: PackedByteArray,
	reason: StringName,
	details: Dictionary
) -> Dictionary:
	# Snapshot restore is itself a native mutation boundary. Keep the adapter
	# fenced until both restore and its exact-byte postcondition are complete.
	var restored := component != null and is_instance_valid(component) \
		and not component.is_torn_down() \
		and component.restore_snapshot(before) \
		and component.write_snapshot() == before
	var binding_current := _binding_is_current()
	_mutation_active = false
	if not restored:
		_latch_recovery(&"health_registration_rollback_failed", {
			"reason": reason, "details": details})
		return _rejection(last_error, {
			"rollback_ok": false, "requires_recovery": true})
	if not binding_current:
		lifecycle = Lifecycle.INVALIDATED
		_phase_registered = false
		last_error = &"health_registration_binding_invalidated"
		return _rejection(last_error, {
			"details": details, "rollback_ok": true})
	return _rejection(reason, {"details": details, "rollback_ok": true})


func _registration_context_is_current(
	component: GameplayAbilityComponent,
	native_entity_id: int,
	initial_tick: int
) -> bool:
	return _mutation_active and lifecycle == Lifecycle.BOUND \
		and _binding_is_current() \
		and _authority.lifecycle == RaidAuthority.Lifecycle.PREPARING \
		and _authority.last_processed_tick == _last_tick \
		and initial_tick == _last_tick \
		and component != null and is_instance_valid(component) \
		and not component.is_queued_for_deletion() \
		and component.entity_id == native_entity_id \
		and component.is_configured() and not component.is_torn_down() \
		and component.is_owner_valid() \
		and component.get_current_tick() == initial_tick


func _abort_registration_context(
	component: GameplayAbilityComponent,
	before: PackedByteArray,
	boundary: StringName
) -> Dictionary:
	var cleanup_proven := false
	if component != null and is_instance_valid(component):
		if component.is_torn_down() or not component.is_owner_valid():
			# A torn-down/quarantined native owner cannot retain a live grant.
			cleanup_proven = true
		else:
			cleanup_proven = component.restore_snapshot(before) \
				and component.write_snapshot() == before
	var binding_current := _binding_is_current()
	_mutation_active = false
	if not cleanup_proven:
		_latch_recovery(&"health_registration_context_cleanup_failed", {
			"boundary": boundary})
		return _rejection(last_error, {
			"cleanup_proven": false, "requires_recovery": true})
	if not binding_current:
		lifecycle = Lifecycle.INVALIDATED
		_phase_registered = false
		last_error = &"health_registration_binding_invalidated"
		return _rejection(last_error, {
			"boundary": boundary, "cleanup_proven": true})
	return _rejection(&"health_registration_context_changed", {
		"boundary": boundary, "cleanup_proven": true})


func _activate_owned(
	actor: Dictionary,
	ability_identifier: StringName,
	tick: int
) -> Dictionary:
	if not _spec_is_live(actor, ability_identifier):
		return {"accepted": false, "reason": &"health_owned_grant_invalid"}
	var sequence := _reserve_actor_sequence(actor)
	if sequence <= 0:
		return {"accepted": false, "reason": &"health_command_sequence_exhausted"}
	var component := actor["component"] as GameplayAbilityComponent
	var result: Dictionary = component.request_activation({
		"spec": _actor_spec(actor, ability_identifier),
		"command_sequence": sequence,
	}, tick)
	var status := result.get("status", {}) as Dictionary
	if bool(result.get("queued", false)) or not bool(status.get("ok", false)) \
			or int(result.get("execution", 0)) <= 0:
		return {
			"accepted": false,
			"reason": &"health_native_activation_failed",
			"command_sequence": sequence,
			"result": result,
		}
	return {
		"accepted": true,
		"command_sequence": sequence,
		"execution": int(result["execution"]),
		"result": result,
	}


func _reserve_actor_sequence(actor: Dictionary) -> int:
	var sequence := int(actor.get("next_command_sequence", 0))
	if sequence <= 0 or sequence > MAX_COMMAND_SEQUENCE:
		return 0
	actor["next_command_sequence"] = sequence + 1
	return sequence


func _actor_spec(actor: Dictionary, ability_identifier: StringName) -> int:
	return int((actor["specs"] as Dictionary).get(String(ability_identifier), 0))


func _spec_is_live(actor: Dictionary, ability_identifier: StringName) -> bool:
	var component := actor.get("component") as GameplayAbilityComponent
	var spec := _actor_spec(actor, ability_identifier)
	var grant := component.get_grant(spec) if component != null else {}
	return spec > 0 and not grant.is_empty() \
		and not bool(grant.get("revoked", true)) \
		and StringName(grant.get("ability_identifier", &"")) == ability_identifier \
		and String(grant.get("input_id", "")) \
			== String((actor["input_ids"] as Dictionary).get(
				String(ability_identifier), ""))


func _bounded_damage_committed(result: Dictionary, expected_applied: int) -> bool:
	return bool(result.get("accepted", false)) \
		and bool(result.get("terminal", true)) \
		and not bool(result.get("queued", false)) \
		and int(result.get("applied_amount_micros", -1)) == expected_applied \
		and (expected_applied == 0 or bool(result.get("committed", true)))


func _fail_component_mutation(
	reason: StringName,
	actor: Dictionary,
	before: PackedByteArray,
	details: Dictionary
) -> bool:
	var component := actor.get("component") as GameplayAbilityComponent
	var current := component.write_snapshot() \
		if component != null and is_instance_valid(component) else PackedByteArray()
	var mutation_state: StringName = &"none"
	var restored := current == before
	if not restored and component != null and is_instance_valid(component):
		restored = component.restore_snapshot(before) \
			and component.write_snapshot() == before
		mutation_state = &"none" if restored else &"ambiguous"
	return _latch_recovery(reason, {
		"actor_id": actor.get("actor_id", ""),
		"details": details,
		"rollback_ok": restored,
		"mutation_state": mutation_state,
	})


func _injury_transition_needed(
	component: GameplayAbilityComponent,
	zone: Dictionary,
	injury: StringName
) -> bool:
	if _injury_is_active(component, zone, injury):
		return false
	if injury == ZerkovHealthConsequencePolicy.INJURY_HEAVY_BLEED:
		return not component.has_tag_exact(String(zone["bandaged_tag_identifier"]))
	if injury == ZerkovHealthConsequencePolicy.INJURY_FRACTURE:
		return not component.has_tag_exact(String(zone["splinted_tag_identifier"]))
	return false


func _injury_is_active(
	component: GameplayAbilityComponent,
	zone: Dictionary,
	injury: StringName
) -> bool:
	if injury == ZerkovHealthConsequencePolicy.INJURY_HEAVY_BLEED:
		return component.has_tag_exact(String(zone["heavy_bleed_tag_identifier"]))
	if injury == ZerkovHealthConsequencePolicy.INJURY_FRACTURE:
		return component.has_tag_exact(String(zone["fracture_tag_identifier"]))
	return false


func _injury_ability(zone: Dictionary, injury: StringName) -> StringName:
	if injury == ZerkovHealthConsequencePolicy.INJURY_HEAVY_BLEED:
		return StringName(zone["heavy_bleed_ability_identifier"])
	if injury == ZerkovHealthConsequencePolicy.INJURY_FRACTURE:
		return StringName(zone["fracture_ability_identifier"])
	return &""


func _treatment_ability(zone: Dictionary, treatment: StringName) -> StringName:
	return StringName(zone["bandage_ability_identifier"]) \
		if treatment == ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE \
		else StringName(zone["splint_ability_identifier"])


func _treatment_tag(zone: Dictionary, treatment: StringName) -> StringName:
	return StringName(zone["bandaged_tag_identifier"]) \
		if treatment == ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE \
		else StringName(zone["splinted_tag_identifier"])


func _component_is_dead(component: GameplayAbilityComponent) -> bool:
	return component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_DEAD)) \
		and not component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_ALIVE)) \
		and _fixed_micros(component.get_attribute_current(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_LIFE_STATE))) == 0


func _start_bleed_schedule(
	actor_key: String,
	zone: StringName,
	attacker_key: String,
	operation_id: String,
	tick: int,
	zone_declaration: Dictionary
) -> void:
	var key := _bleed_schedule_key(actor_key, zone)
	if _bleed_schedules.has(key):
		return
	var schedule_id := _stable_id("bleed", {
		"actor_id": actor_key,
		"body_zone": String(zone),
		"origin_operation_id": operation_id,
	})
	_bleed_schedules[key] = {
		"schedule_id": schedule_id,
		"actor_id": actor_key,
		"body_zone": zone,
		"attacker_id": attacker_key,
		"origin_operation_id": operation_id,
		"start_tick": tick,
		"next_due_tick": tick + int(zone_declaration["heavy_bleed_period_ticks"]),
		"ordinal": 1,
	}


func _remove_actor_bleeds(
	actor_key: String,
	tick: int,
	death_operation_id: String
) -> void:
	var keys := PackedStringArray(_bleed_schedules.keys())
	for key in keys:
		var schedule := _bleed_schedules[key] as Dictionary
		if String(schedule.get("actor_id", "")) == actor_key:
			_phase_cancelled_bleeds[String(key)] = {
				"reason": &"death",
				"tick": tick,
				"death_operation_id": death_operation_id,
				"schedule": schedule.duplicate(true),
			}
			_bleed_schedules.erase(key)


func _bleed_schedule_key(actor_key: String, zone: StringName) -> String:
	return "%s|%s" % [actor_key, String(zone)]


func _due_bleed_keys(tick: int) -> PackedStringArray:
	var ordered: Array[String] = []
	for key in _bleed_schedules.keys():
		var due := int((_bleed_schedules[key] as Dictionary).get("next_due_tick", -1))
		if due <= tick:
			ordered.append(String(key))
	ordered.sort_custom(func(left: String, right: String) -> bool:
		var left_record := _bleed_schedules[left] as Dictionary
		var right_record := _bleed_schedules[right] as Dictionary
		if int(left_record["next_due_tick"]) != int(right_record["next_due_tick"]):
			return int(left_record["next_due_tick"]) < int(right_record["next_due_tick"])
		return left < right)
	return PackedStringArray(ordered)


func _due_treatment_ids(tick: int) -> PackedStringArray:
	var result := PackedStringArray()
	for request_id in _treatment_order:
		var record := _treatment_records.get(request_id, {}) as Dictionary
		if record.is_empty() or not bool(record.get("pending", false)):
			continue
		var request := record["request"] as Dictionary
		if int(request.get("target_tick", -1)) <= tick:
			result.append(request_id)
	return result


func _sort_treatment_order() -> void:
	var ordered: Array[String] = []
	for request_id in _treatment_order:
		ordered.append(request_id)
	ordered.sort_custom(func(left: String, right: String) -> bool:
		var left_request := (_treatment_records[left] as Dictionary)["request"] as Dictionary
		var right_request := (_treatment_records[right] as Dictionary)["request"] as Dictionary
		if int(left_request["target_tick"]) != int(right_request["target_tick"]):
			return int(left_request["target_tick"]) < int(right_request["target_tick"])
		if int(left_request["sequence"]) != int(right_request["sequence"]):
			return int(left_request["sequence"]) < int(right_request["sequence"])
		return left < right)
	_treatment_order = PackedStringArray(ordered)


func _remove_treatment_from_order(request_id: String) -> void:
	var retained := PackedStringArray()
	for candidate in _treatment_order:
		if candidate != request_id:
			retained.append(candidate)
	_treatment_order = retained


func _pending_treatment_record_count() -> int:
	var result := 0
	for value in _treatment_records.values():
		if bool((value as Dictionary).get("pending", false)):
			result += 1
	return result


func _update_treatment_progress(
	request_id: String,
	reservation_id: String,
	mutation_state: StringName
) -> void:
	var record := _treatment_records.get(request_id, {}) as Dictionary
	if record.is_empty() or not bool(record.get("pending", false)):
		return
	record["processing"] = true
	record["reservation_id"] = reservation_id
	record["mutation_state"] = mutation_state
	_treatment_records[request_id] = record


func _medical_port_is_current(
	actor: Dictionary,
	port: MedicalInventoryParticipantPort
) -> bool:
	return port != null and actor.get("medical_port") == port \
		and port.is_ready() \
		and port.identity_token() == String(actor.get("medical_port_token", ""))


func _finalize_treatment(
	request_id: String,
	committed: bool,
	reason: StringName,
	details: Dictionary
) -> void:
	var record := _treatment_records.get(request_id, {}) as Dictionary
	if record.is_empty():
		return
	record["pending"] = false
	record["processing"] = false
	var receipt := record.get("receipt", {}) as Dictionary
	receipt["accepted"] = committed
	receipt["queued"] = false
	receipt["terminal"] = true
	receipt["committed"] = committed
	receipt["reason"] = reason
	for key in details.keys():
		receipt[key] = _duplicate_variant(details[key])
	record["receipt"] = receipt
	_treatment_records[request_id] = record
	_remove_treatment_from_order(request_id)


func _finalize_pending_treatments(reason: StringName) -> void:
	var ids := PackedStringArray(_treatment_records.keys())
	ids.sort()
	for request_id in ids:
		var record := _treatment_records[request_id] as Dictionary
		if not bool(record.get("pending", false)):
			continue
		var details := {}
		if bool(record.get("processing", false)):
			details["reservation_id"] = String(record.get("reservation_id", ""))
			details["mutation_state"] = StringName(record.get(
				"mutation_state", MedicalInventoryParticipantPort.MUTATION_AMBIGUOUS))
		_finalize_treatment(request_id, false, reason, details)
	_treatment_order.clear()


func _interrupt_actor_reloads(actor: Dictionary, tick: int) -> Dictionary:
	var adapter := actor.get("reload_adapter") as InventoryWeaponAdapter
	if adapter == null:
		return {"accepted": true, "interrupted": [], "not_bound": true}
	if not is_instance_valid(adapter) or not adapter.is_bound():
		return {"accepted": false, "reason": &"health_reload_adapter_invalid"}
	var weapon_ids := PackedStringArray()
	for value in adapter.pending_reloads():
		var pending := value as Dictionary
		if String(pending.get("actor_id", "")) == String(actor["actor_id"]):
			weapon_ids.append(String(pending.get("weapon_id", "")))
	weapon_ids.sort()
	var outcomes: Array[Dictionary] = []
	for weapon_id in weapon_ids:
		var outcome := adapter.interrupt_reload(weapon_id, &"death", tick)
		if not bool(outcome.get("accepted", false)):
			return {"accepted": false, "reason": &"reload_interrupt_failed",
				"outcomes": outcomes, "failed_weapon_id": weapon_id}
		# Health receipts carry stable interruption references, not native reload
		# snapshots, ammo profiles, or commit capabilities. Embedding the complete
		# result exceeds the canonical value depth/type budget after a real cancel.
		outcomes.append({
			"weapon_id": weapon_id,
			"reservation_id": String(outcome.get("reservation_id", "")),
			"kind": StringName(outcome.get("kind", &"")),
			"quantity": int(outcome.get("quantity", 0)),
		})
	return {"accepted": true, "interrupted": outcomes}


func _medical_reservation_id(
	request: Dictionary,
	actor: Dictionary,
	port: MedicalInventoryParticipantPort
) -> String:
	var digest := ZCanonicalValue.sha256({
		"schema": "zerkov.medical.reservation.v1",
		"request_id": String(request["request_id"]),
		"raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"authority_generation": _raid_generation,
		"adapter_generation": _binding_generation,
		"actor_id": String(actor["actor_id"]),
		"actor_registration_generation": int(actor["actor_registration_generation"]),
		"medical_port_token": port.identity_token(),
		"owner_generation": port.owner_generation(),
		"inventory_id": port.inventory_id(),
		"body_zone": String(request["body_zone"]),
		"treatment": String(request["treatment"]),
	})
	return "zerkov.medical.%s.%s" % [digest.substr(0, 32), digest.substr(32, 32)] \
		if digest.length() == 64 else ""


func _damage_outcome(
	operation_id: String,
	source_fingerprint: String,
	source_type: StringName,
	attacker_key: String,
	target_key: String,
	zone: StringName,
	requested_micros: int,
	applied_micros: int,
	tick: int,
	actor: Dictionary,
	injuries: Array,
	ignored_dead: bool,
	extra: Dictionary
) -> Dictionary:
	var outcome := {
		"schema": DAMAGE_OUTCOME_SCHEMA,
		"accepted": true,
		"committed": not ignored_dead,
		"replayed": false,
		"ignored_target_dead": ignored_dead,
		"reason": &"target_already_dead" if ignored_dead else &"",
		"operation_id": operation_id,
		"source_fingerprint": source_fingerprint,
		"source_type": source_type,
		"raid_id": _admission.raid_id.canonical_key(),
		"authority_generation": _raid_generation,
		"adapter_generation": _binding_generation,
		"attacker_id": attacker_key,
		"target_id": target_key,
		"body_zone": zone,
		"requested_damage_micros": requested_micros,
		"applied_damage_micros": applied_micros,
		"health_revision": int(actor.get("health_revision", 0)),
		"dead": bool(actor.get("dead", false)),
		"injuries": injuries.duplicate(true),
		"tick": tick,
	}
	for key in extra.keys():
		outcome[key] = _duplicate_variant(extra[key])
	var digest := ZCanonicalValue.sha256(outcome)
	if digest.length() != 64:
		return {}
	outcome["outcome_digest"] = digest
	_make_deep_read_only(outcome)
	return outcome


func _event_payload(schema: String, fields: Dictionary) -> Dictionary:
	var result := fields.duplicate(true)
	result["schema"] = schema
	result["raid_id"] = _admission.raid_id.canonical_key()
	result["authority_generation"] = _raid_generation
	result["adapter_generation"] = _binding_generation
	result["policy_digest"] = _policy_digest
	var digest := ZCanonicalValue.sha256(result)
	if digest.length() != 64:
		return {}
	result["payload_digest"] = digest
	return result


func _event_ids_from_plan(plan: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for entry in plan:
		result.append(String(entry["event_id"]))
	return result


func _stable_id(domain: String, values: Dictionary) -> String:
	if not ZIdentityRules.is_valid_part(domain):
		return ""
	var digest := ZCanonicalValue.sha256({"domain": domain, "values": values})
	if digest.length() != 64:
		return ""
	var identity := ZConsequenceId.from_parts(PackedStringArray([
		"health_" + domain, digest.substr(0, 32), digest.substr(32, 32)]))
	return identity.canonical_key() if identity != null else ""


func _grant_input_id(
	actor_key: String,
	actor_registration_generation: int,
	ability_identifier: String
) -> String:
	var digest := ZCanonicalValue.sha256({
		"schema": "zerkov.health.grant.v1",
		"raid_id": _admission.raid_id.canonical_key(),
		"authority_generation": _raid_generation,
		"adapter_generation": _generation_counter + 1,
		"actor_id": actor_key,
		"actor_registration_generation": actor_registration_generation,
		"ability_identifier": ability_identifier,
	})
	return "zerkov.health.%s.%s" % [digest.substr(0, 24), digest.substr(24, 24)] \
		if digest.length() == 64 else ""


func _journal_records_are_contiguous(records: Array[Dictionary]) -> bool:
	for index in range(records.size()):
		if int(records[index].get("sequence", 0)) != index + 1:
			return false
	return true


func _phase_callback(expected_binding_generation: int) -> Callable:
	return Callable(self, "handle_raid_phase").bind(expected_binding_generation)


func _binding_is_current() -> bool:
	return _authority != null and is_instance_valid(_authority) \
		and _authority.get_instance_id() == _authority_instance_id \
		and _authority.generation() == _raid_generation \
		and _admission != null and _admission.is_usable() \
		and _admission.generation == _raid_generation \
		and _phase_registered \
		and _authority.has_exact_phase_handler(
			PHASE_HANDLER_ID, _phase_registration_id,
			_phase_callback(_binding_generation),
			RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
			_raid_generation)


func _on_component_tree_exiting(
	actor_key: String,
	actor_registration_generation: int
) -> void:
	if lifecycle != Lifecycle.BOUND or not _actors.has(actor_key):
		return
	var actor := _actors[actor_key] as Dictionary
	if int(actor.get("actor_registration_generation", 0)) \
			!= actor_registration_generation:
		return
	if _authority != null and is_instance_valid(_authority) \
			and (_authority.lifecycle == RaidAuthority.Lifecycle.COMPLETED \
				or _authority.lifecycle == RaidAuthority.Lifecycle.FAILED \
				or _authority.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN):
		lifecycle = Lifecycle.INVALIDATED
		last_error = &"health_component_terminal_teardown"
		return
	_latch_recovery(&"health_component_exited", {"actor_id": actor_key})


func _disconnect_actor_callback(actor: Dictionary) -> void:
	var component := actor.get("component") as GameplayAbilityComponent
	var callback := actor.get("tree_exiting_callback", Callable()) as Callable
	if component != null and is_instance_valid(component) \
			and callback.is_valid() and component.tree_exiting.is_connected(callback):
		component.tree_exiting.disconnect(callback)


func _disconnect_public_signal_callbacks() -> void:
	# A released RefCounted adapter must not be kept alive by a subscriber lambda
	# that captured it during a synchronous notification. No public signal can
	# fire after release, so retaining those connections has no valid purpose.
	for signal_name in [
		&"damage_committed", &"injury_committed", &"treatment_committed",
		&"death_committed", &"recovery_latched", &"binding_invalidated",
	]:
		for connection_value in get_signal_connection_list(signal_name):
			var connection := connection_value as Dictionary
			var callback := connection.get("callable", Callable()) as Callable
			if callback.is_valid() and is_connected(signal_name, callback):
				disconnect(signal_name, callback)


func _latch_recovery(reason: StringName, details: Dictionary) -> bool:
	if lifecycle != Lifecycle.RECOVERY_REQUIRED:
		lifecycle = Lifecycle.RECOVERY_REQUIRED
		last_error = reason
		_recovery = {
			"reason": reason,
			"details": details.duplicate(true),
			"raid_id": _admission.raid_id.canonical_key() if _admission != null else "",
			"authority_generation": _raid_generation,
			"adapter_generation": _binding_generation,
			"last_tick": _last_tick,
			"journal_cursor": _journal_cursor,
			"damage_result_count": _damage_results.size(),
			"pending_treatment_count": _pending_treatment_record_count(),
			"bleed_schedule_count": _bleed_schedules.size(),
			"requires_authoritative_teardown": true,
		}
		_emit_recovery(reason, _recovery)
		# Preserve the failure that this outer recovery publication latched.
		last_error = reason
	return false


func _reset_binding_refs() -> void:
	_authority = null
	_authority_instance_id = 0
	_raid_generation = 0
	_admission = null
	_policy_digest = ""
	_phase_registration_id = ""
	_phase_registered = false
	_last_tick = 0
	_journal_cursor = 0
	_phase_active = false
	_public_signal_active = false


func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


func _fixed_micros(value: float) -> int:
	var scaled := value * float(ZerkovHealthAbilityContent.FIXED_SCALE)
	if scaled < 0.0:
		return -int(floor(-scaled + 0.5))
	return int(floor(scaled + 0.5))


func _duplicate_variant(value: Variant) -> Variant:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		return (value as Array).duplicate(true)
	if value is PackedStringArray:
		return (value as PackedStringArray).duplicate()
	if value is PackedInt64Array:
		return (value as PackedInt64Array).duplicate()
	if value is PackedByteArray:
		return (value as PackedByteArray).duplicate()
	return value


func _read_only_copy(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	_make_deep_read_only(result)
	return result


func _make_deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for child in dictionary.values():
			_make_deep_read_only(child)
		dictionary.make_read_only()
	elif value is Array:
		var array := value as Array
		for child in array:
			_make_deep_read_only(child)
		array.make_read_only()


func _emit_damage(outcome: Dictionary) -> void:
	_public_signal_active = true
	damage_committed.emit(_read_only_copy(outcome))
	_public_signal_active = false


func _emit_injury(outcome: Dictionary) -> void:
	_public_signal_active = true
	injury_committed.emit(_read_only_copy(outcome))
	_public_signal_active = false


func _emit_treatment(outcome: Dictionary) -> void:
	_public_signal_active = true
	treatment_committed.emit(_read_only_copy(outcome))
	_public_signal_active = false


func _emit_death(outcome: Dictionary) -> void:
	_public_signal_active = true
	death_committed.emit(_read_only_copy(outcome))
	_public_signal_active = false


func _emit_recovery(reason: StringName, details: Dictionary) -> void:
	_public_signal_active = true
	recovery_latched.emit(reason, _read_only_copy(details))
	_public_signal_active = false


func _emit_binding_invalidated(reason: StringName) -> void:
	_public_signal_active = true
	binding_invalidated.emit(reason)
	_public_signal_active = false


func _rejection(reason: StringName, details: Dictionary = {}) -> Dictionary:
	var result := {
		"accepted": false,
		"committed": false,
		"queued": false,
		"terminal": true,
		"replayed": false,
		"reason": reason,
	}
	result.merge(details, true)
	return _read_only_copy(result)


func _reject_bool(reason: StringName) -> bool:
	last_error = reason
	return false
