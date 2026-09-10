class_name GameplayAbilityEquipmentPort
extends EquipmentAbilityParticipantPort
## Production equipment participant over GameplayAbilityComponent public APIs.
##
## The port never removes an effect handle directly: that method is not public
## in the installed add-on. Instead it grants a PASSIVE_ON_GRANT ability whose
## active execution owns the declared infinite effect, records the native spec,
## execution, and effect handles, then revokes that exact spec. The add-on's
## REVOKE_CANCEL_ACTIVE policy performs the authoritative cleanup.

# Pinned Gameplay Abilities 0.2.0 public budgets (docs/budgets.md and
# docs/api.md). They are preflight headroom checks, not replacement limits.
const MAX_ABILITY_GRANTS: int = 64
const MAX_ACTIVE_EXECUTIONS: int = 32
const MAX_ACTIVE_EFFECTS: int = 128
const MAX_INPUT_ID_BYTES: int = 128
const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000

var _component: GameplayAbilityComponent
var _component_instance_id: int = 0
var _identity_token: String = ""
var _mutation_active: bool = false


func configure(component: GameplayAbilityComponent) -> bool:
	if _component != null or component == null or not is_instance_valid(component) \
			or not component.is_configured() or component.is_torn_down() \
			or not component.is_owner_valid():
		return false
	if component.role != GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY \
			and component.role != GameplayAbilityComponent.ROLE_SERVER_AUTHORITY:
		return false
	if component.entity_id <= 0 or component.get_content_manifest_fingerprint() == 0:
		return false
	_component = component
	_component_instance_id = component.get_instance_id()
	_identity_token = "gameplay_ability:%d:%d:%d" % [
		_component_instance_id,
		component.entity_id,
		component.get_content_manifest_fingerprint(),
	]
	return true


func is_ready() -> bool:
	return _component_is_exact() and _component.is_configured() \
		and _component.is_owner_valid() and not _component.is_torn_down() \
		and _component.get_current_tick() >= 0 \
		and _component.get_current_tick() <= MAX_AUTHORITY_TICK \
		and (_component.role == GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY \
			or _component.role == GameplayAbilityComponent.ROLE_SERVER_AUTHORITY)


func identity_token() -> String:
	return _identity_token if is_ready() else ""


func entity_id() -> int:
	return _component.entity_id if _component_is_exact() else 0


func current_tick() -> int:
	return _component.get_current_tick() if _component_is_exact() else 0


func owner_node() -> Node:
	return _component if _component_is_exact() else null


func validate_content(equipment_declarations: Array[Dictionary]) -> Dictionary:
	if _mutation_active:
		return _rejection(&"equipment_ability_port_reentrant")
	if not is_ready():
		return _rejection(&"ability_component_not_ready")
	if equipment_declarations.is_empty():
		return _rejection(&"equipment_ability_content_empty")
	var seen_items: Dictionary = {}
	var seen_abilities: Dictionary = {}
	var catalog_validation := _validate_canonical_catalog_subset(
		equipment_declarations)
	if not bool(catalog_validation.get("ok", false)):
		return _rejection(StringName(catalog_validation.get(
			"reason", &"equipment_ability_catalog_incompatible")))
	for declaration in equipment_declarations:
		var item_identifier := StringName(
			declaration.get("item_definition_identifier", &""))
		var slots := _identifier_array(declaration.get("allowed_slots", []))
		var grants := declaration.get("ability_grants", []) as Array
		if item_identifier.is_empty() or seen_items.has(item_identifier) \
				or slots.is_empty() or grants.is_empty():
			return _rejection(&"equipment_ability_declaration_invalid")
		seen_items[item_identifier] = true
		for grant_value in grants:
			var grant := grant_value as Dictionary
			var validation := _validate_plan(grant)
			if not bool(validation.get("ok", false)):
				return _rejection(StringName(validation.get(
					"reason", &"equipment_ability_grant_invalid")))
			var ability_identifier := StringName(grant["ability_identifier"])
			if seen_abilities.has(ability_identifier) \
					or _component.ability_id_of(String(ability_identifier)) <= 0:
				return _rejection(&"equipment_ability_definition_missing_or_duplicate")
			seen_abilities[ability_identifier] = true
			for attribute_key in (grant["modifier_delta_micros"] as Dictionary).keys():
				if not _component.has_attribute(String(attribute_key)):
					return _rejection(&"equipment_ability_attribute_uninitialized")
	return {
		"accepted": true,
		"component_token": _identity_token,
		"entity_id": entity_id(),
	}


