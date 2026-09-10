#include "godot/gameplay_ability_component.h"

#include "core/ga_bytes.h"
#include "core/ga_effect_spec.h"
#include "core/ga_fixed.h"
#include "core/ga_identifier.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_snapshot.h"
#include "core/ga_tag_query.h"
#include "core/ga_tag_reactions.h"

#include "godot/gameplay_ability_godot_util.h"
#include "godot/gameplay_ability_hook_bridge.h"
#include "godot/gameplay_target_value.h"
#include "godot/gameplay_definition_validator.h"

#include "resources/gameplay_ability_trigger.h"
#include "resources/gameplay_magnitude.h"
#include "resources/gameplay_modifier_declaration.h"
#include "resources/gameplay_set_by_caller_field.h"
#include "resources/gameplay_stacking_policy.h"
#include "resources/gameplay_tag_operand.h"
#include "resources/gameplay_tag_query_resource.h"
#include "resources/gameplay_tag_reaction_definition.h"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <utility>

// See gameplay_ability_component.h for the class-level design rationale.
// This file duplicates a handful of small Resource -> ga::*Desc converters
// that also appear in gameplay_definition_validator.cpp: that file's
// converters are private to its own anonymous namespace and this task's
// scope forbids editing it, so a thin, independent copy lives here. Both
// converge on identical `ga::*Desc` shapes and therefore identical
// registration behavior; there is nothing to keep "in sync" beyond the core
// structs themselves, which are the single source of truth.
namespace godot {

namespace {

ga::AbilitySpecId to_spec_id(int64_t p_value) { return ga::AbilitySpecId{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }
ga::ExecutionId to_execution_id(int64_t p_value) { return ga::ExecutionId{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }
ga::CommandSeq to_command_seq(int64_t p_value) { return ga::CommandSeq{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }
ga::PredictionKey to_prediction_key(int64_t p_value) { return ga::PredictionKey{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }
ga::EffectHandle to_effect_handle(int64_t p_value) { return ga::EffectHandle{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }
ga::AbilityTaskHandle to_task_handle(int64_t p_value) { return ga::AbilityTaskHandle{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) }; }

ga::ChangeProvenance to_provenance(int p_value) {
	return p_value == GameplayAbilityComponent::PROVENANCE_PREDICTED ? ga::ChangeProvenance::PREDICTED : ga::ChangeProvenance::AUTHORITATIVE;
}

ga::ExecutionEndReason to_end_reason(int p_value) {
	return static_cast<ga::ExecutionEndReason>(p_value);
}

ga::ComponentRole to_core_role(GameplayAbilityComponent::Role p_role) {
	switch (p_role) {
		case GameplayAbilityComponent::ROLE_SERVER_AUTHORITY:
			return ga::ComponentRole::SERVER_AUTHORITY;
		case GameplayAbilityComponent::ROLE_NETWORK_CLIENT:
			return ga::ComponentRole::NETWORK_CLIENT;
		case GameplayAbilityComponent::ROLE_OFFLINE_AUTHORITY:
		default:
			return ga::ComponentRole::OFFLINE_AUTHORITY;
	}
}

std::vector<ga::TagOperandDesc> to_operand_vector(const Array &p_operands) {
	std::vector<ga::TagOperandDesc> result;
	result.reserve(p_operands.size());
	for (int i = 0; i < p_operands.size(); ++i) {
		const Variant entry = p_operands[i];
		ga::TagOperandDesc desc;
		if (entry.get_type() == Variant::STRING || entry.get_type() == Variant::STRING_NAME) {
			desc.tag = to_std(String(entry));
			desc.mode = ga::TagMatchMode::EXACT;
		} else if (entry.get_type() == Variant::DICTIONARY) {
			const Dictionary dict = entry;
			desc.tag = to_std(String(dict.get("tag", String())));
			const int mode = int(dict.get("match_mode", 0));
			desc.mode = mode == 1 ? ga::TagMatchMode::PARENT_AWARE : ga::TagMatchMode::EXACT;
		} else {
			continue;
		}
		if (!desc.tag.empty()) {
			result.push_back(desc);
		}
	}
	return result;
}

ga::TagRequirementDesc to_tag_requirement_desc(const Dictionary &p_dict) {
	ga::TagRequirementDesc desc;
	if (p_dict.has("all_of")) {
		desc.all = to_operand_vector(p_dict["all_of"]);
	}
	if (p_dict.has("any_of")) {
		desc.any = to_operand_vector(p_dict["any_of"]);
	}
	if (p_dict.has("none_of")) {
		desc.none = to_operand_vector(p_dict["none_of"]);
	}
	return desc;
}

std::vector<std::string> to_string_vector(const PackedStringArray &p_array) {
	std::vector<std::string> result;
	result.reserve(p_array.size());
	for (int i = 0; i < p_array.size(); ++i) {
		result.push_back(to_std(p_array[i]));
	}
	return result;
}

// Task 5.1: the single Resource -> `ga::TagReactionCanonicalDesc` converter
// both `configure()`'s reaction-registration loop AND its manifest
// contribution loop use, so the two can never independently drift on what a
// reaction's canonical fields are (mirrors this addon's own "one function
// encodes a reaction's canonical fields" precedent -- see
// `ga::contribute_tag_reaction_manifest`'s own file comment,
// native/core/ga_tag_reactions.h).
ga::TagReactionCanonicalDesc to_reaction_desc(const Ref<GameplayTagReactionDefinition> &p_reaction) {
	ga::TagReactionCanonicalDesc desc;
	if (p_reaction.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_reaction->get_identifier()));
	const Ref<GameplayTagOperand> operand = p_reaction->get_operand();
	if (operand.is_valid()) {
		desc.operand_tag = to_std(String(operand->get_tag()));
		desc.match_mode = operand->get_match_mode() == GameplayTagOperand::MATCH_PARENT_AWARE
				? ga::TagReactionMatchMode::PARENT_AWARE
				: ga::TagReactionMatchMode::EXACT;
	}
	desc.mode = static_cast<ga::TagReactionMode>(p_reaction->get_mode());
	desc.effect_identifier = to_std(String(p_reaction->get_effect_identifier()));
	return desc;
}

ga::MagnitudeSourceDesc to_magnitude_desc(const Ref<GameplayMagnitude> &p_magnitude) {
	ga::MagnitudeSourceDesc desc;
	if (p_magnitude.is_null()) {
		return desc;
	}
	switch (p_magnitude->get_kind()) {
		case GameplayMagnitude::KIND_ABILITY_LEVEL:
			desc.kind = ga::MagnitudeSourceKind::ABILITY_LEVEL;
			break;
		case GameplayMagnitude::KIND_SOURCE_ATTRIBUTE:
			desc.kind = ga::MagnitudeSourceKind::SOURCE_ATTRIBUTE;
			break;
		case GameplayMagnitude::KIND_TARGET_ATTRIBUTE:
			desc.kind = ga::MagnitudeSourceKind::TARGET_ATTRIBUTE;
			break;
		case GameplayMagnitude::KIND_SET_BY_CALLER:
			desc.kind = ga::MagnitudeSourceKind::SET_BY_CALLER;
			break;
		case GameplayMagnitude::KIND_CONSTANT:
		default:
			desc.kind = ga::MagnitudeSourceKind::CONSTANT;
			break;
	}
	desc.coefficient = p_magnitude->get_coefficient();
	desc.attribute = to_std(String(p_magnitude->get_attribute()));
	desc.set_by_caller_field = to_std(String(p_magnitude->get_set_by_caller_field()));
	return desc;
}

ga::ModifierDeclarationDesc to_modifier_desc(const Ref<GameplayModifierDeclaration> &p_modifier) {
	ga::ModifierDeclarationDesc desc;
	if (p_modifier.is_null()) {
		return desc;
	}
	desc.target_attribute = to_std(String(p_modifier->get_target_attribute()));
	switch (p_modifier->get_op()) {
		case GameplayModifierDeclaration::OP_MULTIPLY:
			desc.op = ga::ModifierOp::MULTIPLY;
			break;
		case GameplayModifierDeclaration::OP_OVERRIDE:
			desc.op = ga::ModifierOp::OVERRIDE;
			break;
		case GameplayModifierDeclaration::OP_ADD:
		default:
			desc.op = ga::ModifierOp::ADD;
			break;
	}
	desc.magnitude = to_magnitude_desc(p_modifier->get_magnitude());
	desc.priority = p_modifier->get_priority();
	return desc;
}

ga::SetByCallerFieldDesc to_set_by_caller_desc(const Ref<GameplaySetByCallerField> &p_field) {
	ga::SetByCallerFieldDesc desc;
	if (p_field.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_field->get_identifier()));
	desc.required = p_field->is_required();
	return desc;
}

ga::StackingPolicyDesc to_stacking_policy_desc(const Ref<GameplayStackingPolicy> &p_policy) {
	ga::StackingPolicyDesc desc;
	if (p_policy.is_null()) {
		return desc;
	}
	desc.stackable = p_policy->is_stackable();
	desc.stack_key = to_std(p_policy->get_stack_key());
	desc.source_scope = p_policy->get_source_scope() == GameplayStackingPolicy::TARGET_SCOPED
			? ga::StackSourceScope::TARGET_SCOPED
			: ga::StackSourceScope::SOURCE_SCOPED;
	desc.max_stacks = static_cast<std::uint32_t>(p_policy->get_max_stacks());
	switch (p_policy->get_overflow_policy()) {
		case GameplayStackingPolicy::OVERFLOW_REFRESH:
			desc.overflow_policy = ga::StackOverflowPolicy::REFRESH;
			break;
		case GameplayStackingPolicy::OVERFLOW_REPLACE:
			desc.overflow_policy = ga::StackOverflowPolicy::REPLACE;
			break;
		case GameplayStackingPolicy::OVERFLOW_APPLY_EFFECT:
			desc.overflow_policy = ga::StackOverflowPolicy::APPLY_OVERFLOW_EFFECT;
			break;
		case GameplayStackingPolicy::OVERFLOW_REJECT:
		default:
			desc.overflow_policy = ga::StackOverflowPolicy::REJECT;
			break;
	}
	desc.refresh_duration_on_add = p_policy->is_refresh_duration_on_add();
	desc.reset_period_on_add = p_policy->is_reset_period_on_add();
	desc.removal_rule = p_policy->get_removal_rule() == GameplayStackingPolicy::REMOVE_ALL_STACKS
			? ga::StackRemovalRule::REMOVE_ALL_STACKS
			: ga::StackRemovalRule::REMOVE_SINGLE_STACK;
	desc.overflow_effect = to_std(String(p_policy->get_overflow_effect()));
	return desc;
}

// Shared by `to_effect_desc` (source/target/immunity requirements) and
// `to_ability_desc_from_resource` (required/blocked/cancel tags, task 12.3's
// ergonomic follow-up) -- was a local lambda duplicated per call site before;
// factored out once both need it.
ga::TagRequirementDesc tag_requirement_from_resource(const Ref<GameplayTagQueryResource> &p_query) {
	ga::TagRequirementDesc desc;
	if (p_query.is_null()) {
		return desc;
	}
	auto operands = [](const TypedArray<GameplayTagOperand> &p_operands) {
		std::vector<ga::TagOperandDesc> result;
		result.reserve(p_operands.size());
		for (int i = 0; i < p_operands.size(); ++i) {
			const Ref<GameplayTagOperand> operand = p_operands[i];
			if (operand.is_null()) {
				continue;
			}
			ga::TagOperandDesc od;
			od.tag = to_std(String(operand->get_tag()));
			od.mode = operand->get_match_mode() == GameplayTagOperand::MATCH_PARENT_AWARE
					? ga::TagMatchMode::PARENT_AWARE
					: ga::TagMatchMode::EXACT;
			result.push_back(od);
		}
		return result;
	};
	desc.all = operands(p_query->get_all_of());
	desc.any = operands(p_query->get_any_of());
	desc.none = operands(p_query->get_none_of());
	return desc;
}

ga::EffectDefinitionDesc to_effect_desc(const Ref<GameplayEffectDefinition> &p_effect) {
	ga::EffectDefinitionDesc desc;
	desc.identifier = to_std(String(p_effect->get_identifier()));
	switch (p_effect->get_duration_policy()) {
		case GameplayEffectDefinition::DURATION_DURATION:
			desc.duration_policy = ga::EffectDuration::DURATION;
			break;
		case GameplayEffectDefinition::DURATION_INFINITE:
			desc.duration_policy = ga::EffectDuration::INFINITE;
			break;
		case GameplayEffectDefinition::DURATION_INSTANT:
		default:
			desc.duration_policy = ga::EffectDuration::INSTANT;
			break;
	}
	desc.duration_ticks = static_cast<std::uint64_t>(p_effect->get_duration_ticks());
	desc.has_period = p_effect->get_has_period();
	desc.period_ticks = static_cast<std::uint64_t>(p_effect->get_period_ticks());

	const TypedArray<GameplayModifierDeclaration> modifiers = p_effect->get_modifiers();
	desc.modifiers.reserve(modifiers.size());
	for (int i = 0; i < modifiers.size(); ++i) {
		const Ref<GameplayModifierDeclaration> modifier = modifiers[i];
		if (modifier.is_null()) {
			continue;
		}
		desc.modifiers.push_back(to_modifier_desc(modifier));
	}

	desc.granted_tags = to_string_vector(p_effect->get_granted_tags());

	desc.source_requirements = tag_requirement_from_resource(p_effect->get_source_requirements());
	desc.target_requirements = tag_requirement_from_resource(p_effect->get_target_requirements());
	desc.immunity = tag_requirement_from_resource(p_effect->get_immunity());
	desc.stacking = to_stacking_policy_desc(p_effect->get_stacking());

	const TypedArray<GameplaySetByCallerField> fields = p_effect->get_set_by_caller_fields();
	desc.set_by_caller_fields.reserve(fields.size());
	for (int i = 0; i < fields.size(); ++i) {
		const Ref<GameplaySetByCallerField> field = fields[i];
		if (field.is_null()) {
			continue;
		}
		desc.set_by_caller_fields.push_back(to_set_by_caller_desc(field));
	}

	desc.cue_identifiers = to_string_vector(p_effect->get_cue_identifiers());
	desc.prediction_safe = p_effect->get_prediction_safe();
	desc.retain_target_context =
			p_effect->get_retain_target_context();
	return desc;
}

ga::AbilityTriggerDesc to_trigger_desc(const Dictionary &p_dict) {
	ga::AbilityTriggerDesc desc;
	const int kind = int(p_dict.get("kind", 0));
	desc.kind = kind == 1 ? ga::AbilityTriggerDesc::Kind::GAMEPLAY_EVENT : ga::AbilityTriggerDesc::Kind::INPUT;
	desc.input_id = to_std(String(p_dict.get("input_id", String())));
	desc.gameplay_event_tag = to_std(String(p_dict.get("gameplay_event_tag", String())));
	return desc;
}

ga::AbilityDefinitionDesc to_ability_desc(const Dictionary &p_dict) {
	ga::AbilityDefinitionDesc desc;
	desc.identifier = to_std(String(p_dict.get("identifier", String())));
	desc.activation_policy = static_cast<ga::ActivationPolicy>(int(p_dict.get("activation_policy", 0)));

	if (p_dict.has("required_tags")) {
		desc.required_tags = to_tag_requirement_desc(p_dict["required_tags"]);
	}
	if (p_dict.has("blocked_tags")) {
		desc.blocked_tags = to_tag_requirement_desc(p_dict["blocked_tags"]);
	}
	if (p_dict.has("cancel_tags")) {
		desc.cancel_tags = to_tag_requirement_desc(p_dict["cancel_tags"]);
	}
	if (p_dict.has("owned_tags")) {
		desc.owned_tags = to_string_vector(p_dict["owned_tags"]);
	}

	desc.cost_effect = to_std(String(p_dict.get("cost_effect", String())));
	desc.cooldown_effect = to_std(String(p_dict.get("cooldown_effect", String())));
	if (p_dict.has("commit_effects")) {
		desc.commit_effects = to_string_vector(p_dict["commit_effects"]);
	}

	if (p_dict.has("triggers")) {
		const Array triggers = p_dict["triggers"];
		desc.triggers.reserve(triggers.size());
		for (int i = 0; i < triggers.size(); ++i) {
			desc.triggers.push_back(to_trigger_desc(triggers[i]));
		}
	}

	desc.concurrency_policy = static_cast<ga::AbilityConcurrencyPolicy>(int(p_dict.get("concurrency_policy", 0)));
	desc.duplicate_grant_policy = static_cast<ga::AbilityDuplicateGrantPolicy>(int(p_dict.get("duplicate_grant_policy", 0)));
	desc.revoke_policy = static_cast<ga::AbilityRevokePolicy>(int(p_dict.get("revoke_policy", 0)));
	desc.prediction_policy = static_cast<ga::AbilityPredictionPolicy>(int(p_dict.get("prediction_policy", 0)));
	desc.hook_binding = static_cast<ga::AbilityHookBinding>(int(p_dict.get("hook_binding", 0)));
	desc.auto_commit = bool(p_dict.get("auto_commit", true));
	desc.ends_on_commit = bool(p_dict.get("ends_on_commit", true));
	desc.prediction_safe_declared = bool(p_dict.get("prediction_safe_declared", false));
	return desc;
}

ga::AbilityTriggerDesc to_trigger_desc_from_resource(const Ref<GameplayAbilityTrigger> &p_trigger) {
	ga::AbilityTriggerDesc desc;
	if (p_trigger.is_null()) {
		return desc;
	}
	desc.kind = p_trigger->get_kind() == GameplayAbilityTrigger::KIND_GAMEPLAY_EVENT
			? ga::AbilityTriggerDesc::Kind::GAMEPLAY_EVENT
			: ga::AbilityTriggerDesc::Kind::INPUT;
	desc.input_id = to_std(p_trigger->get_input_id());
	desc.gameplay_event_tag = to_std(String(p_trigger->get_gameplay_event_tag()));
	return desc;
}

// Ergonomic follow-up (task 12.3): `GameplayAbilityDefinition` -> the SAME
// `ga::AbilityDefinitionDesc` shape `to_ability_desc` builds from a
// Dictionary, field for field, mirroring
// `GameplayAbilityDefinitionBridge.to_dictionary()`
// (runtime/ga_ability_definition_bridge.gd) exactly -- so a caller may pass
// either shape into `ability_definitions` interchangeably (see `configure()`).
ga::AbilityDefinitionDesc to_ability_desc_from_resource(const Ref<GameplayAbilityDefinition> &p_ability) {
	ga::AbilityDefinitionDesc desc;
	desc.identifier = to_std(String(p_ability->get_identifier()));
	desc.activation_policy = static_cast<ga::ActivationPolicy>(int(p_ability->get_activation_policy()));

	desc.required_tags = tag_requirement_from_resource(p_ability->get_required_tags());
	desc.blocked_tags = tag_requirement_from_resource(p_ability->get_blocked_tags());
	desc.cancel_tags = tag_requirement_from_resource(p_ability->get_cancel_tags());
	desc.owned_tags = to_string_vector(p_ability->get_owned_tags());

	desc.cost_effect = to_std(String(p_ability->get_cost_effect()));
	desc.cooldown_effect = to_std(String(p_ability->get_cooldown_effect()));
	desc.commit_effects = to_string_vector(p_ability->get_commit_effects());

	const TypedArray<GameplayAbilityTrigger> triggers = p_ability->get_triggers();
	desc.triggers.reserve(triggers.size());
	for (int i = 0; i < triggers.size(); ++i) {
		const Ref<GameplayAbilityTrigger> trigger = triggers[i];
		if (trigger.is_null()) {
			continue;
		}
		desc.triggers.push_back(to_trigger_desc_from_resource(trigger));
	}

	desc.concurrency_policy = static_cast<ga::AbilityConcurrencyPolicy>(int(p_ability->get_concurrency_policy()));
	desc.duplicate_grant_policy = static_cast<ga::AbilityDuplicateGrantPolicy>(int(p_ability->get_duplicate_grant_policy()));
	desc.revoke_policy = static_cast<ga::AbilityRevokePolicy>(int(p_ability->get_revoke_policy()));
	desc.prediction_policy = static_cast<ga::AbilityPredictionPolicy>(int(p_ability->get_prediction_policy()));
	desc.hook_binding = static_cast<ga::AbilityHookBinding>(int(p_ability->get_hook_binding()));
	desc.auto_commit = p_ability->get_auto_commit();
	desc.ends_on_commit = p_ability->get_ends_on_commit();
	desc.prediction_safe_declared = p_ability->get_prediction_safe_declared();
	return desc;
}

} // namespace

GameplayAbilityComponent::GameplayAbilityComponent() {}

GameplayAbilityComponent::~GameplayAbilityComponent() {}

// ---------------------------------------------------------------------------
// Pre-configuration properties
// ---------------------------------------------------------------------------

void GameplayAbilityComponent::set_role(Role p_role) {
	if (is_configured()) {
		return; // immutable once configured -- see class comment.
	}
	role = p_role;
}

void GameplayAbilityComponent::set_entity_id(int64_t p_id) {
	if (is_configured()) {
		return;
	}
	entity_id_value = p_id < 0 ? 0 : p_id;
}

void GameplayAbilityComponent::set_tick_rate(int p_tick_rate) {
	if (is_configured()) {
		return; // immutable once configured -- see class header's doc comment.
	}
	tick_rate = p_tick_rate > 0 ? p_tick_rate : int(ga::DEFAULT_TICK_RATE);
}

int64_t GameplayAbilityComponent::get_entity_id() const {
	if (component != nullptr) {
		return static_cast<int64_t>(component->entity().value);
	}
	return entity_id_value;
}

void GameplayAbilityComponent::set_tag_definitions(const TypedArray<GameplayTagDefinition> &p_tags) {
	if (is_configured()) {
		return;
	}
	tag_definitions = p_tags;
}

void GameplayAbilityComponent::set_attribute_definitions(const TypedArray<GameplayAttributeDefinition> &p_attributes) {
	if (is_configured()) {
		return;
	}
	attribute_definitions = p_attributes;
}

void GameplayAbilityComponent::set_effect_definitions(const TypedArray<GameplayEffectDefinition> &p_effects) {
	if (is_configured()) {
		return;
	}
	effect_definitions = p_effects;
}

void GameplayAbilityComponent::set_cue_definitions(const TypedArray<GameplayCueDefinition> &p_cues) {
	if (is_configured()) {
		return;
	}
	cue_definitions = p_cues;
}

void GameplayAbilityComponent::set_ability_definitions(const Array &p_abilities) {
	if (is_configured()) {
		return;
	}
	ability_definitions = p_abilities;
}

void GameplayAbilityComponent::set_target_data_schemas(const TypedArray<GameplayTargetDataSchema> &p_schemas) {
	if (is_configured()) {
		return;
	}
	target_data_schemas = p_schemas;
}

void GameplayAbilityComponent::set_definition_catalog(const Ref<GameplayDefinitionCatalog> &p_catalog) {
	if (is_configured()) {
		return;
	}
	definition_catalog = p_catalog;
}

// ---------------------------------------------------------------------------
// configure()
// ---------------------------------------------------------------------------

void GameplayAbilityComponent::emit_configure_finding(Array &r_findings, const String &p_severity,
		const String &p_field, const String &p_code, const String &p_message) const {
	Dictionary finding;
	finding["severity"] = p_severity;
	finding["resource_path"] = String();
	finding["field"] = p_field;
	finding["code"] = p_code;
	finding["message"] = p_message;
	r_findings.append(finding);
}

Array GameplayAbilityComponent::configure() {
	Array findings;
	// Deliberately `component != nullptr`, NOT `is_configured()`: the latter
	// also reports false while `quarantined` (Finding 5), and this guard
	// must NOT be fooled by that into thinking a quarantined-but-already-
	// built component is fresh -- re-registering this instance's OWN
	// definitions into its already-sealed registries would just fail every
	// entry with a wall of "already_exists"/"seal_failed" findings below
	// (harmless, but not a real rebuild). The documented recovery from
	// quarantine (`desync_rebuild_required`) is a FRESH `GameplayAbilityComponent`
	// instance, never this same one reused.
	if (component != nullptr) {
		emit_configure_finding(findings, "error", "", "already_configured",
				"configure() was already called; definitions are immutable for the session.");
		return findings;
	}

	// -----------------------------------------------------------------
	// Catalog resolution (task 1.2; design.md decision 1 "Use a unified
	// project definition catalog"). Resolution order: this component's own
	// explicit `definition_catalog` override, else the project setting
	// `gameplay_abilities/default_definition_catalog`, else no catalog at
	// all -- the legacy per-component arrays below then apply exactly as
	// before (task 1.4). Whichever source resolves supplies every
	// collection registered below; a catalog and populated legacy arrays
	// are never merged (see the conflict check immediately below) because
	// which property would "win" depends on authoring/registration order,
	// which this addon documents as unsupported
	// (specs/gameplay-definition-authoring/spec.md "Unambiguous Legacy
	// Definition Migration").
	Ref<GameplayDefinitionCatalog> resolved_catalog = definition_catalog;
	String catalog_source_label; // only meaningful when resolved_catalog is valid.
	if (resolved_catalog.is_valid()) {
		catalog_source_label = "an explicit component override";
	} else {
		const String default_catalog_path = String(ProjectSettings::get_singleton()->get_setting(
				"gameplay_abilities/default_definition_catalog", String()));
		if (!default_catalog_path.is_empty()) {
			// `Ref<Resource> -> Ref<GameplayDefinitionCatalog>` performs its
			// own `Object::cast_to` check (see godot-cpp's Ref::operator=),
			// so a missing file and a file that loads but is the wrong
			// Resource type both simply leave `resolved_catalog` null here --
			// one finding below covers both cases.
			const Ref<Resource> loaded = ResourceLoader::get_singleton()->load(default_catalog_path);
			resolved_catalog = loaded;
			if (resolved_catalog.is_null()) {
				emit_configure_finding(findings, "error", "definition_catalog", "catalog_load_failed",
						vformat("Project default catalog '%s' (gameplay_abilities/default_definition_catalog) "
										"failed to load or is not a GameplayDefinitionCatalog.",
								default_catalog_path));
				return findings; // nothing registered; no partial seal.
			}
			catalog_source_label = "the project default (gameplay_abilities/default_definition_catalog)";
		}
	}

	if (resolved_catalog.is_valid()) {
		// Task 1.4: a resolved catalog and ANY populated legacy definition
		// array is rejected outright, before touching a single registry,
		// rather than merged in whatever order this function happens to
		// visit properties -- see this class's own "Definitions ... become
		// immutable for the session" contract and
		// specs/gameplay-definition-authoring/spec.md's "Catalog and legacy
		// arrays are both configured" scenario.
		struct LegacyField {
			const char *name;
			int size;
		};
		const LegacyField legacy_fields[] = {
			{ "tag_definitions", int(tag_definitions.size()) },
			{ "attribute_definitions", int(attribute_definitions.size()) },
			{ "effect_definitions", int(effect_definitions.size()) },
			{ "cue_definitions", int(cue_definitions.size()) },
			{ "ability_definitions", int(ability_definitions.size()) },
			{ "target_data_schemas", int(target_data_schemas.size()) },
		};
		bool has_legacy_conflict = false;
		for (const LegacyField &field : legacy_fields) {
			if (field.size > 0) {
				has_legacy_conflict = true;
				emit_configure_finding(findings, "error", field.name, "catalog_legacy_conflict",
						vformat("'%s' has %d entr%s while a definition_catalog is also resolved; a component "
										"cannot mix a catalog with legacy per-component definition arrays.",
								String(field.name), field.size, field.size == 1 ? "y" : "ies"));
			}
		}
		if (has_legacy_conflict) {
			return findings; // nothing registered; no partial seal.
		}

		// Task 1.5: the catalog itself must validate cleanly BEFORE any
		// runtime registry is touched
		// (specs/gameplay-definition-authoring/spec.md: "component
		// configuration fails before any runtime registry is sealed").
		Ref<GameplayDefinitionValidator> catalog_validator;
		catalog_validator.instantiate();
		const Array catalog_findings = catalog_validator->validate_catalog(resolved_catalog);
		if (!GameplayDefinitionValidator::is_ok(catalog_findings)) {
			for (int i = 0; i < catalog_findings.size(); ++i) {
				findings.append(catalog_findings[i]);
			}
			return findings; // nothing registered; no partial seal.
		}

		// Task 1.2: a deterministic, observable record of which source
		// resolved. Only emitted when a catalog actually resolves -- the
		// legacy (no catalog) path below stays byte-for-byte identical to
		// its pre-catalog behavior, including an empty findings Array on
		// success, which several existing tests/examples already assert.
		emit_configure_finding(findings, "info", "definition_catalog", "catalog_resolved",
				vformat("Configured from %s: '%s'.", catalog_source_label, resolved_catalog->get_path()));
	}

	const TypedArray<GameplayTagDefinition> tags_source =
			resolved_catalog.is_valid() ? resolved_catalog->get_tag_definitions() : tag_definitions;
	const TypedArray<GameplayAttributeDefinition> attributes_source =
			resolved_catalog.is_valid() ? resolved_catalog->get_attribute_definitions() : attribute_definitions;
	const TypedArray<GameplayEffectDefinition> effects_source =
			resolved_catalog.is_valid() ? resolved_catalog->get_effect_definitions() : effect_definitions;
	const TypedArray<GameplayCueDefinition> cues_source =
			resolved_catalog.is_valid() ? resolved_catalog->get_cue_definitions() : cue_definitions;
	const TypedArray<GameplayTargetDataSchema> target_schemas_source =
			resolved_catalog.is_valid() ? resolved_catalog->get_target_data_schemas() : target_data_schemas;
	const TypedArray<GameplayTagReactionDefinition> reactions_source = resolved_catalog.is_valid()
			? resolved_catalog->get_tag_reactions()
			: TypedArray<GameplayTagReactionDefinition>();
	// `ability_definitions` (legacy) is a plain `Array` accepting either
	// Dictionary or GameplayAbilityDefinition entries (see this class's own
	// header comment); the catalog's collection is a
	// `TypedArray<GameplayAbilityDefinition>`. The two are different C++
	// types (a ternary between them is ambiguous -- both directions have an
	// implicit conversion), so this picks one explicitly rather than
	// through a shared expression.
	Array ability_entries_source = ability_definitions;
	if (resolved_catalog.is_valid()) {
		ability_entries_source = resolved_catalog->get_ability_definitions();
	}

	for (int i = 0; i < tags_source.size(); ++i) {
		const Ref<GameplayTagDefinition> tag = tags_source[i];
		if (tag.is_null()) {
			emit_configure_finding(findings, "error", vformat("tag_definitions[%d]", i), "null_resource", "Tag slot is empty.");
			continue;
		}
		ga::TagDefinitionDesc desc;
		desc.identifier = to_std(String(tag->get_identifier()));
		desc.description = to_std(tag->get_description());
		desc.source_label = to_std(tag->get_source_label());
		const ga::Status status = core_tags.register_tag(desc);
		if (!status.ok()) {
			emit_configure_finding(findings, "error", vformat("tag_definitions[%d]", i), "tag_registration_failed",
					vformat("Tag '%s' failed to register (code %d).", String(tag->get_identifier()), int(status.code)));
		}
	}
	const bool tags_sealed = core_tags.seal().ok();
	if (!tags_sealed) {
		emit_configure_finding(findings, "error", "tag_definitions", "seal_failed", "Failed to seal the tag registry.");
	}

	for (int i = 0; i < attributes_source.size(); ++i) {
		const Ref<GameplayAttributeDefinition> attribute = attributes_source[i];
		if (attribute.is_null()) {
			emit_configure_finding(findings, "error", vformat("attribute_definitions[%d]", i), "null_resource",
					"Attribute slot is empty.");
			continue;
		}
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = core_attributes.register_attribute(to_std(String(attribute->get_identifier())),
				attribute->get_default_base(), attribute->get_has_min(), attribute->get_min_value(),
				attribute->get_has_max(), attribute->get_max_value(), to_std(attribute->get_display_name()), unused_id);
		if (!status.ok()) {
			emit_configure_finding(findings, "error", vformat("attribute_definitions[%d]", i), "attribute_registration_failed",
					vformat("Attribute '%s' failed to register (code %d).", String(attribute->get_identifier()), int(status.code)));
		}
	}
	const bool attributes_sealed = core_attributes.seal().ok();
	if (!attributes_sealed) {
		emit_configure_finding(findings, "error", "attribute_definitions", "seal_failed",
				"Failed to seal the attribute registry.");
	}

	if (!tags_sealed || !attributes_sealed) {
		emit_configure_finding(findings, "error", "", "internal_error",
				"Skipped effect/ability registration because tags or attributes did not seal.");
		return findings;
	}

	for (int i = 0; i < cues_source.size(); ++i) {
		const Ref<GameplayCueDefinition> cue = cues_source[i];
		if (cue.is_null()) {
			emit_configure_finding(findings, "error", vformat("cue_definitions[%d]", i), "null_resource", "Cue slot is empty.");
			continue;
		}
		const ga::Status status = core_effects.register_cue(to_std(String(cue->get_identifier())));
		if (!status.ok()) {
			emit_configure_finding(findings, "error", vformat("cue_definitions[%d]", i), "cue_registration_failed",
					vformat("Cue '%s' failed to register (code %d).", String(cue->get_identifier()), int(status.code)));
		}
	}

	for (int i = 0; i < effects_source.size(); ++i) {
		const Ref<GameplayEffectDefinition> effect = effects_source[i];
		if (effect.is_null()) {
			emit_configure_finding(findings, "error", vformat("effect_definitions[%d]", i), "null_resource",
					"Effect slot is empty.");
			continue;
		}
		const ga::EffectDefinitionDesc desc = to_effect_desc(effect);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = core_effects.register_effect(desc, core_tags, core_attributes, unused_id);
		if (!status.ok()) {
			emit_configure_finding(findings, "error", vformat("effect_definitions[%d]", i), "effect_registration_failed",
					vformat("Effect '%s' failed to register (code %d).", String(effect->get_identifier()), int(status.code)));
		}
	}
	const bool effects_sealed = core_effects.seal().ok();
	if (!effects_sealed) {
		emit_configure_finding(findings, "error", "effect_definitions", "seal_failed", "Failed to seal the effect registry.");
	}

	if (!effects_sealed) {
		emit_configure_finding(findings, "error", "", "internal_error",
				"Skipped ability registration because the effect registry did not seal.");
		return findings;
	}

	// Typed target schemas are real sealed core definitions. Register and
	// seal them before abilities resolve their schema references so task,
	// coordinator, manifest, and network paths all share the exact same
	// canonical ids and behavior fields.
	std::map<std::string, std::pair<int64_t, int64_t>> schema_bounds_by_identifier;
	for (int i = 0; i < target_schemas_source.size(); ++i) {
		const Ref<GameplayTargetDataSchema> schema = target_schemas_source[i];
		if (schema.is_null()) {
			emit_configure_finding(findings, "error", vformat("target_data_schemas[%d]", i), "null_resource",
					"Target data schema slot is empty.");
			continue;
		}
		const ga::TargetSchemaDesc desc = schema->to_core_desc();
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status =
				core_target_schemas.register_schema(desc, unused_id);
		if (!status.ok()) {
			emit_configure_finding(findings, "error",
					vformat("target_data_schemas[%d]", i),
					"target_schema_registration_failed",
					vformat("Target data schema '%s' failed to register "
									"(code %d, diagnostic %d).",
							String(schema->get_identifier()),
							int(status.code), int(status.diagnostic)));
			continue;
		}
		schema_bounds_by_identifier[desc.identifier] = {
			int64_t(desc.max_entities),
			int64_t(desc.max_payload_bytes)
		};
	}
	const ga::Status target_schema_seal_status =
			core_target_schemas.seal();
	if (!target_schema_seal_status.ok()) {
		emit_configure_finding(findings, "error", "target_data_schemas",
				"seal_failed",
				"Failed to seal the typed target schema registry.");
		return findings;
	}

	// Ability entries accept either a Dictionary (mirroring
	// ga::AbilityDefinitionDesc field-for-field) or a GameplayAbilityDefinition
	// Resource directly (task 12.3's ergonomic follow-up) -- `set_ability_definitions`
	// stays a plain `Array` so both element shapes, or a mix, are accepted
	// unchanged.
	std::map<std::string, std::string> pending_ability_target_schema; // ability identifier -> schema identifier
	for (int i = 0; i < ability_entries_source.size(); ++i) {
		const Variant entry = ability_entries_source[i];
		ga::AbilityDefinitionDesc desc;
		std::string target_schema_identifier;
		if (entry.get_type() == Variant::DICTIONARY) {
			const Dictionary dict = entry;
			desc = to_ability_desc(dict);
			target_schema_identifier = to_std(String(dict.get("target_schema", String())));
		} else if (entry.get_type() == Variant::OBJECT) {
			const Ref<GameplayAbilityDefinition> resource = entry;
			if (resource.is_null()) {
				emit_configure_finding(findings, "error", vformat("ability_definitions[%d]", i), "invalid_argument",
						"Ability entry must be a Dictionary or GameplayAbilityDefinition.");
				continue;
			}
			desc = to_ability_desc_from_resource(resource);
			target_schema_identifier = to_std(String(resource->get_target_schema()));
		} else {
			emit_configure_finding(findings, "error", vformat("ability_definitions[%d]", i), "invalid_argument",
					"Ability entry must be a Dictionary or GameplayAbilityDefinition.");
			continue;
		}
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = core_abilities.register_ability(desc, core_tags, core_effects, unused_id);
		if (!status.ok()) {
			emit_configure_finding(findings, "error", vformat("ability_definitions[%d]", i), "ability_registration_failed",
					vformat("Ability '%s' failed to register (code %d).", String(desc.identifier.c_str()), int(status.code)));
			continue;
		}
		if (!target_schema_identifier.empty()) {
			if (schema_bounds_by_identifier.find(target_schema_identifier) == schema_bounds_by_identifier.end()) {
				emit_configure_finding(findings, "error", vformat("ability_definitions[%d]", i), "unknown_target_schema",
						vformat("Ability '%s' references unknown target_schema '%s'.", String(desc.identifier.c_str()),
								String(target_schema_identifier.c_str())));
			} else {
				pending_ability_target_schema[desc.identifier] = target_schema_identifier;
			}
		}
	}
	const bool abilities_sealed = core_abilities.seal().ok();
	if (!abilities_sealed) {
		emit_configure_finding(findings, "error", "ability_definitions", "seal_failed", "Failed to seal the ability registry.");
		return findings;
	}

	// Resolve each pending ability -> schema association now that ability ids
	// are stable (task 7.16).
	for (const auto &pending : pending_ability_target_schema) {
		const ga::DefinitionId ability_id = core_abilities.id_of(pending.first);
		if (ability_id == ga::INVALID_DEFINITION_ID) {
			continue; // registration already failed and was already reported above.
		}
		const auto bounds_it = schema_bounds_by_identifier.find(pending.second);
		if (bounds_it == schema_bounds_by_identifier.end()) {
			continue; // unknown reference already reported above.
		}
		TargetSchemaBounds bounds;
		bounds.identifier = String(pending.second.c_str());
		bounds.max_targets = bounds_it->second.first;
		bounds.max_payload_bytes = bounds_it->second.second;
		ability_target_schema_bounds[ability_id] = bounds;
	}

	// Task 5.1 (design.md decision 3 "Model reactions as immutable registered
	// definitions" / decision 6 "Execute only on authority and restore
	// without replay"): register the resolved catalog's reactions into a
	// sealed core `ga::TagReactionRegistry`, AFTER tags/attributes/effects
	// (and abilities) have already sealed above -- `register_reaction`
	// validates each operand tag and target effect against those two sealed
	// registries, exactly like an ability's own registration does. A legacy
	// (no catalog) component has an empty `reactions_source` (see this
	// function's own catalog-resolution block above), so this loop is a
	// no-op, `core_reactions` is left unsealed and unused, and
	// `reactions_ptr` stays `nullptr` -- byte-for-byte the pre-task-5.1
	// legacy behavior (`ga::AbilityComponent`'s own `p_reactions` parameter
	// defaults to `nullptr`). Any registration/seal failure here -- unknown
	// tag/effect reference, an invalid WHILE_PRESENT lifetime, or a static
	// cycle -- is surfaced as a configure finding with a resource-path-like
	// field and aborts BEFORE `component` is ever constructed, matching
	// every earlier registry's own "nothing registered; no partial seal"
	// contract (specs/gameplay-effects/spec.md "Reaction targets an unknown
	// effect" / "Two reaction effects form a granted-tag cycle": "no
	// component runtime is created from the catalog").
	const ga::TagReactionRegistry *reactions_ptr = nullptr;
	if (resolved_catalog.is_valid()) {
		for (int i = 0; i < reactions_source.size(); ++i) {
			const Ref<GameplayTagReactionDefinition> reaction = reactions_source[i];
			if (reaction.is_null()) {
				continue; // already reported by validate_catalog() before registration began.
			}
			const ga::TagReactionCanonicalDesc desc = to_reaction_desc(reaction);
			ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
			const ga::Status status = core_reactions.register_reaction(desc, core_tags, core_effects, unused_id);
			if (!status.ok()) {
				emit_configure_finding(findings, "error", vformat("tag_reactions[%d]", i), "reaction_registration_failed",
						vformat("Tag reaction '%s' failed to register (code %d).", String(reaction->get_identifier()), int(status.code)));
			}
		}
		ga::TagReactionCycleConflict cycle_conflict;
		const ga::Status reaction_seal_status = core_reactions.seal(core_tags, &cycle_conflict);
		if (!reaction_seal_status.ok()) {
			if (reaction_seal_status.diagnostic == ga::DiagnosticId::REACTION_CYCLE) {
				// Readable involved reaction/effect path, e.g.
				// "reaction.a (effect.a) -> reaction.b (effect.b) -> reaction.a".
				String path_text;
				for (int j = 0; j < int(cycle_conflict.reaction_path.size()); ++j) {
					if (j > 0) {
						path_text += " -> ";
					}
					path_text += String(cycle_conflict.reaction_path[j].c_str());
					if (j < int(cycle_conflict.effect_path.size())) {
						path_text += vformat(" (%s)", String(cycle_conflict.effect_path[j].c_str()));
					}
				}
				emit_configure_finding(findings, "error", "tag_reactions", "reaction_cycle",
						vformat("Tag reaction cycle detected: %s.", path_text));
			} else {
				emit_configure_finding(findings, "error", "tag_reactions", "seal_failed",
						"Failed to seal the tag reaction registry.");
			}
			return findings; // nothing registered downstream; no component runtime created.
		}
		reactions_ptr = &core_reactions;
	}

	component = std::make_unique<ga::AbilityComponent>(core_abilities, core_effects, core_attributes, core_tags,
			to_entity_id(entity_id_value), to_core_role(role), reactions_ptr);
	// Finding 5: this is the ONE place `quarantined` is ever cleared -- a
	// brand-new `component` was just built. Always false already for a
	// genuinely fresh instance (the member's own default); explicit here so
	// the invariant holds even if this exact instance were ever (re)used in
	// a way that had somehow set it (defense in depth, not a supported
	// "reconfigure a quarantined instance in place" path -- see the
	// `component != nullptr` guard above, which already prevents THIS
	// function from ever reaching this line on a quarantined instance,
	// since `component` is already non-null by the time quarantine could
	// ever have been set).
	quarantined = false;
	register_core_listeners();

	// Task 5.1: this component's tag container is genuinely empty at this
	// point (nothing above ever mutates `component->tags()` -- grants and
	// initial state are always a later, caller-driven step), so the core
	// constructor's own internal baselining (see `ga::AbilityComponent`'s
	// constructor) already established a correct, edge-free "everything
	// false" baseline. This explicit call is the documented seam anyway (a
	// cheap no-op today, and defense-in-depth against a future configure()
	// step that mutates tags before this line) so initial tag state can
	// never produce a spurious edge once real gameplay begins.
	component->reinitialize_tag_reaction_baselines();

	// Task 8.10: this component owns the prediction layer for a
	// ROLE_NETWORK_CLIENT session (see gameplay_ability_component.h's "C++
	// only collaborator seams" section for why ownership lives here rather
	// than on GameplayAbilityNetworkBridge -- this component already owns
	// every registry `ga::PredictingComponent`/`ga::PredictionReconciler`
	// need non-owning references to; the bridge only ever resolves a
	// `GameplayAbilityComponent*` by NodePath and has no registry access of
	// its own). Constructed unconditionally for this role (not gated on a
	// confirmed baseline -- `PredictingComponent::prediction_available`
	// already re-checks that per call against the bridge-owned
	// `ClientEventStream`, so "active only ... with a confirmed baseline" is
	// enforced per-request, not by delaying construction).
	if (to_core_role(role) == ga::ComponentRole::NETWORK_CLIENT) {
		predicting = std::make_unique<ga::PredictingComponent>(*component, core_abilities, core_effects);
		reconciler = std::make_unique<ga::PredictionReconciler>(*predicting);
		predicting->add_presentation_listener([this](const ga::PredictionPresentationEvent &p_event) {
			notify_prediction_phase(prediction_presentation_dict(p_event));
		});
	}

	// Content-manifest fingerprint (see get_content_manifest_fingerprint()'s
	// doc comment). Built once, here, over every sealed registry; failure to
	// contribute (should not happen -- every registry above already sealed)
	// simply leaves the fingerprint at 0, which will safely fail any
	// handshake comparison rather than silently reporting a bogus match.
	// Task 7.19: uses THIS component's own `tick_rate` (see set_tick_rate()'s
	// doc comment) -- previously hardcoded to `ga::DEFAULT_TICK_RATE`
	// regardless of what a session actually ran at, so the manifest's
	// documented tick-rate contribution was never exercised through the
	// Godot layer.
	{
		// A named intermediate, not `ManifestBuilder builder(std::uint32_t(tick_rate));`
		// directly -- that form parses as a function DECLARATION (C++'s "most
		// vexing parse": `std::uint32_t(tick_rate)` looks like a parenthesized
		// parameter name), not a variable definition.
		const std::uint32_t manifest_tick_rate = std::uint32_t(tick_rate);
		ga::ManifestBuilder builder(manifest_tick_rate);
		bool manifest_ok = core_tags.contribute_manifest(builder).ok();
		manifest_ok = core_attributes.contribute_manifest(builder).ok() && manifest_ok;
		manifest_ok = core_effects.contribute_manifest(builder).ok() && manifest_ok;
		manifest_ok = core_abilities.contribute_manifest(builder).ok() && manifest_ok;
		manifest_ok =
				core_target_schemas.contribute_manifest(builder).ok() &&
				manifest_ok;
		// Task 1.6/5.1: tag reactions contribute to the manifest manually
		// (via `ga::contribute_tag_reaction_manifest`) rather than through a
		// `core_*` registry's own `contribute_manifest`, because
		// `TagReactionRegistry` (unlike tags/attributes/effects/abilities)
		// only exists at all when a catalog resolved (see `reactions_ptr`
		// above) -- this loop instead walks `reactions_source` directly, the
		// SAME source the registration loop above just consumed, through
		// the SAME `to_reaction_desc` converter, so registration and
		// manifest contribution can never describe a reaction's canonical
		// fields differently. `reactions_source` is empty for every
		// legacy-path component, so this loop is then a no-op and today's
		// fingerprint for a component with no catalog is unaffected.
		for (int i = 0; i < reactions_source.size(); ++i) {
			const Ref<GameplayTagReactionDefinition> reaction = reactions_source[i];
			if (reaction.is_null()) {
				continue; // already reported by validate_catalog() before registration began.
			}
			manifest_ok = ga::contribute_tag_reaction_manifest(builder, to_reaction_desc(reaction)).ok() && manifest_ok;
		}
		if (manifest_ok) {
			ga::ContentManifest manifest;
			if (builder.build(manifest).ok()) {
				manifest_fingerprint = int64_t(manifest.fingerprint);
			}
		}
	}
	return findings;
}

// ---------------------------------------------------------------------------
// Signal-carrying record converters
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::activation_result_dict(const ga::ActivationResult &p_result) const {
	Dictionary d;
	d["status"] = status_dict(p_result.status);
	d["execution"] = int64_t(p_result.execution.value);
	d["cooldown_ready_tick"] = int64_t(p_result.cooldown_ready_tick);
	d["queued"] = p_result.queued;
	// Task 6.13: every accepted-but-not-locally-applicable remote-target hook
	// command this commit produced -- see `apply_pending_remote_effect`'s own
	// doc comment for the supported way to apply one.
	d["pending_remote_effects"] = pending_remote_effects_array(p_result.pending_remote_effects);
	return d;
}

Dictionary GameplayAbilityComponent::pending_remote_effect_dict(const ga::PendingRemoteEffectCommand &p_command) const {
	Dictionary d;
	d["source"] = int64_t(p_command.source.value);
	d["target"] = int64_t(p_command.target.value);
	d["effect_definition"] = int64_t(p_command.effect_definition);
	d["effect_identifier"] = effect_identifier_of(p_command.effect_definition);
	d["level"] = p_command.level;
	Array set_by_caller;
	for (const ga::SetByCallerMagnitude &magnitude : p_command.set_by_caller) {
		Dictionary field;
		field["field"] = String(magnitude.field.c_str());
		field["value"] = ga::fixed_to_double(magnitude.value);
		set_by_caller.push_back(field);
	}
	d["set_by_caller"] = set_by_caller;
	d["provenance"] = int(p_command.provenance);
	d["prediction_key"] = int64_t(p_command.prediction_key.value);
	d["originating_spec"] = int64_t(p_command.originating_spec.value);
	d["originating_execution"] = int64_t(p_command.originating_execution.value);
	d["tick"] = int64_t(p_command.tick);
	return d;
}

Array GameplayAbilityComponent::pending_remote_effects_array(const std::vector<ga::PendingRemoteEffectCommand> &p_commands) const {
	Array result;
	for (const ga::PendingRemoteEffectCommand &command : p_commands) {
		result.push_back(pending_remote_effect_dict(command));
	}
	return result;
}

bool GameplayAbilityComponent::build_pending_remote_effect_command(const Dictionary &p_command, ga::PendingRemoteEffectCommand &r_command) const {
	if (!is_configured() || !p_command.has("target") || !p_command.has("effect_identifier")) {
		return false;
	}
	ga::PendingRemoteEffectCommand out;
	out.source = to_entity_id(int64_t(p_command.get("source", 0)));
	out.target = to_entity_id(int64_t(p_command["target"]));
	out.effect_definition = resolve_effect_definition_id(to_std(String(p_command["effect_identifier"])));
	if (out.effect_definition == ga::INVALID_DEFINITION_ID) {
		return false;
	}
	out.level = int(p_command.get("level", 1));
	// Finding 6d: shared fail-closed converter (see its own doc comment) --
	// this call site used to silently truncate at MAX_SET_BY_CALLER and
	// substitute a zero magnitude for a value that failed quantization.
	if (p_command.has("set_by_caller")) {
		const Array fields = p_command["set_by_caller"];
		if (!parse_set_by_caller_fields(fields, out.set_by_caller)) {
			return false;
		}
	}
	out.provenance = to_provenance(int(p_command.get("provenance", int(PROVENANCE_AUTHORITATIVE))));
	out.prediction_key = to_prediction_key(int64_t(p_command.get("prediction_key", 0)));
	out.originating_spec = to_spec_id(int64_t(p_command.get("originating_spec", 0)));
	out.originating_execution = to_execution_id(int64_t(p_command.get("originating_execution", 0)));
	out.tick = static_cast<ga::Tick>(int64_t(p_command.get("tick", 0)));
	r_command = out;
	return true;
}

Dictionary GameplayAbilityComponent::cancellation_result_dict(const ga::CancellationResult &p_result) {
	Dictionary d;
	d["status"] = status_dict(p_result.status);
	d["execution"] = int64_t(p_result.execution.value);
	return d;
}

String GameplayAbilityComponent::ability_identifier_of(ga::DefinitionId p_id) const {
	const ga::AbilityDefinition *def = core_abilities.find(p_id);
	return def != nullptr ? String(def->identifier.c_str()) : String();
}

String GameplayAbilityComponent::effect_identifier_of(ga::DefinitionId p_id) const {
	const ga::EffectDefinition *def = core_effects.find(p_id);
	return def != nullptr ? String(def->identifier.c_str()) : String();
}

String GameplayAbilityComponent::tag_identifier_of(ga::DefinitionId p_id) const {
	const ga::TagDefinition *def = core_tags.definition(p_id);
	return def != nullptr ? String(def->identifier.c_str()) : String();
}

String GameplayAbilityComponent::attribute_identifier_of(ga::DefinitionId p_id) const {
	const ga::AttributeDefinition *def = core_attributes.find(p_id);
	return def != nullptr ? String(def->identifier.c_str()) : String();
}

Dictionary GameplayAbilityComponent::grant_dict(const ga::AbilityGrant &p_grant) const {
	Dictionary d;
	d["spec"] = int64_t(p_grant.spec.value);
	d["ability"] = int64_t(p_grant.ability);
	d["ability_identifier"] = ability_identifier_of(p_grant.ability);
	d["level"] = p_grant.level;
	d["input_id"] = String(p_grant.input_id.c_str());
	d["revoked"] = p_grant.revoked;
	d["cooldown_handle"] = int64_t(p_grant.cooldown_handle.value);
	d["last_command_sequence"] = int64_t(p_grant.last_command_sequence.value);
	d["revision"] = int64_t(p_grant.revision);
	return d;
}

Dictionary GameplayAbilityComponent::execution_dict(const ga::ActiveExecution &p_execution) const {
	Dictionary d;
	d["id"] = int64_t(p_execution.id.value);
	d["spec"] = int64_t(p_execution.spec.value);
	d["ability"] = int64_t(p_execution.ability);
	d["ability_identifier"] = ability_identifier_of(p_execution.ability);
	d["phase"] = int(p_execution.phase);
	d["begin_tick"] = int64_t(p_execution.begin_tick);
	d["commit_tick"] = int64_t(p_execution.commit_tick);
	PackedInt64Array targets;
	for (ga::EntityId target : p_execution.targets) {
		targets.push_back(int64_t(target.value));
	}
	d["targets"] = targets;
	d["provenance"] = int(p_execution.provenance);
	d["prediction_key"] = int64_t(p_execution.prediction_key.value);
	d["revision"] = int64_t(p_execution.revision);
	return d;
}

Dictionary GameplayAbilityComponent::ability_task_request_dict(
		const ga::AbilityTaskRequest &p_request) const {
	Dictionary d;
	d["kind"] = int(p_request.kind);
	d["has_deadline"] = p_request.has_deadline;
	d["deadline_tick"] =
			p_request.has_deadline ? int64_t(p_request.deadline_tick)
								   : int64_t(-1);
	d["visibility"] = int(p_request.visibility);
	d["prediction_policy"] = int(p_request.prediction_policy);
	d["wait_ticks"] = int64_t(p_request.wait_ticks);
	d["gameplay_event_tag"] =
			tag_identifier_of(p_request.gameplay_event_tag);
	d["gameplay_event_tag_id"] =
			int64_t(p_request.gameplay_event_tag);
	d["gameplay_event_match"] = int(p_request.gameplay_event_match);
	d["tag_query_hash"] = int64_t(p_request.tag_query.hash());
	d["tag_edge"] = int(p_request.tag_edge);
	d["complete_if_already_satisfied"] =
			p_request.complete_if_already_satisfied;
	d["logical_input"] = tag_identifier_of(p_request.logical_input);
	d["logical_input_id"] = int64_t(p_request.logical_input);
	d["logical_phase"] = int(p_request.logical_phase);
	d["authority_prediction_key"] =
			int64_t(p_request.authority_prediction.value);
	d["target_schema"] = int64_t(p_request.target_schema);
	return d;
}

Dictionary GameplayAbilityComponent::active_ability_task_dict(
		const ga::ActiveAbilityTask &p_task) const {
	Dictionary d;
	d["task"] = int64_t(p_task.handle.value);
	d["owner"] = int64_t(p_task.owner.value);
	d["execution"] = int64_t(p_task.execution.value);
	d["spec"] = int64_t(p_task.spec.value);
	d["ability"] = int64_t(p_task.ability);
	d["ability_identifier"] = ability_identifier_of(p_task.ability);
	d["request"] = ability_task_request_dict(p_task.request);
	d["start_tick"] = int64_t(p_task.start_tick);
	d["due_tick"] = p_task.due_tick == ga::INVALID_TICK
			? int64_t(-1)
			: int64_t(p_task.due_tick);
	d["last_tag_truth"] = p_task.last_tag_truth;
	d["last_input_sequence"] =
			int64_t(p_task.last_input_sequence.value);
	d["provenance"] = int(p_task.provenance);
	d["prediction_key"] = int64_t(p_task.prediction_key.value);
	return d;
}

Dictionary GameplayAbilityComponent::ability_task_event_dict(
		const ga::AbilityTaskEvent &p_event) const {
	Dictionary d;
	d["task"] = int64_t(p_event.task.value);
	d["owner"] = int64_t(p_event.owner.value);
	d["execution"] = int64_t(p_event.execution.value);
	d["spec"] = int64_t(p_event.spec.value);
	d["ability"] = int64_t(p_event.ability);
	d["ability_identifier"] = ability_identifier_of(p_event.ability);
	d["kind"] = int(p_event.kind);
	d["outcome"] = int(p_event.outcome);
	d["cancel_reason"] = int(p_event.cancel_reason);
	d["status"] = status_dict(p_event.status);
	d["tick"] = int64_t(p_event.tick);
	d["provenance"] = int(p_event.provenance);
	d["prediction_key"] = int64_t(p_event.prediction_key.value);
	d["restored"] = p_event.restored;
	d["matched_definition"] =
			int64_t(p_event.matched_definition);
	d["matched_identifier"] =
			tag_identifier_of(p_event.matched_definition);
	d["instigator"] = int64_t(p_event.instigator.value);
	d["target"] = int64_t(p_event.target.value);
	d["magnitude"] = ga::fixed_to_double(p_event.magnitude);
	d["payload_tag"] = int64_t(p_event.payload_tag);
	d["logical_phase"] = int(p_event.logical_phase);
	d["command_sequence"] =
			int64_t(p_event.command_sequence.value);
	d["target_session"] = int64_t(p_event.target_session.value);
	d["target_context"] =
			target_effect_context_dict(p_event.target_context);
	return d;
}

Dictionary GameplayAbilityComponent::target_effect_context_dict(
		const ga::TargetEffectContext &p_context) const {
	Dictionary d;
	if (!p_context.present) {
		return d;
	}
	d["schema_id"] = int64_t(p_context.schema);
	d["schema_version"] = int(p_context.schema_version);
	d["source"] = int64_t(p_context.source.value);
	d["target"] = int64_t(p_context.target.value);
	d["ability"] = int64_t(p_context.ability);
	d["execution"] = int64_t(p_context.execution.value);
	d["session"] = int64_t(p_context.session.value);
	d["authority_tick"] = int64_t(p_context.authority_tick);
	d["target_rank"] = int(p_context.target_rank);
	d["accepted"] = p_context.accepted;
	d["target_status"] = status_dict(p_context.target_status);
	d["visibility"] = int(p_context.visibility);
	const ga::TargetSchema *schema =
			core_target_schemas.find(p_context.schema);
	const int64_t coordinate_scale = schema != nullptr ?
			schema->desc.coordinate_scale :
			1000000;
	const int dimension = schema != nullptr ?
			static_cast<int>(schema->desc.dimension) :
			0;
	d["canonical_intent"] = GameplayTargetValue::from_core(
			p_context.canonical_intent, coordinate_scale, dimension);
	d["validated_result"] = GameplayTargetValue::from_core(
			p_context.validated_result, coordinate_scale, dimension);
	return d;
}

Dictionary GameplayAbilityComponent::active_effect_dict(const ga::ActiveEffect &p_effect) const {
	Dictionary d;
	d["definition"] = int64_t(p_effect.definition);
	d["definition_identifier"] = effect_identifier_of(p_effect.definition);
	d["handle"] = int64_t(p_effect.handle.value);
	d["source"] = int64_t(p_effect.source.value);
	d["target"] = int64_t(p_effect.target.value);
	d["stack_count"] = int64_t(p_effect.stack_count);
	d["start_tick"] = int64_t(p_effect.start_tick);
	// `end_tick`/`next_period_tick` use the SAME `INVALID_TICK -> -1` cast
	// convention `execution_dict`'s `commit_tick` already established --
	// INVALID_TICK is `UINT64_MAX` (ga_tick.h), so a direct cast to int64_t
	// yields -1, meaning "never" (no end tick / not periodic) without a
	// separate boolean flag to keep in sync.
	d["end_tick"] = int64_t(p_effect.end_tick);
	d["has_period"] = p_effect.has_period;
	d["next_period_tick"] = int64_t(p_effect.next_period_tick);
	// Remaining duration in ticks as of THIS component's own current tick
	// (see `get_current_tick()`): -1 for an effect with no end tick
	// (INFINITE, or a DURATION effect whose end tick is otherwise unknown);
	// 0 once due/past due but not yet processed by `advance_to`.
	int64_t remaining = -1;
	if (p_effect.end_tick != ga::INVALID_TICK) {
		remaining = p_effect.end_tick > current_tick ? int64_t(p_effect.end_tick - current_tick) : 0;
	}
	d["remaining_duration"] = remaining;
	d["revision"] = int64_t(p_effect.revision);
	d["target_context"] =
			target_effect_context_dict(p_effect.target_context);
	return d;
}

Dictionary GameplayAbilityComponent::lifecycle_event_dict(const ga::AbilityLifecycleEvent &p_event) const {
	Dictionary d;
	d["id"] = int64_t(p_event.id.value);
	d["kind"] = int(p_event.kind);
	d["owner"] = int64_t(p_event.owner.value);
	d["spec"] = int64_t(p_event.spec.value);
	d["ability"] = int64_t(p_event.ability);
	d["ability_identifier"] = ability_identifier_of(p_event.ability);
	d["execution"] = int64_t(p_event.execution.value);
	d["phase"] = int(p_event.phase);
	d["end_reason"] = int(p_event.end_reason);
	d["status"] = status_dict(p_event.status);
	d["tick"] = int64_t(p_event.tick);
	d["transaction"] = int64_t(p_event.transaction.value);
	d["provenance"] = int(p_event.provenance);
	d["prediction_key"] = int64_t(p_event.prediction_key.value);
	d["cleaned_task_count"] = int64_t(p_event.cleaned_task_count);
	return d;
}

Dictionary GameplayAbilityComponent::diagnostic_event_dict(const ga::AbilityDiagnosticEvent &p_event) {
	Dictionary d;
	d["kind"] = int(p_event.kind);
	d["owner"] = int64_t(p_event.owner.value);
	d["spec"] = int64_t(p_event.spec.value);
	d["execution"] = int64_t(p_event.execution.value);
	d["status"] = status_dict(p_event.status);
	d["tick"] = int64_t(p_event.tick);
	return d;
}

Dictionary GameplayAbilityComponent::attribute_change_dict(const ga::AttributeChangeRecord &p_record) {
	Dictionary d;
	d["attribute"] = int64_t(p_record.attribute);
	d["old_base"] = ga::fixed_to_double(p_record.old_base);
	d["new_base"] = ga::fixed_to_double(p_record.new_base);
	d["old_current"] = ga::fixed_to_double(p_record.old_current);
	d["new_current"] = ga::fixed_to_double(p_record.new_current);
	d["requested_current"] = ga::fixed_to_double(p_record.requested_current);
	d["revision"] = int64_t(p_record.revision);
	d["transaction"] = int64_t(p_record.transaction.value);
	d["provenance"] = int(p_record.provenance);
	return d;
}

Dictionary GameplayAbilityComponent::tag_change_dict(const ga::TagChangeRecord &p_record) {
	Dictionary d;
	d["tag"] = int64_t(p_record.tag);
	d["source"] = int64_t(p_record.source.value);
	d["added"] = p_record.added;
	d["owner_count_after"] = int64_t(p_record.owner_count_after);
	d["revision_after"] = int64_t(p_record.revision_after);
	return d;
}

Dictionary GameplayAbilityComponent::effect_lifecycle_dict(const ga::EffectLifecycleEvent &p_event) const {
	Dictionary d;
	d["id"] = int64_t(p_event.id.value);
	d["kind"] = int(p_event.kind);
	d["definition"] = int64_t(p_event.definition);
	d["definition_identifier"] = effect_identifier_of(p_event.definition);
	d["handle"] = int64_t(p_event.handle.value);
	d["source"] = int64_t(p_event.source.value);
	d["target"] = int64_t(p_event.target.value);
	d["stack_count_after"] = int64_t(p_event.stack_count_after);
	d["tick"] = int64_t(p_event.tick);
	d["transaction"] = int64_t(p_event.transaction.value);
	d["removal_reason"] = int(p_event.removal_reason);
	d["provenance"] = int(p_event.provenance);
	d["has_hook_result"] = p_event.has_hook_result;
	d["hook_result"] = ga::fixed_to_double(p_event.hook_result);
	d["target_context"] =
			target_effect_context_dict(p_event.target_context);
	return d;
}

Dictionary GameplayAbilityComponent::effect_cue_dict(const ga::EffectCueEvent &p_event) const {
	Dictionary d;
	d["id"] = int64_t(p_event.id.value);
	d["target"] = int64_t(p_event.dedup.target.value);
	d["definition"] = int64_t(p_event.dedup.definition);
	d["definition_identifier"] = effect_identifier_of(p_event.dedup.definition);
	d["handle"] = int64_t(p_event.dedup.handle.value);
	d["occurrence"] = int64_t(p_event.dedup.occurrence);
	d["prediction_key"] = int64_t(p_event.prediction_key.value);
	d["phase"] = int(p_event.phase);
	d["source"] = int64_t(p_event.source.value);
	d["tick"] = int64_t(p_event.tick);
	PackedStringArray cues;
	for (const std::string &id : p_event.cue_identifiers) {
		cues.push_back(String(id.c_str()));
	}
	d["cue_identifiers"] = cues;
	d["target_context"] =
			target_effect_context_dict(p_event.target_context);
	return d;
}

void GameplayAbilityComponent::register_core_listeners() {
	component->add_ability_listener([this](const ga::AbilityLifecycleEvent &p_event, ga::NotificationQueue &) {
		const Dictionary d = lifecycle_event_dict(p_event);
		switch (p_event.kind) {
			case ga::AbilityLifecycleKind::GRANTED:
				emit_signal("ability_granted", d);
				break;
			case ga::AbilityLifecycleKind::REVOKED:
				emit_signal("ability_revoked", d);
				break;
			case ga::AbilityLifecycleKind::REQUESTED:
				emit_signal("activation_requested", d);
				break;
			case ga::AbilityLifecycleKind::PHASE_CHANGED:
				emit_signal("activation_phase_changed", d);
				break;
			case ga::AbilityLifecycleKind::COMMITTED:
				emit_signal("activation_committed", d);
				break;
			case ga::AbilityLifecycleKind::ENDED:
				emit_signal("activation_ended", d);
				break;
			case ga::AbilityLifecycleKind::CANCELLED:
				emit_signal("activation_cancelled", d);
				break;
			case ga::AbilityLifecycleKind::FAILED:
				emit_signal("activation_failed", d);
				break;
			case ga::AbilityLifecycleKind::SNAPSHOT_RESTORED:
				emit_signal("ability_snapshot_restored", d);
				break;
		}
	});

	component->add_diagnostic_listener([this](const ga::AbilityDiagnosticEvent &p_event) {
		emit_signal("diagnostics_reported", diagnostic_event_dict(p_event));
	});

	component->add_attribute_listener([this](const ga::AttributeChangeRecord &p_record, ga::NotificationQueue &) {
		emit_signal("attribute_changed", attribute_change_dict(p_record));
	});

	component->add_tag_listener([this](const ga::TagChangeRecord &p_record) {
		emit_signal("tag_changed", tag_change_dict(p_record));
	});

	component->add_effect_lifecycle_listener([this](const ga::EffectLifecycleEvent &p_event, ga::NotificationQueue &) {
		emit_signal("effect_lifecycle_changed", effect_lifecycle_dict(p_event));
	});

	component->add_effect_cue_listener([this](const ga::EffectCueEvent &p_event, ga::NotificationQueue &) {
		emit_signal("effect_cue_triggered", effect_cue_dict(p_event));
	});

	component->add_ability_task_listener(
			[this](const ga::AbilityTaskEvent &p_event,
					ga::NotificationQueue &) {
				emit_signal("ability_task_event",
						ability_task_event_dict(p_event));
			});
}

// ---------------------------------------------------------------------------
// Attribute initialization
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::initialize_attribute(const String &p_identifier, bool p_has_override, double p_override_base, int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	const ga::DefinitionId id = core_attributes.id_of(to_std(p_identifier));
	if (id == ga::INVALID_DEFINITION_ID) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::UNKNOWN_ATTRIBUTE));
		return result;
	}
	ga::Fixed override_value = ga::Fixed::zero();
	if (p_has_override) {
		const ga::Status quantize_status = ga::fixed_quantize(p_override_base, override_value);
		if (!quantize_status.ok()) {
			result["status"] = status_dict(quantize_status);
			return result;
		}
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));

	ga::Transaction txn(attribute_init_transaction_allocator.allocate(), static_cast<ga::Tick>(p_tick));
	const ga::Status init_status = component->attributes().initialize_attribute(id, p_has_override, override_value, txn, component->notification_queue());
	ga::TransactionScope scope(txn, component->notification_queue());
	if (!init_status.ok()) {
		scope.fail(init_status);
	}
	const ga::Status commit_status = scope.finish();
	component->notification_queue().dispatch();
	// Review fix (Wave 5, task 6.3 conformance): every OTHER mutating entry
	// point in this file delegates to a core `AbilityComponent`-level method
	// that already calls `flush_change_tracking()` itself (see that method's
	// own doc comment, ga_ability_component.h/.cpp) -- this is the ONE
	// mutating call in this whole file that instead drives `attributes()`
	// directly through its own `Transaction`/`notification_queue().dispatch()`,
	// exactly the "low-level escape hatch" that same doc comment says MUST
	// flush explicitly afterward. Without this, an attribute initialized
	// through this Godot-facing entry point never advanced its audience
	// revision on its own -- the dirty fact sat PENDING until some LATER,
	// unrelated mutation happened to flush it (grant/activate/etc.), so a
	// peer already caught up on deltas at the moment this ran would never
	// receive the initialization through the granular delta path at all,
	// only through a fresh full snapshot. Found by task 6.3's own multipeer
	// delta-parity conformance checkpoint (test_delta_conformance.gd), which
	// forced exactly this ordering (initialize, then settle, then compare a
	// delta-path digest against a snapshot-path one at the same checkpoint)
	// and caught the divergence directly.
	if (commit_status.ok()) {
		component->flush_change_tracking();
	}
	result["status"] = status_dict(commit_status);
	return result;
}

