class_name ZerkovGameplayAbilityContent
extends RefCounted
## Product-owned composition root for the first-playable ability catalog.
##
## GameplayDefinitionCatalog never merges sources at runtime. This explicit
## builder is therefore the single place where independent Zerkov content
## families are combined before a component configures and seals native state.

const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000


static func build_definition_catalog() -> GameplayDefinitionCatalog:
	var equipment := ZerkovEquipmentAbilityContent.build_definition_catalog()
	var health := ZerkovHealthAbilityContent.build_definition_catalog()
	var catalog := GameplayDefinitionCatalog.new()
	catalog.tag_definitions = _merge_tags(equipment, health)
	catalog.attribute_definitions = _merge_attributes(equipment, health)
	catalog.effect_definitions = _merge_effects(equipment, health)
	catalog.ability_definitions = _merge_abilities(equipment, health)
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


static func initialize_component(
	component: GameplayAbilityComponent,
	tick: int = 0
) -> Dictionary:
	var preflight := preflight_component(component, tick)
	if not bool(preflight.get("accepted", false)):
		return preflight
	var before := component.write_snapshot()
	if before.is_empty():
		return {"accepted": false, "reason": &"combined_snapshot_unavailable"}
	var health := ZerkovHealthAbilityContent.initialize_component(component, tick)
	if not bool(health.get("accepted", false)):
		return {
			"accepted": false,
			"reason": health.get("reason", &"health_initialization_failed"),
			"health": health,
			"rollback_ok": component.restore_snapshot(before),
		}
	var equipment := ZerkovEquipmentAbilityContent.initialize_component(component, tick)
	if not bool(equipment.get("accepted", false)):
		return {
			"accepted": false,
			"reason": equipment.get("reason", &"equipment_initialization_failed"),
			"health": health,
			"equipment": equipment,
			"rollback_ok": component.restore_snapshot(before),
		}
	return {
		"accepted": true,
		"health": health,
		"equipment": equipment,
	}


## Checks the exact composition provenance and every predictable family-level
## failure before either initializer can mutate the component.
static func preflight_component(
	component: GameplayAbilityComponent,
	tick: int = 0
) -> Dictionary:
	if component == null or not is_instance_valid(component) \
			or not component.is_configured() or component.is_torn_down() \
			or not component.is_owner_valid():
		return {"accepted": false, "reason": &"combined_component_invalid"}
	if tick < 0 or tick < component.get_current_tick() or tick > MAX_AUTHORITY_TICK:
		return {"accepted": false, "reason": &"combined_tick_invalid"}
	var catalog := _validate_exact_catalog(component)
	if not bool(catalog.get("ok", false)):
		return {
			"accepted": false,
			"reason": catalog.get("reason", &"combined_catalog_invalid"),
			"catalog": catalog,
		}
	var health := ZerkovHealthAbilityContent.preflight_component(component, tick)
	if not bool(health.get("accepted", false)):
		return {
			"accepted": false,
			"reason": health.get("reason", &"health_preflight_failed"),
			"health": health,
		}
	var equipment_identifier := String(
		ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)
	if component.has_attribute(equipment_identifier) \
			and _fixed_micros(component.get_attribute_base(equipment_identifier)) != 0:
		return {
			"accepted": false,
			"reason": &"equipment_attribute_base_conflict",
			"health": health,
		}
	return {
		"accepted": true,
		"catalog_fingerprint": catalog["content_manifest_fingerprint"],
		"health": health,
		"equipment_replayed": component.has_attribute(equipment_identifier),
	}


static func _validate_exact_catalog(component: GameplayAbilityComponent) -> Dictionary:
	var actual := component.get_definition_catalog()
	if actual == null:
		return {"ok": false, "reason": &"combined_catalog_missing"}
	var actual_validator := GameplayDefinitionValidator.new()
	var actual_findings: Array = actual_validator.validate_catalog(actual)
	if not GameplayDefinitionValidator.is_ok(actual_findings) \
			or not actual_validator.get_last_manifest_ok() \
			or actual_validator.get_last_manifest_fingerprint() \
				!= component.get_content_manifest_fingerprint():
		return {"ok": false, "reason": &"combined_catalog_changed_after_configure"}
	var expected := build_definition_catalog()
	var expected_validator := GameplayDefinitionValidator.new()
	var expected_findings: Array = expected_validator.validate_catalog(expected)
	if not GameplayDefinitionValidator.is_ok(expected_findings) \
			or not expected_validator.get_last_manifest_ok():
		return {"ok": false, "reason": &"combined_expected_catalog_invalid"}
	if actual_validator.get_last_manifest_fingerprint() \
			!= expected_validator.get_last_manifest_fingerprint() \
			or actual_validator.get_last_manifest_entry_count() \
				!= expected_validator.get_last_manifest_entry_count() \
			or actual_validator.get_last_manifest_tick_rate() \
				!= expected_validator.get_last_manifest_tick_rate():
		return {"ok": false, "reason": &"combined_catalog_semantics_mismatch"}
	return {
		"ok": true,
		"content_manifest_fingerprint": actual_validator.get_last_manifest_fingerprint(),
	}


static func _fixed_micros(value: float) -> int:
	var scaled := value * float(ZerkovHealthAbilityContent.FIXED_SCALE)
	if scaled < 0.0:
		return -int(floor(-scaled + 0.5))
	return int(floor(scaled + 0.5))


static func _merge_tags(
	first: GameplayDefinitionCatalog,
	second: GameplayDefinitionCatalog
) -> Array[GameplayTagDefinition]:
	var result: Array[GameplayTagDefinition] = []
	for value in first.get_tag_definitions():
		result.append(value as GameplayTagDefinition)
	for value in second.get_tag_definitions():
		result.append(value as GameplayTagDefinition)
	return result


static func _merge_attributes(
	first: GameplayDefinitionCatalog,
	second: GameplayDefinitionCatalog
) -> Array[GameplayAttributeDefinition]:
	var result: Array[GameplayAttributeDefinition] = []
	for value in first.get_attribute_definitions():
		result.append(value as GameplayAttributeDefinition)
	for value in second.get_attribute_definitions():
		result.append(value as GameplayAttributeDefinition)
	return result


static func _merge_effects(
	first: GameplayDefinitionCatalog,
	second: GameplayDefinitionCatalog
) -> Array[GameplayEffectDefinition]:
	var result: Array[GameplayEffectDefinition] = []
	for value in first.get_effect_definitions():
		result.append(value as GameplayEffectDefinition)
	for value in second.get_effect_definitions():
		result.append(value as GameplayEffectDefinition)
	return result


static func _merge_abilities(
	first: GameplayDefinitionCatalog,
	second: GameplayDefinitionCatalog
) -> Array[GameplayAbilityDefinition]:
	var result: Array[GameplayAbilityDefinition] = []
	for value in first.get_ability_definitions():
		result.append(value as GameplayAbilityDefinition)
	for value in second.get_ability_definitions():
		result.append(value as GameplayAbilityDefinition)
	return result