func preflight(
	addition_plans: Array[Dictionary],
	revocation_records: Array[Dictionary]
) -> Dictionary:
	if _mutation_active:
		return _rejection(&"equipment_ability_port_reentrant")
	if not is_ready():
		return _rejection(&"ability_component_not_ready")
	var seen_inputs: Dictionary = {}
	var added_effect_count := 0
	for plan in addition_plans:
		var validation := _validate_plan(plan)
		if not bool(validation.get("ok", false)):
			return _rejection(StringName(validation.get("reason", &"grant_plan_invalid")))
		var input_id := String(plan.get("input_id", ""))
		if seen_inputs.has(input_id) or _has_live_input_id(input_id):
			return _rejection(&"equipment_source_grant_conflict")
		seen_inputs[input_id] = true
		if _component.ability_id_of(String(plan["ability_identifier"])) <= 0:
			return _rejection(&"equipment_ability_definition_missing")
		for attribute_key in (plan["modifier_delta_micros"] as Dictionary).keys():
			if not _component.has_attribute(String(attribute_key)):
				return _rejection(&"equipment_ability_attribute_uninitialized")
		added_effect_count += _identifier_array(plan["effect_identifiers"]).size()
	for record in revocation_records:
		if not grant_record_is_live(record):
			return _rejection(&"equipment_grant_record_not_live")

	var diagnostics := _component.get_diagnostics()
	if int(diagnostics.get("grant_count", MAX_ABILITY_GRANTS)) \
			+ addition_plans.size() > MAX_ABILITY_GRANTS:
		return _rejection(&"equipment_ability_grant_capacity")
	if int(diagnostics.get("active_execution_count", MAX_ACTIVE_EXECUTIONS)) \
			+ addition_plans.size() > MAX_ACTIVE_EXECUTIONS:
		return _rejection(&"equipment_ability_execution_capacity")
	if int(diagnostics.get("active_effect_count", MAX_ACTIVE_EFFECTS)) \
			+ added_effect_count > MAX_ACTIVE_EFFECTS:
		return _rejection(&"equipment_ability_effect_capacity")
	return {
		"accepted": true,
		"component_token": _identity_token,
		"grant_headroom": MAX_ABILITY_GRANTS \
			- int(diagnostics.get("grant_count", MAX_ABILITY_GRANTS)),
		"execution_headroom": MAX_ACTIVE_EXECUTIONS \
			- int(diagnostics.get("active_execution_count", MAX_ACTIVE_EXECUTIONS)),
		"effect_headroom": MAX_ACTIVE_EFFECTS \
			- int(diagnostics.get("active_effect_count", MAX_ACTIVE_EFFECTS)),
	}


func grant(plan: Dictionary, tick: int) -> Dictionary:
	if _mutation_active:
		return _rejection(&"equipment_ability_port_reentrant")
	_mutation_active = true
	var result := _grant_guarded(plan, tick)
	_mutation_active = false
	return result