// ---------------------------------------------------------------------------
// Grants
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::grant_ability(const String &p_identifier, int p_level, const String &p_input_id, int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		result["spec"] = int64_t(0);
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	const ga::DefinitionId ability_id = core_abilities.id_of(to_std(p_identifier));
	ga::AbilitySpecId spec = ga::INVALID_ABILITY_SPEC_ID;
	ga::Status status;
	if (ability_id == ga::INVALID_DEFINITION_ID) {
		status = ga::make_status(ga::StatusCode::UNKNOWN_ABILITY);
	} else {
		status = component->grant_ability(ability_id, p_level, to_std(p_input_id), static_cast<ga::Tick>(p_tick), spec);
	}
	result["status"] = status_dict(status);
	result["spec"] = int64_t(spec.value);
	return result;
}

Dictionary GameplayAbilityComponent::revoke_ability(int64_t p_spec, int64_t p_tick, Provenance p_provenance) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	const ga::Status status = component->revoke_ability(to_spec_id(p_spec), static_cast<ga::Tick>(p_tick), to_provenance(p_provenance));
	result["status"] = status_dict(status);
	return result;
}

bool GameplayAbilityComponent::has_grant(int64_t p_spec) const {
	return is_configured() && component->has_grant(to_spec_id(p_spec));
}

