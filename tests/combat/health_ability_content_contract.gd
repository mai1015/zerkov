extends SceneTree
## Task 5.5 native contract. Task 5.6 consequence scheduling, inventory
## transactions, stable event identity, and cross-domain ordering are not
## implemented here.

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("HEALTH_ABILITY_CONTENT_CONTRACT: " + message)


func run() -> void:
	_test_declarations_and_catalogs()
	_test_initialization_guards()
	_test_combined_fail_before_mutation()
	_test_bounded_application_and_replay()
	_test_bounded_rejection_admission_atomicity()
	_test_bounded_reentrant_rejection_atomicity()
	await _test_foreign_notification_queued_reservations()
	_test_native_queue_capacity_admission_atomicity()
	await _test_bounded_queue_eighty_attempt_stress()
	var first := _new_health_component(51_010)
	var second := _new_health_component(51_010)
	var first_snapshot := _drive_persistent_transitions(first, true)
	var second_snapshot := _drive_persistent_transitions(second, false)
	check(first_snapshot == second_snapshot,
		"identical native transition inputs produce identical snapshots")
	_cleanup_component(first)
	_cleanup_component(second)
	await process_frame
	await process_frame
	print("HEALTH_ABILITY_CONTENT_RESULT checks=", checks,
		" failures=", failures,
		" zones=", ZerkovHealthAbilityContent.BODY_ZONE_IDS.size(),
		" attributes=", ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT,
		" tags=", ZerkovHealthAbilityContent.TAG_DEFINITION_COUNT,
		" effects=", ZerkovHealthAbilityContent.EFFECT_DEFINITION_COUNT,
		" abilities=", ZerkovHealthAbilityContent.ABILITY_DEFINITION_COUNT,
		" real_gameplay_abilities=true")
	quit(0 if failures == 0 else 1)


func _test_declarations_and_catalogs() -> void:
	check(ClassDB.class_exists(&"GameplayDefinitionCatalog"),
		"native definition catalog class is registered")
	check(ClassDB.class_exists(&"GameplayAbilityComponent"),
		"native ability component class is registered")
	check(not ClassDB.class_has_method(&"GameplayAbilityComponent", &"remove_effect"),
		"content does not depend on a nonexistent public effect-removal method")
	check(ZerkovHealthAbilityContent.TICK_RATE == 60,
		"health content declares the canonical 60 Hz authority rate")

	var zones := ZerkovHealthAbilityContent.body_zone_declarations()
	check(zones.size() == 7, "all seven authoritative body zones are authored")
	var identifiers: Dictionary = {}
	var max_total := 0
	var lethal_zones := PackedStringArray()
	for zone in zones:
		var zone_identifier := String(zone["zone_identifier"])
		check(not identifiers.has(zone_identifier),
			"body-zone identity is unique: " + zone_identifier)
		identifiers[zone_identifier] = true
		max_total += int(zone["max_health_micros"])
		if bool(zone["lethal_at_zero"]):
			lethal_zones.append(zone_identifier)
		check(StringName(zone["overflow_policy"])
			== ZerkovHealthAbilityContent.BOUND_CAP_TO_FLOOR,
			"zone damage declares a real bounded-seam policy: " + zone_identifier)
		check(int(zone["heavy_bleed_period_ticks"]) == 60
			and int(zone["heavy_bleed_damage_micros"])
				== ZerkovHealthAbilityContent.FIXED_SCALE,
			"heavy-bleed cadence and damage are fixed-unit declarations: "
				+ zone_identifier)
		check(int(zone["persistent_max_stacks"]) == 1
			and String(zone["persistent_overflow_policy"]) == "reject"
			and not bool(zone["persistent_period_refresh"]),
			"zone state stack and timing behavior is explicit: " + zone_identifier)
		for key in [
			"health_attribute_identifier", "damage_effect_identifier",
			"damage_ability_identifier", "heavy_bleed_tag_identifier",
			"heavy_bleed_effect_identifier", "heavy_bleed_ability_identifier",
			"fracture_tag_identifier", "fracture_effect_identifier",
			"fracture_ability_identifier", "bandaged_tag_identifier",
			"bandage_effect_identifier", "bandage_ability_identifier",
			"bandage_cancels_effect_identifier",
			"bandage_cancels_ability_identifier", "splinted_tag_identifier",
			"splint_effect_identifier", "splint_ability_identifier",
			"splint_cancels_effect_identifier",
			"splint_cancels_ability_identifier",
		]:
			check(String(zone[key]).begins_with("zerkov."),
				"zone declaration has stable identity: %s/%s" % [zone_identifier, key])
		check(String(zone["bandage_cancels_effect_identifier"])
			== String(zone["heavy_bleed_effect_identifier"])
			and String(zone["splint_cancels_effect_identifier"])
				== String(zone["fracture_effect_identifier"]),
			"treatment declares the exact execution-owned injury transition: "
				+ zone_identifier)
	check(lethal_zones == PackedStringArray(["head", "thorax"]),
		"head and thorax are the only zero-health lethal zones")
	check(max_total == 440 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"body-zone maximum health totals 440 fixed units")
	check(ZerkovHealthAbilityContent.ITEM_BANDAGE == ZerkovInventoryCatalog.ITEM_BANDAGE
		and ZerkovHealthAbilityContent.ITEM_SPLINT == ZerkovInventoryCatalog.ITEM_SPLINT,
		"treatments use canonical inventory item identities")

	var attributes := ZerkovHealthAbilityContent.attribute_declarations()
	check(attributes.size() == ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT,
		"health, life, resources, pain, and movement attributes are declared")
	var pain := ZerkovHealthAbilityContent.pain_policy_declaration()
	var movement := ZerkovHealthAbilityContent.movement_policy_declaration()
	var healing := ZerkovHealthAbilityContent.healing_eligibility_declaration()
	check(StringName(pain["attribute_identifier"])
		== ZerkovHealthAbilityContent.ATTRIBUTE_PAIN
		and int(pain["heavy_bleed_contribution_micros"]) > 0
		and int(pain["fracture_contribution_micros"]) > 0,
		"pain sources and bounded aggregation are data-defined")
	check(StringName(movement["attribute_identifier"])
		== ZerkovHealthAbilityContent.ATTRIBUTE_MOVEMENT_SPEED_SCALE
		and int(movement["leg_fracture_delta_micros"]) < 0,
		"fracture movement consequence is a fixed-unit policy declaration")
	check(bool(healing["bandage_requires_exact_zone_heavy_bleed"])
		and bool(healing["splint_requires_exact_zone_fracture"])
		and bool(healing["consume_item_only_after_transition_commit"])
		and String(healing["application_owner"]) == "task_5_6_raid_authority",
		"healing eligibility and the task 5.6 transaction boundary are explicit")
	var zone_digests := ZerkovHealthAbilityContent.body_zone_declaration_digests()
	check(zone_digests.size() == 7
		and zone_digests.all(func(value: String) -> bool: return value.length() == 64)
		and not ZCanonicalValue.sha256(
			ZerkovHealthAbilityContent.instant_application_declarations()).is_empty(),
		"all behavior-bearing declaration sections fit canonical hash bounds")
	check(not ZerkovHealthAbilityContent.declaration_bytes().is_empty()
		and ZerkovHealthAbilityContent.declaration_digest().length() == 64,
		"complete policy fingerprint is canonical and non-empty")
	check(ZerkovHealthAbilityContent.declaration_digest()
		== ZerkovHealthAbilityContent.declaration_digest(),
		"complete policy fingerprint is repeatable")

	var catalog := ZerkovHealthAbilityContent.build_definition_catalog()
	check(catalog.get_attribute_definitions().size()
		== ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT,
		"catalog has exact attribute count")
	check(catalog.get_tag_definitions().size()
		== ZerkovHealthAbilityContent.TAG_DEFINITION_COUNT,
		"catalog has exact tag count")
	check(catalog.get_effect_definitions().size()
		== ZerkovHealthAbilityContent.EFFECT_DEFINITION_COUNT,
		"catalog has exact effect count")
	check(catalog.get_ability_definitions().size()
		== ZerkovHealthAbilityContent.ABILITY_DEFINITION_COUNT,
		"every applied effect family has an authored public-API ability")
	for zone in zones:
		_test_zone_resources(catalog, zone)
	var validation := ZerkovHealthAbilityContent.validate_definition_catalog()
	check(bool(validation["ok"]) and bool(validation["manifest_ok"])
		and (validation["findings"] as Array).is_empty()
		and (validation["prediction_findings"] as Array).is_empty(),
		"native catalog and prediction passes accept the complete definitions")
	check(int(validation["manifest_fingerprint"]) != 0
		and int(validation["manifest_tick_rate"]) == 60,
		"native manifest is non-zero and pinned to 60 Hz")
	var repeat := ZerkovHealthAbilityContent.validate_definition_catalog()
	check(int(validation["manifest_fingerprint"])
		== int(repeat["manifest_fingerprint"]),
		"native manifest fingerprint is deterministic")