func _grant_guarded(plan: Dictionary, tick: int) -> Dictionary:
	if not is_ready():
		return _rejection(&"ability_component_not_ready")
	var validation := _validate_plan(plan)
	if not bool(validation.get("ok", false)):
		return _rejection(StringName(validation.get("reason", &"grant_plan_invalid")))
	if tick < 0 or tick < current_tick() or tick > MAX_AUTHORITY_TICK:
		return _rejection(&"ability_tick_regressed")
	var input_id := String(plan["input_id"])
	if _has_live_input_id(input_id):
		return _rejection(&"equipment_source_grant_conflict")

	var before_executions := _component.active_executions()
	var before_effects := _component.active_effect_handles()
	var before_specs := _component.granted_specs()
	var before_attributes := _attribute_values(plan["modifier_delta_micros"] as Dictionary)
	var before_tags := _tag_presence(_identifier_array(plan["tag_identifiers"]))
	var before_owned_tags := _component.owned_tags()
	var native_result: Dictionary = _component.grant_ability(
		String(plan["ability_identifier"]), int(plan["level"]), input_id, tick)
	var status := native_result.get("status", {}) as Dictionary
	if not bool(status.get("ok", false)):
		var returned_spec := int(native_result.get("spec", 0))
		var recovery_records: Array[Dictionary] = []
		var after_specs := _component.granted_specs()
		for candidate_spec in after_specs:
			if not before_specs.has(candidate_spec):
				recovery_records.append(_capture_recovery_record(
					plan, int(candidate_spec), before_executions, before_effects,
					before_attributes, before_tags, before_owned_tags, tick))
		if recovery_records.is_empty() and (
				returned_spec > 0
				or _component.active_executions() != before_executions
				or _component.active_effect_handles() != before_effects
				or not _attribute_values_equal(before_attributes,
					_attribute_values(plan["modifier_delta_micros"] as Dictionary))
				or before_tags != _tag_presence(
					_identifier_array(plan["tag_identifiers"]))):
			recovery_records.append(_capture_recovery_record(
				plan, returned_spec, before_executions, before_effects,
				before_attributes, before_tags, before_owned_tags, tick))
		return _rejection(&"ability_grant_rejected", {
			"status": status.duplicate(true),
			"mutation_state": MUTATION_NONE if recovery_records.is_empty() \
				else MUTATION_AMBIGUOUS,
			"recovery_records": recovery_records,
		})
	var spec := int(native_result.get("spec", 0))
	var recovery_record := _capture_recovery_record(
		plan, spec, before_executions, before_effects,
		before_attributes, before_tags, before_owned_tags, tick)
	var record := _build_grant_record(
		plan, spec, before_executions, before_effects, before_attributes,
		before_tags, tick)
	if not bool(record.get("accepted", false)):
		var cleanup: Dictionary = {}
		if spec > 0:
			cleanup = _component.revoke_ability(
				spec, tick, GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
		var cleanup_status := cleanup.get("status", {}) as Dictionary
		var cleaned := bool(cleanup_status.get("ok", false)) \
				and _recovery_record_is_clean(recovery_record)
		return _rejection(&"ability_grant_postcondition_failed", {
			"status": status.duplicate(true),
			"postcondition": record,
			"cleanup": cleanup.duplicate(true),
			"mutation_state": MUTATION_NONE if cleaned else MUTATION_AMBIGUOUS,
			"grant_history_consumed": true,
			"recovery_records": [recovery_record.duplicate(true)],
		})
	return record


func revoke(record: Dictionary, tick: int) -> Dictionary:
	if _mutation_active:
		return _rejection(&"equipment_ability_port_reentrant")
	_mutation_active = true
	var result := _revoke_guarded(record, tick)
	_mutation_active = false
	return result


func _revoke_guarded(record: Dictionary, tick: int) -> Dictionary:
	if not _record_matches_component(record):
		return _rejection(&"equipment_grant_record_identity_invalid")
	if not _component_is_exact():
		return _rejection(&"ability_component_replaced", {
			"mutation_state": MUTATION_AMBIGUOUS,
		})
	if grant_record_is_absent(record):
		return {
			"accepted": true,
			"replayed": true,
			"mutation_state": MUTATION_NONE,
			"spec": int(record.get("spec", 0)),
		}
	if not is_ready():
		# Native owner teardown removes executions/effects even though a grant
		# record may no longer be queryable. Only claim success when absence is
		# observable; otherwise the caller must fail-stop.
		return _rejection(&"ability_component_not_ready", {
			"mutation_state": MUTATION_AMBIGUOUS,
		})
	if tick < 0 or tick < current_tick() or tick > MAX_AUTHORITY_TICK:
		return _rejection(&"ability_tick_regressed")
	if not grant_record_is_live(record):
		return _rejection(&"equipment_grant_record_not_live", {
			"mutation_state": MUTATION_AMBIGUOUS,
		})
	var before_executions := _component.active_executions()
	var before_effects := _component.active_effect_handles()
	var before_owned_tags := _component.owned_tags()
	var before_attributes := _attribute_values(record["modifier_delta_micros"] as Dictionary)
	var before_tags := _tag_presence(_identifier_array(record["tag_identifiers"]))
	var native_result: Dictionary = _component.revoke_ability(
		int(record["spec"]), tick, GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
	var status := native_result.get("status", {}) as Dictionary
	var recovery_record := _capture_revoke_recovery_record(
		record, before_executions, before_effects, before_attributes,
		before_tags, before_owned_tags, tick)
	if not bool(status.get("ok", false)):
		var absent := grant_record_is_absent(record)
		var after_rejected_attributes := _attribute_values(
			record["modifier_delta_micros"] as Dictionary)
		var unchanged := grant_record_is_live(record) \
			and _attribute_values_equal(before_attributes, after_rejected_attributes) \
			and before_tags == _tag_presence(
				_identifier_array(record["tag_identifiers"]))
		return _rejection(&"ability_revoke_rejected", {
			"status": status.duplicate(true),
			"mutation_state": MUTATION_COMMITTED \
				if absent and _recovery_record_is_clean(recovery_record) \
				else (MUTATION_NONE if unchanged else MUTATION_AMBIGUOUS),
			"recovery_records": [recovery_record],
		})
	if not grant_record_is_absent(record):
		return _rejection(&"ability_revoke_postcondition_failed", {
			"status": status.duplicate(true),
			"mutation_state": MUTATION_AMBIGUOUS,
			"recovery_records": [recovery_record],
		})
	var after_attributes := _attribute_values(record["modifier_delta_micros"] as Dictionary)
	if not _modifier_delta_unwound(
			before_attributes,
			after_attributes,
			record["modifier_delta_micros"] as Dictionary):
		return _rejection(&"ability_revoke_modifier_postcondition_failed", {
			"status": status.duplicate(true),
			"mutation_state": MUTATION_AMBIGUOUS,
			"modifier_values_before": before_attributes,
			"modifier_values_after": after_attributes,
			"recovery_records": [recovery_record],
		})
	return {
		"accepted": true,
		"replayed": false,
		"mutation_state": MUTATION_COMMITTED,
		"spec": int(record["spec"]),
		"ability_identifier": record["ability_identifier"],
		"input_id": record["input_id"],
		"removed_execution_ids": (record["execution_ids"] as PackedInt64Array).duplicate(),
		"removed_effects": (record["effects"] as Array).duplicate(true),
		"modifier_values_before": before_attributes,
		"modifier_values_after": after_attributes,
		"status": status.duplicate(true),
	}


func grant_record_is_live(record: Dictionary) -> bool:
	if not is_ready() or not _record_matches_component(record):
		return false
	var spec := int(record.get("spec", 0))
	var grant_record := _component.get_grant(spec)
	if grant_record.is_empty() or bool(grant_record.get("revoked", true)) \
			or StringName(grant_record.get("ability_identifier", &"")) \
				!= StringName(record.get("ability_identifier", &"")) \
			or String(grant_record.get("input_id", "")) != String(record.get("input_id", "")):
		return false
	for execution_value in record.get("execution_ids", PackedInt64Array()):
		var execution := _component.get_execution(int(execution_value))
		if execution.is_empty() or int(execution.get("spec", 0)) != spec \
				or int(execution.get("phase", -1)) != GameplayAbilityComponent.PHASE_ACTIVE:
			return false
	for effect_value in record.get("effects", []):
		var effect_record := effect_value as Dictionary
		var effect := _component.get_active_effect(int(effect_record.get("handle", 0)))
		if effect.is_empty() \
				or StringName(effect.get("definition_identifier", &"")) \
					!= StringName(effect_record.get("definition_identifier", &"")):
			return false
	for tag_value in record.get("tag_identifiers", PackedStringArray()):
		if not _component.has_tag_exact(String(tag_value)):
			return false
	return true


func grant_record_is_absent(record: Dictionary) -> bool:
	if not _component_is_exact() or not _record_matches_component(record):
		return false
	var spec := int(record.get("spec", 0))
	var grant_record := _component.get_grant(spec)
	if not grant_record.is_empty() and not bool(grant_record.get("revoked", false)):
		return false
	for execution_value in record.get("execution_ids", PackedInt64Array()):
		if _component.has_execution(int(execution_value)):
			return false
	for effect_value in record.get("effects", []):
		var effect_record := effect_value as Dictionary
		if not _component.get_active_effect(int(effect_record.get("handle", 0))).is_empty():
			return false
	return true


func recovery_record_is_clean(record: Dictionary) -> bool:
	var record_kind := StringName(record.get("record_kind", &""))
	if record_kind == &"mutation_recovery":
		return _recovery_record_is_clean(record)
	if record_kind == &"committed_grant":
		return grant_record_is_absent(record)
	return false


func grant_record_is_terminally_clean(record: Dictionary) -> bool:
	if not _component_is_exact() or not _recovery_record_matches_component(record) \
			or not _component.is_torn_down() or _component.is_owner_valid():
		return false
	# queue_teardown() deliberately retains the grant-history row. Terminal
	# cleanup is instead proven by the exact execution/effect handles and all
	# declared contributions being absent on this exact component instance.
	for execution_value in record.get("execution_ids", PackedInt64Array()):
		if _component.has_execution(int(execution_value)):
			return false
	for effect_value in record.get("effects", []):
		var effect_record := effect_value as Dictionary
		if not _component.get_active_effect(int(effect_record.get("handle", 0))).is_empty():
			return false
	for tag_value in record.get("tag_identifiers", PackedStringArray()):
		if _component.has_tag_exact(String(tag_value)):
			return false
	# Mutation-recovery records can include an unexpected tag that was not in
	# the declared grant. A false baseline proves that contribution must also be
	# gone before terminal cleanup is accepted. A true baseline is intentionally
	# not required after terminal teardown, which removes all component state.
	var tag_baseline := record.get("tag_presence_before", {}) as Dictionary
	for tag_key in tag_baseline.keys():
		if not bool(tag_baseline[tag_key]) \
				and _component.has_tag_exact(String(tag_key)):
			return false
	for attribute_key in (record.get("modifier_delta_micros", {}) as Dictionary).keys():
		var identifier := String(attribute_key)
		if not _component.has_attribute(identifier) \
				or _fixed_micros(_component.get_attribute_current(identifier)) \
					!= _fixed_micros(_component.get_attribute_base(identifier)):
			return false
	return true


func quarantine(records: Array[Dictionary], tick: int) -> Dictionary:
	if _mutation_active:
		return _rejection(&"equipment_ability_port_reentrant")
	if not _component_is_exact() or tick < 0 or tick > MAX_AUTHORITY_TICK \
			or current_tick() < 0 or current_tick() > MAX_AUTHORITY_TICK:
		return _rejection(&"ability_component_quarantine_invalid", {
			"mutation_state": MUTATION_AMBIGUOUS,
		})
	for record in records:
		if not _recovery_record_matches_component(record):
			return _rejection(&"equipment_quarantine_record_identity_invalid", {
				"mutation_state": MUTATION_AMBIGUOUS,
			})
	_mutation_active = true
	_component.queue_teardown(maxi(tick, current_tick()))
	var unclean: Array[Dictionary] = []
	for record in records:
		if not grant_record_is_terminally_clean(record):
			unclean.append(record.duplicate(true))
	_mutation_active = false
	return {
		"accepted": unclean.is_empty(),
		"reason": &"" if unclean.is_empty() \
			else &"ability_component_quarantine_unproven",
		"mutation_state": MUTATION_COMMITTED,
		"terminal": _component.is_torn_down() and not _component.is_owner_valid(),
		"unresolved_records": unclean,
	}


func clear() -> bool:
	if _mutation_active:
		return false
	_component = null
	_component_instance_id = 0
	_identity_token = ""
	return true


func _build_grant_record(
	plan: Dictionary,
	spec: int,
	before_executions: PackedInt64Array,
	before_effects: PackedInt64Array,
	before_attributes: Dictionary,
	before_tags: Dictionary,
	tick: int
) -> Dictionary:
	if spec <= 0:
		return _postcondition_rejection(&"ability_spec_invalid")
	var grant_record := _component.get_grant(spec)
	if grant_record.is_empty() or bool(grant_record.get("revoked", true)) \
			or StringName(grant_record.get("ability_identifier", &"")) \
				!= StringName(plan["ability_identifier"]) \
			or int(grant_record.get("level", 0)) != int(plan["level"]) \
			or String(grant_record.get("input_id", "")) != String(plan["input_id"]):
		return _postcondition_rejection(&"ability_grant_identity_mismatch")

	var execution_ids := PackedInt64Array()
	for execution_id in _component.active_executions():
		if before_executions.has(execution_id):
			continue
		var execution := _component.get_execution(execution_id)
		if int(execution.get("spec", 0)) == spec \
				and int(execution.get("phase", -1)) == GameplayAbilityComponent.PHASE_ACTIVE:
			execution_ids.append(execution_id)
	if execution_ids.size() != 1:
		return _postcondition_rejection(&"passive_execution_missing_or_ambiguous")

	var expected_effects := _identifier_array(plan["effect_identifiers"])
	var effects: Array[Dictionary] = []
	var seen_effect_identifiers: Dictionary = {}
	for handle in _component.active_effect_handles():
		if before_effects.has(handle):
			continue
		var effect := _component.get_active_effect(handle)
		var effect_identifier := StringName(effect.get("definition_identifier", &""))
		if not expected_effects.has(effect_identifier):
			continue
		if seen_effect_identifiers.has(effect_identifier):
			return _postcondition_rejection(&"equipment_effect_ambiguous")
		seen_effect_identifiers[effect_identifier] = true
		effects.append({
			"handle": int(handle),
			"definition_identifier": effect_identifier,
		})
	if effects.size() != expected_effects.size():
		return _postcondition_rejection(&"equipment_effect_missing")
	effects.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["handle"]) < int(right["handle"]))

	var tag_identifiers := _identifier_array(plan["tag_identifiers"])
	for tag_value in tag_identifiers:
		if not _component.has_tag_exact(String(tag_value)):
			return _postcondition_rejection(&"equipment_tag_missing")
	var after_attributes := _attribute_values(plan["modifier_delta_micros"] as Dictionary)
	if not _modifier_delta_matches(
			before_attributes, after_attributes, plan["modifier_delta_micros"] as Dictionary):
		return _postcondition_rejection(&"equipment_modifier_mismatch")
	return {
		"accepted": true,
		"record_kind": &"committed_grant",
		"replayed": false,
		"mutation_state": MUTATION_COMMITTED,
		"component_token": _identity_token,
		"component_entity_id": entity_id(),
		"spec": spec,
		"ability_identifier": plan["ability_identifier"],
		"level": int(plan["level"]),
		"input_id": String(plan["input_id"]),
		"execution_ids": execution_ids,
		"effects": effects,
		"tag_identifiers": tag_identifiers.duplicate(),
		"tag_presence_before": before_tags.duplicate(true),
		"modifier_delta_micros": (plan["modifier_delta_micros"] as Dictionary).duplicate(true),
		"modifier_values_before": before_attributes,
		"modifier_values_after": after_attributes,
		"grant_revision": int(grant_record.get("revision", 0)),
		"tick": tick,
	}


