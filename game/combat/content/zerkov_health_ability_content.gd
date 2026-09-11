class_name ZerkovHealthAbilityContent
extends RefCounted
## First-playable health, resource, injury, and treatment definitions.
##
## Persistent state is owned by long-running Gameplay Abilities executions.
## Authored cancel-tag queries make alive -> dead, heavy bleed -> bandaged,
## and fracture -> splinted real native teardown transitions. Task 5.6 still
## owns the authority decision, inventory transaction, stable consequence
## identity, scheduling, and ordering which request those transitions.

const CONTENT_SCHEMA_VERSION: int = 2
const TICK_RATE: int = 60
const FIXED_SCALE: int = 1_000_000
const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000
const MAX_COMMAND_SEQUENCE: int = 9_007_199_254_740_000
const MAX_APPLICATION_AMOUNT_MICROS: int = 1_000_000 * FIXED_SCALE
const MAX_COMPONENT_ATTRIBUTES: int = 128
const MAX_ABILITY_GRANTS: int = 64
const SET_BY_CALLER_AMOUNT: StringName = &"amount"
const HEALTH_BOOTSTRAP_INPUT_ID: String = "zerkov.bootstrap.health.life"

const BOUND_CAP_TO_FLOOR: StringName = &"cap_to_floor"
const BOUND_REJECT_OVERSPEND: StringName = &"reject_overspend"
const BOUND_CAP_TO_HEADROOM: StringName = &"cap_to_headroom"

const ZONE_HEAD: StringName = &"head"
const ZONE_THORAX: StringName = &"thorax"
const ZONE_ABDOMEN: StringName = &"abdomen"
const ZONE_LEFT_ARM: StringName = &"left_arm"
const ZONE_RIGHT_ARM: StringName = &"right_arm"
const ZONE_LEFT_LEG: StringName = &"left_leg"
const ZONE_RIGHT_LEG: StringName = &"right_leg"
const BODY_ZONE_IDS: PackedStringArray = [
	ZONE_HEAD, ZONE_THORAX, ZONE_ABDOMEN, ZONE_LEFT_ARM,
	ZONE_RIGHT_ARM, ZONE_LEFT_LEG, ZONE_RIGHT_LEG,
]

const ATTRIBUTE_HEALTH_HEAD: StringName = &"zerkov.attribute.health.head"
const ATTRIBUTE_HEALTH_THORAX: StringName = &"zerkov.attribute.health.thorax"
const ATTRIBUTE_HEALTH_ABDOMEN: StringName = &"zerkov.attribute.health.abdomen"
const ATTRIBUTE_HEALTH_LEFT_ARM: StringName = &"zerkov.attribute.health.left_arm"
const ATTRIBUTE_HEALTH_RIGHT_ARM: StringName = &"zerkov.attribute.health.right_arm"
const ATTRIBUTE_HEALTH_LEFT_LEG: StringName = &"zerkov.attribute.health.left_leg"
const ATTRIBUTE_HEALTH_RIGHT_LEG: StringName = &"zerkov.attribute.health.right_leg"
const ATTRIBUTE_LIFE_STATE: StringName = &"zerkov.attribute.life.state"
const ATTRIBUTE_STAMINA: StringName = &"zerkov.attribute.vitals.stamina"
const ATTRIBUTE_HYDRATION: StringName = &"zerkov.attribute.vitals.hydration"
const ATTRIBUTE_PAIN: StringName = &"zerkov.attribute.vitals.pain"
const ATTRIBUTE_MOVEMENT_SPEED_SCALE: StringName = \
	&"zerkov.attribute.movement.speed_scale"

const TAG_LIFE_ALIVE: StringName = &"zerkov.state.life.alive"
const TAG_LIFE_DEAD: StringName = &"zerkov.state.life.dead"
const TAG_HEAVY_BLEED: StringName = &"zerkov.state.injury.heavy_bleed"
const TAG_FRACTURE: StringName = &"zerkov.state.injury.fracture"
const TAG_BANDAGED: StringName = &"zerkov.state.treatment.bandaged"
const TAG_SPLINTED: StringName = &"zerkov.state.treatment.splinted"

const EFFECT_LIFE_ALIVE: StringName = &"zerkov.effect.life.alive"
const EFFECT_LIFE_DEAD: StringName = &"zerkov.effect.life.dead"
const EFFECT_STAMINA_SPEND: StringName = &"zerkov.effect.resource.stamina_spend"
const EFFECT_STAMINA_RESTORE: StringName = &"zerkov.effect.resource.stamina_restore"
const EFFECT_HYDRATION_DRAIN: StringName = &"zerkov.effect.resource.hydration_drain"
const EFFECT_HYDRATION_RESTORE: StringName = &"zerkov.effect.resource.hydration_restore"

const ABILITY_LIFE_ALIVE: StringName = &"zerkov.ability.life.alive"
const ABILITY_LIFE_DEAD: StringName = &"zerkov.ability.life.dead"
const ABILITY_STAMINA_SPEND: StringName = &"zerkov.ability.resource.stamina_spend"
const ABILITY_STAMINA_RESTORE: StringName = &"zerkov.ability.resource.stamina_restore"
const ABILITY_HYDRATION_DRAIN: StringName = &"zerkov.ability.resource.hydration_drain"
const ABILITY_HYDRATION_RESTORE: StringName = &"zerkov.ability.resource.hydration_restore"

const ITEM_BANDAGE: StringName = &"zerkov.item.medical.bandage"
const ITEM_SPLINT: StringName = &"zerkov.item.medical.splint"

const MAX_HEALTH_HEAD_MICROS: int = 35 * FIXED_SCALE
const MAX_HEALTH_THORAX_MICROS: int = 85 * FIXED_SCALE
const MAX_HEALTH_ABDOMEN_MICROS: int = 70 * FIXED_SCALE
const MAX_HEALTH_ARM_MICROS: int = 60 * FIXED_SCALE
const MAX_HEALTH_LEG_MICROS: int = 65 * FIXED_SCALE
const MAX_STAMINA_MICROS: int = 100 * FIXED_SCALE
const MAX_HYDRATION_MICROS: int = 100 * FIXED_SCALE
const MAX_PAIN_MICROS: int = 100 * FIXED_SCALE
const MIN_MOVEMENT_SPEED_SCALE_MICROS: int = 250_000
const DEFAULT_MOVEMENT_SPEED_SCALE_MICROS: int = FIXED_SCALE
const HEAVY_BLEED_PERIOD_TICKS: int = TICK_RATE
const HEAVY_BLEED_DAMAGE_MICROS: int = FIXED_SCALE
const HEAVY_BLEED_PAIN_MICROS: int = 15 * FIXED_SCALE
const FRACTURE_PAIN_MICROS: int = 25 * FIXED_SCALE
const LEG_FRACTURE_MOVEMENT_DELTA_MICROS: int = -250_000

