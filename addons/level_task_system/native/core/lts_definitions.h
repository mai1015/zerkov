#ifndef LEVEL_TASK_SYSTEM_CORE_DEFINITIONS_H
#define LEVEL_TASK_SYSTEM_CORE_DEFINITIONS_H

#include "core/lts_identifier.h"
#include "core/lts_limits.h"
#include "core/lts_localization.h"
#include "core/lts_status.h"
#include "core/lts_values.h"

#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// ---------------------------------------------------------------------------
// Shared compatibility/value declarations
// ---------------------------------------------------------------------------

struct DefinitionCompatibility {
	std::uint16_t schema_version = RESOURCE_SCHEMA_VERSION;
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t snapshot_schema_version = SNAPSHOT_SCHEMA_VERSION;
	std::uint16_t canonical_format_version = CANONICAL_FORMAT_VERSION;
	CatalogFingerprint fingerprint = INVALID_CATALOG_FINGERPRINT;

	Status validate() const;
	bool compatible_with(const DefinitionCompatibility &p_other) const;
	bool operator==(const DefinitionCompatibility &p_other) const {
		return schema_version == p_other.schema_version &&
				protocol_version == p_other.protocol_version && snapshot_schema_version == p_other.snapshot_schema_version &&
				canonical_format_version == p_other.canonical_format_version && fingerprint == p_other.fingerprint;
	}
	bool operator!=(const DefinitionCompatibility &p_other) const { return !(*this == p_other); }
};

// ---------------------------------------------------------------------------
// Task graph values
// ---------------------------------------------------------------------------

enum class TaskNodeKind : std::uint8_t {
	ENTRY = 1,
	OBJECTIVE = 2,
	CONDITION = 3,
	ALL_GATE = 4,
	ANY_GATE = 5,
	EXTERNAL_ACTION = 6,
	CONVERSATION = 7,
	SUBGRAPH = 8,
	REWARD_REQUEST = 9,
	SUCCESS_TERMINAL = 10,
	FAILURE_TERMINAL = 11,
	CANCELLED_TERMINAL = 12,
};

enum class TaskPortDirection : std::uint8_t {
	INPUT = 1,
	OUTPUT = 2,
};

struct TaskPortDefinition {
	std::string identifier;
	TaskPortDirection direction = TaskPortDirection::OUTPUT;
	ValueType value_type = ValueType::NONE;
	bool required = false;

	Status validate() const;
	bool operator==(const TaskPortDefinition &p_other) const {
		return identifier == p_other.identifier && direction == p_other.direction &&
				value_type == p_other.value_type && required == p_other.required;
	}
	bool operator!=(const TaskPortDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskPortDefinition &p_other) const;
};

// One node is a closed declarative record. Type-specific fields are ignored by
// runtime until a later graph compiler validates them; validation below still
// rejects malformed values and requires the fields needed by each node family.
struct TaskNodeDefinition {
	std::string identifier;
	std::uint16_t schema_version = TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	TaskNodeKind kind = TaskNodeKind::ENTRY;
	std::vector<TaskPortDefinition> ports;

	// Provider-backed objective/condition/action/reward nodes.
	std::string provider_identifier;
	std::uint32_t objective_target = 1;
	std::vector<FactPredicate> filters;
	std::vector<Value> parameters;

	// Cross-definition references are identifiers only; no Object, Resource,
	// callable, or pointer is retained in a canonical value.
	std::string conversation_identifier;
	std::string conversation_entry_label;
	std::vector<std::string> accepted_outcomes;
	std::string subgraph_identifier;

	// Terminal node outcome. Graph edges carry topology, while this stable
	// outcome name is the value consumed by the host/task integration.
	std::string outcome_identifier;

	Status validate() const;
	std::uint64_t fingerprint() const;
	bool operator==(const TaskNodeDefinition &p_other) const;
	bool operator!=(const TaskNodeDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskNodeDefinition &p_other) const;
};

struct TaskEdgeDefinition {
	std::string identifier;
	std::uint16_t schema_version = TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	std::string from_node_identifier;
	std::string from_port_identifier;
	std::string to_node_identifier;
	std::string to_port_identifier;

	Status validate() const;
	std::uint64_t fingerprint() const;
	bool operator==(const TaskEdgeDefinition &p_other) const;
	bool operator!=(const TaskEdgeDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskEdgeDefinition &p_other) const;
};