func _capture_recovery_record(
	plan: Dictionary,
	spec: int,
	before_executions: PackedInt64Array,
	before_effects: PackedInt64Array,
	before_attributes: Dictionary,
	before_tags: Dictionary,
	before_owned_tags: PackedStringArray,
	tick: int
) -> Dictionary:
	var execution_ids := PackedInt64Array()
	for execution_id in _component.active_executions():
		if before_executions.has(execution_id):
			continue
		var execution := _component.get_execution(execution_id)
		if spec <= 0 or int(execution.get("spec", 0)) == spec:
			execution_ids.append(execution_id)
	execution_ids.sort()
	var effects: Array[Dictionary] = []
	for handle in _component.active_effect_handles():
		if before_effects.has(handle):
			continue
		var effect := _component.get_active_effect(handle)
		var definition_identifier := StringName(
			effect.get("definition_identifier", &""))
		effects.append({
			"handle": int(handle),
			"definition_identifier": definition_identifier,
		})
	effects.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("handle", 0)) < int(right.get("handle", 0)))
	var recovery_tag_baseline := before_tags.duplicate(true)
	for tag_value in before_owned_tags:
		recovery_tag_baseline[String(tag_value)] = true
	for tag_value in _component.owned_tags():
		var after_identifier := String(tag_value)
		if not recovery_tag_baseline.has(after_identifier):
			recovery_tag_baseline[after_identifier] = false
	return {
		"record_kind": &"mutation_recovery",
		"component_token": _identity_token,
		"component_entity_id": entity_id(),
		"spec": spec,
		"ability_identifier": plan.get("ability_identifier", &""),
		"level": int(plan.get("level", 0)),
		"input_id": String(plan.get("input_id", "")),
		"execution_ids": execution_ids,
		"effects": effects,
		"tag_identifiers": _identifier_array(
			plan.get("tag_identifiers", [])).duplicate(),
		"tag_presence_before": recovery_tag_baseline,
		"modifier_delta_micros": (plan.get(
			"modifier_delta_micros", {}) as Dictionary).duplicate(true),
		"modifier_values_before": before_attributes.duplicate(true),
		"modifier_values_after": _attribute_values(
			plan.get("modifier_delta_micros", {}) as Dictionary),
		"tick": tick,
	}