const ATTRIBUTE_DEFINITION_COUNT: int = 12
const TAG_DEFINITION_COUNT: int = 34
const EFFECT_DEFINITION_COUNT: int = 41
const ABILITY_DEFINITION_COUNT: int = 41


static func build_definition_catalog() -> GameplayDefinitionCatalog:
	var catalog := GameplayDefinitionCatalog.new()
	catalog.tag_definitions = _tag_definitions()
	catalog.attribute_definitions = _attribute_definitions()
	catalog.effect_definitions = _effect_definitions()
	catalog.ability_definitions = _ability_definitions()
	return catalog


static func validate_definition_catalog() -> Dictionary:
	var validator := GameplayDefinitionValidator.new()
	var catalog := build_definition_catalog()
	var findings: Array = validator.validate_catalog(catalog)
	var prediction_findings: Array = \
		GameplayDefinitionValidator.validate_prediction_eligibility_seam(
			catalog.get_tag_definitions(), catalog.get_attribute_definitions(),
			catalog.get_effect_definitions(), catalog.get_cue_definitions(),
			catalog.get_ability_definitions())
	return {
		"ok": GameplayDefinitionValidator.is_ok(findings)
			and GameplayDefinitionValidator.is_ok(prediction_findings),
		"findings": findings.duplicate(true),
		"prediction_findings": prediction_findings.duplicate(true),
		"manifest_ok": validator.get_last_manifest_ok(),
		"manifest_fingerprint": validator.get_last_manifest_fingerprint(),
		"manifest_entry_count": validator.get_last_manifest_entry_count(),
		"manifest_tick_rate": validator.get_last_manifest_tick_rate(),
	}


## Side-effect-free provenance, clock, capacity, and existing-state check.
## Mutable bases are checked against authored bounds, not spawn defaults, so
## replay remains valid after legitimate gameplay.
static func preflight_component(
	component: GameplayAbilityComponent,
	tick: int = 0
) -> Dictionary:
	if component == null or not is_instance_valid(component) \
			or not component.is_configured() or component.is_torn_down() \
			or not component.is_owner_valid():
		return _rejection(&"health_component_invalid")
	if component.get_role() != GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY \
			and component.get_role() != GameplayAbilityComponent.ROLE_SERVER_AUTHORITY:
		return _rejection(&"health_component_role_invalid")
	if component.get_tick_rate() != TICK_RATE:
		return _rejection(&"health_tick_rate_mismatch", {
			"expected_tick_rate": TICK_RATE,
			"actual_tick_rate": component.get_tick_rate(),
		})
	if tick < 0 or tick < component.get_current_tick() or tick > MAX_AUTHORITY_TICK:
		return _rejection(&"health_tick_invalid")
	var provenance := _validate_catalog_subset(component)
	if not bool(provenance.get("ok", false)):
		return _rejection(
			StringName(provenance.get("reason", &"health_catalog_invalid")),
			{"catalog": provenance})

	var missing := PackedStringArray()
	for declaration in attribute_declarations():
		var identifier := String(declaration["identifier"])
		if not component.has_attribute(identifier):
			missing.append(identifier)
			continue
		var base_micros := _fixed_micros(component.get_attribute_base(identifier))
		var current_micros := _fixed_micros(component.get_attribute_current(identifier))
		var minimum := int(declaration["min_micros"])
		var maximum := int(declaration["max_micros"])
		if base_micros < minimum or base_micros > maximum \
				or current_micros < minimum or current_micros > maximum:
			return _rejection(&"health_attribute_out_of_bounds", {
				"attribute_identifier": identifier,
				"base_micros": base_micros,
				"current_micros": current_micros,
				"min_micros": minimum,
				"max_micros": maximum,
			})
	if component.get_initialized_attributes().size() + missing.size() \
			> MAX_COMPONENT_ATTRIBUTES:
		return _rejection(&"health_attribute_capacity_exceeded")
	var lifecycle := _preflight_lifecycle(component)
	if not bool(lifecycle.get("ok", false)):
		return _rejection(
			StringName(lifecycle.get("reason", &"health_lifecycle_invalid")),
			{"lifecycle": lifecycle})
	return {
		"accepted": true,
		"missing_attributes": missing,
		"catalog_fingerprint": provenance["content_manifest_fingerprint"],
		"lifecycle": lifecycle,
	}


## Initializes attributes and the execution-owned initial alive state. All
## predictable failures are checked before mutation; a native snapshot is the
## defensive rollback boundary for an unexpected runtime failure.
static func initialize_component(
	component: GameplayAbilityComponent,
	tick: int = 0
) -> Dictionary:
	var preflight := preflight_component(component, tick)
	if not bool(preflight.get("accepted", false)):
		return preflight
	var before := component.write_snapshot()
	if before.is_empty():
		return _rejection(&"health_snapshot_unavailable")
	var initialized := PackedStringArray()
	var replayed := PackedStringArray()
	for declaration in attribute_declarations():
		var identifier := String(declaration["identifier"])
		if component.has_attribute(identifier):
			replayed.append(identifier)
			continue
		var result: Dictionary = component.initialize_attribute(
			identifier, false, 0.0, tick)
		var status := result.get("status", {}) as Dictionary
		if not bool(status.get("ok", false)):
			return _rollback_initialization(component, before,
				&"health_attribute_initialization_failed", {
					"attribute_identifier": identifier,
					"status": status.duplicate(true),
				})
		initialized.append(identifier)
	var lifecycle := preflight.get("lifecycle", {}) as Dictionary
	var bootstrap_specs := lifecycle.get("bootstrap_specs", PackedInt64Array()) \
		as PackedInt64Array
	var life_replayed := not bootstrap_specs.is_empty()
	if bootstrap_specs.is_empty():
		var grant: Dictionary = component.grant_ability(
			String(ABILITY_LIFE_ALIVE), 1, HEALTH_BOOTSTRAP_INPUT_ID, tick)
		var grant_status := grant.get("status", {}) as Dictionary
		if not bool(grant_status.get("ok", false)):
			return _rollback_initialization(component, before,
				&"health_life_bootstrap_failed", {
					"status": grant_status.duplicate(true),
				})
	var verified_lifecycle := _preflight_lifecycle(component)
	if not bool(verified_lifecycle.get("ok", false)) \
			or StringName(verified_lifecycle.get("life_state", &"")) \
				== StringName():
		return _rollback_initialization(component, before,
			&"health_life_postcondition_failed", {
				"lifecycle": verified_lifecycle,
			})
	return {
		"accepted": true,
		"initialized": initialized,
		"replayed": replayed,
		"life_replayed": life_replayed,
		"life_state": verified_lifecycle["life_state"],
		"bootstrap_spec": int((verified_lifecycle["bootstrap_specs"] \
			as PackedInt64Array)[0]),
		"catalog_fingerprint": preflight["catalog_fingerprint"],
	}