struct TaskGraphDefinition {
	std::string identifier;
	std::uint16_t schema_version = TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	std::string entry_node_identifier;
	std::vector<std::string> terminal_outcomes;
	std::vector<TaskNodeDefinition> nodes;
	std::vector<TaskEdgeDefinition> edges;
	std::uint32_t max_transitions_per_advance = MAX_TRANSITIONS_PER_ADVANCE;

	Status validate() const;
	Status validate_and_canonicalize();
	std::uint64_t fingerprint() const;
	bool operator==(const TaskGraphDefinition &p_other) const;
	bool operator!=(const TaskGraphDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskGraphDefinition &p_other) const;

private:
	Status validate_and_canonicalize_in_place();
};

// ---------------------------------------------------------------------------
// Level values
// ---------------------------------------------------------------------------

enum class SceneAnchorKind : std::uint8_t {
	POINT = 1,
	TRANSFORM = 2,
	AREA = 3,
};

struct LevelAnchorDefinition {
	std::string identifier;
	SceneAnchorKind kind = SceneAnchorKind::POINT;
	bool required = true;
	std::string binding_label;

	Status validate() const;
	bool operator==(const LevelAnchorDefinition &p_other) const {
		return identifier == p_other.identifier && kind == p_other.kind && required == p_other.required &&
				binding_label == p_other.binding_label;
	}
	bool operator!=(const LevelAnchorDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const LevelAnchorDefinition &p_other) const;
};

struct LevelExitDefinition {
	std::string identifier;
	std::string target_level_identifier;
	std::string target_anchor_identifier;
	std::string outcome_identifier;

	Status validate() const;
	bool operator==(const LevelExitDefinition &p_other) const {
		return identifier == p_other.identifier && target_level_identifier == p_other.target_level_identifier &&
				target_anchor_identifier == p_other.target_anchor_identifier && outcome_identifier == p_other.outcome_identifier;
	}
	bool operator!=(const LevelExitDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const LevelExitDefinition &p_other) const;
};

struct LevelDefinition {
	std::string identifier;
	std::uint16_t schema_version = LEVEL_DEFINITION_SCHEMA_VERSION;
	std::string display_name_key;
	std::string description_key;
	std::string scene_resource;
	std::vector<FactPredicate> availability_rules;
	std::vector<std::string> entry_graph_identifiers;
	std::vector<LevelAnchorDefinition> anchors;
	std::vector<LevelExitDefinition> exits;

	Status validate() const;
	Status validate_and_canonicalize();
	std::uint64_t fingerprint() const;
	bool operator==(const LevelDefinition &p_other) const;
	bool operator!=(const LevelDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const LevelDefinition &p_other) const;

private:
	Status validate_and_canonicalize_in_place();
};

// ---------------------------------------------------------------------------
// Conversation values
// ---------------------------------------------------------------------------

enum class ConversationStepKind : std::uint8_t {
	LINE = 1,
	CHOICE = 2,
	CONDITION = 3,
	EXTERNAL_ACTION = 4,
	JUMP = 5,
	OUTCOME = 6,
};

struct ConversationChoiceDefinition {
	std::string identifier;
	std::string label_key;
	std::string target_step_identifier;
	std::vector<FactPredicate> conditions;

	Status validate() const;
	bool operator==(const ConversationChoiceDefinition &p_other) const {
		return identifier == p_other.identifier && label_key == p_other.label_key &&
				target_step_identifier == p_other.target_step_identifier && conditions == p_other.conditions;
	}
	bool operator!=(const ConversationChoiceDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const ConversationChoiceDefinition &p_other) const;
};

struct ConversationStepDefinition {
	std::string identifier;
	ConversationStepKind kind = ConversationStepKind::LINE;

	// LINE fields.
	std::string speaker_identifier;
	std::string line_key;
	std::vector<LocalizedParameter> parameters;
	std::string next_step_identifier;

	// CONDITION and EXTERNAL_ACTION fields. The provider is a declaration id;
	// execution and acknowledgement are owned by a later runtime slice.
	std::string provider_identifier;
	std::vector<FactPredicate> conditions;
	std::string true_step_identifier;
	std::string false_step_identifier;
	std::string success_step_identifier;
	std::string failure_step_identifier;

	// CHOICE/JUMP/OUTCOME fields.
	std::vector<ConversationChoiceDefinition> choices;
	std::string target_step_identifier;
	std::string outcome_identifier;

