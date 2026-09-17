extends RefCounted
## Frozen pre-optimization algorithm from be18fc7. Test oracle only.

static func validate(component: GameplayAbilityComponent) -> Dictionary:
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
	var expected_catalog := ZerkovHealthAbilityContent.build_definition_catalog()
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