Dictionary GameplayAbilityComponent::get_grant(int64_t p_spec) const {
	if (!is_configured()) {
		return Dictionary();
	}
	const ga::AbilityGrant *grant = component->find_grant(to_spec_id(p_spec));
	return grant != nullptr ? grant_dict(*grant) : Dictionary();
}

PackedInt64Array GameplayAbilityComponent::granted_specs() const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::AbilitySpecId spec : component->granted_specs()) {
		result.push_back(int64_t(spec.value));
	}
	return result;
}

int64_t GameplayAbilityComponent::ability_id_of(const String &p_identifier) const {
	return int64_t(core_abilities.id_of(to_std(p_identifier)));
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

// Finding 6d: see this method's own header doc comment. `parsed` is only
// assigned into `r_out` on full success -- a rejected array never leaves
// `r_out` partially filled, matching `build_activation_request`'s existing
// "leaves r_request untouched" convention.
bool GameplayAbilityComponent::parse_set_by_caller_fields(const Array &p_fields, std::vector<ga::SetByCallerMagnitude> &r_out) {
	if (p_fields.size() > int(ga::MAX_SET_BY_CALLER)) {
		return false;
	}
	std::vector<ga::SetByCallerMagnitude> parsed;
	parsed.reserve(p_fields.size());
	for (int i = 0; i < p_fields.size(); ++i) {
		const Dictionary entry = p_fields[i];
		ga::SetByCallerMagnitude magnitude;
		magnitude.field = to_std(String(entry.get("field", String())));
		ga::Fixed quantized = ga::Fixed::zero();
		if (!ga::fixed_quantize(double(entry.get("value", 0.0)), quantized).ok()) {
			return false;
		}
		magnitude.value = quantized;
		parsed.push_back(magnitude);
	}
	r_out = std::move(parsed);
	return true;
}

bool GameplayAbilityComponent::build_activation_request(const Dictionary &p_request, ga::ActivationRequest &r_request) const {
	if (!p_request.has("spec")) {
		return false;
	}
	r_request.spec = to_spec_id(int64_t(p_request["spec"]));

	if (p_request.has("targets")) {
		const Variant targets_variant = p_request["targets"];
		if (targets_variant.get_type() == Variant::PACKED_INT64_ARRAY) {
			const PackedInt64Array targets = targets_variant;
			if (targets.size() > int(ga::MAX_TARGETS_PER_COMMAND)) {
				return false;
			}
			for (int i = 0; i < targets.size(); ++i) {
				r_request.targets.push_back(to_entity_id(targets[i]));
			}
		} else if (targets_variant.get_type() == Variant::ARRAY) {
			const Array targets = targets_variant;
			if (targets.size() > int(ga::MAX_TARGETS_PER_COMMAND)) {
				return false;
			}
			for (int i = 0; i < targets.size(); ++i) {
				r_request.targets.push_back(to_entity_id(int64_t(targets[i])));
			}
		}
	}

	// Finding 6d: shared fail-closed converter (see its own doc comment) --
	// this call site was already the ONE correct (reject, never truncate)
	// implementation among the four this addon had; it now delegates to the
	// same helper the other two call sites use, so there is exactly one
	// implementation of this policy instead of three copies that happened to
	// agree only here.
	if (p_request.has("set_by_caller")) {
		const Array fields = p_request["set_by_caller"];
		if (!parse_set_by_caller_fields(fields, r_request.set_by_caller)) {
			return false;
		}
	}

	r_request.command_sequence = to_command_seq(int64_t(p_request.get("command_sequence", 0)));
	r_request.provenance = to_provenance(int(p_request.get("provenance", int(PROVENANCE_AUTHORITATIVE))));
	r_request.prediction_key = to_prediction_key(int64_t(p_request.get("prediction_key", 0)));
	return true;
}

ga::Status GameplayAbilityComponent::validate_activation_request_schema(const ga::ActivationRequest &p_request) const {
	if (const ga::AbilityGrant *grant = component->find_grant(p_request.spec)) {
		return validate_target_data_schema(ability_identifier_of(grant->ability), p_request.targets, p_request.set_by_caller);
	}
	return ga::ok_status();
}

Dictionary GameplayAbilityComponent::request_activation(const Dictionary &p_request, int64_t p_tick) {
	if (!is_configured()) {
		return activation_result_dict(ga::ActivationResult{ ga::make_status(ga::StatusCode::NOT_SUPPORTED) });
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	ga::ActivationRequest request;
	if (!build_activation_request(p_request, request)) {
		return activation_result_dict(ga::ActivationResult{ ga::make_status(ga::StatusCode::INVALID_ARGUMENT) });
	}
	// Task 7.20: enforce this ability's own declared target-data schema HERE
	// too, not just on the networked RPC validation path (see
	// `validate_activation_request_schema`'s own doc comment) -- rejected
	// BEFORE the core ever sees this request, so no cost/cooldown/tag is
	// ever paid for a schema-violating direct/offline activation.
	const ga::Status schema_status = validate_activation_request_schema(request);
	if (!schema_status.ok()) {
		return activation_result_dict(ga::ActivationResult{ schema_status });
	}
	return activation_result_dict(component->request_activation(request, static_cast<ga::Tick>(p_tick)));
}

Array GameplayAbilityComponent::process_activation_batch(const Array &p_requests, int64_t p_tick) {
	Array results;
	if (!is_configured()) {
		return results;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));

	// Order-preservation invariant (pre-existing, unrelated to task 7.20):
	// `results` must appear in the SAME relative order as their originating
	// `p_requests` entries. A malformed entry that fails
	// `build_activation_request` is dropped entirely -- no result at all --
	// exactly as before this task. Task 7.20 adds a SECOND way an entry can
	// be resolved without ever reaching the core (a schema violation); that
	// result is computed eagerly but spliced back into its ORIGINAL slot
	// below, rather than appended immediately, so it can never appear before
	// an earlier, still-pending valid request's own (later-computed) result.
	std::vector<Variant> ordered_results;
	ordered_results.reserve(p_requests.size());
	std::vector<ga::ActivationRequest> requests;
	requests.reserve(p_requests.size());
	// Parallel to `requests`: the `ordered_results` slot each entry's
	// eventual core result belongs at.
	std::vector<std::size_t> core_result_slots;
	core_result_slots.reserve(p_requests.size());

	for (int i = 0; i < p_requests.size(); ++i) {
		ga::ActivationRequest request;
		if (!build_activation_request(p_requests[i], request)) {
			continue;
		}
		// Task 7.20: same schema enforcement as `request_activation` above,
		// applied per-request -- a schema-violating request is resolved
		// right here and never reaches the core's own batch call below,
		// exactly like a standalone `request_activation` call would reject
		// it.
		const ga::Status schema_status = validate_activation_request_schema(request);
		if (!schema_status.ok()) {
			ordered_results.push_back(activation_result_dict(ga::ActivationResult{ schema_status }));
			continue;
		}
		core_result_slots.push_back(ordered_results.size());
		ordered_results.push_back(Variant()); // placeholder -- filled in from core_results below.
		requests.push_back(request);
	}

	// `core_results[i]` lines up with `core_result_slots[i]` (i.e. this
	// method never reorders `requests` relative to how it built
	// `core_result_slots` above) ONLY because
	// `ga::AbilityComponent::process_activation_batch`'s own internal
	// stable_sort-by-(command_sequence, spec) is a no-op whenever a batch's
	// command sequences are already non-decreasing in submission order --
	// the case every caller of THIS method relies on. `core_results.size()`
	// always equals `requests.size()` (the core produces exactly one result
	// per request it was given), so the two vectors are always the same
	// length here.
	const std::vector<ga::ActivationResult> core_results = component->process_activation_batch(requests, static_cast<ga::Tick>(p_tick));
	for (std::size_t i = 0; i < core_results.size() && i < core_result_slots.size(); ++i) {
		ordered_results[core_result_slots[i]] = activation_result_dict(core_results[i]);
	}

	for (const Variant &result : ordered_results) {
		results.append(result);
	}
	return results;
}

Dictionary GameplayAbilityComponent::commit_activation(int64_t p_execution, int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	// Task 6.13: this Godot-facing call always supplies a destination for any
	// remote command the commit produces, so it can never trigger
	// `PENDING_REMOTE_EFFECT_DROPPED` -- exactly like `request_activation`'s
	// auto-commit path (see `ga::AbilityComponent::commit_execution_immediate`'s
	// own doc comment).
	std::vector<ga::PendingRemoteEffectCommand> pending_remote_effects;
	result["status"] = status_dict(component->commit_activation(to_execution_id(p_execution), static_cast<ga::Tick>(p_tick), &pending_remote_effects));
	result["pending_remote_effects"] = pending_remote_effects_array(pending_remote_effects);
	return result;
}

Dictionary GameplayAbilityComponent::apply_pending_remote_effect(const Dictionary &p_command, GameplayAbilityComponent *p_source, int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		result["handle"] = int64_t(0);
		return result;
	}
	ga::PendingRemoteEffectCommand command;
	if (!build_pending_remote_effect_command(p_command, command)) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		result["handle"] = int64_t(0);
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));

	// `p_source`'s own read-only state, exactly like `EffectRuntime::apply`'s
	// `p_source_attributes`/`p_source_tags` parameters already document --
	// this is the public accessor pattern every other cross-component read in
	// this addon uses, never a reach into `p_source`'s internals. Null if
	// unavailable/not configured; a magnitude declaration that then needs a
	// live source-attribute read fails exactly as `apply` already documents.
	const ga::AttributeSet *source_attributes = (p_source != nullptr && p_source->is_configured()) ? &p_source->component->attributes() : nullptr;
	const ga::TagContainer *source_tags = (p_source != nullptr && p_source->is_configured()) ? &p_source->component->tags() : nullptr;

	ga::EffectHandle handle;
	const ga::Status status = component->apply_remote_effect(command, static_cast<ga::Tick>(p_tick), source_attributes, source_tags, handle);
	result["status"] = status_dict(status);
	result["handle"] = int64_t(handle.value);
	return result;
}