	Status validate() const;
	bool operator==(const ConversationStepDefinition &p_other) const;
	bool operator!=(const ConversationStepDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const ConversationStepDefinition &p_other) const;
};

struct SpeakerDefinition {
	std::string identifier;
	std::uint16_t schema_version = SPEAKER_DEFINITION_SCHEMA_VERSION;
	std::string display_name_key;
	std::string portrait_key;

	Status validate() const;
	std::uint64_t fingerprint() const;
	bool operator==(const SpeakerDefinition &p_other) const {
		return identifier == p_other.identifier && schema_version == p_other.schema_version &&
				display_name_key == p_other.display_name_key && portrait_key == p_other.portrait_key;
	}
	bool operator!=(const SpeakerDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const SpeakerDefinition &p_other) const;
};

struct ConversationDefinition {
	std::string identifier;
	std::uint16_t schema_version = CONVERSATION_DEFINITION_SCHEMA_VERSION;
	std::string entry_label;
	std::vector<std::string> speaker_identifiers;
	std::vector<std::string> terminal_outcomes;
	std::vector<ConversationStepDefinition> steps;
	std::uint32_t max_steps_per_advance = MAX_CONVERSATION_STEPS_PER_ADVANCE;
	std::uint32_t max_jumps_per_advance = MAX_JUMPS_PER_ADVANCE;

	Status validate() const;
	Status validate_and_canonicalize();
	std::uint64_t fingerprint() const;
	bool operator==(const ConversationDefinition &p_other) const;
	bool operator!=(const ConversationDefinition &p_other) const { return !(*this == p_other); }
	bool operator<(const ConversationDefinition &p_other) const;

private:
	Status validate_and_canonicalize_in_place();
};

// ---------------------------------------------------------------------------
// Host-provider declarations
// ---------------------------------------------------------------------------

enum class ProviderKind : std::uint8_t {
	FACT = 1,
	EVENT = 2,
	CONDITION = 3,
	ACTION = 4,
	REWARD = 5,
	LEVEL_TRANSITION = 6,
	CONVERSATION = 7,
};

struct ProviderDeclaration {
	std::string identifier;
	std::uint16_t schema_version = PROVIDER_DEFINITION_SCHEMA_VERSION;
	ProviderKind kind = ProviderKind::FACT;
	ValueType request_type = ValueType::NONE;
	ValueType response_type = ValueType::NONE;
	std::uint32_t max_request_bytes = 0;
	std::uint32_t max_response_bytes = 0;
	bool deterministic = true;
	bool authority_only = true;

	Status validate() const;
	std::uint64_t fingerprint() const;
	bool operator==(const ProviderDeclaration &p_other) const;
	bool operator!=(const ProviderDeclaration &p_other) const { return !(*this == p_other); }
	bool operator<(const ProviderDeclaration &p_other) const;
};

using ProviderDefinition = ProviderDeclaration;

// ---------------------------------------------------------------------------
// Validation/canonicalization helpers
// ---------------------------------------------------------------------------

bool is_known_task_node_kind(TaskNodeKind p_kind);
bool is_known_task_port_direction(TaskPortDirection p_direction);
bool is_known_anchor_kind(SceneAnchorKind p_kind);
bool is_known_conversation_step_kind(ConversationStepKind p_kind);
bool is_known_provider_kind(ProviderKind p_kind);

Status validate_and_canonicalize(Value &r_value);
Status validate_and_canonicalize(FactPredicate &r_predicate);
Status validate_and_canonicalize(TaskPortDefinition &r_port);
Status validate_and_canonicalize(TaskNodeDefinition &r_node);
Status validate_and_canonicalize(TaskEdgeDefinition &r_edge);
Status validate_and_canonicalize(TaskGraphDefinition &r_definition);
Status validate_and_canonicalize(LevelAnchorDefinition &r_anchor);
Status validate_and_canonicalize(LevelExitDefinition &r_exit);
Status validate_and_canonicalize(LevelDefinition &r_definition);
Status validate_and_canonicalize(ConversationChoiceDefinition &r_choice);
Status validate_and_canonicalize(ConversationStepDefinition &r_step);
Status validate_and_canonicalize(ConversationDefinition &r_definition);
Status validate_and_canonicalize(ProviderDeclaration &r_definition);
Status validate_and_canonicalize(SpeakerDefinition &r_definition);

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_DEFINITIONS_H
