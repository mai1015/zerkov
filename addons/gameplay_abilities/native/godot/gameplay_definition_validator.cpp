#include "godot/gameplay_definition_validator.h"

#include "godot/gameplay_ability_godot_util.h"

#include "resources/gameplay_ability_trigger.h"
#include "resources/gameplay_magnitude.h"
#include "resources/gameplay_modifier_declaration.h"
#include "resources/gameplay_set_by_caller_field.h"
#include "resources/gameplay_stacking_policy.h"
#include "resources/gameplay_tag_operand.h"
#include "resources/gameplay_tag_reaction_definition.h"

#include "core/ga_abilities.h"
#include "core/ga_attributes.h"
#include "core/ga_bytes.h"
#include "core/ga_effects.h"
#include "core/ga_hash.h"
#include "core/ga_identifier.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_prediction.h"
#include "core/ga_status.h"
#include "core/ga_tag_query.h"
#include "core/ga_tag_reactions.h"
#include "core/ga_tags.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace godot {

namespace {

const char *SEV_ERROR = "error";

String slot_label(const char *p_collection, int p_index) {
	return vformat("<%s[%d]>", p_collection, p_index);
}

// Resolves a Resource's addressable label for a finding: its saved path when
// it has one, otherwise a positional fallback naming the collection/slot it
// came from (mirrors CommonUIInputConfig::validate()'s `<slot %d>` pattern).
String resource_label(const Ref<Resource> &p_resource, const char *p_collection, int p_index) {
	if (p_resource.is_valid() && !p_resource->get_path().is_empty()) {
		return p_resource->get_path();
	}
	return slot_label(p_collection, p_index);
}

Dictionary make_finding(const String &p_severity, const String &p_resource_path, const String &p_field,
		const String &p_code, const String &p_message) {
	Dictionary finding;
	finding["severity"] = p_severity;
	finding["resource_path"] = p_resource_path;
	finding["field"] = p_field;
	finding["code"] = p_code;
	finding["message"] = p_message;
	return finding;
}

// Lowercase snake_case name for every `ga::DiagnosticId` this validator's
// entry points can actually surface. Diagnostics are the core's most specific
// available signal, so they take priority over the coarser `StatusCode` name
// below whenever a `Status` carries one.
String diagnostic_code(ga::DiagnosticId p_diagnostic) {
	switch (p_diagnostic) {
		case ga::DiagnosticId::IDENTIFIER_EMPTY_SEGMENT:
			return "identifier_empty_segment";
		case ga::DiagnosticId::IDENTIFIER_BAD_CHARACTER:
			return "identifier_bad_character";
		case ga::DiagnosticId::IDENTIFIER_NOT_NAMESPACED:
			return "identifier_not_namespaced";
		case ga::DiagnosticId::IDENTIFIER_TOO_LONG:
			return "identifier_too_long";
		case ga::DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS:
			return "identifier_too_many_segments";
		case ga::DiagnosticId::DEFINITION_DUPLICATE:
			return "duplicate_definition";
		case ga::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE:
			return "unknown_reference";
		case ga::DiagnosticId::VALUE_NOT_REPRESENTABLE:
			return "value_not_representable";
		case ga::DiagnosticId::BOUNDS_INVERTED:
			return "bounds_inverted";
		case ga::DiagnosticId::TICK_RATE_UNSUPPORTED:
			return "tick_rate_unsupported";
		case ga::DiagnosticId::QUERY_TOO_DEEP:
			return "query_too_deep";
		case ga::DiagnosticId::QUERY_TOO_MANY_OPERANDS:
			return "query_too_many_operands";
		case ga::DiagnosticId::COUNT_LIMIT_EXCEEDED:
			return "count_limit_exceeded";
		case ga::DiagnosticId::BYTE_LIMIT_EXCEEDED:
			return "byte_limit_exceeded";
		case ga::DiagnosticId::PERIOD_INVALID:
			return "period_invalid";
		case ga::DiagnosticId::DURATION_INVALID:
			return "duration_invalid";
		default:
			return vformat("diagnostic_%d", static_cast<int>(p_diagnostic));
	}
}

// Fallback name for a `Status` whose `diagnostic == DiagnosticId::NONE` (the
// core reserves that for cases the `StatusCode` alone already identifies
// precisely enough, e.g. `UNDECLARED_SET_BY_CALLER`).
String status_code_name(ga::StatusCode p_code) {
	switch (p_code) {
		case ga::StatusCode::INVALID_ARGUMENT:
			return "invalid_argument";
		case ga::StatusCode::NOT_FOUND:
			return "not_found";
		case ga::StatusCode::ALREADY_EXISTS:
			return "already_exists";
		case ga::StatusCode::OUT_OF_BOUNDS:
			return "out_of_bounds";
		case ga::StatusCode::ARITHMETIC_ERROR:
			return "arithmetic_error";
		case ga::StatusCode::CAPACITY_EXCEEDED:
			return "capacity_exceeded";
		case ga::StatusCode::NOT_SUPPORTED:
			return "not_supported";
		case ga::StatusCode::INTERNAL_ERROR:
			return "internal_error";
		case ga::StatusCode::INVALID_IDENTIFIER:
			return "invalid_identifier";
		case ga::StatusCode::DUPLICATE_DEFINITION:
			return "duplicate_definition";
		case ga::StatusCode::UNKNOWN_DEFINITION:
			return "unknown_reference";
		case ga::StatusCode::INVALID_REFERENCE:
			return "invalid_reference";
		case ga::StatusCode::REGISTRY_SEALED:
			return "internal_error";
		case ga::StatusCode::MANIFEST_MISMATCH:
			return "manifest_mismatch";
		case ga::StatusCode::UNKNOWN_TAG:
			return "unknown_reference";
		case ga::StatusCode::UNKNOWN_TAG_SOURCE:
			return "unknown_reference";
		case ga::StatusCode::INVALID_QUERY:
			return "invalid_query";
		case ga::StatusCode::UNKNOWN_ATTRIBUTE:
			return "unknown_reference";
		case ga::StatusCode::INVALID_BOUNDS:
			return "bounds_inverted";
		case ga::StatusCode::UNKNOWN_EFFECT:
			return "unknown_reference";
		case ga::StatusCode::MISSING_SET_BY_CALLER:
			return "missing_set_by_caller";
		case ga::StatusCode::UNDECLARED_SET_BY_CALLER:
			return "undeclared_set_by_caller";
		default:
			return vformat("status_%d", static_cast<int>(p_code));
	}
}

String status_code(const ga::Status &p_status) {
	if (p_status.diagnostic != ga::DiagnosticId::NONE) {
		return diagnostic_code(p_status.diagnostic);
	}
	return status_code_name(p_status.code);
}

Dictionary status_finding(const String &p_resource_path, const String &p_field, const ga::Status &p_status,
		const String &p_message) {
	return make_finding(SEV_ERROR, p_resource_path, p_field, status_code(p_status), p_message);
}

bool build_target_schema_registry(
		const TypedArray<GameplayTargetDataSchema> &p_schemas,
		const char *p_collection, Array &r_findings,
		ga::TargetSchemaRegistry &r_registry,
		std::map<std::string, String> &r_paths) {
	for (int i = 0; i < p_schemas.size(); ++i) {
		const Ref<GameplayTargetDataSchema> schema = p_schemas[i];
		if (schema.is_null()) {
			r_findings.append(make_finding(SEV_ERROR,
					slot_label(p_collection, i), "", "null_resource",
					vformat("Target data schema slot %d is empty.", i)));
			continue;
		}
		const String path =
				resource_label(schema, p_collection, i);
		const ga::TargetSchemaDesc desc = schema->to_core_desc();
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status =
				r_registry.register_schema(desc, unused_id);
		if (!status.ok()) {
			String field = "schema";
			if (status.code == ga::StatusCode::INVALID_IDENTIFIER) {
				field = "identifier";
			} else if (status.diagnostic ==
					ga::DiagnosticId::INVALID_TARGET_COORDINATE) {
				field = "spatial_contract";
			} else if (status.diagnostic ==
							ga::DiagnosticId::COUNT_LIMIT_EXCEEDED ||
					status.diagnostic ==
							ga::DiagnosticId::BYTE_LIMIT_EXCEEDED) {
				field = "bounds";
			} else if (status.diagnostic ==
					ga::DiagnosticId::INVALID_TARGET_SCHEMA) {
				field = "schema_contract";
			}
			r_findings.append(status_finding(path, field, status,
					vformat("Target data schema '%s' is invalid.",
							String(schema->get_identifier()))));
			continue;
		}
		r_paths[desc.identifier] = path;
	}
	const ga::Status seal_status = r_registry.seal();
	if (!seal_status.ok()) {
		r_findings.append(status_finding("", p_collection,
				seal_status,
				"Failed to seal the typed target schema registry."));
		return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Resource -> core desc conversions. Every one of these is a straight field
// copy into the exact shape the core's own `register_*`/`build_*` functions
// consume -- no normalization, no re-validation happens here.
// ---------------------------------------------------------------------------

std::vector<ga::TagOperandDesc> to_operand_vector(const TypedArray<GameplayTagOperand> &p_operands) {
	std::vector<ga::TagOperandDesc> result;
	result.reserve(p_operands.size());
	for (int i = 0; i < p_operands.size(); ++i) {
		const Ref<GameplayTagOperand> operand = p_operands[i];
		if (operand.is_null()) {
			continue; // an empty slot contributes no operand; see file comment.
		}
		ga::TagOperandDesc desc;
		desc.tag = to_std(String(operand->get_tag()));
		desc.mode = operand->get_match_mode() == GameplayTagOperand::MATCH_PARENT_AWARE
				? ga::TagMatchMode::PARENT_AWARE
				: ga::TagMatchMode::EXACT;
		result.push_back(desc);
	}
	return result;
}

ga::TagRequirementDesc to_tag_requirement_desc(const Ref<GameplayTagQueryResource> &p_query) {
	ga::TagRequirementDesc desc;
	if (p_query.is_null()) {
		return desc; // no query authored == the trivial always-true requirement.
	}
	desc.all = to_operand_vector(p_query->get_all_of());
	desc.any = to_operand_vector(p_query->get_any_of());
	desc.none = to_operand_vector(p_query->get_none_of());
	return desc;
}

ga::MagnitudeSourceDesc to_magnitude_desc(const Ref<GameplayMagnitude> &p_magnitude) {
	ga::MagnitudeSourceDesc desc;
	if (p_magnitude.is_null()) {
		return desc; // defaults to CONSTANT, coefficient 1.0.
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
	ga::StackingPolicyDesc desc; // matches core defaults when nothing is authored.
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

	const PackedStringArray granted_tags = p_effect->get_granted_tags();
	desc.granted_tags.reserve(granted_tags.size());
	for (int i = 0; i < granted_tags.size(); ++i) {
		desc.granted_tags.push_back(to_std(granted_tags[i]));
	}

	desc.source_requirements = to_tag_requirement_desc(p_effect->get_source_requirements());
	desc.target_requirements = to_tag_requirement_desc(p_effect->get_target_requirements());
	desc.immunity = to_tag_requirement_desc(p_effect->get_immunity());
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

	const PackedStringArray cues = p_effect->get_cue_identifiers();
	desc.cue_identifiers.reserve(cues.size());
	for (int i = 0; i < cues.size(); ++i) {
		desc.cue_identifiers.push_back(to_std(cues[i]));
	}

	desc.prediction_safe = p_effect->get_prediction_safe();
	desc.retain_target_context =
			p_effect->get_retain_target_context();
	return desc;
}

// Best-effort attribution of a `register_effect` failure's `Status::detail`
// (an FNV1a64 hash, see `ga::hash_string`) back to the authored field it came
// from, by re-hashing every identifier this effect resource references and
// comparing. `register_effect`'s `Status` never names a field directly (it
// only carries the failing identifier's hash, see ga_effects.h), so this is
// the only way to recover field-level precision for a finding.
bool try_locate_effect_field(const Ref<GameplayEffectDefinition> &p_effect, std::uint64_t p_detail,
		String &r_field, String &r_identifier) {
	auto matches = [&](const String &p_text) {
		return !p_text.is_empty() && ga::hash_string(to_std(p_text)) == p_detail;
	};

	if (matches(String(p_effect->get_identifier()))) {
		r_field = "identifier";
		r_identifier = String(p_effect->get_identifier());
		return true;
	}

	const TypedArray<GameplayModifierDeclaration> modifiers = p_effect->get_modifiers();
	for (int i = 0; i < modifiers.size(); ++i) {
		const Ref<GameplayModifierDeclaration> modifier = modifiers[i];
		if (modifier.is_null()) {
			continue;
		}
		if (matches(String(modifier->get_target_attribute()))) {
			r_field = vformat("modifiers[%d].target_attribute", i);
			r_identifier = String(modifier->get_target_attribute());
			return true;
		}
		const Ref<GameplayMagnitude> magnitude = modifier->get_magnitude();
		if (magnitude.is_valid() && matches(String(magnitude->get_attribute()))) {
			r_field = vformat("modifiers[%d].magnitude.attribute", i);
			r_identifier = String(magnitude->get_attribute());
			return true;
		}
	}

	const PackedStringArray granted_tags = p_effect->get_granted_tags();
	for (int i = 0; i < granted_tags.size(); ++i) {
		if (matches(granted_tags[i])) {
			r_field = vformat("granted_tags[%d]", i);
			r_identifier = granted_tags[i];
			return true;
		}
	}

	struct RequirementSlot {
		const char *label;
		Ref<GameplayTagQueryResource> query;
	};
	const RequirementSlot requirement_slots[] = {
		{ "source_requirements", p_effect->get_source_requirements() },
		{ "target_requirements", p_effect->get_target_requirements() },
		{ "immunity", p_effect->get_immunity() },
	};
	for (const RequirementSlot &slot : requirement_slots) {
		if (slot.query.is_null()) {
			continue;
		}
		struct ClauseSlot {
			const char *label;
			TypedArray<GameplayTagOperand> operands;
		};
		const ClauseSlot clause_slots[] = {
			{ "all_of", slot.query->get_all_of() },
			{ "any_of", slot.query->get_any_of() },
			{ "none_of", slot.query->get_none_of() },
		};
		for (const ClauseSlot &clause : clause_slots) {
			for (int i = 0; i < clause.operands.size(); ++i) {
				const Ref<GameplayTagOperand> operand = clause.operands[i];
				if (operand.is_null()) {
					continue;
				}
				if (matches(String(operand->get_tag()))) {
					r_field = vformat("%s.%s[%d].tag", slot.label, clause.label, i);
					r_identifier = String(operand->get_tag());
					return true;
				}
			}
		}
	}

	const PackedStringArray cues = p_effect->get_cue_identifiers();
	for (int i = 0; i < cues.size(); ++i) {
		if (matches(cues[i])) {
			r_field = vformat("cue_identifiers[%d]", i);
			r_identifier = cues[i];
			return true;
		}
	}

	return false;
}

Dictionary effect_status_finding(const Ref<GameplayEffectDefinition> &p_effect, const String &p_resource_path,
		const ga::Status &p_status) {
	String field = "effect";
	String identifier;
	if (try_locate_effect_field(p_effect, p_status.detail, field, identifier)) {
		return status_finding(p_resource_path, field,
				p_status, vformat("Effect '%s' references unresolved '%s' (%s).",
									 String(p_effect->get_identifier()), identifier, field));
	}
	return status_finding(p_resource_path, field, p_status,
			vformat("Effect '%s' failed validation.", String(p_effect->get_identifier())));
}

// ---------------------------------------------------------------------------
// Ability resource -> core desc conversion (task 9.1 remainder / 8.1 seam).
// Same "straight field copy, no re-validation" convention as the effect
// converters above.
// ---------------------------------------------------------------------------

ga::AbilityTriggerDesc to_trigger_desc(const Ref<GameplayAbilityTrigger> &p_trigger) {
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

ga::AbilityDefinitionDesc to_ability_desc(const Ref<GameplayAbilityDefinition> &p_ability) {
	ga::AbilityDefinitionDesc desc;
	desc.identifier = to_std(String(p_ability->get_identifier()));
	switch (p_ability->get_activation_policy()) {
		case GameplayAbilityDefinition::ACTIVATION_GAMEPLAY_EVENT:
			desc.activation_policy = ga::ActivationPolicy::GAMEPLAY_EVENT;
			break;
		case GameplayAbilityDefinition::ACTIVATION_PASSIVE_ON_GRANT:
			desc.activation_policy = ga::ActivationPolicy::PASSIVE_ON_GRANT;
			break;
		case GameplayAbilityDefinition::ACTIVATION_MANUAL:
		default:
			desc.activation_policy = ga::ActivationPolicy::MANUAL;
			break;
	}
	desc.required_tags = to_tag_requirement_desc(p_ability->get_required_tags());
	desc.blocked_tags = to_tag_requirement_desc(p_ability->get_blocked_tags());

	const PackedStringArray owned = p_ability->get_owned_tags();
	desc.owned_tags.reserve(owned.size());
	for (int i = 0; i < owned.size(); ++i) {
		desc.owned_tags.push_back(to_std(owned[i]));
	}

	desc.cancel_tags = to_tag_requirement_desc(p_ability->get_cancel_tags());
	desc.cost_effect = to_std(String(p_ability->get_cost_effect()));
	desc.cooldown_effect = to_std(String(p_ability->get_cooldown_effect()));

	const PackedStringArray commit_effects = p_ability->get_commit_effects();
	desc.commit_effects.reserve(commit_effects.size());
	for (int i = 0; i < commit_effects.size(); ++i) {
		desc.commit_effects.push_back(to_std(commit_effects[i]));
	}

	const TypedArray<GameplayAbilityTrigger> triggers = p_ability->get_triggers();
	desc.triggers.reserve(triggers.size());
	for (int i = 0; i < triggers.size(); ++i) {
		const Ref<GameplayAbilityTrigger> trigger = triggers[i];
		if (trigger.is_null()) {
			continue; // an empty slot contributes no trigger; matches the tag-operand convention above.
		}
		desc.triggers.push_back(to_trigger_desc(trigger));
	}

	switch (p_ability->get_concurrency_policy()) {
		case GameplayAbilityDefinition::CONCURRENCY_ALLOW_MULTIPLE:
			desc.concurrency_policy = ga::AbilityConcurrencyPolicy::ALLOW_MULTIPLE;
			break;
		case GameplayAbilityDefinition::CONCURRENCY_REJECT_IF_ACTIVE:
		default:
			desc.concurrency_policy = ga::AbilityConcurrencyPolicy::REJECT_IF_ACTIVE;
			break;
	}
	switch (p_ability->get_duplicate_grant_policy()) {
		case GameplayAbilityDefinition::DUPLICATE_GRANT_REPLACE:
			desc.duplicate_grant_policy = ga::AbilityDuplicateGrantPolicy::REPLACE;
			break;
		case GameplayAbilityDefinition::DUPLICATE_GRANT_MULTI_GRANT:
			desc.duplicate_grant_policy = ga::AbilityDuplicateGrantPolicy::MULTI_GRANT;
			break;
		case GameplayAbilityDefinition::DUPLICATE_GRANT_REJECT:
		default:
			desc.duplicate_grant_policy = ga::AbilityDuplicateGrantPolicy::REJECT;
			break;
	}
	desc.revoke_policy = p_ability->get_revoke_policy() == GameplayAbilityDefinition::REVOKE_PERMIT_COMPLETION
			? ga::AbilityRevokePolicy::PERMIT_COMPLETION
			: ga::AbilityRevokePolicy::CANCEL_ACTIVE;
	desc.prediction_policy = p_ability->get_prediction_policy() == GameplayAbilityDefinition::PREDICTION_PREDICTABLE
			? ga::AbilityPredictionPolicy::PREDICTABLE
			: ga::AbilityPredictionPolicy::NOT_PREDICTABLE;
	switch (p_ability->get_hook_binding()) {
		case GameplayAbilityDefinition::HOOK_BINDING_AUTHORITY_ONLY:
			desc.hook_binding = ga::AbilityHookBinding::AUTHORITY_ONLY;
			break;
		case GameplayAbilityDefinition::HOOK_BINDING_PREDICTION_SAFE:
			desc.hook_binding = ga::AbilityHookBinding::PREDICTION_SAFE;
			break;
		case GameplayAbilityDefinition::HOOK_BINDING_NONE:
		default:
			desc.hook_binding = ga::AbilityHookBinding::NONE;
			break;
	}
	desc.auto_commit = p_ability->get_auto_commit();
	desc.ends_on_commit = p_ability->get_ends_on_commit();
	desc.prediction_safe_declared = p_ability->get_prediction_safe_declared();
	return desc;
}

// Best-effort attribution of a `register_ability` failure's `Status::detail`
// back to the authored field it came from -- same technique (and same
// limitation) as `try_locate_effect_field` above.
bool try_locate_ability_field(const Ref<GameplayAbilityDefinition> &p_ability, std::uint64_t p_detail,
		String &r_field, String &r_identifier) {
	auto matches = [&](const String &p_text) {
		return !p_text.is_empty() && ga::hash_string(to_std(p_text)) == p_detail;
	};

	if (matches(String(p_ability->get_identifier()))) {
		r_field = "identifier";
		r_identifier = String(p_ability->get_identifier());
		return true;
	}
	if (matches(String(p_ability->get_cost_effect()))) {
		r_field = "cost_effect";
		r_identifier = String(p_ability->get_cost_effect());
		return true;
	}
	if (matches(String(p_ability->get_cooldown_effect()))) {
		r_field = "cooldown_effect";
		r_identifier = String(p_ability->get_cooldown_effect());
		return true;
	}

	const PackedStringArray commit_effects = p_ability->get_commit_effects();
	for (int i = 0; i < commit_effects.size(); ++i) {
		if (matches(commit_effects[i])) {
			r_field = vformat("commit_effects[%d]", i);
			r_identifier = commit_effects[i];
			return true;
		}
	}

	const PackedStringArray owned_tags = p_ability->get_owned_tags();
	for (int i = 0; i < owned_tags.size(); ++i) {
		if (matches(owned_tags[i])) {
			r_field = vformat("owned_tags[%d]", i);
			r_identifier = owned_tags[i];
			return true;
		}
	}

	struct RequirementSlot {
		const char *label;
		Ref<GameplayTagQueryResource> query;
	};
	const RequirementSlot requirement_slots[] = {
		{ "required_tags", p_ability->get_required_tags() },
		{ "blocked_tags", p_ability->get_blocked_tags() },
		{ "cancel_tags", p_ability->get_cancel_tags() },
	};
	for (const RequirementSlot &slot : requirement_slots) {
		if (slot.query.is_null()) {
			continue;
		}
		struct ClauseSlot {
			const char *label;
			TypedArray<GameplayTagOperand> operands;
		};
		const ClauseSlot clause_slots[] = {
			{ "all_of", slot.query->get_all_of() },
			{ "any_of", slot.query->get_any_of() },
			{ "none_of", slot.query->get_none_of() },
		};
		for (const ClauseSlot &clause : clause_slots) {
			for (int i = 0; i < clause.operands.size(); ++i) {
				const Ref<GameplayTagOperand> operand = clause.operands[i];
				if (operand.is_null()) {
					continue;
				}
				if (matches(String(operand->get_tag()))) {
					r_field = vformat("%s.%s[%d].tag", slot.label, clause.label, i);
					r_identifier = String(operand->get_tag());
					return true;
				}
			}
		}
	}

	const TypedArray<GameplayAbilityTrigger> triggers = p_ability->get_triggers();
	for (int i = 0; i < triggers.size(); ++i) {
		const Ref<GameplayAbilityTrigger> trigger = triggers[i];
		if (trigger.is_null()) {
			continue;
		}
		if (matches(trigger->get_input_id())) {
			r_field = vformat("triggers[%d].input_id", i);
			r_identifier = trigger->get_input_id();
			return true;
		}
		if (matches(String(trigger->get_gameplay_event_tag()))) {
			r_field = vformat("triggers[%d].gameplay_event_tag", i);
			r_identifier = String(trigger->get_gameplay_event_tag());
			return true;
		}
	}

	return false;
}

Dictionary ability_status_finding(const Ref<GameplayAbilityDefinition> &p_ability, const String &p_resource_path,
		const ga::Status &p_status) {
	String field = "ability";
	String identifier;
	if (try_locate_ability_field(p_ability, p_status.detail, field, identifier)) {
		return status_finding(p_resource_path, field,
				p_status, vformat("Ability '%s' references unresolved '%s' (%s).",
									 String(p_ability->get_identifier()), identifier, field));
	}
	return status_finding(p_resource_path, field, p_status,
			vformat("Ability '%s' failed validation.", String(p_ability->get_identifier())));
}

} // namespace

Array GameplayDefinitionValidator::validate(const TypedArray<GameplayTagDefinition> &p_tags,
		const TypedArray<GameplayAttributeDefinition> &p_attributes,
		const TypedArray<GameplayEffectDefinition> &p_effects,
		const TypedArray<GameplayCueDefinition> &p_cues,
		const TypedArray<GameplayTagQueryResource> &p_tag_queries,
		const TypedArray<GameplayTargetDataSchema> &p_target_schemas) {
	Array findings;
	last_manifest_ok = false;
	last_manifest_fingerprint = 0;
	last_manifest_entry_count = 0;
	last_manifest_tick_rate = 0;

	// -----------------------------------------------------------------
	// Tags
	// -----------------------------------------------------------------
	ga::TagRegistry tag_registry;
	for (int i = 0; i < p_tags.size(); ++i) {
		const Ref<GameplayTagDefinition> tag = p_tags[i];
		if (tag.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("tags", i), "", "null_resource",
					vformat("Tag slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(tag, "tags", i);
		ga::TagDefinitionDesc desc;
		desc.identifier = to_std(String(tag->get_identifier()));
		desc.description = to_std(tag->get_description());
		desc.source_label = to_std(tag->get_source_label().is_empty() ? path : tag->get_source_label());

		ga::TagRegistrationConflict conflict;
		const ga::Status status = tag_registry.register_tag(desc, &conflict);
		if (!status.ok()) {
			String message = vformat("Tag '%s' failed to register.", String(tag->get_identifier()));
			if (status.code == ga::StatusCode::DUPLICATE_DEFINITION && !conflict.identifier.empty()) {
				message = vformat("Tag identifier '%s' is declared by both '%s' and '%s'.",
						String(conflict.identifier.c_str()), String(conflict.first_source_label.c_str()),
						String(conflict.second_source_label.c_str()));
			}
			findings.append(status_finding(path, "identifier", status, message));
		}
	}
	const ga::Status tag_seal_status = tag_registry.seal();
	const bool tags_sealed = tag_seal_status.ok();
	if (!tags_sealed) {
		findings.append(status_finding("", "tags", tag_seal_status, "Failed to seal the tag registry."));
	}

	// -----------------------------------------------------------------
	// Attributes
	// -----------------------------------------------------------------
	ga::AttributeRegistry attribute_registry;
	for (int i = 0; i < p_attributes.size(); ++i) {
		const Ref<GameplayAttributeDefinition> attribute = p_attributes[i];
		if (attribute.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("attributes", i), "", "null_resource",
					vformat("Attribute slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(attribute, "attributes", i);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = attribute_registry.register_attribute(to_std(String(attribute->get_identifier())),
				attribute->get_default_base(), attribute->get_has_min(), attribute->get_min_value(),
				attribute->get_has_max(), attribute->get_max_value(), to_std(attribute->get_display_name()),
				unused_id);
		if (!status.ok()) {
			String field = "identifier";
			if (status.diagnostic == ga::DiagnosticId::BOUNDS_INVERTED) {
				field = "bounds";
			} else if (status.diagnostic == ga::DiagnosticId::VALUE_NOT_REPRESENTABLE) {
				field = "default_base|min_value|max_value";
			}
			findings.append(status_finding(path, field, status,
					vformat("Attribute '%s' failed to register.", String(attribute->get_identifier()))));
		}
	}
	const ga::Status attribute_seal_status = attribute_registry.seal();
	const bool attributes_sealed = attribute_seal_status.ok();
	if (!attributes_sealed) {
		findings.append(status_finding("", "attributes", attribute_seal_status,
				"Failed to seal the attribute registry."));
	}

	// Effects, standalone tag queries, and the manifest all need sealed tag
	// (and, for effects, attribute) registries to mean anything; skip them
	// with an explicit finding rather than guessing at partial results.
	if (!tags_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "effects", "internal_error",
				"Skipped effect/tag-query validation because the tag registry did not seal."));
		return findings;
	}

	// -----------------------------------------------------------------
	// Cues (registered before effects so they may reference them)
	// -----------------------------------------------------------------
	ga::EffectRegistry effect_registry;
	for (int i = 0; i < p_cues.size(); ++i) {
		const Ref<GameplayCueDefinition> cue = p_cues[i];
		if (cue.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("cues", i), "", "null_resource",
					vformat("Cue slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(cue, "cues", i);
		const ga::Status status = effect_registry.register_cue(to_std(String(cue->get_identifier())));
		if (!status.ok()) {
			findings.append(status_finding(path, "identifier", status,
					vformat("Cue '%s' failed to register.", String(cue->get_identifier()))));
		}
	}

	// -----------------------------------------------------------------
	// Effects
	// -----------------------------------------------------------------
	std::map<std::string, String> effect_path_by_identifier;
	if (attributes_sealed) {
		for (int i = 0; i < p_effects.size(); ++i) {
			const Ref<GameplayEffectDefinition> effect = p_effects[i];
			if (effect.is_null()) {
				findings.append(make_finding(SEV_ERROR, slot_label("effects", i), "", "null_resource",
						vformat("Effect slot %d is empty.", i)));
				continue;
			}
			const String path = resource_label(effect, "effects", i);
			const ga::EffectDefinitionDesc desc = to_effect_desc(effect);
			ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
			const ga::Status status = effect_registry.register_effect(desc, tag_registry, attribute_registry, unused_id);
			if (!status.ok()) {
				findings.append(effect_status_finding(effect, path, status));
				continue;
			}
			effect_path_by_identifier[to_std(String(effect->get_identifier()))] = path;
		}
	} else {
		findings.append(make_finding(SEV_ERROR, "", "effects", "internal_error",
				"Skipped effect validation because the attribute registry did not seal."));
	}

	const ga::Status effect_seal_status = effect_registry.seal();
	const bool effects_sealed = effect_seal_status.ok();
	if (!effects_sealed && attributes_sealed) {
		findings.append(status_finding("", "stacking.overflow_effect", effect_seal_status,
				"Failed to seal the effect registry (likely an unresolved overflow-effect reference)."));
	}

	// Authoring-time overflow-effect cycle detection. The core registry does
	// not reject this at seal() time (runtime bounds overflow application to
	// one hop instead, see ga_effects.h's `StackOverflowPolicy::APPLY_OVERFLOW_EFFECT`
	// comment), so a chain that loops back on itself would otherwise seal
	// cleanly and only misbehave at runtime. This walk is bounded by the
	// sealed effect count, so it can never spin on a malformed chain.
	if (effects_sealed) {
		for (const ga::DefinitionId start_id : effect_registry.canonical_order()) {
			const ga::EffectDefinition *start_def = effect_registry.find(start_id);
			if (start_def == nullptr || !start_def->stacking.has_overflow_effect) {
				continue;
			}
			ga::DefinitionId current = start_def->stacking.overflow_effect;
			bool cycle = false;
			const std::size_t step_limit = effect_registry.size() + 1;
			for (std::size_t step = 0; step < step_limit; ++step) {
				if (current == start_id) {
					cycle = true;
					break;
				}
				const ga::EffectDefinition *node = effect_registry.find(current);
				if (node == nullptr || !node->stacking.has_overflow_effect) {
					break;
				}
				current = node->stacking.overflow_effect;
			}
			if (cycle) {
				const auto found = effect_path_by_identifier.find(start_def->identifier);
				const String path = found != effect_path_by_identifier.end() ? found->second : String();
				findings.append(make_finding(SEV_ERROR, path, "stacking.overflow_effect", "overflow_effect_cycle",
						vformat("Effect '%s' overflow-effect chain loops back to itself.",
								String(start_def->identifier.c_str()))));
			}
		}
	}

	// -----------------------------------------------------------------
	// Standalone tag-query resources (not embedded in an effect). Resolved
	// against the sealed tag registry and normalized with the exact same
	// `ga::TagQuery::build_requirements` an effect's requirements go through.
	// -----------------------------------------------------------------
	for (int i = 0; i < p_tag_queries.size(); ++i) {
		const Ref<GameplayTagQueryResource> query = p_tag_queries[i];
		if (query.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("tag_queries", i), "", "null_resource",
					vformat("Tag query slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(query, "tag_queries", i);
		const std::vector<ga::TagOperandDesc> all_ops = to_operand_vector(query->get_all_of());
		const std::vector<ga::TagOperandDesc> any_ops = to_operand_vector(query->get_any_of());
		const std::vector<ga::TagOperandDesc> none_ops = to_operand_vector(query->get_none_of());

		bool unknown_tag_found = false;
		std::vector<ga::TagQueryOperand> resolved_all, resolved_any, resolved_none;
		struct Group {
			const char *label;
			const std::vector<ga::TagOperandDesc> *descs;
			std::vector<ga::TagQueryOperand> *resolved;
		};
		const Group groups[] = {
			{ "all_of", &all_ops, &resolved_all },
			{ "any_of", &any_ops, &resolved_any },
			{ "none_of", &none_ops, &resolved_none },
		};
		for (const Group &group : groups) {
			for (std::size_t j = 0; j < group.descs->size(); ++j) {
				const ga::TagOperandDesc &operand_desc = (*group.descs)[j];
				const ga::DefinitionId tag_id = tag_registry.id_of(operand_desc.tag);
				if (tag_id == ga::INVALID_DEFINITION_ID) {
					unknown_tag_found = true;
					findings.append(make_finding(SEV_ERROR, path, vformat("%s[%d].tag", group.label, (int)j),
							"unknown_reference",
							vformat("Tag query references unknown tag '%s'.",
									String(operand_desc.tag.c_str()))));
					continue;
				}
				group.resolved->push_back(ga::TagQueryOperand{ tag_id, operand_desc.mode });
			}
		}
		if (unknown_tag_found) {
			continue;
		}
		ga::TagQuery built_query;
		const ga::Status build_status =
				ga::TagQuery::build_requirements(resolved_all, resolved_any, resolved_none, built_query);
		if (!build_status.ok()) {
			findings.append(status_finding(path, "", build_status, "Tag query exceeds the configured bounds."));
		}
	}

	// -----------------------------------------------------------------
	// Typed target schemas use the same sealed registry and canonical
	// validation as runtime components.
	// -----------------------------------------------------------------
	ga::TargetSchemaRegistry target_schema_registry;
	std::map<std::string, String> schema_paths;
	const bool target_schemas_sealed = build_target_schema_registry(
			p_target_schemas, "target_schemas", findings,
			target_schema_registry, schema_paths);

	// -----------------------------------------------------------------
	// Content manifest: every sealed registry contributes its canonical
	// bytes, including the sealed typed target registry.
	// -----------------------------------------------------------------
	ga::ManifestBuilder builder(ga::DEFAULT_TICK_RATE);
	bool manifest_ok = true;
	ga::Status contribute_status = tag_registry.contribute_manifest(builder);
	manifest_ok = manifest_ok && contribute_status.ok();
	if (attributes_sealed) {
		contribute_status = attribute_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	if (effects_sealed) {
		contribute_status = effect_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	if (target_schemas_sealed) {
		contribute_status =
				target_schema_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}

	if (manifest_ok) {
		ga::ContentManifest manifest;
		const ga::Status build_status = builder.build(manifest);
		if (build_status.ok()) {
			last_manifest_ok = true;
			last_manifest_fingerprint = static_cast<int64_t>(manifest.fingerprint);
			last_manifest_entry_count = static_cast<int>(manifest.entry_count);
			last_manifest_tick_rate = static_cast<int>(manifest.tick_rate);
		} else {
			findings.append(status_finding("", "manifest", build_status, "Failed to build the content manifest."));
		}
	} else {
		findings.append(make_finding(SEV_ERROR, "", "manifest", "internal_error",
				"Skipped manifest assembly because a registry's canonical contribution failed."));
	}

	return findings;
}

bool GameplayDefinitionValidator::is_ok(const Array &p_findings) {
	for (int i = 0; i < p_findings.size(); ++i) {
		const Dictionary finding = p_findings[i];
		if (String(finding.get("severity", "")) == String(SEV_ERROR)) {
			return false;
		}
	}
	return true;
}

String GameplayDefinitionValidator::format(const Array &p_findings) {
	if (p_findings.is_empty()) {
		return "GameplayAbilities definition validation: OK";
	}
	String result;
	for (int i = 0; i < p_findings.size(); ++i) {
		const Dictionary finding = p_findings[i];
		const String severity = String(finding.get("severity", "")).to_upper();
		const String path = finding.get("resource_path", "");
		const String field = finding.get("field", "");
		const String code = finding.get("code", "");
		const String message = finding.get("message", "");
		String location = path;
		if (!field.is_empty()) {
			location = location.is_empty() ? field : (location + ":" + field);
		}
		if (i > 0) {
			result += "\n";
		}
		result += vformat("[%s] (%s) %s: %s", severity, code, location, message);
	}
	return result;
}

Array GameplayDefinitionValidator::validate_prediction_eligibility_seam(
		const TypedArray<GameplayTagDefinition> &p_tags, const TypedArray<GameplayAttributeDefinition> &p_attributes,
		const TypedArray<GameplayEffectDefinition> &p_effects, const TypedArray<GameplayCueDefinition> &p_cues,
		const TypedArray<GameplayAbilityDefinition> &p_abilities) {
	Array findings;

	// -----------------------------------------------------------------
	// Tags (abilities may reference required/blocked/cancel/owned tags).
	// -----------------------------------------------------------------
	ga::TagRegistry tag_registry;
	for (int i = 0; i < p_tags.size(); ++i) {
		const Ref<GameplayTagDefinition> tag = p_tags[i];
		if (tag.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("tags", i), "", "null_resource",
					vformat("Tag slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(tag, "tags", i);
		ga::TagDefinitionDesc desc;
		desc.identifier = to_std(String(tag->get_identifier()));
		desc.description = to_std(tag->get_description());
		desc.source_label = to_std(tag->get_source_label().is_empty() ? path : tag->get_source_label());
		ga::TagRegistrationConflict conflict;
		const ga::Status status = tag_registry.register_tag(desc, &conflict);
		if (!status.ok()) {
			findings.append(status_finding(path, "identifier", status,
					vformat("Tag '%s' failed to register.", String(tag->get_identifier()))));
		}
	}
	const bool tags_sealed = tag_registry.seal().ok();
	if (!tags_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "tags", "internal_error", "Failed to seal the tag registry."));
		return findings;
	}

	// -----------------------------------------------------------------
	// Attributes (effects referenced by abilities may modify them).
	// -----------------------------------------------------------------
	ga::AttributeRegistry attribute_registry;
	for (int i = 0; i < p_attributes.size(); ++i) {
		const Ref<GameplayAttributeDefinition> attribute = p_attributes[i];
		if (attribute.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("attributes", i), "", "null_resource",
					vformat("Attribute slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(attribute, "attributes", i);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = attribute_registry.register_attribute(to_std(String(attribute->get_identifier())),
				attribute->get_default_base(), attribute->get_has_min(), attribute->get_min_value(),
				attribute->get_has_max(), attribute->get_max_value(), to_std(attribute->get_display_name()),
				unused_id);
		if (!status.ok()) {
			findings.append(status_finding(path, "identifier", status,
					vformat("Attribute '%s' failed to register.", String(attribute->get_identifier()))));
		}
	}
	const bool attributes_sealed = attribute_registry.seal().ok();
	if (!attributes_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "attributes", "internal_error",
				"Failed to seal the attribute registry."));
		return findings;
	}

	// -----------------------------------------------------------------
	// Cues, then effects (an ability's cost/cooldown/commit effects).
	// -----------------------------------------------------------------
	ga::EffectRegistry effect_registry;
	for (int i = 0; i < p_cues.size(); ++i) {
		const Ref<GameplayCueDefinition> cue = p_cues[i];
		if (cue.is_null()) {
			continue; // an empty cue slot is reported by validate(); this seam only needs registered identifiers.
		}
		effect_registry.register_cue(to_std(String(cue->get_identifier())));
	}
	for (int i = 0; i < p_effects.size(); ++i) {
		const Ref<GameplayEffectDefinition> effect = p_effects[i];
		if (effect.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("effects", i), "", "null_resource",
					vformat("Effect slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(effect, "effects", i);
		const ga::EffectDefinitionDesc desc = to_effect_desc(effect);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = effect_registry.register_effect(desc, tag_registry, attribute_registry, unused_id);
		if (!status.ok()) {
			findings.append(effect_status_finding(effect, path, status));
		}
	}
	const bool effects_sealed = effect_registry.seal().ok();
	if (!effects_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "effects", "internal_error",
				"Failed to seal the effect registry (likely an unresolved overflow-effect reference)."));
		return findings;
	}

	// -----------------------------------------------------------------
	// Abilities: register every one (reporting malformed abilities exactly
	// like `validate()` reports malformed effects), then seal.
	// -----------------------------------------------------------------
	ga::AbilityRegistry ability_registry;
	std::map<std::string, String> ability_path_by_identifier;
	for (int i = 0; i < p_abilities.size(); ++i) {
		const Ref<GameplayAbilityDefinition> ability = p_abilities[i];
		if (ability.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("abilities", i), "", "null_resource",
					vformat("Ability slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(ability, "abilities", i);
		const ga::AbilityDefinitionDesc desc = to_ability_desc(ability);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = ability_registry.register_ability(desc, tag_registry, effect_registry, unused_id);
		if (!status.ok()) {
			findings.append(ability_status_finding(ability, path, status));
			continue;
		}
		ability_path_by_identifier[to_std(String(ability->get_identifier()))] = path;
	}
	const bool abilities_sealed = ability_registry.seal().ok();
	if (!abilities_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "abilities", "internal_error",
				"Failed to seal the ability registry."));
		return findings;
	}

	// -----------------------------------------------------------------
	// The strict pass: every PREDICTABLE ability must pass
	// `ga::validate_prediction_eligibility`, which -- unlike
	// `AbilityRegistry::register_ability`'s own inline check -- recurses
	// into a referenced effect's stacking overflow-effect chain (see this
	// method's header doc comment for exactly why that distinction matters).
	// A definition can therefore register successfully above and still be
	// rejected here.
	// -----------------------------------------------------------------
	for (const ga::DefinitionId id : ability_registry.canonical_order()) {
		const ga::AbilityDefinition *definition = ability_registry.find(id);
		if (definition == nullptr || definition->prediction_policy != ga::AbilityPredictionPolicy::PREDICTABLE) {
			continue;
		}
		const ga::Status eligibility = ga::validate_prediction_eligibility(*definition, effect_registry, nullptr);
		if (!eligibility.ok()) {
			const auto found = ability_path_by_identifier.find(definition->identifier);
			const String path = found != ability_path_by_identifier.end() ? found->second : String();
			findings.append(status_finding(path, "prediction_policy", eligibility,
					vformat("Ability '%s' is declared predictable (prediction_policy = Predictable) but its "
									"declared execution leaves the v1 prediction-safe set (remote-target "
									"mutation, periodic outcome, scene query, random value, authority-only "
									"hook, or a non-self cost/cooldown/commit effect -- including one reached "
									"only through a stackable effect's overflow-effect chain).",
							String(definition->identifier.c_str()))));
		}
	}

	return findings;
}

Array GameplayDefinitionValidator::validate_catalog(const Ref<GameplayDefinitionCatalog> &p_catalog) {
	Array findings;
	last_manifest_ok = false;
	last_manifest_fingerprint = 0;
	last_manifest_entry_count = 0;
	last_manifest_tick_rate = 0;

	if (p_catalog.is_null()) {
		findings.append(make_finding(SEV_ERROR, "", "definition_catalog", "null_resource", "Catalog is null."));
		return findings;
	}

	const TypedArray<GameplayTagDefinition> p_tags = p_catalog->get_tag_definitions();
	const TypedArray<GameplayAttributeDefinition> p_attributes = p_catalog->get_attribute_definitions();
	const TypedArray<GameplayCueDefinition> p_cues = p_catalog->get_cue_definitions();
	const TypedArray<GameplayEffectDefinition> p_effects = p_catalog->get_effect_definitions();
	const TypedArray<GameplayAbilityDefinition> p_abilities = p_catalog->get_ability_definitions();
	const TypedArray<GameplayTargetDataSchema> p_target_schemas = p_catalog->get_target_data_schemas();
	const TypedArray<GameplayTagReactionDefinition> p_reactions = p_catalog->get_tag_reactions();

	// -----------------------------------------------------------------
	// Tags
	// -----------------------------------------------------------------
	ga::TagRegistry tag_registry;
	for (int i = 0; i < p_tags.size(); ++i) {
		const Ref<GameplayTagDefinition> tag = p_tags[i];
		if (tag.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("tag_definitions", i), "", "null_resource",
					vformat("Tag definitions slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(tag, "tag_definitions", i);
		ga::TagDefinitionDesc desc;
		desc.identifier = to_std(String(tag->get_identifier()));
		desc.description = to_std(tag->get_description());
		desc.source_label = to_std(tag->get_source_label().is_empty() ? path : tag->get_source_label());

		ga::TagRegistrationConflict conflict;
		const ga::Status status = tag_registry.register_tag(desc, &conflict);
		if (!status.ok()) {
			String message = vformat("Tag '%s' failed to register.", String(tag->get_identifier()));
			if (status.code == ga::StatusCode::DUPLICATE_DEFINITION && !conflict.identifier.empty()) {
				message = vformat("Tag identifier '%s' is declared by both '%s' and '%s'.",
						String(conflict.identifier.c_str()), String(conflict.first_source_label.c_str()),
						String(conflict.second_source_label.c_str()));
			}
			findings.append(status_finding(path, "identifier", status, message));
		}
	}
	const ga::Status tag_seal_status = tag_registry.seal();
	const bool tags_sealed = tag_seal_status.ok();
	if (!tags_sealed) {
		findings.append(status_finding("", "tag_definitions", tag_seal_status, "Failed to seal the tag registry."));
	}

	// -----------------------------------------------------------------
	// Attributes
	// -----------------------------------------------------------------
	ga::AttributeRegistry attribute_registry;
	for (int i = 0; i < p_attributes.size(); ++i) {
		const Ref<GameplayAttributeDefinition> attribute = p_attributes[i];
		if (attribute.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("attribute_definitions", i), "", "null_resource",
					vformat("Attribute definitions slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(attribute, "attribute_definitions", i);
		ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
		const ga::Status status = attribute_registry.register_attribute(to_std(String(attribute->get_identifier())),
				attribute->get_default_base(), attribute->get_has_min(), attribute->get_min_value(),
				attribute->get_has_max(), attribute->get_max_value(), to_std(attribute->get_display_name()),
				unused_id);
		if (!status.ok()) {
			String field = "identifier";
			if (status.diagnostic == ga::DiagnosticId::BOUNDS_INVERTED) {
				field = "bounds";
			} else if (status.diagnostic == ga::DiagnosticId::VALUE_NOT_REPRESENTABLE) {
				field = "default_base|min_value|max_value";
			}
			findings.append(status_finding(path, field, status,
					vformat("Attribute '%s' failed to register.", String(attribute->get_identifier()))));
		}
	}
	const ga::Status attribute_seal_status = attribute_registry.seal();
	const bool attributes_sealed = attribute_seal_status.ok();
	if (!attributes_sealed) {
		findings.append(status_finding("", "attribute_definitions", attribute_seal_status,
				"Failed to seal the attribute registry."));
	}

	if (!tags_sealed) {
		findings.append(make_finding(SEV_ERROR, "", "effect_definitions", "internal_error",
				"Skipped effect/ability/reaction validation because the tag registry did not seal."));
		return findings;
	}

	// -----------------------------------------------------------------
	// Cues (registered before effects so they may reference them)
	// -----------------------------------------------------------------
	ga::EffectRegistry effect_registry;
	for (int i = 0; i < p_cues.size(); ++i) {
		const Ref<GameplayCueDefinition> cue = p_cues[i];
		if (cue.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("cue_definitions", i), "", "null_resource",
					vformat("Cue definitions slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(cue, "cue_definitions", i);
		const ga::Status status = effect_registry.register_cue(to_std(String(cue->get_identifier())));
		if (!status.ok()) {
			findings.append(status_finding(path, "identifier", status,
					vformat("Cue '%s' failed to register.", String(cue->get_identifier()))));
		}
	}

	// -----------------------------------------------------------------
	// Effects
	// -----------------------------------------------------------------
	std::map<std::string, String> effect_path_by_identifier;
	if (attributes_sealed) {
		for (int i = 0; i < p_effects.size(); ++i) {
			const Ref<GameplayEffectDefinition> effect = p_effects[i];
			if (effect.is_null()) {
				findings.append(make_finding(SEV_ERROR, slot_label("effect_definitions", i), "", "null_resource",
						vformat("Effect definitions slot %d is empty.", i)));
				continue;
			}
			const String path = resource_label(effect, "effect_definitions", i);
			const ga::EffectDefinitionDesc desc = to_effect_desc(effect);
			ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
			const ga::Status status = effect_registry.register_effect(desc, tag_registry, attribute_registry, unused_id);
			if (!status.ok()) {
				findings.append(effect_status_finding(effect, path, status));
				continue;
			}
			effect_path_by_identifier[to_std(String(effect->get_identifier()))] = path;
		}
	} else {
		findings.append(make_finding(SEV_ERROR, "", "effect_definitions", "internal_error",
				"Skipped effect validation because the attribute registry did not seal."));
	}

	const ga::Status effect_seal_status = effect_registry.seal();
	const bool effects_sealed = effect_seal_status.ok();
	if (!effects_sealed && attributes_sealed) {
		findings.append(status_finding("", "effect_definitions.stacking.overflow_effect", effect_seal_status,
				"Failed to seal the effect registry (likely an unresolved overflow-effect reference)."));
	}

	// Authoring-time overflow-effect cycle detection -- same bounded walk
	// `validate()` runs (see that method's own comment for why the core
	// registry cannot reject this at seal() time).
	if (effects_sealed) {
		for (const ga::DefinitionId start_id : effect_registry.canonical_order()) {
			const ga::EffectDefinition *start_def = effect_registry.find(start_id);
			if (start_def == nullptr || !start_def->stacking.has_overflow_effect) {
				continue;
			}
			ga::DefinitionId current = start_def->stacking.overflow_effect;
			bool cycle = false;
			const std::size_t step_limit = effect_registry.size() + 1;
			for (std::size_t step = 0; step < step_limit; ++step) {
				if (current == start_id) {
					cycle = true;
					break;
				}
				const ga::EffectDefinition *node = effect_registry.find(current);
				if (node == nullptr || !node->stacking.has_overflow_effect) {
					break;
				}
				current = node->stacking.overflow_effect;
			}
			if (cycle) {
				const auto found = effect_path_by_identifier.find(start_def->identifier);
				const String path = found != effect_path_by_identifier.end() ? found->second : String();
				findings.append(make_finding(SEV_ERROR, path, "stacking.overflow_effect", "overflow_effect_cycle",
						vformat("Effect '%s' overflow-effect chain loops back to itself.",
								String(start_def->identifier.c_str()))));
			}
		}
	}

	// -----------------------------------------------------------------
	// Target-data schemas: same sealed core registry `validate()` and runtime
	// components use.
	// -----------------------------------------------------------------
	ga::TargetSchemaRegistry target_schema_registry;
	std::map<std::string, String> schema_paths;
	const bool target_schemas_sealed = build_target_schema_registry(
			p_target_schemas, "target_data_schemas", findings,
			target_schema_registry, schema_paths);

	// -----------------------------------------------------------------
	// Abilities: registered against the sealed tag/effect registries
	// exactly like `validate_prediction_eligibility_seam`'s own
	// registration stage (task 1.5's "cross-definition references"). This
	// method does NOT additionally run that seam's stricter
	// prediction-safety pass -- call it separately over the same catalog
	// collections if that is also needed.
	// -----------------------------------------------------------------
	ga::AbilityRegistry ability_registry;
	std::map<std::string, bool> referenced_target_schemas;
	if (effects_sealed) {
		for (int i = 0; i < p_abilities.size(); ++i) {
			const Ref<GameplayAbilityDefinition> ability = p_abilities[i];
			if (ability.is_null()) {
				findings.append(make_finding(SEV_ERROR, slot_label("ability_definitions", i), "", "null_resource",
						vformat("Ability definitions slot %d is empty.", i)));
				continue;
			}
			const String path = resource_label(ability, "ability_definitions", i);
			const std::string target_schema = to_std(
					String(ability->get_target_schema()));
			if (!target_schema.empty()) {
				if (target_schema_registry.id_of(target_schema) ==
						ga::INVALID_DEFINITION_ID) {
					findings.append(make_finding(SEV_ERROR, path,
							"target_schema", "unknown_reference",
							vformat("Ability '%s' references unknown target "
											"schema '%s'.",
									String(ability->get_identifier()),
									String(ability->get_target_schema()))));
				} else {
					referenced_target_schemas[target_schema] = true;
				}
			}
			const ga::AbilityDefinitionDesc desc = to_ability_desc(ability);
			ga::DefinitionId unused_id = ga::INVALID_DEFINITION_ID;
			const ga::Status status = ability_registry.register_ability(desc, tag_registry, effect_registry, unused_id);
			if (!status.ok()) {
				findings.append(ability_status_finding(ability, path, status));
			}
		}
	} else {
		findings.append(make_finding(SEV_ERROR, "", "ability_definitions", "internal_error",
				"Skipped ability validation because the effect registry did not seal."));
	}
	const ga::Status ability_seal_status = ability_registry.seal();
	const bool abilities_sealed = ability_seal_status.ok();
	if (!abilities_sealed && effects_sealed) {
		findings.append(status_finding("", "ability_definitions", ability_seal_status,
				"Failed to seal the ability registry."));
	}
	for (const auto &schema_path : schema_paths) {
		if (referenced_target_schemas.find(schema_path.first) ==
				referenced_target_schemas.end()) {
			findings.append(make_finding("warning", schema_path.second,
					"identifier", "orphan_target_schema",
					vformat("Target schema '%s' is not referenced by any "
									"ability in this catalog.",
							String(schema_path.first.c_str()))));
		}
	}

	// -----------------------------------------------------------------
	// Tag reactions (task 1.5: identifier presence/uniqueness only -- see
	// GameplayTagReactionDefinition's own header comment for what a later
	// change still needs to add here).
	// -----------------------------------------------------------------
	std::map<std::string, String> reaction_paths;
	for (int i = 0; i < p_reactions.size(); ++i) {
		const Ref<GameplayTagReactionDefinition> reaction = p_reactions[i];
		if (reaction.is_null()) {
			findings.append(make_finding(SEV_ERROR, slot_label("tag_reactions", i), "", "null_resource",
					vformat("Tag reaction slot %d is empty.", i)));
			continue;
		}
		const String path = resource_label(reaction, "tag_reactions", i);
		const std::string identifier = to_std(String(reaction->get_identifier()));
		const ga::Status identifier_status = ga::validate_identifier(identifier);
		if (!identifier_status.ok()) {
			findings.append(status_finding(path, "identifier", identifier_status,
					vformat("Tag reaction identifier '%s' is invalid.", String(reaction->get_identifier()))));
			continue;
		}
		if (reaction_paths.find(identifier) != reaction_paths.end()) {
			findings.append(make_finding(SEV_ERROR, path, "identifier", "duplicate_definition",
					vformat("Tag reaction identifier '%s' is declared more than once.",
							String(reaction->get_identifier()))));
			continue;
		}
		reaction_paths[identifier] = path;
	}

	// -----------------------------------------------------------------
	// Content manifest: every sealed registry contributes its canonical
	// bytes, plus one manual entry per validated target-data schema and
	// per validated tag reaction (neither has a sealed core registry of its
	// own yet -- see the loops above and
	// native/core/ga_tag_reactions.h's own comment).
	// -----------------------------------------------------------------
	ga::ManifestBuilder builder(ga::DEFAULT_TICK_RATE);
	bool manifest_ok = true;
	ga::Status contribute_status = tag_registry.contribute_manifest(builder);
	manifest_ok = manifest_ok && contribute_status.ok();
	if (attributes_sealed) {
		contribute_status = attribute_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	if (effects_sealed) {
		contribute_status = effect_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	if (abilities_sealed) {
		contribute_status = ability_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	if (target_schemas_sealed) {
		contribute_status =
				target_schema_registry.contribute_manifest(builder);
		manifest_ok = manifest_ok && contribute_status.ok();
	}
	for (int i = 0; i < p_reactions.size(); ++i) {
		const Ref<GameplayTagReactionDefinition> reaction = p_reactions[i];
		if (reaction.is_null()) {
			continue;
		}
		const std::string identifier = to_std(String(reaction->get_identifier()));
		if (reaction_paths.find(identifier) == reaction_paths.end()) {
			continue; // failed its own validation above; excluded from the manifest.
		}
		ga::TagReactionCanonicalDesc desc;
		desc.identifier = identifier;
		const Ref<GameplayTagOperand> operand = reaction->get_operand();
		if (operand.is_valid()) {
			desc.operand_tag = to_std(String(operand->get_tag()));
			desc.match_mode = operand->get_match_mode() == GameplayTagOperand::MATCH_PARENT_AWARE
					? ga::TagReactionMatchMode::PARENT_AWARE
					: ga::TagReactionMatchMode::EXACT;
		}
		desc.mode = static_cast<ga::TagReactionMode>(reaction->get_mode());
		desc.effect_identifier = to_std(String(reaction->get_effect_identifier()));
		contribute_status = ga::contribute_tag_reaction_manifest(builder, desc);
		manifest_ok = manifest_ok && contribute_status.ok();
	}

	if (manifest_ok) {
		ga::ContentManifest manifest;
		const ga::Status build_status = builder.build(manifest);
		if (build_status.ok()) {
			last_manifest_ok = true;
			last_manifest_fingerprint = static_cast<int64_t>(manifest.fingerprint);
			last_manifest_entry_count = static_cast<int>(manifest.entry_count);
			last_manifest_tick_rate = static_cast<int>(manifest.tick_rate);
		} else {
			findings.append(status_finding("", "manifest", build_status, "Failed to build the content manifest."));
		}
	} else {
		findings.append(make_finding(SEV_ERROR, "", "manifest", "internal_error",
				"Skipped manifest assembly because a registry's canonical contribution failed."));
	}

	return findings;
}

void GameplayDefinitionValidator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("validate", "tags", "attributes", "effects", "cues", "tag_queries",
								 "target_schemas"),
			&GameplayDefinitionValidator::validate);
	ClassDB::bind_method(D_METHOD("validate_catalog", "catalog"), &GameplayDefinitionValidator::validate_catalog);
	ClassDB::bind_method(D_METHOD("get_last_manifest_ok"), &GameplayDefinitionValidator::get_last_manifest_ok);
	ClassDB::bind_method(D_METHOD("get_last_manifest_fingerprint"),
			&GameplayDefinitionValidator::get_last_manifest_fingerprint);
	ClassDB::bind_method(D_METHOD("get_last_manifest_entry_count"),
			&GameplayDefinitionValidator::get_last_manifest_entry_count);
	ClassDB::bind_method(D_METHOD("get_last_manifest_tick_rate"),
			&GameplayDefinitionValidator::get_last_manifest_tick_rate);
	ClassDB::bind_static_method("GameplayDefinitionValidator", D_METHOD("is_ok", "findings"),
			&GameplayDefinitionValidator::is_ok);
	ClassDB::bind_static_method("GameplayDefinitionValidator", D_METHOD("format", "findings"),
			&GameplayDefinitionValidator::format);
	ClassDB::bind_static_method("GameplayDefinitionValidator",
			D_METHOD("validate_prediction_eligibility_seam", "tags", "attributes", "effects", "cues", "abilities"),
			&GameplayDefinitionValidator::validate_prediction_eligibility_seam);
}

} // namespace godot