Dictionary GameplayAbilityComponent::preflight_pending_remote_effect(const Dictionary &p_command, GameplayAbilityComponent *p_source, int64_t p_tick) const {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	ga::PendingRemoteEffectCommand command;
	if (!build_pending_remote_effect_command(p_command, command)) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}

	// Same read-only source-state accessor pattern as `apply_pending_remote_effect`
	// above (see its own comment) -- deliberately does NOT advance
	// `current_tick`, unlike that mutating twin: this method is const and
	// side-effect-free (see this method's own header doc comment).
	const ga::AttributeSet *source_attributes = (p_source != nullptr && p_source->is_configured()) ? &p_source->component->attributes() : nullptr;
	const ga::TagContainer *source_tags = (p_source != nullptr && p_source->is_configured()) ? &p_source->component->tags() : nullptr;

	const ga::Status status = component->preflight_remote_effect(command, static_cast<ga::Tick>(p_tick), source_attributes, source_tags);
	result["status"] = status_dict(status);
	return result;
}

bool GameplayAbilityComponent::build_gameplay_event(const Dictionary &p_event, ga::GameplayEventContext &r_event) const {
	if (!is_configured() || !p_event.has("event_tag")) {
		return false;
	}
	const ga::DefinitionId tag_id = core_tags.id_of(to_std(String(p_event["event_tag"])));
	if (tag_id == ga::INVALID_DEFINITION_ID) {
		return false;
	}
	r_event.event_tag = tag_id;
	r_event.instigator = to_entity_id(int64_t(p_event.get("instigator", 0)));
	r_event.target = to_entity_id(int64_t(p_event.get("target", 0)));
	ga::Fixed magnitude = ga::Fixed::zero();
	ga::fixed_quantize(double(p_event.get("magnitude", 0.0)), magnitude);
	r_event.magnitude = magnitude;
	r_event.payload_tag = uint64_t(int64_t(p_event.get("payload_tag", 0)));
	return true;
}