func _test_zone_resources(
	catalog: GameplayDefinitionCatalog,
	zone: Dictionary
) -> void:
	var zone_identifier := String(zone["zone_identifier"])
	var damage := _find_effect(catalog, StringName(zone["damage_effect_identifier"]))
	var bleed := _find_effect(catalog, StringName(zone["heavy_bleed_effect_identifier"]))
	var fracture := _find_effect(catalog, StringName(zone["fracture_effect_identifier"]))
	var bandage := _find_effect(catalog, StringName(zone["bandage_effect_identifier"]))
	var splint := _find_effect(catalog, StringName(zone["splint_effect_identifier"]))
	check(damage != null
		and damage.duration_policy == GameplayEffectDefinition.DURATION_INSTANT
		and damage.set_by_caller_fields.size() == 1,
		"zone damage is an authored parameterized instant effect: " + zone_identifier)
	check(bleed != null
		and bleed.duration_policy == GameplayEffectDefinition.DURATION_INFINITE
		and not bleed.has_period and bleed.modifiers.size() == 1,
		"heavy bleed is persistent state/pain while bounded tick damage stays at 5.6: "
			+ zone_identifier)
	check(fracture != null
		and fracture.duration_policy == GameplayEffectDefinition.DURATION_INFINITE
		and fracture.modifiers.size() == (2 if zone_identifier.ends_with("leg") else 1),
		"fracture owns pain and applicable movement modifiers: " + zone_identifier)
	for persistent in [bleed, fracture, bandage, splint]:
		var effect := persistent as GameplayEffectDefinition
		check(effect != null and effect.stacking != null
			and effect.stacking.source_scope == GameplayStackingPolicy.TARGET_SCOPED
			and effect.stacking.max_stacks == 1
			and effect.stacking.overflow_policy
				== GameplayStackingPolicy.OVERFLOW_REJECT,
			"persistent state has target max-one rejection: " + zone_identifier)
	var bleed_ability := _find_ability(
		catalog, StringName(zone["heavy_bleed_ability_identifier"]))
	var bandage_ability := _find_ability(
		catalog, StringName(zone["bandage_ability_identifier"]))
	var fracture_ability := _find_ability(
		catalog, StringName(zone["fracture_ability_identifier"]))
	check(bleed_ability != null and not bleed_ability.ends_on_commit
		and _query_has_exact(bleed_ability.cancel_tags,
			StringName(zone["bandaged_tag_identifier"])),
		"bleed execution cancels from the exact bandage tag: " + zone_identifier)
	check(fracture_ability != null and not fracture_ability.ends_on_commit
		and _query_has_exact(fracture_ability.cancel_tags,
			StringName(zone["splinted_tag_identifier"])),
		"fracture execution cancels from the exact splint tag: " + zone_identifier)
	check(bandage_ability != null and not bandage_ability.ends_on_commit
		and _query_has_exact(bandage_ability.required_tags,
			StringName(zone["heavy_bleed_tag_identifier"]))
		and _query_has_exact(bandage_ability.required_tags,
			ZerkovHealthAbilityContent.TAG_LIFE_ALIVE)
		and _query_has_exact(bandage_ability.blocked_tags,
			ZerkovHealthAbilityContent.TAG_LIFE_DEAD),
		"bandage activation enforces exact injury and alive eligibility: "
			+ zone_identifier)


