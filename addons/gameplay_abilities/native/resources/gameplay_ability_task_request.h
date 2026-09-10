#ifndef GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TASK_REQUEST_H
#define GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TASK_REQUEST_H

#include "resources/gameplay_tag_query_resource.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor/script-facing immutable-by-copy declaration of one deterministic
// ability wait. GameplayAbilityComponent resolves its identifier fields into
// the closed ga::AbilityTaskRequest value when a task is started; this
// Resource never owns runtime state or a callback.
class GameplayAbilityTaskRequest : public Resource {
	GDCLASS(GameplayAbilityTaskRequest, Resource)

public:
	enum Kind {
		KIND_WAIT_TICKS = 0,
		KIND_WAIT_GAMEPLAY_EVENT = 1,
		KIND_WAIT_TAG_QUERY = 2,
		KIND_WAIT_LOGICAL_INPUT = 3,
		KIND_WAIT_AUTHORITY = 4,
		KIND_WAIT_TARGET_DATA = 5,
	};
	enum Visibility {
		VISIBILITY_OWNER_ONLY = 0,
		VISIBILITY_OBSERVABLE = 1,
		VISIBILITY_INTERNAL = 2,
	};
	enum PredictionPolicy {
		PREDICTION_AUTHORITY_ONLY = 0,
		PREDICTION_SAFE = 1,
		PREDICTION_REQUIRES_AUTHORITY = 2,
	};
	enum TagEdge {
		TAG_EDGE_BECOMES_TRUE = 0,
		TAG_EDGE_BECOMES_FALSE = 1,
	};
	enum InputPhase {
		INPUT_PRESS = 0,
		INPUT_RELEASE = 1,
		INPUT_CONFIRM = 2,
		INPUT_CANCEL = 3,
	};
	enum EventMatch {
		EVENT_MATCH_EXACT = 0,
		EVENT_MATCH_PARENT_AWARE = 1,
	};

	void set_kind(Kind p_kind);
	Kind get_kind() const { return kind; }
	void set_has_deadline(bool p_value);
	bool get_has_deadline() const { return has_deadline; }
	void set_deadline_tick(int64_t p_tick);
	int64_t get_deadline_tick() const { return deadline_tick; }
	void set_visibility(Visibility p_visibility);
	Visibility get_visibility() const { return visibility; }
	void set_prediction_policy(PredictionPolicy p_policy);
	PredictionPolicy get_prediction_policy() const { return prediction_policy; }

	void set_wait_ticks(int64_t p_ticks);
	int64_t get_wait_ticks() const { return wait_ticks; }
	void set_gameplay_event_tag(const StringName &p_tag);
	StringName get_gameplay_event_tag() const { return gameplay_event_tag; }
	void set_gameplay_event_match(EventMatch p_match);
	EventMatch get_gameplay_event_match() const { return gameplay_event_match; }
	void set_tag_query(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_tag_query() const { return tag_query; }
	void set_tag_edge(TagEdge p_edge);
	TagEdge get_tag_edge() const { return tag_edge; }
	void set_complete_if_already_satisfied(bool p_value);
	bool get_complete_if_already_satisfied() const {
		return complete_if_already_satisfied;
	}
	void set_logical_input(const StringName &p_input);
	StringName get_logical_input() const { return logical_input; }
	void set_logical_phase(InputPhase p_phase);
	InputPhase get_logical_phase() const { return logical_phase; }
	void set_authority_prediction_key(int64_t p_key);
	int64_t get_authority_prediction_key() const {
		return authority_prediction_key;
	}
	void set_target_schema(const StringName &p_schema);
	StringName get_target_schema() const { return target_schema; }

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	Kind kind = KIND_WAIT_TICKS;
	bool has_deadline = false;
	int64_t deadline_tick = 0;
	Visibility visibility = VISIBILITY_OWNER_ONLY;
	PredictionPolicy prediction_policy = PREDICTION_AUTHORITY_ONLY;
	int64_t wait_ticks = 1;
	StringName gameplay_event_tag;
	EventMatch gameplay_event_match = EVENT_MATCH_EXACT;
	Ref<GameplayTagQueryResource> tag_query;
	TagEdge tag_edge = TAG_EDGE_BECOMES_TRUE;
	bool complete_if_already_satisfied = false;
	StringName logical_input;
	InputPhase logical_phase = INPUT_PRESS;
	int64_t authority_prediction_key = 0;
	StringName target_schema;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::Kind);
VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::Visibility);
VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::PredictionPolicy);
VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::TagEdge);
VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::InputPhase);
VARIANT_ENUM_CAST(GameplayAbilityTaskRequest::EventMatch);

#endif // GAMEPLAY_ABILITIES_RESOURCES_ABILITY_TASK_REQUEST_H