bool GameplayAbilityComponent::build_ability_task_request(
		const Ref<GameplayAbilityTaskRequest> &p_request,
		ga::AbilityTaskRequest &r_request) const {
	if (!is_configured() || p_request.is_null()) {
		return false;
	}
	const int kind = int(p_request->get_kind());
	const int visibility = int(p_request->get_visibility());
	const int prediction = int(p_request->get_prediction_policy());
	if (kind < 0 || kind > int(ga::AbilityTaskKind::WAIT_TARGET_DATA) ||
			visibility < 0 ||
			visibility > int(ga::AbilityTaskVisibility::INTERNAL) ||
			prediction < 0 ||
			prediction >
					int(ga::AbilityTaskPredictionPolicy::REQUIRES_AUTHORITY)) {
		return false;
	}

	ga::AbilityTaskRequest request;
	request.kind = static_cast<ga::AbilityTaskKind>(kind);
	request.has_deadline = p_request->get_has_deadline();
	if (request.has_deadline) {
		request.deadline_tick =
				static_cast<ga::Tick>(p_request->get_deadline_tick());
	}
	request.visibility =
			static_cast<ga::AbilityTaskVisibility>(visibility);
	request.prediction_policy =
			static_cast<ga::AbilityTaskPredictionPolicy>(prediction);
	switch (request.kind) {
		case ga::AbilityTaskKind::WAIT_TICKS:
			request.wait_ticks =
					static_cast<ga::Tick>(p_request->get_wait_ticks());
			break;
		case ga::AbilityTaskKind::WAIT_GAMEPLAY_EVENT:
			request.gameplay_event_match =
					static_cast<ga::TagMatchMode>(
							int(p_request->get_gameplay_event_match()));
			request.gameplay_event_tag = core_tags.id_of(
					to_std(String(p_request->get_gameplay_event_tag())));
			break;
		case ga::AbilityTaskKind::WAIT_TAG_QUERY: {
			request.tag_edge = static_cast<ga::AbilityTaskTagEdge>(
					int(p_request->get_tag_edge()));
			request.complete_if_already_satisfied =
					p_request->get_complete_if_already_satisfied();
			const Ref<GameplayTagQueryResource> query =
					p_request->get_tag_query();
			if (query.is_null()) {
				break;
			}
			auto resolve_operands = [this](
										 const TypedArray<GameplayTagOperand> &p_authored,
										 std::vector<ga::TagQueryOperand> &r_resolved) {
				if (p_authored.size() > int(ga::MAX_QUERY_OPERANDS)) {
					return false;
				}
				for (int i = 0; i < p_authored.size(); ++i) {
					const Ref<GameplayTagOperand> operand = p_authored[i];
					if (operand.is_null()) {
						return false;
					}
					const ga::DefinitionId tag = core_tags.id_of(
							to_std(String(operand->get_tag())));
					if (tag == ga::INVALID_DEFINITION_ID) {
						return false;
					}
					r_resolved.push_back(ga::TagQueryOperand{
							tag,
							operand->get_match_mode() ==
											GameplayTagOperand::MATCH_PARENT_AWARE
									? ga::TagMatchMode::PARENT_AWARE
									: ga::TagMatchMode::EXACT });
				}
				return true;
			};
			std::vector<ga::TagQueryOperand> all;
			std::vector<ga::TagQueryOperand> any;
			std::vector<ga::TagQueryOperand> none;
			if (!resolve_operands(query->get_all_of(), all) ||
					!resolve_operands(query->get_any_of(), any) ||
					!resolve_operands(query->get_none_of(), none) ||
					!ga::TagQuery::build_requirements(
							 std::move(all), std::move(any), std::move(none),
							 request.tag_query)
							 .ok()) {
				return false;
			}
			break;
		}
		case ga::AbilityTaskKind::WAIT_LOGICAL_INPUT:
			request.logical_phase = static_cast<ga::LogicalInputPhase>(
					int(p_request->get_logical_phase()));
			request.logical_input = core_tags.id_of(
					to_std(String(p_request->get_logical_input())));
			break;
		case ga::AbilityTaskKind::WAIT_AUTHORITY:
			request.authority_prediction = to_prediction_key(
					p_request->get_authority_prediction_key());
			break;
		case ga::AbilityTaskKind::WAIT_TARGET_DATA:
			request.target_schema = core_target_schemas.id_of(
					to_std(String(p_request->get_target_schema())));
			if (request.target_schema == ga::INVALID_DEFINITION_ID) {
				return false;
			}
			break;
	}
	r_request = std::move(request);
	return true;
}

Dictionary GameplayAbilityComponent::handle_gameplay_event(const Dictionary &p_event, int64_t p_tick) {
	Dictionary result;
	ga::GameplayEventContext event;
	if (!build_gameplay_event(p_event, event)) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	result["status"] = status_dict(component->handle_gameplay_event(event, static_cast<ga::Tick>(p_tick)));
	return result;
}