func _test_initialization_guards() -> void:
	var wrong_rate := _configure_component(
		ZerkovHealthAbilityContent.build_definition_catalog(), 51_020, 30)
	var before := wrong_rate.write_snapshot()
	var result := ZerkovHealthAbilityContent.initialize_component(wrong_rate, 0)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &"")) == &"health_tick_rate_mismatch"
		and wrong_rate.write_snapshot() == before
		and wrong_rate.get_initialized_attributes().is_empty()
		and wrong_rate.granted_specs().is_empty(),
		"30 Hz component fails before any attribute, grant, or effect mutation")
	_cleanup_component(wrong_rate)

	var catalog := ZerkovHealthAbilityContent.build_definition_catalog()
	var mutated := _configure_component(catalog, 51_021, 60)
	var first_attribute := catalog.get_attribute_definitions()[0] \
		as GameplayAttributeDefinition
	first_attribute.max_value = first_attribute.max_value - 1.0
	before = mutated.write_snapshot()
	result = ZerkovHealthAbilityContent.initialize_component(mutated, 0)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &""))
			== &"health_catalog_changed_after_configure"
		and mutated.write_snapshot() == before
		and mutated.get_initialized_attributes().is_empty(),
		"authored-resource mutation after seal fails provenance before mutation")
	_cleanup_component(mutated)

	catalog = ZerkovHealthAbilityContent.build_definition_catalog()
	first_attribute = catalog.get_attribute_definitions()[0] \
		as GameplayAttributeDefinition
	first_attribute.max_value = first_attribute.max_value - 1.0
	mutated = _configure_component(catalog, 51_022, 60)
	before = mutated.write_snapshot()
	result = ZerkovHealthAbilityContent.initialize_component(mutated, 0)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &""))
			== &"health_catalog_semantics_mismatch"
		and mutated.write_snapshot() == before
		and mutated.get_initialized_attributes().is_empty(),
		"a consistently sealed but noncanonical health catalog fails provenance")
	_cleanup_component(mutated)


func _test_combined_fail_before_mutation() -> void:
	var combined := ZerkovGameplayAbilityContent.build_definition_catalog()
	var component := _configure_component(combined, 51_030, 60)
	var equipment_identifier := String(
		ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)
	var injected: Dictionary = component.initialize_attribute(
		equipment_identifier, true, 1.0, 0)
	check(bool((injected.get("status", {}) as Dictionary).get("ok", false)),
		"adversarial combined fixture preinitializes conflicting equipment base")
	var before := component.write_snapshot()
	var result := ZerkovGameplayAbilityContent.initialize_component(component, 0)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &""))
			== &"equipment_attribute_base_conflict"
		and component.write_snapshot() == before
		and component.get_initialized_attributes().size() == 1
		and not component.has_attribute(
			String(ZerkovHealthAbilityContent.ATTRIBUTE_HEALTH_HEAD))
		and component.granted_specs().is_empty(),
		"combined conflict is discovered before health initialization mutates anything")
	_cleanup_component(component)

	component = _configure_component(
		ZerkovGameplayAbilityContent.build_definition_catalog(), 51_031, 60)
	result = ZerkovGameplayAbilityContent.initialize_component(component, 0)
	check(bool(result.get("accepted", false))
		and component.get_initialized_attributes().size()
			== ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT + 1
		and component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_ALIVE)),
		"valid combined content initializes both families and initial life state")
	var stable := component.write_snapshot()
	var replay := ZerkovGameplayAbilityContent.initialize_component(component, 0)
	check(bool(replay.get("accepted", false))
		and component.write_snapshot() == stable,
		"valid combined initialization replay is byte-for-byte mutation-free")
	_cleanup_component(component)