## The only task-5.5 seam allowed to apply set-by-caller instant health or
## resource effects. Integer micro-units, exact grant identity, and real
## base/current headroom are all validated before activation.
static func apply_bounded_instant(
	component: GameplayAbilityComponent,
	ability_spec: int,
	effect_identifier: StringName,
	requested_amount_micros: Variant,
	tick: int,
	command_sequence: int
) -> Dictionary:
	var preflight := preflight_component(component, tick)
	if not bool(preflight.get("accepted", false)):
		return preflight
	if typeof(requested_amount_micros) != TYPE_INT:
		return _rejection(&"health_amount_type_invalid")
	var requested := int(requested_amount_micros)
	if requested <= 0 or requested > MAX_APPLICATION_AMOUNT_MICROS:
		return _rejection(&"health_amount_out_of_bounds")
	if command_sequence <= 0 or command_sequence > MAX_COMMAND_SEQUENCE:
		return _rejection(&"health_command_sequence_invalid")
	if not component.has_tag_exact(String(TAG_LIFE_ALIVE)) \
			or component.has_tag_exact(String(TAG_LIFE_DEAD)):
		return _rejection(&"health_actor_not_alive")
	var policy := instant_application_declaration(effect_identifier)
	if policy.is_empty():
		return _rejection(&"health_instant_effect_not_declared")
	var grant := component.get_grant(ability_spec)
	if grant.is_empty() or bool(grant.get("revoked", true)) \
			or StringName(grant.get("ability_identifier", &"")) \
				!= StringName(policy["ability_identifier"]):
		return _rejection(&"health_ability_spec_mismatch")
	var attribute_identifier := String(policy["attribute_identifier"])
	if not component.has_attribute(attribute_identifier):
		return _rejection(&"health_attribute_uninitialized")
	var minimum := int(policy["min_micros"])
	var maximum := int(policy["max_micros"])
	var base_before := _fixed_micros(component.get_attribute_base(attribute_identifier))
	var current_before := _fixed_micros(component.get_attribute_current(attribute_identifier))
	if base_before < minimum or base_before > maximum \
			or current_before < minimum or current_before > maximum:
		return _rejection(&"health_attribute_out_of_bounds")
	var applied := requested
	var mode := StringName(policy["bound_policy"])
	if mode == BOUND_CAP_TO_FLOOR:
		applied = mini(requested,
			mini(base_before - minimum, current_before - minimum))
	elif mode == BOUND_REJECT_OVERSPEND:
		var available := mini(base_before - minimum, current_before - minimum)
		if requested > available:
			return _rejection(&"health_resource_overspend", {
				"requested_amount_micros": requested,
				"available_amount_micros": available,
			})
	elif mode == BOUND_CAP_TO_HEADROOM:
		applied = mini(requested,
			mini(maximum - base_before, maximum - current_before))
	else:
		return _rejection(&"health_bound_policy_invalid")
	if applied == 0:
		return {
			"accepted": true,
			"reason": &"",
			"requested_amount_micros": requested,
			"applied_amount_micros": 0,
			"clamped": true,
			"native_invoked": false,
			"attribute_identifier": attribute_identifier,
			"base_before_micros": base_before,
			"base_after_micros": base_before,
		}
	var before := component.write_snapshot()
	if before.is_empty():
		return _rejection(&"health_snapshot_unavailable")
	var activation: Dictionary = component.request_activation({
		"spec": ability_spec,
		"command_sequence": command_sequence,
		"set_by_caller": [{
			"field": String(SET_BY_CALLER_AMOUNT),
			"value": float(applied) / float(FIXED_SCALE),
		}],
	}, tick)
	var status := activation.get("status", {}) as Dictionary
	if not bool(status.get("ok", false)):
		var rollback_ok := component.write_snapshot() == before
		if not rollback_ok:
			rollback_ok = component.restore_snapshot(before)
		return _rejection(&"health_native_activation_failed", {
			"status": status.duplicate(true),
			"rollback_ok": rollback_ok,
		})
	var direction := int(policy["direction"])
	var expected_after := base_before + direction * applied
	var base_after := _fixed_micros(component.get_attribute_base(attribute_identifier))
	var current_after := _fixed_micros(component.get_attribute_current(attribute_identifier))
	if base_after != expected_after or base_after < minimum or base_after > maximum \
			or current_after < minimum or current_after > maximum:
		var rollback_ok := component.restore_snapshot(before)
		return _rejection(&"health_native_postcondition_failed", {
			"rollback_ok": rollback_ok,
			"expected_base_micros": expected_after,
			"actual_base_micros": base_after,
		})
	return {
		"accepted": true,
		"reason": &"",
		"requested_amount_micros": requested,
		"applied_amount_micros": applied,
		"clamped": applied != requested,
		"native_invoked": true,
		"attribute_identifier": attribute_identifier,
		"base_before_micros": base_before,
		"base_after_micros": base_after,
		"activation": activation,
	}


static func body_zone_declarations() -> Array[Dictionary]:
	return [
		_zone_declaration(ZONE_HEAD, "Head", ATTRIBUTE_HEALTH_HEAD,
			MAX_HEALTH_HEAD_MICROS, true, 0),
		_zone_declaration(ZONE_THORAX, "Thorax", ATTRIBUTE_HEALTH_THORAX,
			MAX_HEALTH_THORAX_MICROS, true, 0),
		_zone_declaration(ZONE_ABDOMEN, "Abdomen", ATTRIBUTE_HEALTH_ABDOMEN,
			MAX_HEALTH_ABDOMEN_MICROS, false, 0),
		_zone_declaration(ZONE_LEFT_ARM, "Left arm", ATTRIBUTE_HEALTH_LEFT_ARM,
			MAX_HEALTH_ARM_MICROS, false, 0),
		_zone_declaration(ZONE_RIGHT_ARM, "Right arm", ATTRIBUTE_HEALTH_RIGHT_ARM,
			MAX_HEALTH_ARM_MICROS, false, 0),
		_zone_declaration(ZONE_LEFT_LEG, "Left leg", ATTRIBUTE_HEALTH_LEFT_LEG,
			MAX_HEALTH_LEG_MICROS, false, LEG_FRACTURE_MOVEMENT_DELTA_MICROS),
		_zone_declaration(ZONE_RIGHT_LEG, "Right leg", ATTRIBUTE_HEALTH_RIGHT_LEG,
			MAX_HEALTH_LEG_MICROS, false, LEG_FRACTURE_MOVEMENT_DELTA_MICROS),
	]