Dictionary GameplayAbilityComponent::start_ability_task(
		int64_t p_execution,
		const Ref<GameplayAbilityTaskRequest> &p_request, int64_t p_tick,
		Provenance p_provenance) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		result["task"] = int64_t(0);
		return result;
	}
	ga::AbilityTaskRequest request;
	if (!build_ability_task_request(p_request, request)) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::INVALID_ABILITY_TASK,
				ga::DiagnosticId::INVALID_TASK_PAYLOAD));
		result["task"] = int64_t(0);
		return result;
	}
	const ga::Tick tick = static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick);
	current_tick = std::max(current_tick, tick);
	const ga::AbilityTaskStartResult started =
			component->start_ability_task(to_execution_id(p_execution),
					request, tick, to_provenance(p_provenance));
	result["status"] = status_dict(started.status);
	result["task"] = int64_t(started.task.value);
	result["queued"] = started.queued;
	result["terminal"] = started.terminal;
	if (started.terminal) {
		result["event"] = ability_task_event_dict(started.event);
	}
	return result;
}

Dictionary GameplayAbilityComponent::cancel_ability_task(
		int64_t p_task, int64_t p_tick, TaskCancelReason p_reason,
		Provenance p_provenance) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	if (int(p_reason) < 0 ||
			int(p_reason) >
					int(ga::AbilityTaskCancelReason::
								 TARGET_SESSION_CANCELLED)) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}
	const ga::Tick tick = static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick);
	current_tick = std::max(current_tick, tick);
	const ga::AbilityTaskTransitionResult transition =
			component->cancel_ability_task(
					to_task_handle(p_task), tick,
					static_cast<ga::AbilityTaskCancelReason>(int(p_reason)),
					to_provenance(p_provenance));
	result["status"] = status_dict(transition.status);
	result["queued"] = transition.queued;
	result["transitioned"] = transition.transitioned;
	if (transition.transitioned) {
		result["event"] = ability_task_event_dict(transition.event);
	}
	return result;
}

Dictionary GameplayAbilityComponent::submit_logical_input(
		int64_t p_execution, int64_t p_task,
		const String &p_logical_input, LogicalInputPhase p_phase,
		int64_t p_command_sequence, int64_t p_prediction_key,
		int64_t p_tick, Provenance p_provenance) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	if (int(p_phase) < 0 ||
			int(p_phase) > int(ga::LogicalInputPhase::CANCEL)) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}
	const ga::DefinitionId input =
			core_tags.id_of(to_std(p_logical_input));
	if (input == ga::INVALID_DEFINITION_ID) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::UNKNOWN_TAG));
		return result;
	}
	ga::AbilityTaskLogicalInputCommand command;
	command.owner = component->entity();
	command.execution = to_execution_id(p_execution);
	command.task = to_task_handle(p_task);
	command.logical_input = input;
	command.phase =
			static_cast<ga::LogicalInputPhase>(int(p_phase));
	command.sequence = to_command_seq(p_command_sequence);
	command.prediction_key = to_prediction_key(p_prediction_key);
	const ga::Tick tick = static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick);
	current_tick = std::max(current_tick, tick);
	const ga::AbilityTaskTransitionResult transition =
			component->submit_logical_input(
					command, tick, to_provenance(p_provenance));
	result["status"] = status_dict(transition.status);
	result["queued"] = transition.queued;
	result["transitioned"] = transition.transitioned;
	if (transition.transitioned) {
		result["event"] = ability_task_event_dict(transition.event);
	}
	return result;
}

Dictionary GameplayAbilityComponent::acknowledge_task_authority(
		int64_t p_prediction_key, int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	const ga::Tick tick = static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick);
	current_tick = std::max(current_tick, tick);
	result["status"] = status_dict(
			component->acknowledge_task_authority(
					to_prediction_key(p_prediction_key), tick));
	return result;
}

bool GameplayAbilityComponent::has_ability_task(int64_t p_task) const {
	return is_configured() &&
			component->ability_tasks().has(to_task_handle(p_task));
}

Dictionary GameplayAbilityComponent::get_ability_task(int64_t p_task) const {
	if (!is_configured()) {
		return Dictionary();
	}
	const ga::ActiveAbilityTask *task =
			component->ability_tasks().find(to_task_handle(p_task));
	return task != nullptr ? active_ability_task_dict(*task) : Dictionary();
}

PackedInt64Array GameplayAbilityComponent::active_ability_tasks() const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::AbilityTaskHandle task :
			component->ability_tasks().active_handles()) {
		result.push_back(int64_t(task.value));
	}
	return result;
}

PackedInt64Array GameplayAbilityComponent::ability_tasks_for_execution(
		int64_t p_execution) const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::AbilityTaskHandle task :
			component->ability_tasks().tasks_for_execution(
					to_execution_id(p_execution))) {
		result.push_back(int64_t(task.value));
	}
	return result;
}

void GameplayAbilityComponent::notify_restored_ability_tasks(int64_t p_tick) {
	if (!is_configured()) {
		return;
	}
	const ga::Tick tick = static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick);
	current_tick = std::max(current_tick, tick);
	component->notify_restored_ability_tasks(tick);
}

// ---------------------------------------------------------------------------
// Ending & cancellation
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::end_execution(int64_t p_execution, int64_t p_tick, Provenance p_provenance) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	result["status"] = status_dict(component->end_execution(to_execution_id(p_execution), static_cast<ga::Tick>(p_tick), to_provenance(p_provenance)));
	return result;
}

Dictionary GameplayAbilityComponent::cancel_execution(int64_t p_execution, int64_t p_tick, Provenance p_provenance, EndReason p_reason) {
	if (!is_configured()) {
		return cancellation_result_dict(ga::CancellationResult{ ga::make_status(ga::StatusCode::NOT_SUPPORTED) });
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	return cancellation_result_dict(component->cancel_execution(to_execution_id(p_execution), static_cast<ga::Tick>(p_tick),
			to_provenance(p_provenance), to_end_reason(p_reason)));
}

bool GameplayAbilityComponent::has_execution(int64_t p_execution) const {
	return is_configured() && component->has_execution(to_execution_id(p_execution));
}

Dictionary GameplayAbilityComponent::get_execution(int64_t p_execution) const {
	if (!is_configured()) {
		return Dictionary();
	}
	const ga::ActiveExecution *execution = component->find_execution(to_execution_id(p_execution));
	return execution != nullptr ? execution_dict(*execution) : Dictionary();
}

PackedInt64Array GameplayAbilityComponent::active_executions() const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::ExecutionId id : component->active_executions()) {
		result.push_back(int64_t(id.value));
	}
	return result;
}

// ---------------------------------------------------------------------------
// Active effects (task 6.12)
// ---------------------------------------------------------------------------

PackedInt64Array GameplayAbilityComponent::active_effect_handles() const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::EffectHandle handle : component->effects().active_handles()) {
		result.push_back(int64_t(handle.value));
	}
	return result;
}

Dictionary GameplayAbilityComponent::get_active_effect(int64_t p_handle) const {
	if (!is_configured()) {
		return Dictionary();
	}
	const ga::ActiveEffect *effect = component->effects().find(to_effect_handle(p_handle));
	return effect != nullptr ? active_effect_dict(*effect) : Dictionary();
}

int64_t GameplayAbilityComponent::predicted_effect_authority_handle(int64_t p_temp_handle) const {
	if (reconciler == nullptr) {
		return 0;
	}
	ga::EffectHandle authority;
	if (!reconciler->handle_map().temp_to_authority(to_effect_handle(p_temp_handle), authority)) {
		return 0;
	}
	return int64_t(authority.value);
}

// ---------------------------------------------------------------------------
// Tick driver
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::advance_to(int64_t p_tick) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	result["status"] = status_dict(component->advance_to(static_cast<ga::Tick>(p_tick)));
	return result;
}

// ---------------------------------------------------------------------------
// Attribute / tag queries
// ---------------------------------------------------------------------------

bool GameplayAbilityComponent::has_attribute(const String &p_identifier) const {
	if (!is_configured()) {
		return false;
	}
	const ga::DefinitionId id = core_attributes.id_of(to_std(p_identifier));
	return id != ga::INVALID_DEFINITION_ID && component->attributes().has_attribute(id);
}

double GameplayAbilityComponent::get_attribute_base(const String &p_identifier) const {
	if (!is_configured()) {
		return 0.0;
	}
	const ga::DefinitionId id = core_attributes.id_of(to_std(p_identifier));
	ga::Fixed value = ga::Fixed::zero();
	if (id == ga::INVALID_DEFINITION_ID || !component->attributes().get_base(id, value).ok()) {
		return 0.0;
	}
	return ga::fixed_to_double(value);
}

double GameplayAbilityComponent::get_attribute_current(const String &p_identifier) const {
	if (!is_configured()) {
		return 0.0;
	}
	const ga::DefinitionId id = core_attributes.id_of(to_std(p_identifier));
	ga::Fixed value = ga::Fixed::zero();
	if (id == ga::INVALID_DEFINITION_ID || !component->attributes().get_current(id, value).ok()) {
		return 0.0;
	}
	return ga::fixed_to_double(value);
}

bool GameplayAbilityComponent::has_tag_exact(const String &p_identifier) const {
	if (!is_configured()) {
		return false;
	}
	const ga::DefinitionId id = core_tags.id_of(to_std(p_identifier));
	return id != ga::INVALID_DEFINITION_ID && component->tags().has_exact(id);
}

bool GameplayAbilityComponent::has_tag_parent_aware(const String &p_identifier) const {
	if (!is_configured()) {
		return false;
	}
	const ga::DefinitionId id = core_tags.id_of(to_std(p_identifier));
	return id != ga::INVALID_DEFINITION_ID && component->tags().has_parent_aware(id);
}

PackedStringArray GameplayAbilityComponent::get_initialized_attributes() const {
	PackedStringArray result;
	if (!is_configured()) {
		return result;
	}
	for (ga::DefinitionId id : component->attributes().initialized_attributes()) {
		result.push_back(attribute_identifier_of(id));
	}
	return result;
}

PackedStringArray GameplayAbilityComponent::owned_tags() const {
	PackedStringArray result;
	if (!is_configured()) {
		return result;
	}
	for (ga::DefinitionId id : component->tags().owned_tags()) {
		result.push_back(tag_identifier_of(id));
	}
	return result;
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::get_diagnostics() const {
	Dictionary d;
	d["configured"] = is_configured();
	d["role"] = int(role);
	d["entity_id"] = get_entity_id();
	d["current_tick"] = get_current_tick();
	d["owner_valid"] = is_owner_valid();
	d["torn_down"] = is_torn_down();
	if (is_configured()) {
		d["grant_count"] = int64_t(component->granted_specs().size());
		d["active_execution_count"] = int64_t(component->active_executions().size());
		d["active_effect_count"] = int64_t(component->effects().active_count());
		d["tag_revision"] = int64_t(component->tags().revision());
	}
	return d;
}

// ---------------------------------------------------------------------------
// Canonical snapshots (task 7.9)
// ---------------------------------------------------------------------------

PackedByteArray GameplayAbilityComponent::write_snapshot() const {
	PackedByteArray out;
	if (!is_configured()) {
		return out;
	}
	ga::SnapshotWriter writer;
	const ga::Status status = component->write_snapshot(writer);
	if (!status.ok() || !writer.ok()) {
		return out;
	}
	const std::vector<std::uint8_t> bytes = writer.take();
	return to_packed(bytes);
}

bool GameplayAbilityComponent::restore_snapshot(const PackedByteArray &p_bytes) {
	if (!is_configured()) {
		return false;
	}
	// Finding 5: capture the pre-restore state FIRST -- see this method's
	// own header doc comment for the full rollback-then-quarantine contract.
	const PackedByteArray pre_state = write_snapshot();

	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	ga::SnapshotReader reader(bytes);
	const ga::Status status = component->restore_snapshot(reader);
	if (status.ok()) {
		// Task 8.12 fix ("reconnect STALE_COMMAND" defect): this is a
		// confirmed-baseline adoption point -- the RESTORED grants' own
		// `last_command_sequence` values are only ever visible from here on.
		// Re-seeding on every plain restore (not just after a reconnect
		// specifically) is deliberately cheap/idempotent -- see
		// `PredictingComponent::seed_from_owning_component`'s own doc comment
		// -- so no separate "is this actually a reconnect" detection is
		// needed. A no-op for any role without a `PredictingComponent` at all
		// (offline/server authority, or a remote peer's mirror).
		if (predicting) {
			predicting->seed_from_owning_component();
		}
		return true;
	}
	rollback_or_quarantine(pre_state, status);
	return false;
}

void GameplayAbilityComponent::rollback_or_quarantine(const PackedByteArray &p_pre_state, const ga::Status &p_original_failure) {
	if (component != nullptr && !p_pre_state.is_empty()) {
		const std::vector<std::uint8_t> pre_bytes = from_packed(p_pre_state);
		// Directly through the CORE restore, never `this->restore_snapshot()`
		// -- see this method's own header doc comment for why (avoids both
		// infinite recursion and re-capturing "pre-state" from mid-rollback).
		ga::SnapshotReader rollback_reader(pre_bytes);
		if (component->restore_snapshot(rollback_reader).ok()) {
			return; // rolled back to the known-good pre-state -- still fully usable.
		}
	}
	// Either there was no captured pre-state to roll back to (`write_snapshot()`
	// itself failed before the restore was even attempted -- should not
	// happen for an already-`is_configured()` component, but defended
	// against anyway) or the rollback restore ALSO failed: this component is
	// genuinely unrecoverable.
	quarantined = true;
	emit_signal("desync_rebuild_required", status_dict(p_original_failure));
}

ga::ReconciliationResult GameplayAbilityComponent::reconcile_snapshot(
		const std::vector<std::uint8_t> &p_confirmed_snapshot,
		ga::Tick p_tick, const ga::proto::ClientEventStream &p_stream,
		const ga::AuthoritativeEventApplier &p_apply_events,
		ga::GameplayAbilityWorldCoordinator *p_target_coordinator) {
	if (!is_configured() || reconciler == nullptr) {
		ga::ReconciliationResult result;
		result.outcome = ga::ReconciliationOutcomeKind::COMPONENT_MUST_BE_REBUILT;
		result.status = ga::make_status(ga::StatusCode::NOT_SUPPORTED);
		return result;
	}
	// Finding 5: same rollback-then-quarantine contract as `restore_snapshot()`
	// -- capture pre-state before `reconcile()` runs (it performs its own
	// restore internally; this wrapper never restores `p_confirmed_snapshot`
	// a second time).
	const PackedByteArray pre_state = write_snapshot();
	const ga::ReconciliationResult result = reconciler->reconcile(
			p_confirmed_snapshot, p_tick, p_stream, p_apply_events,
			p_target_coordinator);
	if (result.outcome == ga::ReconciliationOutcomeKind::COMPONENT_MUST_BE_REBUILT) {
		rollback_or_quarantine(pre_state, result.status);
	} else if (predicting) {
		// Task 8.12 fix ("reconnect STALE_COMMAND" defect): the OTHER
		// confirmed-baseline adoption seam (see `restore_snapshot()`'s own
		// comment above) -- `reconcile()` just restored this component to
		// `p_confirmed_snapshot` internally (REPLAYED or
		// EVENT_APPLICATION_FAILED both leave the restore itself applied; see
		// `PredictionReconciler::reconcile`), so the restored grants'
		// `last_command_sequence` values are visible from here on too.
		predicting->seed_from_owning_component();
	}
	return result;
}

// ---------------------------------------------------------------------------
// Owner teardown seam
// ---------------------------------------------------------------------------

void GameplayAbilityComponent::queue_teardown(int64_t p_tick) {
	teardown_requested = true;
	if (!is_configured()) {
		return;
	}
	current_tick = std::max<ga::Tick>(current_tick, static_cast<ga::Tick>(p_tick < 0 ? 0 : p_tick));
	component->queue_teardown(static_cast<ga::Tick>(p_tick));
}

bool GameplayAbilityComponent::is_owner_valid() const {
	return is_configured() ? component->is_owner_valid() : !teardown_requested;
}

bool GameplayAbilityComponent::is_torn_down() const {
	return is_configured() ? component->is_torn_down() : teardown_requested;
}

// ---------------------------------------------------------------------------
// Network-bridge seams
// ---------------------------------------------------------------------------

void GameplayAbilityComponent::notify_replication_gap(int p_reason_code, int64_t p_detail) {
	Dictionary d;
	d["reason_code"] = p_reason_code;
	d["detail"] = p_detail;
	emit_signal("replication_gap_detected", d);
}

void GameplayAbilityComponent::notify_prediction_phase(const Dictionary &p_payload) {
	emit_signal("prediction_phase_changed", p_payload);
}

Dictionary GameplayAbilityComponent::prediction_presentation_dict(const ga::PredictionPresentationEvent &p_event) const {
	Dictionary d;
	d["prediction_key"] = int64_t(p_event.prediction_key.value);
	d["phase"] = int(p_event.phase);
	d["ability"] = int64_t(p_event.ability);
	d["ability_identifier"] = ability_identifier_of(p_event.ability);
	d["target"] = int64_t(p_event.target.value);
	// ga::CueDedupId field-for-field, so runtime/ga_cue_adapter.gd's
	// dedup logic keys on the SAME (target, definition, handle, occurrence)
	// tuple it already uses for effect_cue_triggered -- see that file's
	// `_dedup_key_for_prediction`.
	d["definition"] = int64_t(p_event.dedup.definition);
	d["handle"] = int64_t(p_event.dedup.handle.value);
	d["occurrence"] = int64_t(p_event.dedup.occurrence);
	d["tick"] = int64_t(p_event.tick);
	return d;
}

// ---------------------------------------------------------------------------
// Constrained behavior hooks (tasks 6.6, 6.10)
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::bind_authority_hook(
		const String &p_ability_identifier, const Callable &p_callable,
		const Callable &p_task_callable) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	if (!p_callable.is_valid()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}
	const ga::DefinitionId ability_id = core_abilities.id_of(to_std(p_ability_identifier));
	if (ability_id == ga::INVALID_DEFINITION_ID) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::UNKNOWN_ABILITY));
		return result;
	}
	auto adapter = std::make_unique<ScriptAuthorityAbilityHook>(
			this, p_callable, p_task_callable);
	const ga::Status status = component->bind_authority_hook(ability_id, adapter.get());
	if (status.ok()) {
		script_authority_hooks.push_back(std::move(adapter));
	}
	result["status"] = status_dict(status);
	return result;
}