func _test_bounded_application_and_replay() -> void:
	var component := _new_health_component(51_040)
	var head := ZerkovHealthAbilityContent.body_zone_declaration(
		ZerkovHealthAbilityContent.ZONE_HEAD)
	var specs := {
		StringName(head["damage_effect_identifier"]): _grant(component,
			StringName(head["damage_ability_identifier"]), "bounds.damage", 0),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND: _grant(component,
			ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND, "bounds.stamina.spend", 0),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE: _grant(component,
			ZerkovHealthAbilityContent.ABILITY_STAMINA_RESTORE,
			"bounds.stamina.restore", 0),
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN: _grant(component,
			ZerkovHealthAbilityContent.ABILITY_HYDRATION_DRAIN,
			"bounds.hydration.drain", 0),
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_RESTORE: _grant(component,
			ZerkovHealthAbilityContent.ABILITY_HYDRATION_RESTORE,
			"bounds.hydration.restore", 0),
	}
	var damage_effect := StringName(head["damage_effect_identifier"])
	var result := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[damage_effect]), damage_effect,
		50 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(bool(result.get("accepted", false)) and bool(result.get("clamped", false))
		and int(result.get("applied_amount_micros", 0))
			== ZerkovHealthAbilityContent.MAX_HEALTH_HEAD_MICROS
		and _base_micros(component,
			ZerkovHealthAbilityContent.ATTRIBUTE_HEALTH_HEAD) == 0,
		"overkill caps at the zone floor without hidden native base debt")
	var at_floor := component.write_snapshot()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[damage_effect]), damage_effect,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 2)
	check(bool(result.get("accepted", false))
		and not bool(result.get("native_invoked", true))
		and component.write_snapshot() == at_floor,
		"damage at zero is a mutation-free bounded no-op")

	var before := component.write_snapshot()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		150 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &"")) == &"health_resource_overspend"
		and component.write_snapshot() == before
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== ZerkovHealthAbilityContent.MAX_STAMINA_MICROS,
		"stamina overspend fails before mutation and creates no base debt")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		90 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 2)
	check(bool(result.get("accepted", false))
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 10 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"bounded stamina spend applies the exact integer amount")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE,
		150 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(bool(result.get("accepted", false)) and bool(result.get("clamped", false))
		and int(result.get("applied_amount_micros", 0))
			== 90 * ZerkovHealthAbilityContent.FIXED_SCALE
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== ZerkovHealthAbilityContent.MAX_STAMINA_MICROS,
		"overrestore caps at true stamina headroom without base credit")
	before = component.write_snapshot()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 2)
	check(bool(result.get("accepted", false))
		and not bool(result.get("native_invoked", true))
		and component.write_snapshot() == before,
		"restore at full capacity is a mutation-free no-op")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		10 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 3)
	check(bool(result.get("accepted", false))
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 90 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"post-overrestore spend proves no hidden credit was retained")

	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN]),
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN,
		100 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(bool(result.get("accepted", false))
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_HYDRATION) == 0,
		"exact hydration drain can reach but never cross the floor")
	before = component.write_snapshot()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN]),
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 2)
	check(not bool(result.get("accepted", true))
		and component.write_snapshot() == before,
		"hydration overspend at zero is rejected without mutation")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_HYDRATION_RESTORE]),
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_RESTORE,
		150 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(bool(result.get("accepted", false))
		and int(result.get("applied_amount_micros", 0))
			== ZerkovHealthAbilityContent.MAX_HYDRATION_MICROS
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_HYDRATION)
			== ZerkovHealthAbilityContent.MAX_HYDRATION_MICROS,
		"hydration overrestore consumes only real headroom")

	before = component.write_snapshot()
	for invalid_amount in [0, -1, 1.5,
		ZerkovHealthAbilityContent.MAX_APPLICATION_AMOUNT_MICROS + 1]:
		result = ZerkovHealthAbilityContent.apply_bounded_instant(
			component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND]),
			ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
			invalid_amount, 0, 10)
		check(not bool(result.get("accepted", true)),
			"invalid dynamic amount fails closed: " + str(invalid_amount))
	check(component.write_snapshot() == before,
		"all invalid dynamic magnitudes are mutation-free")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 11)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &"")) == &"health_ability_spec_mismatch"
		and component.write_snapshot() == before,
		"bounded seam rejects a valid grant for the wrong authored effect")

	before = component.write_snapshot()
	var replay := ZerkovHealthAbilityContent.initialize_component(component, 0)
	check(bool(replay.get("accepted", false))
		and (replay["replayed"] as PackedStringArray).size()
			== ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT
		and bool(replay["life_replayed"])
		and component.write_snapshot() == before,
		"provenance-based initialization remains idempotent after gameplay bases change")
	var dead_spec := _grant(component, ZerkovHealthAbilityContent.ABILITY_LIFE_DEAD,
		"bounds.dead", 0)
	var death := _activate(component, dead_spec, 0, 1)
	var advanced: Dictionary = component.advance_to(0)
	check(bool((death.get("status", {}) as Dictionary).get("ok", false))
		and bool((advanced.get("status", {}) as Dictionary).get("ok", false))
		and component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_DEAD)),
		"bounds fixture enters dead through the authored native transition")
	before = component.write_snapshot()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, int(specs[ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE]),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_RESTORE,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 3)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &"")) == &"health_actor_not_alive"
		and component.write_snapshot() == before,
		"dead state rejects further bounded resource/healing mutation")
	_cleanup_component(component)


func _test_bounded_rejection_admission_atomicity() -> void:
	var component := _new_health_component(51_041)
	var stamina_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND,
		"atomic.stamina.spend", 0)
	var result := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	check(bool(result.get("accepted", false))
		and component.get_current_tick() == 0
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 99 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"atomicity fixture accepts sequence 1 at authority tick 0")

	var before := component.write_snapshot()
	var tick_before := component.get_current_tick()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 120, 1)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &""))
			== &"health_command_sequence_stale",
		"future-tick stale sequence is rejected by the bounded admission seam")
	check(component.write_snapshot() == before
		and component.get_current_tick() == tick_before,
		"stale rejection changes neither canonical bytes nor wrapper tick admission")

	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 1, 2)
	check(bool(result.get("accepted", false))
		and component.get_current_tick() == 1
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 98 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"stale future input cannot poison the next valid tick and sequence")

	before = component.write_snapshot()
	tick_before = component.get_current_tick()
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		0, 240, 3)
	check(not bool(result.get("accepted", true))
		and StringName(result.get("reason", &"")) == &"health_amount_out_of_bounds"
		and component.write_snapshot() == before
		and component.get_current_tick() == tick_before,
		"future-tick invalid magnitude is rejected without admitting its tick")
	result = ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 2, 3)
	check(bool(result.get("accepted", false))
		and component.get_current_tick() == 2
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 97 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"rejected future magnitude cannot poison the next valid admission")
	_cleanup_component(component)


func _test_bounded_reentrant_rejection_atomicity() -> void:
	var component := _new_health_component(51_042)
	var hydration_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_HYDRATION_DRAIN,
		"reentrant.hydration.drain", 0)
	var stamina_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND,
		"reentrant.stamina.spend", 0)
	var observation := {
		"armed": false,
		"calls": 0,
		"before": PackedByteArray(),
		"after": PackedByteArray(),
		"tick_before": -1,
		"tick_after": -1,
		"result": {},
	}
	var callback := func(_record: Dictionary) -> void:
		if not bool(observation["armed"]):
			return
		observation["armed"] = false
		observation["calls"] = int(observation["calls"]) + 1
		observation["before"] = component.write_snapshot()
		observation["tick_before"] = component.get_current_tick()
		observation["result"] = \
			ZerkovHealthAbilityContent.apply_bounded_instant(
				component, stamina_spec,
				ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
				ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
		observation["after"] = component.write_snapshot()
		observation["tick_after"] = component.get_current_tick()
	component.attribute_changed.connect(callback)
	observation["armed"] = true
	var outer := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, hydration_spec,
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN,
		ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
	component.attribute_changed.disconnect(callback)
	var nested := observation["result"] as Dictionary
	check(bool(outer.get("accepted", false)) and int(observation["calls"]) == 1,
		"outer bounded activation synchronously reaches the adversarial listener")
	check(not bool(nested.get("accepted", true))
		and StringName(nested.get("reason", &"")) == &"health_application_reentrant"
		and not bool(nested.get("native_invoked", true)),
		"reentrant bounded application is rejected before native queue admission")
	check(observation["after"] == observation["before"]
		and int(observation["tick_after"]) == int(observation["tick_before"])
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== ZerkovHealthAbilityContent.MAX_STAMINA_MICROS,
		"reentrant rejection cannot mutate now or drain a queued mutation later")

	var legitimate := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 1, 1)
	check(bool(legitimate.get("accepted", false))
		and component.get_current_tick() == 1
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 99 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"reentrant rejection consumes neither the later valid tick nor sequence")
	_cleanup_component(component)