func _capture_revoke_recovery_record(
	record: Dictionary,
	before_executions: PackedInt64Array,
	before_effects: PackedInt64Array,
	before_attributes: Dictionary,
	before_tags: Dictionary,
	before_owned_tags: PackedStringArray,
	tick: int
) -> Dictionary:
	var recovery := record.duplicate(true)
	recovery["record_kind"] = &"mutation_recovery"
	var execution_ids := PackedInt64Array(
		recovery.get("execution_ids", PackedInt64Array()))
	for execution_id in _component.active_executions():
		if not before_executions.has(execution_id) \
				and not execution_ids.has(execution_id):
			execution_ids.append(execution_id)
	execution_ids.sort()
	recovery["execution_ids"] = execution_ids
	var effects := recovery.get("effects", []) as Array
	var effect_handles: Dictionary = {}
	for effect_value in effects:
		effect_handles[int((effect_value as Dictionary).get("handle", 0))] = true
	for handle in _component.active_effect_handles():
		if before_effects.has(handle) or effect_handles.has(int(handle)):
			continue
		var effect := _component.get_active_effect(handle)
		effects.append({
			"handle": int(handle),
			"definition_identifier": StringName(
				effect.get("definition_identifier", &"")),
		})
	effects.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("handle", 0)) < int(right.get("handle", 0)))
	recovery["effects"] = effects
	var expected_attributes: Dictionary = {}
	var modifier_deltas := record.get("modifier_delta_micros", {}) as Dictionary
	for key in before_attributes.keys():
		expected_attributes[String(key)] = float(before_attributes[key]) \
			- float(modifier_deltas.get(key, 0)) \
				/ float(ZerkovEquipmentAbilityContent.FIXED_SCALE)
	recovery["modifier_values_before"] = expected_attributes
	recovery["modifier_values_after"] = _attribute_values(modifier_deltas)
	# A committed record captured the tag state from immediately before its
	# own grant. Retain that exact baseline for ambiguous cleanup; if unrelated
	# contributors changed in the meantime, fail-stop quarantine is safer than
	# claiming a leaked tag was restored.
	var recovery_tag_baseline: Dictionary = {}
	for tag_value in before_owned_tags:
		recovery_tag_baseline[String(tag_value)] = true
	for tag_value in _component.owned_tags():
		var after_identifier := String(tag_value)
		if not recovery_tag_baseline.has(after_identifier):
			recovery_tag_baseline[after_identifier] = false
	for tag_value in _identifier_array(record.get("tag_identifiers", [])):
		var declared_identifier := String(tag_value)
		recovery_tag_baseline[declared_identifier] = bool((record.get(
			"tag_presence_before", {}) as Dictionary).get(declared_identifier, false))
	recovery["tag_presence_before"] = recovery_tag_baseline
	recovery["revoke_tag_presence_before"] = before_tags.duplicate(true)
	recovery["tick"] = tick
	return recovery