Dictionary GameplayAbilityComponent::bind_prediction_safe_hook(const String &p_ability_identifier, const Callable &p_callable,
		bool p_depends_on_time, bool p_depends_on_randomness, bool p_depends_on_scene_or_physics,
		bool p_uses_unrestricted_callback, const Callable &p_task_callable) {
	Dictionary result;
	if (!is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		return result;
	}
	if (!p_callable.is_valid()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}
	const ga::DefinitionId ability_id = core_abilities.id_of(to_std(p_ability_identifier));
	if (ability_id == ga::INVALID_DEFINITION_ID) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::UNKNOWN_ABILITY));
		return result;
	}
	auto adapter = std::make_unique<ScriptPredictionSafeAbilityHook>(this, p_callable, p_depends_on_time,
			p_depends_on_randomness, p_depends_on_scene_or_physics,
			p_uses_unrestricted_callback, p_task_callable);
	// `component->bind_prediction_safe_hook` runs `validate_prediction_safe_hook`
	// over the adapter (which honestly reports back exactly the four booleans
	// above) before ever installing it -- an honestly-declared non-deterministic
	// dependency is rejected here with STATUS_PREDICTION_NOT_SAFE, never
	// silently accepted (task 6.10's "a prediction-safe Callable declaring a
	// non-deterministic dependency is rejected" requirement).
	const ga::Status status = component->bind_prediction_safe_hook(ability_id, adapter.get());
	if (status.ok()) {
		script_prediction_hooks.push_back(std::move(adapter));
	}
	result["status"] = status_dict(status);
	return result;
}

// ---------------------------------------------------------------------------
// Identifier resolvers
// ---------------------------------------------------------------------------

String GameplayAbilityComponent::resolve_tag_identifier(int64_t p_id) const {
	return is_configured() ? tag_identifier_of(static_cast<ga::DefinitionId>(p_id)) : String();
}

String GameplayAbilityComponent::resolve_attribute_identifier(int64_t p_id) const {
	return is_configured() ? attribute_identifier_of(static_cast<ga::DefinitionId>(p_id)) : String();
}

String GameplayAbilityComponent::resolve_ability_identifier(int64_t p_id) const {
	return is_configured() ? ability_identifier_of(static_cast<ga::DefinitionId>(p_id)) : String();
}

std::unique_ptr<ga::AbilityComponent> GameplayAbilityComponent::build_scratch_mirror() const {
	if (!is_configured()) {
		return nullptr;
	}
	return std::make_unique<ga::AbilityComponent>(core_abilities, core_effects, core_attributes, core_tags,
			component->entity(), component->role());
}

ga::DefinitionId GameplayAbilityComponent::resolve_effect_definition_id(const std::string &p_identifier) const {
	return is_configured() ? core_effects.id_of(p_identifier) : ga::INVALID_DEFINITION_ID;
}

ga::DefinitionId GameplayAbilityComponent::resolve_attribute_definition_id(const std::string &p_identifier) const {
	return is_configured() ? core_attributes.id_of(p_identifier) : ga::INVALID_DEFINITION_ID;
}

ga::DefinitionId GameplayAbilityComponent::resolve_tag_definition_id(const std::string &p_identifier) const {
	return is_configured() ? core_tags.id_of(p_identifier) : ga::INVALID_DEFINITION_ID;
}

ga::DefinitionId GameplayAbilityComponent::resolve_ability_definition_id(const std::string &p_identifier) const {
	return is_configured() ? core_abilities.id_of(p_identifier) : ga::INVALID_DEFINITION_ID;
}

// ---------------------------------------------------------------------------
// Per-ability target-data schema (task 7.16)
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::get_target_data_schema_for_ability(const String &p_ability_identifier) const {
	Dictionary result;
	if (!is_configured()) {
		return result;
	}
	const ga::DefinitionId ability_id = core_abilities.id_of(to_std(p_ability_identifier));
	if (ability_id == ga::INVALID_DEFINITION_ID) {
		return result;
	}
	const auto it = ability_target_schema_bounds.find(ability_id);
	if (it == ability_target_schema_bounds.end()) {
		return result;
	}
	result["schema"] = it->second.identifier;
	result["max_targets"] = it->second.max_targets;
	result["max_payload_bytes"] = it->second.max_payload_bytes;
	return result;
}

// Task 7.16/7.20: see this method's own header doc comment -- the ONE
// implementation `GameplayAbilityNetworkBridge::validate_target_data_schema`
// (networked path) and `request_activation`/`process_activation_batch` below
// (direct/offline path) both delegate to.
ga::Status GameplayAbilityComponent::validate_target_data_schema(const String &p_ability_identifier,
		const std::vector<ga::EntityId> &p_targets, const std::vector<ga::SetByCallerMagnitude> &p_set_by_caller) const {
	if (!is_configured()) {
		return ga::ok_status(); // nothing sealed to look a schema up against yet -- callers already gate mutation on is_configured() themselves.
	}
	const ga::DefinitionId ability_id = core_abilities.id_of(to_std(p_ability_identifier));
	if (ability_id == ga::INVALID_DEFINITION_ID) {
		return ga::ok_status(); // unrecognized identifier -- only the protocol's global bounds apply.
	}
	const auto it = ability_target_schema_bounds.find(ability_id);
	if (it == ability_target_schema_bounds.end()) {
		return ga::ok_status(); // no per-ability schema declared -- only the global bounds apply.
	}
	const int64_t max_targets = it->second.max_targets;
	const int64_t max_payload_bytes = it->second.max_payload_bytes;
	if (int64_t(p_targets.size()) > max_targets) {
		return ga::make_status(ga::StatusCode::ABILITY_INVALID_TARGET, ga::DiagnosticId::COUNT_LIMIT_EXCEEDED, p_targets.size());
	}
	// Measure the SAME encoded shape `encode_activation_command`
	// (gameplay_ability_network_bridge.cpp) writes for the target-data
	// portion of one command (entity ids, then the set-by-caller fields), so
	// "byte limit" means the actual wire bytes a schema author is bounding,
	// not an approximation -- identical probe encoding for both the
	// networked and direct/offline activation paths.
	ga::ByteWriter probe(ga::MAX_COMMAND_PACKET_BYTES);
	for (ga::EntityId target : p_targets) {
		ga::handle_write(probe, target);
	}
	probe.write_count(p_set_by_caller.size(), ga::MAX_SET_BY_CALLER);
	for (const ga::SetByCallerMagnitude &magnitude : p_set_by_caller) {
		probe.write_string(magnitude.field);
		ga::fixed_write(probe, magnitude.value);
	}
	if (!probe.ok() || int64_t(probe.size()) > max_payload_bytes) {
		return ga::make_status(ga::StatusCode::PAYLOAD_TOO_LARGE, ga::DiagnosticId::BYTE_LIMIT_EXCEEDED, probe.size());
	}
	return ga::ok_status();
}

// ---------------------------------------------------------------------------
// Script-hook execution-context snapshot (task 6.10)
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityComponent::ability_execution_context_dict(const ga::AbilityExecutionContext &p_context) const {
	Dictionary d;
	d["owner"] = int64_t(p_context.owner.value);
	d["spec"] = int64_t(p_context.spec.value);
	d["execution"] = int64_t(p_context.execution.value);
	d["ability"] = int64_t(p_context.ability);
	d["ability_identifier"] = ability_identifier_of(p_context.ability);
	d["level"] = p_context.level;
	d["tick"] = int64_t(p_context.tick);
	d["role"] = int(p_context.role);
	d["provenance"] = int(p_context.provenance);

	Dictionary owner_attributes;
	for (const auto &pair : p_context.owner_attributes) {
		const String identifier = attribute_identifier_of(pair.first);
		if (!identifier.is_empty()) {
			owner_attributes[identifier] = ga::fixed_to_double(pair.second);
		}
	}
	d["owner_attributes"] = owner_attributes;

	PackedStringArray owner_tags;
	for (ga::DefinitionId tag_id : p_context.owner_tags) {
		const String identifier = tag_identifier_of(tag_id);
		if (!identifier.is_empty()) {
			owner_tags.push_back(identifier);
		}
	}
	d["owner_tags"] = owner_tags;

	PackedInt64Array targets;
	for (ga::EntityId target : p_context.targets) {
		targets.push_back(int64_t(target.value));
	}
	d["targets"] = targets;

	Array set_by_caller;
	for (const ga::SetByCallerMagnitude &magnitude : p_context.set_by_caller) {
		Dictionary field;
		field["field"] = String(magnitude.field.c_str());
		field["value"] = ga::fixed_to_double(magnitude.value);
		set_by_caller.push_back(field);
	}
	d["set_by_caller"] = set_by_caller;

	d["has_event"] = p_context.has_event;
	if (p_context.has_event) {
		Dictionary event;
		event["event_tag"] = tag_identifier_of(p_context.event.event_tag);
		event["instigator"] = int64_t(p_context.event.instigator.value);
		event["target"] = int64_t(p_context.event.target.value);
		event["magnitude"] = ga::fixed_to_double(p_context.event.magnitude);
		event["payload_tag"] = int64_t(p_context.event.payload_tag);
		d["event"] = event;
	} else {
		d["event"] = Dictionary();
	}
	return d;
}

void GameplayAbilityComponent::_notification(int p_what) {
	// Task 7.4 / GA_CONTRACT.md section 11: a freed Godot owner must never
	// leave a stale pointer in core. NOTIFICATION_PREDELETE fires first (the
	// object is still fully valid) and NOTIFICATION_EXIT_TREE fires whenever
	// this node leaves the tree without necessarily being freed; queue_teardown
	// is idempotent (see ga_ability_component.h), so calling it from both is
	// harmless and covers "removed from tree" as well as "freed outright".
	if (p_what == NOTIFICATION_PREDELETE || p_what == NOTIFICATION_EXIT_TREE) {
		queue_teardown(get_current_tick());
	}
}

// ---------------------------------------------------------------------------
// _bind_methods
// ---------------------------------------------------------------------------