func _test_foreign_notification_queued_reservations() -> void:
	var component := _new_health_component(51_043)
	var head := ZerkovHealthAbilityContent.body_zone_declaration(
		ZerkovHealthAbilityContent.ZONE_HEAD)
	var bleed_spec := _grant(component,
		StringName(head["heavy_bleed_ability_identifier"]),
		"queued.heavy_bleed", 0)
	var stamina_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND,
		"queued.stamina.spend", 0)
	var hydration_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_HYDRATION_DRAIN,
		"queued.hydration.drain", 0)
	var observations: Array[Dictionary] = []
	var first_state := {"armed": true}
	var second_state := {"armed": true}
	var first_listener := func(_record: Dictionary) -> void:
		if not bool(first_state["armed"]):
			return
		first_state["armed"] = false
		var receipt := ZerkovHealthAbilityContent.apply_bounded_instant(
			component, stamina_spec,
			ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
			60 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 1)
		observations.append({
			"immediate": receipt.duplicate(true),
			"live": receipt,
		})
	var second_listener := func(_record: Dictionary) -> void:
		if not bool(second_state["armed"]):
			return
		second_state["armed"] = false
		var receipt := ZerkovHealthAbilityContent.apply_bounded_instant(
			component, stamina_spec,
			ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
			60 * ZerkovHealthAbilityContent.FIXED_SCALE, 0, 2)
		observations.append({
			"immediate": receipt.duplicate(true),
			"live": receipt,
		})
	component.attribute_changed.connect(first_listener)
	component.attribute_changed.connect(second_listener)
	var outer := _activate(component, bleed_spec, 0, 1)
	component.attribute_changed.disconnect(first_listener)
	component.attribute_changed.disconnect(second_listener)
	check(bool((outer.get("status", {}) as Dictionary).get("ok", false))
		and observations.size() == 2,
		"direct authored heavy bleed invokes both adversarial attribute listeners")
	var first_immediate := observations[0]["immediate"] as Dictionary
	var first_terminal := observations[0]["live"] as Dictionary
	var second_immediate := observations[1]["immediate"] as Dictionary
	check(bool(first_immediate.get("accepted", false))
		and bool(first_immediate.get("queued", false))
		and not bool(first_immediate.get("terminal", true))
		and not bool(first_immediate.get("committed", true))
		and not bool(first_immediate.get("native_invoked", true))
		and int(first_immediate.get("applied_amount_micros", -1)) == 0
		and int(first_immediate.get("reserved_amount_micros", 0))
			== 60 * ZerkovHealthAbilityContent.FIXED_SCALE
		and bool(((first_immediate.get("admission_probe", {}) as Dictionary)
			.get("status", {}) as Dictionary).get("ok", false)),
		"queued admission reports a reservation, never immediate applied state")
	check(not bool(second_immediate.get("accepted", true))
		and StringName(second_immediate.get("reason", &""))
			== &"health_resource_overspend"
		and not bool(second_immediate.get("native_invoked", true)),
		"second listener cannot oversubscribe stamina reserved by the first")
	var queued_follower := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, hydration_spec,
		ZerkovHealthAbilityContent.EFFECT_HYDRATION_DRAIN,
		10 * ZerkovHealthAbilityContent.FIXED_SCALE, 1, 1)
	check(bool(queued_follower.get("accepted", false))
		and bool(queued_follower.get("queued", false))
		and not bool(queued_follower.get("terminal", true))
		and not bool(queued_follower.get("native_invoked", true)),
		"a call arriving behind pending work joins the bounded queue without overtaking")
	await process_frame
	check(bool(first_terminal.get("accepted", false))
		and not bool(first_terminal.get("queued", true))
		and bool(first_terminal.get("terminal", false))
		and bool(first_terminal.get("committed", false))
		and bool(first_terminal.get("native_invoked", false))
		and bool(first_terminal.get("postcondition_ok", false))
		and int(first_terminal.get("applied_amount_micros", 0))
			== 60 * ZerkovHealthAbilityContent.FIXED_SCALE
		and int(first_terminal.get("reserved_amount_micros", -1)) == 0,
		"native lifecycle settles the queued reservation to an honest terminal receipt")
	var terminal_lookup := ZerkovHealthAbilityContent.bounded_application_receipt(
		component, String(first_immediate.get("reservation_id", "")))
	check(bool(terminal_lookup.get("terminal", false))
		and bool(terminal_lookup.get("committed", false))
		and int(terminal_lookup.get("applied_amount_micros", 0))
			== 60 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"bounded receipt lookup exposes queued work's terminal committed result")
	check(_base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 40 * ZerkovHealthAbilityContent.FIXED_SCALE
		and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 40 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"queued bounded work leaves stamina base/current inside authored bounds")
	check(bool(queued_follower.get("terminal", false))
		and bool(queued_follower.get("committed", false))
		and _base_micros(component,
			ZerkovHealthAbilityContent.ATTRIBUTE_HYDRATION)
			== 90 * ZerkovHealthAbilityContent.FIXED_SCALE
		and component.get_current_tick() == 1,
		"queued followers execute in admitted tick order and settle honestly")

	var after_queue := component.write_snapshot()
	var replay := ZerkovHealthAbilityContent.initialize_component(component, 1)
	check(bool(replay.get("accepted", false))
		and component.write_snapshot() == after_queue,
		"post-queue initialization replay remains byte-for-byte idempotent")
	var followup := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		40 * ZerkovHealthAbilityContent.FIXED_SCALE, 1, 2)
	check(bool(followup.get("accepted", false))
		and not bool(followup.get("queued", false))
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA) == 0
		and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA) == 0,
		"rejected oversubscription consumes no sequence and valid follow-up reaches floor")
	_cleanup_component(component)