func _validate_plan(plan: Dictionary) -> Dictionary:
	var required := PackedStringArray([
		"ability_identifier",
		"level",
		"effect_identifiers",
		"tag_identifiers",
		"modifier_delta_micros",
	])
	for key in required:
		if not plan.has(key):
			return {"ok": false, "reason": &"grant_plan_schema_invalid"}
	var ability_identifier := StringName(plan.get("ability_identifier", &""))
	var effects := _identifier_array(plan.get("effect_identifiers", []))
	var tags := _identifier_array(plan.get("tag_identifiers", []))
	var modifiers := plan.get("modifier_delta_micros", {}) as Dictionary
	if ability_identifier.is_empty() or int(plan.get("level", 0)) <= 0 \
			or effects.is_empty() or tags.is_empty() or modifiers.is_empty():
		return {"ok": false, "reason": &"grant_plan_content_invalid"}
	if plan.has("input_id"):
		var input_id := String(plan.get("input_id", ""))
		if input_id.is_empty() or input_id.to_utf8_buffer().size() > MAX_INPUT_ID_BYTES:
			return {"ok": false, "reason": &"grant_plan_input_id_invalid"}
	var unique_effects: Dictionary = {}
	for effect in effects:
		if StringName(effect).is_empty() or unique_effects.has(StringName(effect)):
			return {"ok": false, "reason": &"grant_plan_effects_invalid"}
		unique_effects[StringName(effect)] = true
	var unique_tags: Dictionary = {}
	for tag in tags:
		if StringName(tag).is_empty() or unique_tags.has(StringName(tag)):
			return {"ok": false, "reason": &"grant_plan_tags_invalid"}
		unique_tags[StringName(tag)] = true
	for attribute_key in modifiers.keys():
		if StringName(attribute_key).is_empty() \
				or typeof(modifiers[attribute_key]) != TYPE_INT:
			return {"ok": false, "reason": &"grant_plan_modifiers_invalid"}
	return {"ok": true}


