#include "core/ga_effect_spec.h"

#include "core/ga_hash.h"

#include <set>

namespace ga {

Status validate_effect_spec(const EffectSpec &p_spec, const EffectRegistry &p_registry) {
	const EffectDefinition *definition = p_registry.find(p_spec.definition);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_spec.definition);
	}

	if (p_spec.set_by_caller.size() > MAX_SET_BY_CALLER) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_spec.set_by_caller.size());
	}
	if (p_spec.target_data.size() > MAX_TARGETS_PER_COMMAND) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_spec.target_data.size());
	}
	const Status target_context_status =
			validate_target_effect_context(p_spec.target_context);
	if (!target_context_status.ok()) {
		return target_context_status;
	}
	if (p_spec.target_context.present &&
			(p_spec.target_context.source != p_spec.source ||
					p_spec.target_context.target != p_spec.target)) {
		return make_status(StatusCode::INVALID_EFFECT_SPEC,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}

	std::set<std::string> declared_fields;
	std::set<std::string> required_fields;
	for (const SetByCallerFieldDesc &field : definition->set_by_caller_fields) {
		declared_fields.insert(field.identifier);
		if (field.required) {
			required_fields.insert(field.identifier);
		}
	}

	std::set<std::string> supplied_fields;
	for (const SetByCallerMagnitude &magnitude : p_spec.set_by_caller) {
		if (declared_fields.find(magnitude.field) == declared_fields.end()) {
			return make_status(StatusCode::UNDECLARED_SET_BY_CALLER, DiagnosticId::NONE, hash_string(magnitude.field));
		}
		if (!supplied_fields.insert(magnitude.field).second) {
			return make_status(StatusCode::UNDECLARED_SET_BY_CALLER, DiagnosticId::NONE, hash_string(magnitude.field));
		}
	}

	for (const std::string &required_field : required_fields) {
		if (supplied_fields.find(required_field) == supplied_fields.end()) {
			return make_status(StatusCode::MISSING_SET_BY_CALLER, DiagnosticId::NONE, hash_string(required_field));
		}
	}

	return ok_status();
}

} // namespace ga