func _test_native_queue_capacity_admission_atomicity() -> void:
	var component := _new_health_component(51_044)
	var head := ZerkovHealthAbilityContent.body_zone_declaration(
		ZerkovHealthAbilityContent.ZONE_HEAD)
	var bleed_spec := _grant(component,
		StringName(head["heavy_bleed_ability_identifier"]),
		"capacity.heavy_bleed", 0)
	var stamina_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND,
		"capacity.stamina.spend", 0)
	var observation := {
		"armed": true,
		"queued_duplicates": 0,
		"before": PackedByteArray(),
		"after": PackedByteArray(),
		"tick_before": -1,
		"tick_after": -1,
		"receipt": {},
	}
	var listener := func(_record: Dictionary) -> void:
		if not bool(observation["armed"]):
			return
		observation["armed"] = false
		for index in range(64):
			var duplicate: Dictionary = component.request_activation({
				"spec": bleed_spec,
				"command_sequence": index + 2,
			}, 0)
			var duplicate_status := duplicate.get("status", {}) as Dictionary
			if bool(duplicate.get("queued", false)) \
					and bool(duplicate_status.get("ok", false)):
				observation["queued_duplicates"] = \
					int(observation["queued_duplicates"]) + 1
		observation["before"] = component.write_snapshot()
		observation["tick_before"] = component.get_current_tick()
		observation["receipt"] = \
			ZerkovHealthAbilityContent.apply_bounded_instant(
				component, stamina_spec,
				ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
				ZerkovHealthAbilityContent.FIXED_SCALE, 120, 1)
		observation["after"] = component.write_snapshot()
		observation["tick_after"] = component.get_current_tick()
	component.attribute_changed.connect(listener)
	var outer := _activate(component, bleed_spec, 0, 1)
	component.attribute_changed.disconnect(listener)
	var receipt := observation["receipt"] as Dictionary
	var capacity_probe := receipt.get("admission_probe", {}) as Dictionary
	var capacity_status := capacity_probe.get("status", {}) as Dictionary
	check(bool((outer.get("status", {}) as Dictionary).get("ok", false))
		and int(observation["queued_duplicates"]) == 64,
		"direct heavy-bleed notification saturates all 64 native mutation slots")
	check(not bool(receipt.get("accepted", true))
		and StringName(receipt.get("reason", &""))
			== &"health_native_queue_capacity_exceeded"
		and not bool(receipt.get("native_invoked", true))
		and int(receipt.get("reserved_amount_micros", 0)) == 0
		and not receipt.has("reservation_id")
		and int(capacity_status.get("code", -1)) == 6
		and int(capacity_status.get("diagnostic", -1)) == 13,
		"saturated native admission rejects synchronously without a reservation")
	check(observation["after"] == observation["before"]
		and int(observation["tick_after"]) == int(observation["tick_before"])
		and component.get_current_tick() == 0,
		"saturated rejection changes neither canonical bytes nor native tick watermark")

	var retry := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		ZerkovHealthAbilityContent.FIXED_SCALE, 1, 1)
	check(bool(retry.get("accepted", false))
		and bool(retry.get("terminal", false))
		and bool(retry.get("committed", false))
		and component.get_current_tick() == 1,
		"capacity rejection consumes neither tick nor sequence and retry commits")
	check(_base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 99 * ZerkovHealthAbilityContent.FIXED_SCALE
		and _current_micros(component,
			ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 99 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"post-saturation retry leaves stamina base/current within authored bounds")
	_cleanup_component(component)


func _test_bounded_queue_eighty_attempt_stress() -> void:
	var component := _new_health_component(51_045)
	var hydration_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_HYDRATION_DRAIN,
		"stress.hydration.drain", 0)
	var stamina_spec := _grant(component,
		ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND,
		"stress.stamina.spend", 0)
	var accepted: Array[Dictionary] = []
	var rejected: Array[Dictionary] = []
	var listener_state := {"armed": true}
	var listener := func(_record: Dictionary) -> void:
		if not bool(listener_state["armed"]):
			return
		listener_state["armed"] = false
		for sequence in range(1, 81):
			var receipt := ZerkovHealthAbilityContent.apply_bounded_instant(
				component, stamina_spec,
				ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
				ZerkovHealthAbilityContent.FIXED_SCALE, 0, sequence)
			if bool(receipt.get("accepted", false)):
				accepted.append(receipt)
			else:
				rejected.append(receipt)
	component.attribute_changed.connect(listener)
	var outer: Dictionary = component.request_activation({
		"spec": hydration_spec,
		"command_sequence": 1,
		"set_by_caller": [{
			"field": String(ZerkovHealthAbilityContent.SET_BY_CALLER_AMOUNT),
			"value": 1.0,
		}],
	}, 0)
	component.attribute_changed.disconnect(listener)
	var rejected_clean := true
	for receipt in rejected:
		rejected_clean = rejected_clean \
			and StringName(receipt.get("reason", &"")) \
				== &"health_queued_reservation_capacity_exceeded" \
			and not bool(receipt.get("native_invoked", true)) \
			and not receipt.has("reservation_id")
	check(bool((outer.get("status", {}) as Dictionary).get("ok", false))
		and accepted.size() == 64 and rejected.size() == 16
		and rejected_clean and component.get_current_tick() == 0,
		"80 notification attempts admit 64 bounded reservations and reject 16 cleanly")
	await process_frame
	var terminal_clean := true
	for receipt in accepted:
		terminal_clean = terminal_clean \
			and bool(receipt.get("accepted", false)) \
			and bool(receipt.get("terminal", false)) \
			and bool(receipt.get("committed", false)) \
			and int(receipt.get("applied_amount_micros", 0)) \
				== ZerkovHealthAbilityContent.FIXED_SCALE \
			and int(receipt.get("reserved_amount_micros", -1)) == 0
	check(terminal_clean
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 36 * ZerkovHealthAbilityContent.FIXED_SCALE
		and _current_micros(component,
			ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)
			== 36 * ZerkovHealthAbilityContent.FIXED_SCALE,
		"all 64 admitted stress receipts settle natively without exceeding bounds")
	var retry := ZerkovHealthAbilityContent.apply_bounded_instant(
		component, stamina_spec,
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND,
		36 * ZerkovHealthAbilityContent.FIXED_SCALE, 1, 65)
	check(bool(retry.get("accepted", false))
		and bool(retry.get("committed", false))
		and _base_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA) == 0
		and _current_micros(component,
			ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA) == 0,
		"rejected stress attempt consumes no sequence and retry reaches the floor")
	_cleanup_component(component)