func _validate_canonical_catalog_subset(
	_equipment_declarations: Array[Dictionary]
) -> Dictionary:
	var actual_catalog := _component.get_definition_catalog()
	if actual_catalog == null:
		return {"ok": false, "reason": &"equipment_ability_catalog_missing"}
	var expected_catalog := ZerkovEquipmentAbilityContent.build_definition_catalog()
	if expected_catalog == null:
		return {"ok": false, "reason": &"equipment_ability_catalog_expected_invalid"}
	# GameplayAbilityComponent copies and seals definitions at configure time,
	# while the authored Resource remains mutable. Tie the currently inspected
	# Resource graph back to the exact fingerprint captured by the live native
	# core before trusting any subset extracted from it.
	var full_validator := GameplayDefinitionValidator.new()
	var full_findings: Array = full_validator.validate_catalog(actual_catalog)
	if not GameplayDefinitionValidator.is_ok(full_findings) \
			or not full_validator.get_last_manifest_ok() \
			or full_validator.get_last_manifest_fingerprint() \
				!= _component.get_content_manifest_fingerprint():
		return {"ok": false, "reason": &"ability_catalog_changed_after_configure"}

	# The installed add-on exposes immutable authored Resources and its own
	# canonical manifest builder. Extract only this product content by stable
	# identifier so a larger combined catalog remains valid, then compare the
	# complete resource semantics to a fresh canonical content catalog through
	# the add-on's validator/fingerprint rather than reinterpreting its fields.
	var subset := GameplayDefinitionCatalog.new()
	var actual_tags: Array = actual_catalog.get_tag_definitions()
	var actual_attributes: Array = actual_catalog.get_attribute_definitions()
	var actual_effects: Array = actual_catalog.get_effect_definitions()
	var actual_abilities: Array = actual_catalog.get_ability_definitions()
	var subset_tags: Array[GameplayTagDefinition] = []
	var subset_attributes: Array[GameplayAttributeDefinition] = []
	var subset_effects: Array[GameplayEffectDefinition] = []
	var subset_abilities: Array[GameplayAbilityDefinition] = []
	for expected_value in expected_catalog.get_tag_definitions():
		var expected := expected_value as GameplayTagDefinition
		var actual := _find_tag_definition(actual_tags, expected.get_identifier())
		if actual == null:
			return {"ok": false, "reason": &"equipment_tag_definition_missing"}
		subset_tags.append(actual)
	for expected_value in expected_catalog.get_attribute_definitions():
		var expected := expected_value as GameplayAttributeDefinition
		var actual := _find_attribute_definition(
			actual_attributes, expected.get_identifier())
		if actual == null:
			return {"ok": false, "reason": &"equipment_attribute_definition_missing"}
		subset_attributes.append(actual)
	for expected_value in expected_catalog.get_effect_definitions():
		var expected := expected_value as GameplayEffectDefinition
		var actual := _find_effect_definition(actual_effects, expected.get_identifier())
		if actual == null:
			return {"ok": false, "reason": &"equipment_effect_definition_missing"}
		subset_effects.append(actual)
	for expected_value in expected_catalog.get_ability_definitions():
		var expected := expected_value as GameplayAbilityDefinition
		var actual := _find_ability_definition(
			actual_abilities, expected.get_identifier())
		if actual == null:
			return {"ok": false, "reason": &"equipment_ability_definition_missing"}
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
		return {"ok": false, "reason": &"equipment_ability_catalog_expected_invalid"}
	if not GameplayDefinitionValidator.is_ok(actual_findings) \
			or not actual_validator.get_last_manifest_ok():
		return {"ok": false, "reason": &"equipment_ability_catalog_subset_invalid"}
	if actual_validator.get_last_manifest_fingerprint() \
			!= expected_validator.get_last_manifest_fingerprint() \
			or actual_validator.get_last_manifest_entry_count() \
				!= expected_validator.get_last_manifest_entry_count() \
			or actual_validator.get_last_manifest_tick_rate() \
				!= expected_validator.get_last_manifest_tick_rate():
		return {"ok": false, "reason": &"equipment_ability_semantics_mismatch"}
	return {
		"ok": true,
		"content_manifest_fingerprint": actual_validator.get_last_manifest_fingerprint(),
	}


func _find_tag_definition(
	definitions: Array,
	identifier: StringName
) -> GameplayTagDefinition:
	var found: GameplayTagDefinition
	for value in definitions:
		if not value is GameplayTagDefinition:
			continue
		var definition := value as GameplayTagDefinition
		if definition.get_identifier() != identifier:
			continue
		if found != null:
			return null
		found = definition
	return found