static func body_zone_declaration(zone_identifier: StringName) -> Dictionary:
	for declaration in body_zone_declarations():
		if StringName(declaration["zone_identifier"]) == zone_identifier:
			return declaration.duplicate(true)
	return {}


static func attribute_declarations() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for zone in body_zone_declarations():
		result.append(_attribute_declaration(
			StringName(zone["health_attribute_identifier"]),
			int(zone["max_health_micros"]), 0, int(zone["max_health_micros"])))
	result.append(_attribute_declaration(
		ATTRIBUTE_LIFE_STATE, FIXED_SCALE, 0, FIXED_SCALE))
	result.append(_attribute_declaration(
		ATTRIBUTE_STAMINA, MAX_STAMINA_MICROS, 0, MAX_STAMINA_MICROS))
	result.append(_attribute_declaration(
		ATTRIBUTE_HYDRATION, MAX_HYDRATION_MICROS, 0, MAX_HYDRATION_MICROS))
	result.append(_attribute_declaration(ATTRIBUTE_PAIN, 0, 0, MAX_PAIN_MICROS))
	result.append(_attribute_declaration(
		ATTRIBUTE_MOVEMENT_SPEED_SCALE, DEFAULT_MOVEMENT_SPEED_SCALE_MICROS,
		MIN_MOVEMENT_SPEED_SCALE_MICROS, DEFAULT_MOVEMENT_SPEED_SCALE_MICROS))
	return result


static func instant_application_declarations() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for zone in body_zone_declarations():
		result.append(_instant_application_declaration(
			StringName(zone["damage_effect_identifier"]),
			StringName(zone["damage_ability_identifier"]),
			StringName(zone["health_attribute_identifier"]), -1,
			BOUND_CAP_TO_FLOOR, 0, int(zone["max_health_micros"])))
	result.append(_instant_application_declaration(
		EFFECT_STAMINA_SPEND, ABILITY_STAMINA_SPEND, ATTRIBUTE_STAMINA, -1,
		BOUND_REJECT_OVERSPEND, 0, MAX_STAMINA_MICROS))
	result.append(_instant_application_declaration(
		EFFECT_STAMINA_RESTORE, ABILITY_STAMINA_RESTORE, ATTRIBUTE_STAMINA, 1,
		BOUND_CAP_TO_HEADROOM, 0, MAX_STAMINA_MICROS))
	result.append(_instant_application_declaration(
		EFFECT_HYDRATION_DRAIN, ABILITY_HYDRATION_DRAIN, ATTRIBUTE_HYDRATION, -1,
		BOUND_REJECT_OVERSPEND, 0, MAX_HYDRATION_MICROS))
	result.append(_instant_application_declaration(
		EFFECT_HYDRATION_RESTORE, ABILITY_HYDRATION_RESTORE,
		ATTRIBUTE_HYDRATION, 1, BOUND_CAP_TO_HEADROOM, 0,
		MAX_HYDRATION_MICROS))
	return result


static func instant_application_declaration(effect_identifier: StringName) -> Dictionary:
	for declaration in instant_application_declarations():
		if StringName(declaration["effect_identifier"]) == effect_identifier:
			return declaration.duplicate(true)
	return {}


static func pain_policy_declaration() -> Dictionary:
	return {
		"attribute_identifier": String(ATTRIBUTE_PAIN),
		"min_micros": 0,
		"max_micros": MAX_PAIN_MICROS,
		"aggregation": "active_injury_additive_clamped",
		"heavy_bleed_contribution_micros": HEAVY_BLEED_PAIN_MICROS,
		"fracture_contribution_micros": FRACTURE_PAIN_MICROS,
		"application_owner": "task_5_6_authorized_injury_transition",
	}


static func movement_policy_declaration() -> Dictionary:
	return {
		"attribute_identifier": String(ATTRIBUTE_MOVEMENT_SPEED_SCALE),
		"min_micros": MIN_MOVEMENT_SPEED_SCALE_MICROS,
		"default_micros": DEFAULT_MOVEMENT_SPEED_SCALE_MICROS,
		"aggregation": "active_fracture_additive_clamped",
		"leg_fracture_delta_micros": LEG_FRACTURE_MOVEMENT_DELTA_MICROS,
		"non_leg_fracture_delta_micros": 0,
		"application_owner": "task_5_6_authorized_injury_transition",
	}


static func healing_eligibility_declaration() -> Dictionary:
	return {
		"requires_life_tag_identifier": String(TAG_LIFE_ALIVE),
		"blocked_life_tag_identifier": String(TAG_LIFE_DEAD),
		"health_restore_requires_below_zone_max": true,
		"bandage_requires_exact_zone_heavy_bleed": true,
		"splint_requires_exact_zone_fracture": true,
		"consume_item_only_after_transition_commit": true,
		"bandage_restores_zone_health": false,
		"splint_restores_zone_health": false,
		"application_owner": "task_5_6_raid_authority",
	}


static func persistent_execution_policy_declaration() -> Dictionary:
	return {
		"activation_policy": "manual_except_passive_initial_alive",
		"concurrency_policy": "reject_if_active",
		"duplicate_grant_policy": "reject",
		"revoke_policy": "cancel_active",
		"ends_on_commit": false,
		"stack_scope": "target",
		"max_stacks": 1,
		"overflow_policy": "reject",
		"refresh_duration_on_add": false,
		"reset_period_on_add": false,
		"removal_rule": "all_stacks",
	}


static func declaration_bytes() -> PackedByteArray:
	var encoded := ZCanonicalValue.encode(_canonical_declaration_record())
	return encoded.to_utf8_buffer() if not encoded.is_empty() \
		else PackedByteArray()


static func declaration_digest() -> String:
	return ZCanonicalValue.sha256(_canonical_declaration_record())


static func body_zone_declaration_digests() -> Array[String]:
	var result: Array[String] = []
	for zone in body_zone_declarations():
		result.append(ZCanonicalValue.sha256(zone))
	return result


