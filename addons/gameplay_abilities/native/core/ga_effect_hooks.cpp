#include "core/ga_effect_hooks.h"

namespace ga {

Status CalculationContext::find_source_attribute(DefinitionId p_id, Fixed &r_out) const {
	for (const auto &entry : source_attributes) {
		if (entry.first == p_id) {
			r_out = entry.second;
			return ok_status();
		}
	}
	return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
}

Status CalculationContext::find_target_attribute(DefinitionId p_id, Fixed &r_out) const {
	for (const auto &entry : target_attributes) {
		if (entry.first == p_id) {
			r_out = entry.second;
			return ok_status();
		}
	}
	return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
}

Status CalculationContext::find_set_by_caller(const std::string &p_field, Fixed &r_out) const {
	for (const auto &entry : set_by_caller) {
		if (entry.first == p_field) {
			r_out = entry.second;
			return ok_status();
		}
	}
	return make_status(StatusCode::MISSING_SET_BY_CALLER);
}

Status validate_prediction_safe(const PredictionSafeCalculationHook &p_hook) {
	std::uint64_t flags = 0;
	if (p_hook.depends_on_time()) {
		flags |= PREDICTION_UNSAFE_TIME;
	}
	if (p_hook.depends_on_randomness()) {
		flags |= PREDICTION_UNSAFE_RANDOMNESS;
	}
	if (p_hook.depends_on_scene_or_physics()) {
		flags |= PREDICTION_UNSAFE_SCENE_OR_PHYSICS;
	}
	if (p_hook.uses_unrestricted_callback()) {
		flags |= PREDICTION_UNSAFE_UNRESTRICTED_CALLBACK;
	}
	if (flags != 0) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, flags);
	}
	return ok_status();
}

} // namespace ga