func _find_ability_definition(
	definitions: Array,
	identifier: StringName
) -> GameplayAbilityDefinition:
	var found: GameplayAbilityDefinition
	for value in definitions:
		if not value is GameplayAbilityDefinition:
			continue
		var definition := value as GameplayAbilityDefinition
		if definition.get_identifier() != identifier:
			continue
		if found != null:
			return null
		found = definition
	return found


func _find_effect_definition(
	definitions: Array,
	identifier: StringName
) -> GameplayEffectDefinition:
	var found: GameplayEffectDefinition
	for value in definitions:
		if not value is GameplayEffectDefinition:
			continue
		var definition := value as GameplayEffectDefinition
		if definition.get_identifier() != identifier:
			continue
		if found != null:
			return null
		found = definition
	return found


func _find_attribute_definition(
	definitions: Array,
	identifier: StringName
) -> GameplayAttributeDefinition:
	var found: GameplayAttributeDefinition
	for value in definitions:
		if not value is GameplayAttributeDefinition:
			continue
		var definition := value as GameplayAttributeDefinition
		if definition.get_identifier() != identifier:
			continue
		if found != null:
			return null
		found = definition
	return found


func _record_matches_component(record: Dictionary) -> bool:
	return int(record.get("spec", 0)) > 0 \
		and _recovery_record_matches_component(record)


func _recovery_record_matches_component(record: Dictionary) -> bool:
	var record_kind := StringName(record.get("record_kind", &""))
	return (record_kind == &"committed_grant" \
			or record_kind == &"mutation_recovery") \
		and int(record.get("spec", -1)) >= 0 \
		and String(record.get("component_token", "")) == _identity_token \
		and int(record.get("component_entity_id", 0)) == entity_id() \
		and not StringName(record.get("ability_identifier", &"")).is_empty() \
		and not String(record.get("input_id", "")).is_empty()


func _has_live_input_id(input_id: String) -> bool:
	for spec in _component.granted_specs():
		var grant_record := _component.get_grant(spec)
		if not bool(grant_record.get("revoked", true)) \
				and String(grant_record.get("input_id", "")) == input_id:
			return true
	return false


func _recovery_record_is_clean(record: Dictionary) -> bool:
	if not grant_record_is_absent(record):
		return false
	var before_attributes := record.get("modifier_values_before", {}) as Dictionary
	for key in before_attributes.keys():
		if _fixed_micros(_component.get_attribute_current(String(key))) \
				!= _fixed_micros(float(before_attributes[key])):
			return false
	var before_tags := record.get("tag_presence_before", {}) as Dictionary
	for key in before_tags.keys():
		if _component.has_tag_exact(String(key)) != bool(before_tags[key]):
			return false
	return true


func _attribute_values(modifier_delta_micros: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var identifiers := PackedStringArray()
	for key in modifier_delta_micros.keys():
		identifiers.append(String(key))
	identifiers.sort()
	for identifier in identifiers:
		result[String(identifier)] = _component.get_attribute_current(identifier)
	return result


func _tag_presence(tag_identifiers: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for identifier in tag_identifiers:
		result[String(identifier)] = _component.has_tag_exact(identifier)
	return result


func _attribute_values_equal(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for key in left.keys():
		if not right.has(key) \
				or _fixed_micros(float(left[key])) \
					!= _fixed_micros(float(right[key])):
			return false
	return true


func _modifier_delta_matches(
	before: Dictionary,
	after: Dictionary,
	expected_delta_micros: Dictionary
) -> bool:
	for key in expected_delta_micros.keys():
		var expected_micros := _fixed_micros(float(before.get(key, 0.0))) \
			+ int(expected_delta_micros[key])
		if _fixed_micros(float(after.get(key, 0.0))) != expected_micros:
			return false
	return true


func _modifier_delta_unwound(
	before: Dictionary,
	after: Dictionary,
	expected_delta_micros: Dictionary
) -> bool:
	for key in expected_delta_micros.keys():
		var expected_micros := _fixed_micros(float(before.get(String(key), 0.0))) \
			- int(expected_delta_micros[key])
		if _fixed_micros(float(after.get(String(key), 0.0))) != expected_micros:
			return false
	return true


func _fixed_micros(value: float) -> int:
	var scaled := value * float(ZerkovEquipmentAbilityContent.FIXED_SCALE)
	if scaled < 0.0:
		return -int(floor(-scaled + 0.5))
	return int(floor(scaled + 0.5))


func _identifier_array(value: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if value is PackedStringArray:
		return (value as PackedStringArray).duplicate()
	if not (value is Array):
		return result
	for entry in value as Array:
		if typeof(entry) != TYPE_STRING and typeof(entry) != TYPE_STRING_NAME:
			return PackedStringArray()
		result.append(String(entry))
	return result


func _component_is_exact() -> bool:
	return _component != null and is_instance_valid(_component) \
		and _component.get_instance_id() == _component_instance_id


func _postcondition_rejection(reason: StringName) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"mutation_state": MUTATION_AMBIGUOUS,
	}


func _rejection(reason: StringName, details: Dictionary = {}) -> Dictionary:
	var result := {
		"accepted": false,
		"reason": reason,
		"mutation_state": MUTATION_NONE,
	}
	result.merge(details, true)
	return result