static func _canonical_declaration_record() -> Dictionary:
	return {
		"schema_version": CONTENT_SCHEMA_VERSION,
		"tick_rate": TICK_RATE,
		"fixed_scale": FIXED_SCALE,
		"max_application_amount_micros": MAX_APPLICATION_AMOUNT_MICROS,
		"life_state": {
			"attribute_identifier": String(ATTRIBUTE_LIFE_STATE),
			"alive_tag_identifier": String(TAG_LIFE_ALIVE),
			"dead_tag_identifier": String(TAG_LIFE_DEAD),
			"alive_effect_identifier": String(EFFECT_LIFE_ALIVE),
			"dead_effect_identifier": String(EFFECT_LIFE_DEAD),
			"alive_ability_identifier": String(ABILITY_LIFE_ALIVE),
			"dead_ability_identifier": String(ABILITY_LIFE_DEAD),
			"transition": "dead_tag_cancels_alive_execution",
			"death_rule": "head_or_thorax_zero",
		},
		"medical_items": {
			"bandage_item_identifier": String(ITEM_BANDAGE),
			"splint_item_identifier": String(ITEM_SPLINT),
		},
		"attribute_declarations_digest":
			ZCanonicalValue.sha256(attribute_declarations()),
		"body_zone_declaration_digests": body_zone_declaration_digests(),
		"instant_application_declarations_digest":
			ZCanonicalValue.sha256(instant_application_declarations()),
		"persistent_execution_policy": persistent_execution_policy_declaration(),
		"pain_policy": pain_policy_declaration(),
		"movement_policy": movement_policy_declaration(),
		"healing_eligibility": healing_eligibility_declaration(),
	}


static func _zone_declaration(
	zone_identifier: StringName,
	display_name: String,
	health_attribute_identifier: StringName,
	max_health_micros: int,
	lethal_at_zero: bool,
	fracture_movement_delta_micros: int
) -> Dictionary:
	var zone := String(zone_identifier)
	var damage_effect := "zerkov.effect.damage.%s" % zone
	var bleed_effect := "zerkov.effect.injury.heavy_bleed.%s" % zone
	var fracture_effect := "zerkov.effect.injury.fracture.%s" % zone
	var bandage_effect := "zerkov.effect.treatment.bandage.%s" % zone
	var splint_effect := "zerkov.effect.treatment.splint.%s" % zone
	return {
		"zone_identifier": zone,
		"display_name": display_name,
		"health_attribute_identifier": String(health_attribute_identifier),
		"max_health_micros": max_health_micros,
		"lethal_at_zero": lethal_at_zero,
		"overflow_policy": String(BOUND_CAP_TO_FLOOR),
		"damage_effect_identifier": damage_effect,
		"damage_ability_identifier": _ability_identifier_for_effect(damage_effect),
		"heavy_bleed_tag_identifier": "zerkov.state.injury.heavy_bleed.%s" % zone,
		"heavy_bleed_effect_identifier": bleed_effect,
		"heavy_bleed_ability_identifier": _ability_identifier_for_effect(bleed_effect),
		"heavy_bleed_period_ticks": HEAVY_BLEED_PERIOD_TICKS,
		"heavy_bleed_damage_micros": HEAVY_BLEED_DAMAGE_MICROS,
		"heavy_bleed_pain_micros": HEAVY_BLEED_PAIN_MICROS,
		"heavy_bleed_stack_key": "zerkov.stack.injury.heavy_bleed.%s" % zone,
		"fracture_tag_identifier": "zerkov.state.injury.fracture.%s" % zone,
		"fracture_effect_identifier": fracture_effect,
		"fracture_ability_identifier": _ability_identifier_for_effect(fracture_effect),
		"fracture_pain_micros": FRACTURE_PAIN_MICROS,
		"fracture_movement_delta_micros": fracture_movement_delta_micros,
		"fracture_stack_key": "zerkov.stack.injury.fracture.%s" % zone,
		"bandaged_tag_identifier": "zerkov.state.treatment.bandaged.%s" % zone,
		"bandage_effect_identifier": bandage_effect,
		"bandage_ability_identifier": _ability_identifier_for_effect(bandage_effect),
		"bandage_cancels_effect_identifier": bleed_effect,
		"bandage_cancels_ability_identifier": _ability_identifier_for_effect(bleed_effect),
		"bandage_stack_key": "zerkov.stack.treatment.bandage.%s" % zone,
		"splinted_tag_identifier": "zerkov.state.treatment.splinted.%s" % zone,
		"splint_effect_identifier": splint_effect,
		"splint_ability_identifier": _ability_identifier_for_effect(splint_effect),
		"splint_cancels_effect_identifier": fracture_effect,
		"splint_cancels_ability_identifier": _ability_identifier_for_effect(fracture_effect),
		"splint_stack_key": "zerkov.stack.treatment.splint.%s" % zone,
		"persistent_max_stacks": 1,
		"persistent_overflow_policy": "reject",
		"persistent_period_refresh": false,
	}


static func _tag_definitions() -> Array[GameplayTagDefinition]:
	var result: Array[GameplayTagDefinition] = [
		_tag(TAG_LIFE_ALIVE, "The actor is authoritatively alive."),
		_tag(TAG_LIFE_DEAD, "The actor is authoritatively dead."),
		_tag(TAG_HEAVY_BLEED, "Parent-aware query identity for any heavy bleed."),
		_tag(TAG_FRACTURE, "Parent-aware query identity for any fracture."),
		_tag(TAG_BANDAGED, "Parent-aware query identity for any bandaged wound."),
		_tag(TAG_SPLINTED, "Parent-aware query identity for any splinted fracture."),
	]
	for zone in body_zone_declarations():
		result.append(_tag(StringName(zone["heavy_bleed_tag_identifier"]),
			"Heavy bleeding is active on %s." % zone["display_name"]))
		result.append(_tag(StringName(zone["fracture_tag_identifier"]),
			"A fracture is active on %s." % zone["display_name"]))
		result.append(_tag(StringName(zone["bandaged_tag_identifier"]),
			"Bandage treatment is present on %s." % zone["display_name"]))
		result.append(_tag(StringName(zone["splinted_tag_identifier"]),
			"Splint treatment is present on %s." % zone["display_name"]))
	return result


static func _attribute_definitions() -> Array[GameplayAttributeDefinition]:
	var result: Array[GameplayAttributeDefinition] = []
	for declaration in attribute_declarations():
		result.append(_attribute(
			StringName(declaration["identifier"]),
			String(declaration["identifier"]).get_slice(".", -1).capitalize(),
			int(declaration["default_base_micros"]),
			int(declaration["min_micros"]),
			int(declaration["max_micros"])))
	return result