func _drive_persistent_transitions(
	component: GameplayAbilityComponent,
	verify_state: bool
) -> PackedByteArray:
	var head := ZerkovHealthAbilityContent.body_zone_declaration(
		ZerkovHealthAbilityContent.ZONE_HEAD)
	var left_leg := ZerkovHealthAbilityContent.body_zone_declaration(
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG)
	var specs := {
		"bleed": _grant(component, StringName(head["heavy_bleed_ability_identifier"]),
			"transition.bleed", 0),
		"bandage": _grant(component, StringName(head["bandage_ability_identifier"]),
			"transition.bandage", 0),
		"fracture": _grant(component, StringName(left_leg["fracture_ability_identifier"]),
			"transition.fracture", 0),
		"splint": _grant(component, StringName(left_leg["splint_ability_identifier"]),
			"transition.splint", 0),
		"dead": _grant(component, ZerkovHealthAbilityContent.ABILITY_LIFE_DEAD,
			"transition.dead", 0),
	}
	var before := component.write_snapshot()
	var rejected := _activate(component, int(specs["bandage"]), 0, 1, false)
	check(not bool((rejected.get("status", {}) as Dictionary).get("ok", true))
		and component.write_snapshot() == before,
		"bandage without matching zone bleed fails healing eligibility atomically")
	rejected = _activate(component, int(specs["splint"]), 0, 1, false)
	check(not bool((rejected.get("status", {}) as Dictionary).get("ok", true))
		and component.write_snapshot() == before,
		"splint without matching zone fracture fails healing eligibility atomically")

	var result := _activate(component, int(specs["bleed"]), 0, 1)
	var bleed_execution := int(result.get("execution", 0))
	if verify_state:
		check(bleed_execution > 0 and component.has_execution(bleed_execution)
			and component.has_tag_exact(String(head["heavy_bleed_tag_identifier"]))
			and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_PAIN)
				== ZerkovHealthAbilityContent.HEAVY_BLEED_PAIN_MICROS,
			"heavy bleed is execution-owned and contributes declared pain")
	var head_before := _base_micros(
		component, StringName(head["health_attribute_identifier"]))
	var advanced: Dictionary = component.advance_to(
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS)
	check(bool((advanced.get("status", {}) as Dictionary).get("ok", false))
		and _base_micros(component, StringName(head["health_attribute_identifier"]))
			== head_before,
		"5.5 bleed state never creates unbounded periodic base debt; 5.6 schedules ticks")
	result = _activate(component, int(specs["bleed"]),
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS, 2, false)
	check(not bool((result.get("status", {}) as Dictionary).get("ok", true))
		and _effect_count(component,
			StringName(head["heavy_bleed_effect_identifier"])) == 1,
		"duplicate bleed activation is rejected at ability concurrency and stack bounds")
	result = _activate(component, int(specs["bandage"]),
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS, 2)
	advanced = component.advance_to(ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS)
	check(bool((advanced.get("status", {}) as Dictionary).get("ok", false)),
		"native cancel-tag queue drains deterministically at the authority tick")
	if verify_state:
		check(not component.has_execution(bleed_execution)
			and _effect_count(component,
				StringName(head["heavy_bleed_effect_identifier"])) == 0
			and not component.has_tag_exact(String(head["heavy_bleed_tag_identifier"]))
			and component.has_tag_exact(String(head["bandaged_tag_identifier"]))
			and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_PAIN) == 0,
			"bandage tag cancels the owning bleed execution and removes effect/tag/pain")

	result = _activate(component, int(specs["fracture"]),
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS, 1)
	var fracture_execution := int(result.get("execution", 0))
	if verify_state:
		check(component.has_execution(fracture_execution)
			and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_PAIN)
				== ZerkovHealthAbilityContent.FRACTURE_PAIN_MICROS
			and _current_micros(component,
				ZerkovHealthAbilityContent.ATTRIBUTE_MOVEMENT_SPEED_SCALE)
				== ZerkovHealthAbilityContent.DEFAULT_MOVEMENT_SPEED_SCALE_MICROS
					+ ZerkovHealthAbilityContent.LEG_FRACTURE_MOVEMENT_DELTA_MICROS,
			"leg fracture owns declared pain and movement effects")
	result = _activate(component, int(specs["splint"]),
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS, 2)
	advanced = component.advance_to(ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS)
	if verify_state:
		check(not component.has_execution(fracture_execution)
			and not component.has_tag_exact(String(left_leg["fracture_tag_identifier"]))
			and component.has_tag_exact(String(left_leg["splinted_tag_identifier"]))
			and _current_micros(component, ZerkovHealthAbilityContent.ATTRIBUTE_PAIN) == 0
			and _current_micros(component,
				ZerkovHealthAbilityContent.ATTRIBUTE_MOVEMENT_SPEED_SCALE)
				== ZerkovHealthAbilityContent.DEFAULT_MOVEMENT_SPEED_SCALE_MICROS,
			"splint cancels fracture execution and unwinds pain/movement modifiers")

	var alive_execution := _execution_for_ability(
		component, ZerkovHealthAbilityContent.ABILITY_LIFE_ALIVE)
	result = _activate(component, int(specs["dead"]),
		ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS, 1)
	advanced = component.advance_to(ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS)
	if verify_state:
		check(not component.has_execution(alive_execution)
			and not component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_ALIVE))
			and _effect_count(component, ZerkovHealthAbilityContent.EFFECT_LIFE_ALIVE) == 0
			and component.has_tag_exact(String(ZerkovHealthAbilityContent.TAG_LIFE_DEAD))
			and _effect_count(component, ZerkovHealthAbilityContent.EFFECT_LIFE_DEAD) == 1
			and _current_micros(component,
				ZerkovHealthAbilityContent.ATTRIBUTE_LIFE_STATE) == 0,
			"dead tag cancels alive execution and leaves one authoritative dead state")
	before = component.write_snapshot()
	var replay := ZerkovHealthAbilityContent.initialize_component(
		component, ZerkovHealthAbilityContent.HEAVY_BLEED_PERIOD_TICKS)
	check(bool(replay.get("accepted", false))
		and StringName(replay.get("life_state", &"")) == &"dead"
		and component.write_snapshot() == before,
		"initialization replay recognizes provenance after alive-to-dead gameplay")
	return component.write_snapshot()


