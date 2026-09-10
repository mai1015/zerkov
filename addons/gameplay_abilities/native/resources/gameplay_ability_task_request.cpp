#include "resources/gameplay_ability_task_request.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

#define GA_TASK_SETTER(m_name, m_type, m_field) \
	void GameplayAbilityTaskRequest::m_name(m_type p_value) { \
		m_field = p_value; \
		emit_changed(); \
		notify_property_list_changed(); \
	}

GA_TASK_SETTER(set_kind, Kind, kind)
GA_TASK_SETTER(set_has_deadline, bool, has_deadline)
GA_TASK_SETTER(set_visibility, Visibility, visibility)
GA_TASK_SETTER(set_prediction_policy, PredictionPolicy, prediction_policy)
GA_TASK_SETTER(set_gameplay_event_match, EventMatch, gameplay_event_match)
GA_TASK_SETTER(set_tag_edge, TagEdge, tag_edge)
GA_TASK_SETTER(set_complete_if_already_satisfied, bool,
		complete_if_already_satisfied)
GA_TASK_SETTER(set_logical_phase, InputPhase, logical_phase)

#undef GA_TASK_SETTER

void GameplayAbilityTaskRequest::set_deadline_tick(int64_t p_tick) {
	deadline_tick = p_tick < 0 ? 0 : p_tick;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_wait_ticks(int64_t p_ticks) {
	wait_ticks = p_ticks < 0 ? 0 : p_ticks;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_gameplay_event_tag(const StringName &p_tag) {
	gameplay_event_tag = p_tag;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_tag_query(
		const Ref<GameplayTagQueryResource> &p_query) {
	tag_query = p_query;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_logical_input(const StringName &p_input) {
	logical_input = p_input;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_authority_prediction_key(int64_t p_key) {
	authority_prediction_key = p_key < 0 ? 0 : p_key;
	emit_changed();
}

void GameplayAbilityTaskRequest::set_target_schema(const StringName &p_schema) {
	target_schema = p_schema;
	emit_changed();
}

void GameplayAbilityTaskRequest::_validate_property(PropertyInfo &p_property) const {
	const StringName name = p_property.name;
	auto is = [&name](const char *p_name) {
		return name == StringName(p_name);
	};
	if (is("deadline_tick") && !has_deadline) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	const bool visible =
			(kind == KIND_WAIT_TICKS && is("wait_ticks")) ||
			(kind == KIND_WAIT_GAMEPLAY_EVENT &&
					(is("gameplay_event_tag") ||
							is("gameplay_event_match"))) ||
			(kind == KIND_WAIT_TAG_QUERY &&
					(is("tag_query") || is("tag_edge") ||
							is("complete_if_already_satisfied"))) ||
			(kind == KIND_WAIT_LOGICAL_INPUT &&
					(is("logical_input") || is("logical_phase"))) ||
			(kind == KIND_WAIT_AUTHORITY &&
					is("authority_prediction_key")) ||
			(kind == KIND_WAIT_TARGET_DATA && is("target_schema"));
	const bool kind_specific =
			is("wait_ticks") || is("gameplay_event_tag") ||
			is("gameplay_event_match") || is("tag_query") ||
			is("tag_edge") || is("complete_if_already_satisfied") ||
			is("logical_input") || is("logical_phase") ||
			is("authority_prediction_key") || is("target_schema");
	if (kind_specific && !visible) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayAbilityTaskRequest::_bind_methods() {
#define GA_BIND_TASK_PROPERTY(m_name, m_setter, m_getter) \
	ClassDB::bind_method(D_METHOD(#m_setter, #m_name), \
			&GameplayAbilityTaskRequest::m_setter); \
	ClassDB::bind_method(D_METHOD(#m_getter), \
			&GameplayAbilityTaskRequest::m_getter)

	GA_BIND_TASK_PROPERTY(kind, set_kind, get_kind);
	GA_BIND_TASK_PROPERTY(has_deadline, set_has_deadline, get_has_deadline);
	GA_BIND_TASK_PROPERTY(deadline_tick, set_deadline_tick, get_deadline_tick);
	GA_BIND_TASK_PROPERTY(visibility, set_visibility, get_visibility);
	GA_BIND_TASK_PROPERTY(prediction_policy, set_prediction_policy,
			get_prediction_policy);
	GA_BIND_TASK_PROPERTY(wait_ticks, set_wait_ticks, get_wait_ticks);
	GA_BIND_TASK_PROPERTY(gameplay_event_tag, set_gameplay_event_tag,
			get_gameplay_event_tag);
	GA_BIND_TASK_PROPERTY(gameplay_event_match, set_gameplay_event_match,
			get_gameplay_event_match);
	GA_BIND_TASK_PROPERTY(tag_query, set_tag_query, get_tag_query);
	GA_BIND_TASK_PROPERTY(tag_edge, set_tag_edge, get_tag_edge);
	GA_BIND_TASK_PROPERTY(complete_if_already_satisfied,
			set_complete_if_already_satisfied,
			get_complete_if_already_satisfied);
	GA_BIND_TASK_PROPERTY(logical_input, set_logical_input, get_logical_input);
	GA_BIND_TASK_PROPERTY(logical_phase, set_logical_phase, get_logical_phase);
	GA_BIND_TASK_PROPERTY(authority_prediction_key,
			set_authority_prediction_key, get_authority_prediction_key);
	GA_BIND_TASK_PROPERTY(target_schema, set_target_schema, get_target_schema);

#undef GA_BIND_TASK_PROPERTY

	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
						 "WaitTicks,WaitGameplayEvent,WaitTagQuery,WaitLogicalInput,WaitAuthority,WaitTargetData"),
			"set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_deadline"),
			"set_has_deadline", "get_has_deadline");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "deadline_tick",
						 PROPERTY_HINT_RANGE, "0,9223372036854775807,1"),
			"set_deadline_tick", "get_deadline_tick");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "visibility", PROPERTY_HINT_ENUM,
						 "OwnerOnly,Observable,Internal"),
			"set_visibility", "get_visibility");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "prediction_policy",
						 PROPERTY_HINT_ENUM,
						 "AuthorityOnly,PredictionSafe,RequiresAuthority"),
			"set_prediction_policy", "get_prediction_policy");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "wait_ticks", PROPERTY_HINT_RANGE,
						 "0,864000,1"),
			"set_wait_ticks", "get_wait_ticks");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "gameplay_event_tag"),
			"set_gameplay_event_tag", "get_gameplay_event_tag");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gameplay_event_match",
						 PROPERTY_HINT_ENUM, "Exact,ParentAware"),
			"set_gameplay_event_match", "get_gameplay_event_match");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "tag_query",
						 PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_tag_query", "get_tag_query");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tag_edge", PROPERTY_HINT_ENUM,
						 "BecomesTrue,BecomesFalse"),
			"set_tag_edge", "get_tag_edge");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL,
						 "complete_if_already_satisfied"),
			"set_complete_if_already_satisfied",
			"get_complete_if_already_satisfied");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "logical_input"),
			"set_logical_input", "get_logical_input");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "logical_phase",
						 PROPERTY_HINT_ENUM, "Press,Release,Confirm,Cancel"),
			"set_logical_phase", "get_logical_phase");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "authority_prediction_key"),
			"set_authority_prediction_key", "get_authority_prediction_key");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_schema"),
			"set_target_schema", "get_target_schema");

	BIND_ENUM_CONSTANT(KIND_WAIT_TICKS);
	BIND_ENUM_CONSTANT(KIND_WAIT_GAMEPLAY_EVENT);
	BIND_ENUM_CONSTANT(KIND_WAIT_TAG_QUERY);
	BIND_ENUM_CONSTANT(KIND_WAIT_LOGICAL_INPUT);
	BIND_ENUM_CONSTANT(KIND_WAIT_AUTHORITY);
	BIND_ENUM_CONSTANT(KIND_WAIT_TARGET_DATA);
	BIND_ENUM_CONSTANT(VISIBILITY_OWNER_ONLY);
	BIND_ENUM_CONSTANT(VISIBILITY_OBSERVABLE);
	BIND_ENUM_CONSTANT(VISIBILITY_INTERNAL);
	BIND_ENUM_CONSTANT(PREDICTION_AUTHORITY_ONLY);
	BIND_ENUM_CONSTANT(PREDICTION_SAFE);
	BIND_ENUM_CONSTANT(PREDICTION_REQUIRES_AUTHORITY);
	BIND_ENUM_CONSTANT(TAG_EDGE_BECOMES_TRUE);
	BIND_ENUM_CONSTANT(TAG_EDGE_BECOMES_FALSE);
	BIND_ENUM_CONSTANT(INPUT_PRESS);
	BIND_ENUM_CONSTANT(INPUT_RELEASE);
	BIND_ENUM_CONSTANT(INPUT_CONFIRM);
	BIND_ENUM_CONSTANT(INPUT_CANCEL);
	BIND_ENUM_CONSTANT(EVENT_MATCH_EXACT);
	BIND_ENUM_CONSTANT(EVENT_MATCH_PARENT_AWARE);
}

} // namespace godot