static func _effect_definitions() -> Array[GameplayEffectDefinition]:
	var result: Array[GameplayEffectDefinition] = [
		_state_effect(EFFECT_LIFE_ALIVE, TAG_LIFE_ALIVE,
			ATTRIBUTE_LIFE_STATE, FIXED_SCALE, "zerkov.stack.life.alive"),
		_state_effect(EFFECT_LIFE_DEAD, TAG_LIFE_DEAD,
			ATTRIBUTE_LIFE_STATE, 0, "zerkov.stack.life.dead"),
		_parameterized_effect(EFFECT_STAMINA_SPEND, ATTRIBUTE_STAMINA, -1),
		_parameterized_effect(EFFECT_STAMINA_RESTORE, ATTRIBUTE_STAMINA, 1),
		_parameterized_effect(EFFECT_HYDRATION_DRAIN, ATTRIBUTE_HYDRATION, -1),
		_parameterized_effect(EFFECT_HYDRATION_RESTORE, ATTRIBUTE_HYDRATION, 1),
	]
	for zone in body_zone_declarations():
		result.append(_parameterized_effect(
			StringName(zone["damage_effect_identifier"]),
			StringName(zone["health_attribute_identifier"]), -1))
		result.append(_injury_effect(
			StringName(zone["heavy_bleed_effect_identifier"]),
			StringName(zone["heavy_bleed_tag_identifier"]),
			int(zone["heavy_bleed_pain_micros"]), 0,
			String(zone["heavy_bleed_stack_key"])))
		result.append(_injury_effect(
			StringName(zone["fracture_effect_identifier"]),
			StringName(zone["fracture_tag_identifier"]),
			int(zone["fracture_pain_micros"]),
			int(zone["fracture_movement_delta_micros"]),
			String(zone["fracture_stack_key"])))
		result.append(_tag_state_effect(
			StringName(zone["bandage_effect_identifier"]),
			StringName(zone["bandaged_tag_identifier"]),
			String(zone["bandage_stack_key"])))
		result.append(_tag_state_effect(
			StringName(zone["splint_effect_identifier"]),
			StringName(zone["splinted_tag_identifier"]),
			String(zone["splint_stack_key"])))
	return result