void GameplayAbilityComponent::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_role", "role"), &GameplayAbilityComponent::set_role);
	ClassDB::bind_method(D_METHOD("get_role"), &GameplayAbilityComponent::get_role);
	ClassDB::bind_method(D_METHOD("set_entity_id", "id"), &GameplayAbilityComponent::set_entity_id);
	ClassDB::bind_method(D_METHOD("get_entity_id"), &GameplayAbilityComponent::get_entity_id);
	ClassDB::bind_method(D_METHOD("set_tick_rate", "tick_rate"), &GameplayAbilityComponent::set_tick_rate);
	ClassDB::bind_method(D_METHOD("get_tick_rate"), &GameplayAbilityComponent::get_tick_rate);
	ClassDB::bind_method(D_METHOD("set_tag_definitions", "tags"), &GameplayAbilityComponent::set_tag_definitions);
	ClassDB::bind_method(D_METHOD("get_tag_definitions"), &GameplayAbilityComponent::get_tag_definitions);
	ClassDB::bind_method(D_METHOD("set_attribute_definitions", "attributes"), &GameplayAbilityComponent::set_attribute_definitions);
	ClassDB::bind_method(D_METHOD("get_attribute_definitions"), &GameplayAbilityComponent::get_attribute_definitions);
	ClassDB::bind_method(D_METHOD("set_effect_definitions", "effects"), &GameplayAbilityComponent::set_effect_definitions);
	ClassDB::bind_method(D_METHOD("get_effect_definitions"), &GameplayAbilityComponent::get_effect_definitions);
	ClassDB::bind_method(D_METHOD("set_cue_definitions", "cues"), &GameplayAbilityComponent::set_cue_definitions);
	ClassDB::bind_method(D_METHOD("get_cue_definitions"), &GameplayAbilityComponent::get_cue_definitions);
	ClassDB::bind_method(D_METHOD("set_ability_definitions", "abilities"), &GameplayAbilityComponent::set_ability_definitions);
	ClassDB::bind_method(D_METHOD("get_ability_definitions"), &GameplayAbilityComponent::get_ability_definitions);
	ClassDB::bind_method(D_METHOD("set_target_data_schemas", "schemas"), &GameplayAbilityComponent::set_target_data_schemas);
	ClassDB::bind_method(D_METHOD("get_target_data_schemas"), &GameplayAbilityComponent::get_target_data_schemas);
	ClassDB::bind_method(D_METHOD("set_definition_catalog", "catalog"), &GameplayAbilityComponent::set_definition_catalog);
	ClassDB::bind_method(D_METHOD("get_definition_catalog"), &GameplayAbilityComponent::get_definition_catalog);

	ClassDB::bind_method(D_METHOD("configure"), &GameplayAbilityComponent::configure);
	ClassDB::bind_method(D_METHOD("is_configured"), &GameplayAbilityComponent::is_configured);
	ClassDB::bind_method(D_METHOD("get_content_manifest_fingerprint"), &GameplayAbilityComponent::get_content_manifest_fingerprint);

	ClassDB::bind_method(D_METHOD("initialize_attribute", "identifier", "has_override", "override_base", "tick"),
			&GameplayAbilityComponent::initialize_attribute);

	ClassDB::bind_method(D_METHOD("grant_ability", "identifier", "level", "input_id", "tick"),
			&GameplayAbilityComponent::grant_ability);
	ClassDB::bind_method(D_METHOD("revoke_ability", "spec", "tick", "provenance"),
			&GameplayAbilityComponent::revoke_ability, DEFVAL(int(PROVENANCE_AUTHORITATIVE)));
	ClassDB::bind_method(D_METHOD("has_grant", "spec"), &GameplayAbilityComponent::has_grant);
	ClassDB::bind_method(D_METHOD("get_grant", "spec"), &GameplayAbilityComponent::get_grant);
	ClassDB::bind_method(D_METHOD("granted_specs"), &GameplayAbilityComponent::granted_specs);
	ClassDB::bind_method(D_METHOD("ability_id_of", "identifier"), &GameplayAbilityComponent::ability_id_of);

	ClassDB::bind_method(D_METHOD("request_activation", "request", "tick"), &GameplayAbilityComponent::request_activation);
	ClassDB::bind_method(D_METHOD("process_activation_batch", "requests", "tick"),
			&GameplayAbilityComponent::process_activation_batch);
	ClassDB::bind_method(D_METHOD("commit_activation", "execution", "tick"), &GameplayAbilityComponent::commit_activation);
	ClassDB::bind_method(D_METHOD("handle_gameplay_event", "event", "tick"), &GameplayAbilityComponent::handle_gameplay_event);
	ClassDB::bind_method(D_METHOD("start_ability_task", "execution", "request",
						 "tick", "provenance"),
			&GameplayAbilityComponent::start_ability_task,
			DEFVAL(int(PROVENANCE_AUTHORITATIVE)));
	ClassDB::bind_method(D_METHOD("cancel_ability_task", "task", "tick",
						 "reason", "provenance"),
			&GameplayAbilityComponent::cancel_ability_task,
			DEFVAL(int(TASK_CANCEL_EXPLICIT)),
			DEFVAL(int(PROVENANCE_AUTHORITATIVE)));
	ClassDB::bind_method(D_METHOD("submit_logical_input", "execution", "task",
						 "logical_input", "phase", "command_sequence",
						 "prediction_key", "tick", "provenance"),
			&GameplayAbilityComponent::submit_logical_input,
			DEFVAL(int(PROVENANCE_AUTHORITATIVE)));
	ClassDB::bind_method(D_METHOD("acknowledge_task_authority",
						 "prediction_key", "tick"),
			&GameplayAbilityComponent::acknowledge_task_authority);
	ClassDB::bind_method(D_METHOD("has_ability_task", "task"),
			&GameplayAbilityComponent::has_ability_task);
	ClassDB::bind_method(D_METHOD("get_ability_task", "task"),
			&GameplayAbilityComponent::get_ability_task);
	ClassDB::bind_method(D_METHOD("active_ability_tasks"),
			&GameplayAbilityComponent::active_ability_tasks);
	ClassDB::bind_method(D_METHOD("ability_tasks_for_execution", "execution"),
			&GameplayAbilityComponent::ability_tasks_for_execution);
	ClassDB::bind_method(D_METHOD("notify_restored_ability_tasks", "tick"),
			&GameplayAbilityComponent::notify_restored_ability_tasks);
	ClassDB::bind_method(D_METHOD("apply_pending_remote_effect", "command", "source", "tick"),
			&GameplayAbilityComponent::apply_pending_remote_effect);
	ClassDB::bind_method(D_METHOD("preflight_pending_remote_effect", "command", "source", "tick"),
			&GameplayAbilityComponent::preflight_pending_remote_effect);

	ClassDB::bind_method(D_METHOD("end_execution", "execution", "tick", "provenance"),
			&GameplayAbilityComponent::end_execution, DEFVAL(int(PROVENANCE_AUTHORITATIVE)));
	ClassDB::bind_method(D_METHOD("cancel_execution", "execution", "tick", "provenance", "reason"),
			&GameplayAbilityComponent::cancel_execution, DEFVAL(int(PROVENANCE_AUTHORITATIVE)), DEFVAL(int(END_REASON_EXPLICIT_CANCEL)));
	ClassDB::bind_method(D_METHOD("has_execution", "execution"), &GameplayAbilityComponent::has_execution);
	ClassDB::bind_method(D_METHOD("get_execution", "execution"), &GameplayAbilityComponent::get_execution);
	ClassDB::bind_method(D_METHOD("active_executions"), &GameplayAbilityComponent::active_executions);

	ClassDB::bind_method(D_METHOD("active_effect_handles"), &GameplayAbilityComponent::active_effect_handles);
	ClassDB::bind_method(D_METHOD("get_active_effect", "handle"), &GameplayAbilityComponent::get_active_effect);
	ClassDB::bind_method(D_METHOD("predicted_effect_authority_handle", "temp_handle"),
			&GameplayAbilityComponent::predicted_effect_authority_handle);

	ClassDB::bind_method(D_METHOD("advance_to", "tick"), &GameplayAbilityComponent::advance_to);
	ClassDB::bind_method(D_METHOD("get_current_tick"), &GameplayAbilityComponent::get_current_tick);

	ClassDB::bind_method(D_METHOD("has_attribute", "identifier"), &GameplayAbilityComponent::has_attribute);
	ClassDB::bind_method(D_METHOD("get_attribute_base", "identifier"), &GameplayAbilityComponent::get_attribute_base);
	ClassDB::bind_method(D_METHOD("get_attribute_current", "identifier"), &GameplayAbilityComponent::get_attribute_current);
	ClassDB::bind_method(D_METHOD("get_initialized_attributes"), &GameplayAbilityComponent::get_initialized_attributes);
	ClassDB::bind_method(D_METHOD("has_tag_exact", "identifier"), &GameplayAbilityComponent::has_tag_exact);
	ClassDB::bind_method(D_METHOD("has_tag_parent_aware", "identifier"), &GameplayAbilityComponent::has_tag_parent_aware);
	ClassDB::bind_method(D_METHOD("owned_tags"), &GameplayAbilityComponent::owned_tags);

	ClassDB::bind_method(D_METHOD("get_diagnostics"), &GameplayAbilityComponent::get_diagnostics);

	ClassDB::bind_method(D_METHOD("write_snapshot"), &GameplayAbilityComponent::write_snapshot);
	ClassDB::bind_method(D_METHOD("restore_snapshot", "bytes"), &GameplayAbilityComponent::restore_snapshot);

	ClassDB::bind_method(D_METHOD("queue_teardown", "tick"), &GameplayAbilityComponent::queue_teardown);
	ClassDB::bind_method(D_METHOD("is_owner_valid"), &GameplayAbilityComponent::is_owner_valid);
	ClassDB::bind_method(D_METHOD("is_torn_down"), &GameplayAbilityComponent::is_torn_down);

	ClassDB::bind_method(D_METHOD("notify_replication_gap", "reason_code", "detail"),
			&GameplayAbilityComponent::notify_replication_gap);
	ClassDB::bind_method(D_METHOD("notify_prediction_phase", "payload"),
			&GameplayAbilityComponent::notify_prediction_phase);

	ClassDB::bind_method(D_METHOD("bind_authority_hook", "ability_identifier",
						 "callable", "task_callable"),
			&GameplayAbilityComponent::bind_authority_hook,
			DEFVAL(Callable()));
	ClassDB::bind_method(D_METHOD("bind_prediction_safe_hook", "ability_identifier", "callable",
						 "depends_on_time", "depends_on_randomness", "depends_on_scene_or_physics", "uses_unrestricted_callback",
						 "task_callable"),
			&GameplayAbilityComponent::bind_prediction_safe_hook,
			DEFVAL(false), DEFVAL(false), DEFVAL(false), DEFVAL(false),
			DEFVAL(Callable()));

	ClassDB::bind_method(D_METHOD("resolve_tag_identifier", "id"), &GameplayAbilityComponent::resolve_tag_identifier);
	ClassDB::bind_method(D_METHOD("resolve_attribute_identifier", "id"), &GameplayAbilityComponent::resolve_attribute_identifier);
	ClassDB::bind_method(D_METHOD("resolve_ability_identifier", "id"), &GameplayAbilityComponent::resolve_ability_identifier);

	ClassDB::bind_method(D_METHOD("get_target_data_schema_for_ability", "ability_identifier"),
			&GameplayAbilityComponent::get_target_data_schema_for_ability);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "role", PROPERTY_HINT_ENUM, "OfflineAuthority,ServerAuthority,NetworkClient"),
			"set_role", "get_role");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "entity_id"), "set_entity_id", "get_entity_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tick_rate"), "set_tick_rate", "get_tick_rate");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "tag_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_tag_definitions", "get_tag_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "attribute_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayAttributeDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_attribute_definitions", "get_attribute_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "effect_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayEffectDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_effect_definitions", "get_effect_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "cue_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayCueDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_cue_definitions", "get_cue_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "ability_definitions"), "set_ability_definitions", "get_ability_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "target_data_schemas", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTargetDataSchema", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_target_data_schemas", "get_target_data_schemas");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "definition_catalog", PROPERTY_HINT_RESOURCE_TYPE, "GameplayDefinitionCatalog"),
			"set_definition_catalog", "get_definition_catalog");

	ADD_SIGNAL(MethodInfo("ability_granted", PropertyInfo(Variant::DICTIONARY, "grant")));
	ADD_SIGNAL(MethodInfo("ability_revoked", PropertyInfo(Variant::DICTIONARY, "grant")));
	ADD_SIGNAL(MethodInfo("activation_requested", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("activation_phase_changed", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("activation_committed", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("activation_ended", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("activation_cancelled", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("activation_failed", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("ability_snapshot_restored", PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("ability_task_event",
			PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("attribute_changed", PropertyInfo(Variant::DICTIONARY, "record")));
	ADD_SIGNAL(MethodInfo("tag_changed", PropertyInfo(Variant::DICTIONARY, "record")));
	ADD_SIGNAL(MethodInfo("effect_lifecycle_changed", PropertyInfo(Variant::DICTIONARY, "record")));
	ADD_SIGNAL(MethodInfo("effect_cue_triggered", PropertyInfo(Variant::DICTIONARY, "cue")));
	ADD_SIGNAL(MethodInfo("prediction_phase_changed", PropertyInfo(Variant::DICTIONARY, "payload")));
	ADD_SIGNAL(MethodInfo("replication_gap_detected", PropertyInfo(Variant::DICTIONARY, "payload")));
	ADD_SIGNAL(MethodInfo("diagnostics_reported", PropertyInfo(Variant::DICTIONARY, "event")));
	// Finding 5: emitted when a snapshot restore's own rollback ALSO fails
	// (see `rollback_or_quarantine()`) -- this component is now quarantined
	// (`is_configured()` reports false; every mutating entry point fails
	// closed) and genuinely unrecoverable. `status` is the ORIGINAL restore/
	// reconcile failure (not the rollback's own failure) so the game can see
	// what went wrong; the fix is always the same regardless: discard this
	// instance and rebuild via a fresh `configure()`.
	ADD_SIGNAL(MethodInfo("desync_rebuild_required", PropertyInfo(Variant::DICTIONARY, "status")));

	BIND_ENUM_CONSTANT(ROLE_OFFLINE_AUTHORITY);
	BIND_ENUM_CONSTANT(ROLE_SERVER_AUTHORITY);
	BIND_ENUM_CONSTANT(ROLE_NETWORK_CLIENT);

	BIND_ENUM_CONSTANT(PROVENANCE_AUTHORITATIVE);
	BIND_ENUM_CONSTANT(PROVENANCE_PREDICTED);

	BIND_ENUM_CONSTANT(PHASE_REQUESTED);
	BIND_ENUM_CONSTANT(PHASE_VALIDATING);
	BIND_ENUM_CONSTANT(PHASE_BEGUN);
	BIND_ENUM_CONSTANT(PHASE_COMMITTED);
	BIND_ENUM_CONSTANT(PHASE_ACTIVE);
	BIND_ENUM_CONSTANT(PHASE_ENDED);
	BIND_ENUM_CONSTANT(PHASE_CANCELLED);

	BIND_ENUM_CONSTANT(END_REASON_NONE);
	BIND_ENUM_CONSTANT(END_REASON_EXPLICIT_SUCCESS);
	BIND_ENUM_CONSTANT(END_REASON_EXPLICIT_CANCEL);
	BIND_ENUM_CONSTANT(END_REASON_CANCEL_TAG);
	BIND_ENUM_CONSTANT(END_REASON_REVOKED);
	BIND_ENUM_CONSTANT(END_REASON_OWNER_TEARDOWN);
	BIND_ENUM_CONSTANT(END_REASON_AUTHORITY_CORRECTION);
	BIND_ENUM_CONSTANT(END_REASON_HOOK_FAILURE);

	BIND_ENUM_CONSTANT(LIFECYCLE_GRANTED);
	BIND_ENUM_CONSTANT(LIFECYCLE_REVOKED);
	BIND_ENUM_CONSTANT(LIFECYCLE_REQUESTED);
	BIND_ENUM_CONSTANT(LIFECYCLE_PHASE_CHANGED);
	BIND_ENUM_CONSTANT(LIFECYCLE_COMMITTED);
	BIND_ENUM_CONSTANT(LIFECYCLE_ENDED);
	BIND_ENUM_CONSTANT(LIFECYCLE_CANCELLED);
	BIND_ENUM_CONSTANT(LIFECYCLE_FAILED);
	BIND_ENUM_CONSTANT(LIFECYCLE_SNAPSHOT_RESTORED);

	BIND_ENUM_CONSTANT(DIAGNOSTIC_EVENT_RECURSION_LIMIT_REACHED);
	BIND_ENUM_CONSTANT(DIAGNOSTIC_EVENT_CAPABILITY_VIOLATION_DETECTED);
	BIND_ENUM_CONSTANT(DIAGNOSTIC_EVENT_ROLE_VIOLATION_DETECTED);

	BIND_ENUM_CONSTANT(EFFECT_LIFECYCLE_APPLIED);
	BIND_ENUM_CONSTANT(EFFECT_LIFECYCLE_STACK_CHANGED);
	BIND_ENUM_CONSTANT(EFFECT_LIFECYCLE_PERIODIC_EXECUTED);
	BIND_ENUM_CONSTANT(EFFECT_LIFECYCLE_REMOVED);
	BIND_ENUM_CONSTANT(EFFECT_LIFECYCLE_EXPIRED);

	BIND_ENUM_CONSTANT(EFFECT_REMOVAL_NONE);
	BIND_ENUM_CONSTANT(EFFECT_REMOVAL_EXPLICIT);
	BIND_ENUM_CONSTANT(EFFECT_REMOVAL_EXPIRED);
	BIND_ENUM_CONSTANT(EFFECT_REMOVAL_REPLACED_BY_STACK_POLICY);

	BIND_ENUM_CONSTANT(CUE_PREDICT);
	BIND_ENUM_CONSTANT(CUE_CONFIRM);
	BIND_ENUM_CONSTANT(CUE_CORRECT);
	BIND_ENUM_CONSTANT(CUE_CANCEL);
	BIND_ENUM_CONSTANT(CUE_AUTHORITY_ONLY);
	BIND_ENUM_CONSTANT(CUE_SNAPSHOT_RESTORED);

	BIND_ENUM_CONSTANT(TASK_WAIT_TICKS);
	BIND_ENUM_CONSTANT(TASK_WAIT_GAMEPLAY_EVENT);
	BIND_ENUM_CONSTANT(TASK_WAIT_TAG_QUERY);
	BIND_ENUM_CONSTANT(TASK_WAIT_LOGICAL_INPUT);
	BIND_ENUM_CONSTANT(TASK_WAIT_AUTHORITY);
	BIND_ENUM_CONSTANT(TASK_WAIT_TARGET_DATA);
	BIND_ENUM_CONSTANT(TASK_ACTIVE);
	BIND_ENUM_CONSTANT(TASK_COMPLETED);
	BIND_ENUM_CONSTANT(TASK_FAILED);
	BIND_ENUM_CONSTANT(TASK_TIMED_OUT);
	BIND_ENUM_CONSTANT(TASK_CANCELLED);
	BIND_ENUM_CONSTANT(TASK_CANCEL_NONE);
	BIND_ENUM_CONSTANT(TASK_CANCEL_EXPLICIT);
	BIND_ENUM_CONSTANT(TASK_CANCEL_PARENT_ENDED);
	BIND_ENUM_CONSTANT(TASK_CANCEL_PARENT_CANCELLED);
	BIND_ENUM_CONSTANT(TASK_CANCEL_SPEC_REVOKED);
	BIND_ENUM_CONSTANT(TASK_CANCEL_OWNER_TEARDOWN);
	BIND_ENUM_CONSTANT(TASK_CANCEL_AUTHORITY_CORRECTION);
	BIND_ENUM_CONSTANT(TASK_CANCEL_TARGET_SESSION);
	BIND_ENUM_CONSTANT(LOGICAL_INPUT_PRESS);
	BIND_ENUM_CONSTANT(LOGICAL_INPUT_RELEASE);
	BIND_ENUM_CONSTANT(LOGICAL_INPUT_CONFIRM);
	BIND_ENUM_CONSTANT(LOGICAL_INPUT_CANCEL);

	BIND_ENUM_CONSTANT(STATUS_OK);
	BIND_ENUM_CONSTANT(STATUS_INVALID_ARGUMENT);
	BIND_ENUM_CONSTANT(STATUS_NOT_FOUND);
	BIND_ENUM_CONSTANT(STATUS_ALREADY_EXISTS);
	BIND_ENUM_CONSTANT(STATUS_OUT_OF_BOUNDS);
	BIND_ENUM_CONSTANT(STATUS_ARITHMETIC_ERROR);
	BIND_ENUM_CONSTANT(STATUS_CAPACITY_EXCEEDED);
	BIND_ENUM_CONSTANT(STATUS_NOT_SUPPORTED);
	BIND_ENUM_CONSTANT(STATUS_INTERNAL_ERROR);
	BIND_ENUM_CONSTANT(STATUS_INVALID_IDENTIFIER);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_INVALID_REFERENCE);
	BIND_ENUM_CONSTANT(STATUS_REGISTRY_SEALED);
	BIND_ENUM_CONSTANT(STATUS_MANIFEST_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_TAG);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_TAG_SOURCE);
	BIND_ENUM_CONSTANT(STATUS_TAG_COUNT_UNDERFLOW);
	BIND_ENUM_CONSTANT(STATUS_INVALID_QUERY);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_ATTRIBUTE);
	BIND_ENUM_CONSTANT(STATUS_INVALID_BOUNDS);
	BIND_ENUM_CONSTANT(STATUS_INSUFFICIENT_ATTRIBUTE);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_MODIFIER);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_EFFECT);
	BIND_ENUM_CONSTANT(STATUS_INVALID_EFFECT_SPEC);
	BIND_ENUM_CONSTANT(STATUS_EFFECT_REQUIREMENTS_FAILED);
	BIND_ENUM_CONSTANT(STATUS_EFFECT_IMMUNE);
	BIND_ENUM_CONSTANT(STATUS_EFFECT_STACK_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_EFFECT_HANDLE);
	BIND_ENUM_CONSTANT(STATUS_MISSING_SET_BY_CALLER);
	BIND_ENUM_CONSTANT(STATUS_UNDECLARED_SET_BY_CALLER);
	BIND_ENUM_CONSTANT(STATUS_HOOK_FAILED);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_ABILITY);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_NOT_GRANTED);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_ALREADY_GRANTED);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_ALREADY_ACTIVE);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_MISSING_TAG);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_BLOCKED_TAG);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_ON_COOLDOWN);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_COST_UNAFFORDABLE);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_INVALID_TARGET);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_ALREADY_ENDED);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_REVOKED);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_POLICY_VIOLATION);
	BIND_ENUM_CONSTANT(STATUS_RECURSION_LIMIT);
	BIND_ENUM_CONSTANT(STATUS_CAPABILITY_VIOLATION);
	BIND_ENUM_CONSTANT(STATUS_ROLE_VIOLATION);
	BIND_ENUM_CONSTANT(STATUS_NOT_AUTHORITY);
	BIND_ENUM_CONSTANT(STATUS_NOT_OWNER);
	BIND_ENUM_CONSTANT(STATUS_PERMISSION_DENIED);
	BIND_ENUM_CONSTANT(STATUS_NETWORK_UNAVAILABLE);
	BIND_ENUM_CONSTANT(STATUS_PROTOCOL_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_SESSION_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_STALE_COMMAND);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_COMMAND);
	BIND_ENUM_CONSTANT(STATUS_RATE_LIMITED);
	BIND_ENUM_CONSTANT(STATUS_SEQUENCE_GAP);
	BIND_ENUM_CONSTANT(STATUS_DECODE_FAILED);
	BIND_ENUM_CONSTANT(STATUS_PAYLOAD_TOO_LARGE);
	BIND_ENUM_CONSTANT(STATUS_SNAPSHOT_REQUIRED);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_NETWORK_IDENTITY);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_UNAVAILABLE);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_NOT_SAFE);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_JOURNAL_FULL);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_BASELINE_LOST);
	BIND_ENUM_CONSTANT(STATUS_PREDICTION_UNKNOWN_KEY);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_ABILITY_TASK);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_TASK_ALREADY_TERMINAL);
	BIND_ENUM_CONSTANT(STATUS_INVALID_ABILITY_TASK);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_TASK_TIMED_OUT);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_TASK_CANCELLED);
	BIND_ENUM_CONSTANT(STATUS_ABILITY_TASK_INPUT_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_TARGET_SCHEMA);
	BIND_ENUM_CONSTANT(STATUS_INVALID_TARGET_DATA);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_TARGET_SESSION);
	BIND_ENUM_CONSTANT(STATUS_TARGET_SESSION_ALREADY_TERMINAL);
	BIND_ENUM_CONSTANT(STATUS_TARGET_PROVIDER_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_TARGET_BATCH_REJECTED);
}

} // namespace godot