func _new_health_component(entity_id: int) -> GameplayAbilityComponent:
	var component := _configure_component(
		ZerkovHealthAbilityContent.build_definition_catalog(), entity_id, 60)
	var initialized := ZerkovHealthAbilityContent.initialize_component(component, 0)
	check(bool(initialized.get("accepted", false))
		and StringName(initialized.get("life_state", &"")) == &"alive"
		and component.get_initialized_attributes().size()
			== ZerkovHealthAbilityContent.ATTRIBUTE_DEFINITION_COUNT,
		"health initialization authors every attribute and an owned alive state")
	return component


func _configure_component(
	catalog: GameplayDefinitionCatalog,
	entity_id: int,
	tick_rate: int
) -> GameplayAbilityComponent:
	var component := GameplayAbilityComponent.new()
	component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	component.entity_id = entity_id
	component.tick_rate = tick_rate
	component.definition_catalog = catalog
	root.add_child(component)
	var findings: Array = component.configure()
	check(GameplayDefinitionValidator.is_ok(findings) and component.is_configured(),
		"real native component configures from authored catalog")
	return component


func _grant(
	component: GameplayAbilityComponent,
	ability_identifier: StringName,
	input_suffix: String,
	tick: int
) -> int:
	var result: Dictionary = component.grant_ability(
		String(ability_identifier), 1, "zerkov.test.%s" % input_suffix, tick)
	var status := result.get("status", {}) as Dictionary
	check(bool(status.get("ok", false)) and int(result.get("spec", 0)) > 0,
		"authored ability grants through public API: " + String(ability_identifier))
	return int(result.get("spec", 0))


func _activate(
	component: GameplayAbilityComponent,
	spec: int,
	tick: int,
	sequence: int,
	expect_success: bool = true
) -> Dictionary:
	var result: Dictionary = component.request_activation({
		"spec": spec,
		"command_sequence": sequence,
	}, tick)
	if expect_success:
		check(bool((result.get("status", {}) as Dictionary).get("ok", false)),
			"authored ability activates through public API: " + str(result))
	return result


func _find_effect(
	catalog: GameplayDefinitionCatalog,
	identifier: StringName
) -> GameplayEffectDefinition:
	for value in catalog.get_effect_definitions():
		var effect := value as GameplayEffectDefinition
		if effect != null and effect.identifier == identifier:
			return effect
	return null


func _find_ability(
	catalog: GameplayDefinitionCatalog,
	identifier: StringName
) -> GameplayAbilityDefinition:
	for value in catalog.get_ability_definitions():
		var ability := value as GameplayAbilityDefinition
		if ability != null and ability.identifier == identifier:
			return ability
	return null


func _query_has_exact(
	query: GameplayTagQueryResource,
	identifier: StringName
) -> bool:
	if query == null:
		return false
	for collection in [query.all_of, query.any_of, query.none_of]:
		for value in collection:
			var operand := value as GameplayTagOperand
			if operand != null and operand.tag == identifier \
					and operand.match_mode == GameplayTagOperand.MATCH_EXACT:
				return true
	return false


func _effect_count(
	component: GameplayAbilityComponent,
	identifier: StringName
) -> int:
	var count := 0
	for handle in component.active_effect_handles():
		if StringName(component.get_active_effect(handle).get(
				"definition_identifier", &"")) == identifier:
			count += 1
	return count


func _execution_for_ability(
	component: GameplayAbilityComponent,
	identifier: StringName
) -> int:
	for execution_id in component.active_executions():
		if StringName(component.get_execution(execution_id).get(
				"ability_identifier", &"")) == identifier:
			return execution_id
	return 0


func _base_micros(
	component: GameplayAbilityComponent,
	identifier: StringName
) -> int:
	return _fixed_micros(component.get_attribute_base(String(identifier)))


func _current_micros(
	component: GameplayAbilityComponent,
	identifier: StringName
) -> int:
	return _fixed_micros(component.get_attribute_current(String(identifier)))


func _fixed_micros(value: float) -> int:
	var scaled := value * float(ZerkovHealthAbilityContent.FIXED_SCALE)
	if scaled < 0.0:
		return -int(floor(-scaled + 0.5))
	return int(floor(scaled + 0.5))


func _cleanup_component(component: GameplayAbilityComponent) -> void:
	if component == null or not is_instance_valid(component):
		return
	if not component.is_torn_down():
		component.queue_teardown(component.get_current_tick())
	component.queue_free()