static func _ability_definitions() -> Array[GameplayAbilityDefinition]:
	var result: Array[GameplayAbilityDefinition] = [
		_ability(ABILITY_LIFE_ALIVE, [EFFECT_LIFE_ALIVE], true,
			PackedStringArray(), PackedStringArray([TAG_LIFE_DEAD]),
			PackedStringArray([TAG_LIFE_DEAD]), true),
		_ability(ABILITY_LIFE_DEAD, [EFFECT_LIFE_DEAD], true,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()),
		_ability(ABILITY_STAMINA_SPEND, [EFFECT_STAMINA_SPEND], false,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()),
		_ability(ABILITY_STAMINA_RESTORE, [EFFECT_STAMINA_RESTORE], false,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()),
		_ability(ABILITY_HYDRATION_DRAIN, [EFFECT_HYDRATION_DRAIN], false,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()),
		_ability(ABILITY_HYDRATION_RESTORE, [EFFECT_HYDRATION_RESTORE], false,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()),
	]
	for zone in body_zone_declarations():
		var bleed_tag := StringName(zone["heavy_bleed_tag_identifier"])
		var fracture_tag := StringName(zone["fracture_tag_identifier"])
		var bandaged_tag := StringName(zone["bandaged_tag_identifier"])
		var splinted_tag := StringName(zone["splinted_tag_identifier"])
		result.append(_ability(
			StringName(zone["damage_ability_identifier"]),
			[StringName(zone["damage_effect_identifier"])], false,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()))
		result.append(_ability(
			StringName(zone["heavy_bleed_ability_identifier"]),
			[StringName(zone["heavy_bleed_effect_identifier"])], true,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD, bandaged_tag]),
			PackedStringArray([bandaged_tag])))
		result.append(_ability(
			StringName(zone["fracture_ability_identifier"]),
			[StringName(zone["fracture_effect_identifier"])], true,
			PackedStringArray([TAG_LIFE_ALIVE]),
			PackedStringArray([TAG_LIFE_DEAD, splinted_tag]),
			PackedStringArray([splinted_tag])))
		result.append(_ability(
			StringName(zone["bandage_ability_identifier"]),
			[StringName(zone["bandage_effect_identifier"])], true,
			PackedStringArray([TAG_LIFE_ALIVE, bleed_tag]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()))
		result.append(_ability(
			StringName(zone["splint_ability_identifier"]),
			[StringName(zone["splint_effect_identifier"])], true,
			PackedStringArray([TAG_LIFE_ALIVE, fracture_tag]),
			PackedStringArray([TAG_LIFE_DEAD]), PackedStringArray()))
	return result


static func _ability(
	identifier: StringName,
	effect_identifiers: Array,
	persistent: bool,
	required_tags: PackedStringArray,
	blocked_tags: PackedStringArray,
	cancel_tags: PackedStringArray,
	passive_on_grant: bool = false
) -> GameplayAbilityDefinition:
	var commits := PackedStringArray()
	for effect_identifier in effect_identifiers:
		commits.append(String(effect_identifier))
	var ability := GameplayAbilityDefinition.new()
	ability.identifier = identifier
	ability.activation_policy = GameplayAbilityDefinition.ACTIVATION_PASSIVE_ON_GRANT \
		if passive_on_grant else GameplayAbilityDefinition.ACTIVATION_MANUAL
	ability.commit_effects = commits
	ability.concurrency_policy = GameplayAbilityDefinition.CONCURRENCY_REJECT_IF_ACTIVE
	ability.duplicate_grant_policy = GameplayAbilityDefinition.DUPLICATE_GRANT_REJECT
	ability.revoke_policy = GameplayAbilityDefinition.REVOKE_CANCEL_ACTIVE
	ability.prediction_policy = GameplayAbilityDefinition.PREDICTION_NOT_PREDICTABLE
	ability.hook_binding = GameplayAbilityDefinition.HOOK_BINDING_NONE
	ability.auto_commit = true
	ability.ends_on_commit = not persistent
	if not required_tags.is_empty():
		ability.required_tags = _tag_query(required_tags, false)
	if not blocked_tags.is_empty():
		ability.blocked_tags = _tag_query(blocked_tags, true)
	if not cancel_tags.is_empty():
		ability.cancel_tags = _tag_query(cancel_tags, true)
	return ability


static func _tag_query(
	tags: PackedStringArray,
	use_any: bool
) -> GameplayTagQueryResource:
	var operands: Array[GameplayTagOperand] = []
	for tag_identifier in tags:
		var operand := GameplayTagOperand.new()
		operand.tag = StringName(tag_identifier)
		operand.match_mode = GameplayTagOperand.MATCH_EXACT
		operands.append(operand)
	var query := GameplayTagQueryResource.new()
	if use_any:
		query.any_of = operands
	else:
		query.all_of = operands
	return query


static func _tag(identifier: StringName, description: String) -> GameplayTagDefinition:
	var tag := GameplayTagDefinition.new()
	tag.identifier = identifier
	tag.description = description
	tag.source_label = "Zerkov health ability content"
	return tag


static func _attribute(
	identifier: StringName,
	display_name: String,
	default_micros: int,
	min_micros: int,
	max_micros: int
) -> GameplayAttributeDefinition:
	var attribute := GameplayAttributeDefinition.new()
	attribute.identifier = identifier
	attribute.default_base = float(default_micros) / float(FIXED_SCALE)
	attribute.has_min = true
	attribute.min_value = float(min_micros) / float(FIXED_SCALE)
	attribute.has_max = true
	attribute.max_value = float(max_micros) / float(FIXED_SCALE)
	attribute.display_name = display_name
	return attribute


static func _parameterized_effect(
	identifier: StringName,
	target_attribute: StringName,
	direction: int
) -> GameplayEffectDefinition:
	var field := GameplaySetByCallerField.new()
	field.identifier = SET_BY_CALLER_AMOUNT
	field.required = true
	var magnitude := GameplayMagnitude.new()
	magnitude.kind = GameplayMagnitude.KIND_SET_BY_CALLER
	magnitude.coefficient = float(direction)
	magnitude.set_by_caller_field = SET_BY_CALLER_AMOUNT
	var modifier := GameplayModifierDeclaration.new()
	modifier.target_attribute = target_attribute
	modifier.op = GameplayModifierDeclaration.OP_ADD
	modifier.magnitude = magnitude
	modifier.priority = 0
	var effect := GameplayEffectDefinition.new()
	effect.identifier = identifier
	effect.duration_policy = GameplayEffectDefinition.DURATION_INSTANT
	effect.modifiers = [modifier]
	effect.set_by_caller_fields = [field]
	effect.prediction_safe = false
	return effect


static func _state_effect(
	identifier: StringName,
	granted_tag: StringName,
	target_attribute: StringName,
	value_micros: int,
	stack_key: String
) -> GameplayEffectDefinition:
	var effect := _tag_state_effect(identifier, granted_tag, stack_key)
	effect.modifiers = [_constant_modifier(
		target_attribute, GameplayModifierDeclaration.OP_OVERRIDE, value_micros)]
	return effect


static func _injury_effect(
	identifier: StringName,
	granted_tag: StringName,
	pain_micros: int,
	movement_delta_micros: int,
	stack_key: String
) -> GameplayEffectDefinition:
	var effect := _tag_state_effect(identifier, granted_tag, stack_key)
	var modifiers: Array[GameplayModifierDeclaration] = [
		_constant_modifier(
			ATTRIBUTE_PAIN, GameplayModifierDeclaration.OP_ADD, pain_micros),
	]
	if movement_delta_micros != 0:
		modifiers.append(_constant_modifier(ATTRIBUTE_MOVEMENT_SPEED_SCALE,
			GameplayModifierDeclaration.OP_ADD, movement_delta_micros))
	effect.modifiers = modifiers
	return effect


static func _constant_modifier(
	target_attribute: StringName,
	op: int,
	magnitude_micros: int
) -> GameplayModifierDeclaration:
	var magnitude := GameplayMagnitude.new()
	magnitude.kind = GameplayMagnitude.KIND_CONSTANT
	magnitude.coefficient = float(magnitude_micros) / float(FIXED_SCALE)
	var modifier := GameplayModifierDeclaration.new()
	modifier.target_attribute = target_attribute
	modifier.op = op
	modifier.magnitude = magnitude
	modifier.priority = 0
	return modifier


static func _tag_state_effect(
	identifier: StringName,
	granted_tag: StringName,
	stack_key: String
) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.identifier = identifier
	effect.duration_policy = GameplayEffectDefinition.DURATION_INFINITE
	effect.granted_tags = PackedStringArray([granted_tag])
	effect.stacking = _single_instance_stack(stack_key)
	effect.prediction_safe = false
	return effect


static func _single_instance_stack(stack_key: String) -> GameplayStackingPolicy:
	var policy := GameplayStackingPolicy.new()
	policy.stackable = true
	policy.stack_key = stack_key
	policy.source_scope = GameplayStackingPolicy.TARGET_SCOPED
	policy.max_stacks = 1
	policy.overflow_policy = GameplayStackingPolicy.OVERFLOW_REJECT
	policy.refresh_duration_on_add = false
	policy.reset_period_on_add = false
	policy.removal_rule = GameplayStackingPolicy.REMOVE_ALL_STACKS
	return policy


static func _attribute_declaration(
	identifier: StringName,
	default_micros: int,
	min_micros: int,
	max_micros: int
) -> Dictionary:
	return {
		"identifier": String(identifier),
		"default_base_micros": default_micros,
		"min_micros": min_micros,
		"max_micros": max_micros,
	}


static func _instant_application_declaration(
	effect_identifier: StringName,
	ability_identifier: StringName,
	attribute_identifier: StringName,
	direction: int,
	bound_policy: StringName,
	min_micros: int,
	max_micros: int
) -> Dictionary:
	return {
		"effect_identifier": String(effect_identifier),
		"ability_identifier": String(ability_identifier),
		"attribute_identifier": String(attribute_identifier),
		"direction": direction,
		"bound_policy": String(bound_policy),
		"min_micros": min_micros,
		"max_micros": max_micros,
		"max_request_micros": MAX_APPLICATION_AMOUNT_MICROS,
	}


static func _ability_identifier_for_effect(effect_identifier: String) -> String:
	return "zerkov.ability.%s" % effect_identifier.trim_prefix("zerkov.effect.")


static func _preflight_lifecycle(component: GameplayAbilityComponent) -> Dictionary:
	var bootstrap_specs := PackedInt64Array()
	for spec in component.granted_specs():
		var grant := component.get_grant(spec)
		if String(grant.get("input_id", "")) != HEALTH_BOOTSTRAP_INPUT_ID:
			continue
		if bool(grant.get("revoked", true)) \
				or StringName(grant.get("ability_identifier", &"")) != ABILITY_LIFE_ALIVE \
				or int(grant.get("level", 0)) != 1:
			return {"ok": false, "reason": &"health_bootstrap_provenance_conflict"}
		bootstrap_specs.append(spec)
	if bootstrap_specs.size() > 1:
		return {"ok": false, "reason": &"health_bootstrap_provenance_ambiguous"}
	var alive := component.has_tag_exact(String(TAG_LIFE_ALIVE))
	var dead := component.has_tag_exact(String(TAG_LIFE_DEAD))
	var alive_effects := _active_effect_count(component, EFFECT_LIFE_ALIVE)
	var dead_effects := _active_effect_count(component, EFFECT_LIFE_DEAD)
	if bootstrap_specs.is_empty():
		if alive or dead or alive_effects > 0 or dead_effects > 0:
			return {"ok": false, "reason": &"health_lifecycle_provenance_missing"}
		if component.granted_specs().size() >= MAX_ABILITY_GRANTS:
			return {"ok": false, "reason": &"health_grant_capacity_exceeded"}
		return {
			"ok": true,
			"bootstrap_specs": bootstrap_specs,
			"life_state": &"",
		}
	if alive == dead:
		return {"ok": false, "reason": &"health_life_tags_not_exclusive"}
	var expected_ability := ABILITY_LIFE_ALIVE if alive else ABILITY_LIFE_DEAD
	var expected_effect_count := alive_effects if alive else dead_effects
	var opposing_effect_count := dead_effects if alive else alive_effects
	if expected_effect_count != 1 or opposing_effect_count != 0 \
			or _active_execution_count(component, expected_ability) != 1:
		return {"ok": false, "reason": &"health_life_execution_ownership_invalid"}
	if alive and not _execution_uses_spec(component, bootstrap_specs[0]):
		return {"ok": false, "reason": &"health_alive_bootstrap_execution_missing"}
	return {
		"ok": true,
		"bootstrap_specs": bootstrap_specs,
		"life_state": &"alive" if alive else &"dead",
	}


static func _validate_catalog_subset(component: GameplayAbilityComponent) -> Dictionary:
	var actual_catalog := component.get_definition_catalog()
	if actual_catalog == null:
		return {"ok": false, "reason": &"health_catalog_missing"}
	var full_validator := GameplayDefinitionValidator.new()
	var full_findings: Array = full_validator.validate_catalog(actual_catalog)
	if not GameplayDefinitionValidator.is_ok(full_findings) \
			or not full_validator.get_last_manifest_ok() \
			or full_validator.get_last_manifest_fingerprint() \
				!= component.get_content_manifest_fingerprint():
		return {"ok": false, "reason": &"health_catalog_changed_after_configure"}
	var expected_catalog := build_definition_catalog()
	var subset := GameplayDefinitionCatalog.new()
	var subset_tags: Array[GameplayTagDefinition] = []
	var subset_attributes: Array[GameplayAttributeDefinition] = []
	var subset_effects: Array[GameplayEffectDefinition] = []
	var subset_abilities: Array[GameplayAbilityDefinition] = []
	for expected_value in expected_catalog.get_tag_definitions():
		var expected := expected_value as GameplayTagDefinition
		var actual := _find_definition(
			actual_catalog.get_tag_definitions(), expected.identifier) \
			as GameplayTagDefinition
		if actual == null:
			return {"ok": false, "reason": &"health_tag_definition_missing"}
		subset_tags.append(actual)
	for expected_value in expected_catalog.get_attribute_definitions():
		var expected := expected_value as GameplayAttributeDefinition
		var actual := _find_definition(
			actual_catalog.get_attribute_definitions(), expected.identifier) \
			as GameplayAttributeDefinition
		if actual == null:
			return {"ok": false, "reason": &"health_attribute_definition_missing"}
		subset_attributes.append(actual)
	for expected_value in expected_catalog.get_effect_definitions():
		var expected := expected_value as GameplayEffectDefinition
		var actual := _find_definition(
			actual_catalog.get_effect_definitions(), expected.identifier) \
			as GameplayEffectDefinition
		if actual == null:
			return {"ok": false, "reason": &"health_effect_definition_missing"}
		subset_effects.append(actual)
	for expected_value in expected_catalog.get_ability_definitions():
		var expected := expected_value as GameplayAbilityDefinition
		var actual := _find_definition(
			actual_catalog.get_ability_definitions(), expected.identifier) \
			as GameplayAbilityDefinition
		if actual == null:
			return {"ok": false, "reason": &"health_ability_definition_missing"}
		subset_abilities.append(actual)
	subset.tag_definitions = subset_tags
	subset.attribute_definitions = subset_attributes
	subset.effect_definitions = subset_effects
	subset.ability_definitions = subset_abilities
	var expected_validator := GameplayDefinitionValidator.new()
	var expected_findings: Array = expected_validator.validate_catalog(expected_catalog)
	var actual_validator := GameplayDefinitionValidator.new()
	var actual_findings: Array = actual_validator.validate_catalog(subset)
	if not GameplayDefinitionValidator.is_ok(expected_findings) \
			or not expected_validator.get_last_manifest_ok():
		return {"ok": false, "reason": &"health_expected_catalog_invalid"}
	if not GameplayDefinitionValidator.is_ok(actual_findings) \
			or not actual_validator.get_last_manifest_ok():
		return {"ok": false, "reason": &"health_catalog_subset_invalid"}
	if actual_validator.get_last_manifest_fingerprint() \
			!= expected_validator.get_last_manifest_fingerprint() \
			or actual_validator.get_last_manifest_entry_count() \
				!= expected_validator.get_last_manifest_entry_count() \
			or actual_validator.get_last_manifest_tick_rate() \
				!= expected_validator.get_last_manifest_tick_rate():
		return {"ok": false, "reason": &"health_catalog_semantics_mismatch"}
	return {
		"ok": true,
		"content_manifest_fingerprint": actual_validator.get_last_manifest_fingerprint(),
	}


static func _find_definition(definitions: Array, identifier: StringName) -> Resource:
	var found: Resource
	for value in definitions:
		if not value is Resource or not value.has_method("get_identifier"):
			continue
		var definition := value as Resource
		if StringName(definition.call("get_identifier")) != identifier:
			continue
		if found != null:
			return null
		found = definition
	return found


static func _active_effect_count(
	component: GameplayAbilityComponent,
	effect_identifier: StringName
) -> int:
	var count := 0
	for handle in component.active_effect_handles():
		var effect := component.get_active_effect(handle)
		if StringName(effect.get("definition_identifier", &"")) == effect_identifier:
			count += 1
	return count


static func _active_execution_count(
	component: GameplayAbilityComponent,
	ability_identifier: StringName
) -> int:
	var count := 0
	for execution_id in component.active_executions():
		var execution := component.get_execution(execution_id)
		if StringName(execution.get("ability_identifier", &"")) == ability_identifier:
			count += 1
	return count


static func _execution_uses_spec(
	component: GameplayAbilityComponent,
	spec: int
) -> bool:
	for execution_id in component.active_executions():
		if int(component.get_execution(execution_id).get("spec", 0)) == spec:
			return true
	return false


static func _rollback_initialization(
	component: GameplayAbilityComponent,
	before: PackedByteArray,
	reason: StringName,
	details: Dictionary
) -> Dictionary:
	var result := _rejection(reason, details)
	result["rollback_ok"] = component.restore_snapshot(before)
	return result


static func _fixed_micros(value: float) -> int:
	var scaled := value * float(FIXED_SCALE)
	if scaled < 0.0:
		return -int(floor(-scaled + 0.5))
	return int(floor(scaled + 0.5))


static func _rejection(reason: StringName, details: Dictionary = {}) -> Dictionary:
	var result := {
		"accepted": false,
		"reason": reason,
		"mutation_state": &"none",
	}
	result.merge(details, true)
	return result
