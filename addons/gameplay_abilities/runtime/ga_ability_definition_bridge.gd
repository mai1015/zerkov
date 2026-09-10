class_name GameplayAbilityDefinitionBridge
extends RefCounted

## Converts an authored [GameplayAbilityDefinition] resource into the exact
## [code]Dictionary[/code] shape [method GameplayAbilityComponent.set_ability_definitions]
## already accepts.
##
## [GameplayAbilityComponent]'s native binding still takes
## [code]Array[Dictionary][/code] rather than
## [code]TypedArray[GameplayAbilityDefinition][/code] directly --
## [code]native/godot/gameplay_ability_component.h/.cpp[/code] is frozen for
## this task (see the resource's own header comment), so widening that
## binding is a follow-up. This bridge is the seam that follow-up would
## replace: a game authors [GameplayAbilityDefinition] resources today and
## converts them with [method to_dictionary_array] right before calling
## [method GameplayAbilityComponent.set_ability_definitions]; nothing else in
## a game's authoring workflow needs to change once the native binding
## widens, since the Dictionary shape is unchanged either way.
##
## Mirrors `to_ability_desc(const Dictionary &)` in
## [code]native/godot/gameplay_ability_component.cpp[/code] field for field --
## see that function for the authoritative shape.

static func to_dictionary(ability: GameplayAbilityDefinition) -> Dictionary:
	var dict := {
		"identifier": String(ability.get_identifier()),
		"activation_policy": int(ability.get_activation_policy()),
		"owned_tags": ability.get_owned_tags(),
		"cost_effect": String(ability.get_cost_effect()),
		"cooldown_effect": String(ability.get_cooldown_effect()),
		"commit_effects": ability.get_commit_effects(),
		"concurrency_policy": int(ability.get_concurrency_policy()),
		"duplicate_grant_policy": int(ability.get_duplicate_grant_policy()),
		"revoke_policy": int(ability.get_revoke_policy()),
		"prediction_policy": int(ability.get_prediction_policy()),
		"hook_binding": int(ability.get_hook_binding()),
		"auto_commit": ability.get_auto_commit(),
		"ends_on_commit": ability.get_ends_on_commit(),
		"prediction_safe_declared": ability.get_prediction_safe_declared(),
		"target_schema": String(ability.get_target_schema()),
	}

	var required := _tag_query_to_dictionary(ability.get_required_tags())
	if not required.is_empty():
		dict["required_tags"] = required
	var blocked := _tag_query_to_dictionary(ability.get_blocked_tags())
	if not blocked.is_empty():
		dict["blocked_tags"] = blocked
	var cancel := _tag_query_to_dictionary(ability.get_cancel_tags())
	if not cancel.is_empty():
		dict["cancel_tags"] = cancel

	var triggers: Array = []
	for entry in ability.get_triggers():
		var trigger: GameplayAbilityTrigger = entry
		if trigger == null:
			continue
		triggers.append({
			"kind": int(trigger.get_kind()),
			"input_id": trigger.get_input_id(),
			"gameplay_event_tag": String(trigger.get_gameplay_event_tag()),
		})
	dict["triggers"] = triggers

	return dict


## Converts every [GameplayAbilityDefinition] in [param abilities] (any other
## element is skipped rather than raising an error, so a caller may pass a
## loosely-typed authoring array).
static func to_dictionary_array(abilities: Array) -> Array:
	var result: Array = []
	for entry in abilities:
		if entry is GameplayAbilityDefinition:
			result.append(to_dictionary(entry))
	return result


static func _tag_query_to_dictionary(query: GameplayTagQueryResource) -> Dictionary:
	if query == null:
		return {}
	var result := {}
	var all_of := _operands_to_array(query.get_all_of())
	if not all_of.is_empty():
		result["all_of"] = all_of
	var any_of := _operands_to_array(query.get_any_of())
	if not any_of.is_empty():
		result["any_of"] = any_of
	var none_of := _operands_to_array(query.get_none_of())
	if not none_of.is_empty():
		result["none_of"] = none_of
	return result


static func _operands_to_array(operands: Array) -> Array:
	var result: Array = []
	for entry in operands:
		var operand: GameplayTagOperand = entry
		if operand == null:
			continue
		result.append({"tag": String(operand.get_tag()), "match_mode": int(operand.get_match_mode())})
	return result
