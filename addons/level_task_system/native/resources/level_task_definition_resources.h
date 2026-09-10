#ifndef LEVEL_TASK_SYSTEM_RESOURCES_DEFINITION_RESOURCES_H
#define LEVEL_TASK_SYSTEM_RESOURCES_DEFINITION_RESOURCES_H

// Godot-facing authoring resources for the engine-independent Level Task
// System definitions.  These classes deliberately contain authoring data
// only.  `to_core_*()` copies into a local native value, validates it, and
// commits the copy to the caller only when the complete value is valid.  A
// sealed catalog/runtime therefore never retains a Resource, Node, Object,
// Callable, script, or other live engine value.

#include "core/lts_definitions.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

class LevelTaskValue;
class LevelTaskFactPredicate;
class LevelTaskLocalizedParameter;
class LevelTaskPortDefinition;
class LevelTaskNodeDefinition;
class LevelTaskEdgeDefinition;
class LevelTaskLevelAnchorDefinition;
class LevelTaskLevelExitDefinition;
class LevelTaskConversationChoiceDefinition;
class LevelTaskConversationStepDefinition;

// Closed, copyable counterpart of lts::Value.  The payload is intentionally
// represented by explicit fields rather than a Variant so an Object, Callable,
// script, or arbitrary container cannot enter canonical data accidentally.
class LevelTaskValue : public Resource {
	GDCLASS(LevelTaskValue, Resource)

public:
	enum ValueType {
		VALUE_NONE = 0,
		VALUE_BOOLEAN = 1,
		VALUE_INTEGER = 2,
		VALUE_FIXED = 3,
		VALUE_STRING = 4,
		VALUE_IDENTIFIER = 5,
		VALUE_BYTES = 6,
	};

	void set_type(ValueType p_type);
	ValueType get_type() const { return type; }

	void set_boolean_value(bool p_value);
	bool get_boolean_value() const { return boolean_value; }

	void set_integer_value(int64_t p_value);
	int64_t get_integer_value() const { return integer_value; }

	// Fixed-point values are authored as raw integer units.  The core applies
	// lts::FIXED_SCALE; no floating-point value crosses the Resource boundary.
	void set_fixed_raw(int64_t p_value);
	int64_t get_fixed_raw() const { return fixed_raw; }

	void set_string_value(const String &p_value);
	String get_string_value() const { return string_value; }

	// For VALUE_IDENTIFIER the same field is validated using the global,
	// namespaced identifier grammar.  For VALUE_STRING it is ordinary bounded
	// UTF-8 text.
	void set_text_value(const String &p_value);
	String get_text_value() const { return text_value; }
	// Explicit alias for callers that prefer a type-specific name.  The
	// Inspector uses `text_value` so the field remains shared with older
	// authoring data without introducing a Variant payload.
	void set_identifier_value(const String &p_value) { set_text_value(p_value); }
	String get_identifier_value() const { return get_text_value(); }

	void set_bytes_value(const PackedByteArray &p_value);
	PackedByteArray get_bytes_value() const { return bytes_value; }

	// Status-returning conversion is the fail-atomic seam used by catalogs and
	// tests.  The bool overload is convenient for callers that only need to
	// know whether conversion succeeded.
	lts::Status to_core_value(lts::Value &r_value) const;
	lts::Value to_core_value() const {
		lts::Value value;
		to_core_value(value);
		return value;
	}
	lts::Status to_core_desc(lts::Value &r_value) const { return to_core_value(r_value); }
	lts::Value to_core_desc() const { return to_core_value(); }
	bool to_core(lts::Value &r_value) const { return to_core_value(r_value).ok(); }
	bool to_core_value_checked(lts::Value &r_value) const { return to_core_value(r_value).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	ValueType type = VALUE_NONE;
	bool boolean_value = false;
	int64_t integer_value = 0;
	int64_t fixed_raw = 0;
	String string_value;
	String text_value;
	PackedByteArray bytes_value;
};

// Declarative fact/event condition used by levels, task nodes, and
// conversation choices.  The nested value is an authoring Resource only; the
// converter copies it into lts::FactPredicate by value.
class LevelTaskFactPredicate : public Resource {
	GDCLASS(LevelTaskFactPredicate, Resource)

public:
	enum ComparisonOperator {
		COMPARISON_EQUAL = 0,
		COMPARISON_NOT_EQUAL = 1,
		COMPARISON_LESS = 2,
		COMPARISON_LESS_OR_EQUAL = 3,
		COMPARISON_GREATER = 4,
		COMPARISON_GREATER_OR_EQUAL = 5,
	};

	void set_provider_identifier(const StringName &p_identifier);
	StringName get_provider_identifier() const { return provider_identifier; }
	void set_fact_identifier(const StringName &p_identifier);
	StringName get_fact_identifier() const { return fact_identifier; }
	void set_comparator(ComparisonOperator p_comparator);
	ComparisonOperator get_comparator() const { return comparator; }
	void set_expected(const Ref<LevelTaskValue> &p_expected);
	Ref<LevelTaskValue> get_expected() const { return expected; }

	lts::Status to_core_predicate(lts::FactPredicate &r_predicate) const;
	lts::FactPredicate to_core_predicate() const {
		lts::FactPredicate predicate;
		to_core_predicate(predicate);
		return predicate;
	}
	lts::Status to_core_desc(lts::FactPredicate &r_predicate) const { return to_core_predicate(r_predicate); }
	lts::FactPredicate to_core_desc() const { return to_core_predicate(); }
	bool to_core(lts::FactPredicate &r_predicate) const { return to_core_predicate(r_predicate).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName provider_identifier;
	StringName fact_identifier;
	ComparisonOperator comparator = COMPARISON_EQUAL;
	Ref<LevelTaskValue> expected;
};

// Named substitution value in a render-neutral conversation line.
class LevelTaskLocalizedParameter : public Resource {
	GDCLASS(LevelTaskLocalizedParameter, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_value(const Ref<LevelTaskValue> &p_value);
	Ref<LevelTaskValue> get_value() const { return value; }

	lts::Status to_core_parameter(lts::LocalizedParameter &r_parameter) const;
	lts::LocalizedParameter to_core_parameter() const {
		lts::LocalizedParameter parameter;
		to_core_parameter(parameter);
		return parameter;
	}
	lts::Status to_core_desc(lts::LocalizedParameter &r_parameter) const { return to_core_parameter(r_parameter); }
	lts::LocalizedParameter to_core_desc() const { return to_core_parameter(); }
	bool to_core(lts::LocalizedParameter &r_parameter) const { return to_core_parameter(r_parameter).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	Ref<LevelTaskValue> value;
};

// A typed named port on a task node.
class LevelTaskPortDefinition : public Resource {
	GDCLASS(LevelTaskPortDefinition, Resource)

public:
	enum PortDirection {
		PORT_INPUT = 0,
		PORT_OUTPUT = 1,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_direction(PortDirection p_direction);
	PortDirection get_direction() const { return direction; }
	void set_value_type(LevelTaskValue::ValueType p_value_type);
	LevelTaskValue::ValueType get_value_type() const { return value_type; }
	void set_required(bool p_required);
	bool get_required() const { return required; }

	lts::Status to_core_port(lts::TaskPortDefinition &r_port) const;
	lts::TaskPortDefinition to_core_port() const {
		lts::TaskPortDefinition port;
		to_core_port(port);
		return port;
	}
	lts::Status to_core_desc(lts::TaskPortDefinition &r_port) const { return to_core_port(r_port); }
	lts::TaskPortDefinition to_core_desc() const { return to_core_port(); }
	bool to_core(lts::TaskPortDefinition &r_port) const { return to_core_port(r_port).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	PortDirection direction = PORT_OUTPUT;
	LevelTaskValue::ValueType value_type = LevelTaskValue::VALUE_NONE;
	bool required = false;
};

// One closed declarative task node.  Runtime execution fields are copied into
// lts::TaskNodeDefinition; no Resource in a nested array becomes runtime
// authority state.
class LevelTaskNodeDefinition : public Resource {
	GDCLASS(LevelTaskNodeDefinition, Resource)

public:
	enum NodeKind {
		NODE_ENTRY = 0,
		NODE_OBJECTIVE = 1,
		NODE_CONDITION = 2,
		NODE_ALL_GATE = 3,
		NODE_ANY_GATE = 4,
		NODE_EXTERNAL_ACTION = 5,
		NODE_CONVERSATION = 6,
		NODE_SUBGRAPH = 7,
		NODE_REWARD_REQUEST = 8,
		NODE_SUCCESS_TERMINAL = 9,
		NODE_FAILURE_TERMINAL = 10,
		NODE_CANCELLED_TERMINAL = 11,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_kind(NodeKind p_kind);
	NodeKind get_kind() const { return kind; }
	void set_ports(const TypedArray<LevelTaskPortDefinition> &p_ports);
	TypedArray<LevelTaskPortDefinition> get_ports() const { return ports; }

	void set_provider_identifier(const StringName &p_identifier);
	StringName get_provider_identifier() const { return provider_identifier; }
	void set_objective_target(int p_target);
	int get_objective_target() const { return objective_target; }
	void set_filters(const TypedArray<LevelTaskFactPredicate> &p_filters);
	TypedArray<LevelTaskFactPredicate> get_filters() const { return filters; }
	void set_parameters(const TypedArray<LevelTaskValue> &p_parameters);
	TypedArray<LevelTaskValue> get_parameters() const { return parameters; }

	void set_conversation_identifier(const StringName &p_identifier);
	StringName get_conversation_identifier() const { return conversation_identifier; }
	void set_conversation_entry_label(const StringName &p_label);
	StringName get_conversation_entry_label() const { return conversation_entry_label; }
	void set_accepted_outcomes(const PackedStringArray &p_outcomes);
	PackedStringArray get_accepted_outcomes() const { return accepted_outcomes; }
	void set_subgraph_identifier(const StringName &p_identifier);
	StringName get_subgraph_identifier() const { return subgraph_identifier; }
	void set_outcome_identifier(const StringName &p_identifier);
	StringName get_outcome_identifier() const { return outcome_identifier; }

	lts::Status to_core_node(lts::TaskNodeDefinition &r_node) const;
	lts::TaskNodeDefinition to_core_node() const {
		lts::TaskNodeDefinition node;
		to_core_node(node);
		return node;
	}
	lts::Status to_core_desc(lts::TaskNodeDefinition &r_node) const { return to_core_node(r_node); }
	lts::TaskNodeDefinition to_core_desc() const { return to_core_node(); }
	lts::Status to_core_definition(lts::TaskNodeDefinition &r_node) const { return to_core_node(r_node); }
	lts::TaskNodeDefinition to_core_definition() const { return to_core_node(); }
	bool to_core(lts::TaskNodeDefinition &r_node) const { return to_core_node(r_node).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	int schema_version = lts::TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	NodeKind kind = NODE_ENTRY;
	TypedArray<LevelTaskPortDefinition> ports;

	StringName provider_identifier;
	int objective_target = 1;
	TypedArray<LevelTaskFactPredicate> filters;
	TypedArray<LevelTaskValue> parameters;

	StringName conversation_identifier;
	StringName conversation_entry_label;
	PackedStringArray accepted_outcomes;
	StringName subgraph_identifier;
	StringName outcome_identifier;
};

class LevelTaskEdgeDefinition : public Resource {
	GDCLASS(LevelTaskEdgeDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_from_node_identifier(const StringName &p_identifier);
	StringName get_from_node_identifier() const { return from_node_identifier; }
	void set_from_port_identifier(const StringName &p_identifier);
	StringName get_from_port_identifier() const { return from_port_identifier; }
	void set_to_node_identifier(const StringName &p_identifier);
	StringName get_to_node_identifier() const { return to_node_identifier; }
	void set_to_port_identifier(const StringName &p_identifier);
	StringName get_to_port_identifier() const { return to_port_identifier; }

	lts::Status to_core_edge(lts::TaskEdgeDefinition &r_edge) const;
	lts::TaskEdgeDefinition to_core_edge() const {
		lts::TaskEdgeDefinition edge;
		to_core_edge(edge);
		return edge;
	}
	lts::Status to_core_desc(lts::TaskEdgeDefinition &r_edge) const { return to_core_edge(r_edge); }
	lts::TaskEdgeDefinition to_core_desc() const { return to_core_edge(); }
	lts::Status to_core_definition(lts::TaskEdgeDefinition &r_edge) const { return to_core_edge(r_edge); }
	lts::TaskEdgeDefinition to_core_definition() const { return to_core_edge(); }
	bool to_core(lts::TaskEdgeDefinition &r_edge) const { return to_core_edge(r_edge).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	StringName from_node_identifier;
	StringName from_port_identifier;
	StringName to_node_identifier;
	StringName to_port_identifier;
};

class LevelTaskGraphDefinition : public Resource {
	GDCLASS(LevelTaskGraphDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_entry_node_identifier(const StringName &p_identifier);
	StringName get_entry_node_identifier() const { return entry_node_identifier; }
	void set_terminal_outcomes(const PackedStringArray &p_outcomes);
	PackedStringArray get_terminal_outcomes() const { return terminal_outcomes; }
	void set_nodes(const TypedArray<LevelTaskNodeDefinition> &p_nodes);
	TypedArray<LevelTaskNodeDefinition> get_nodes() const { return nodes; }
	void set_edges(const TypedArray<LevelTaskEdgeDefinition> &p_edges);
	TypedArray<LevelTaskEdgeDefinition> get_edges() const { return edges; }
	void set_max_transitions_per_advance(int p_limit);
	int get_max_transitions_per_advance() const { return max_transitions_per_advance; }

	lts::Status to_core_graph(lts::TaskGraphDefinition &r_graph) const;
	lts::TaskGraphDefinition to_core_graph() const {
		lts::TaskGraphDefinition graph;
		to_core_graph(graph);
		return graph;
	}
	lts::Status to_core_desc(lts::TaskGraphDefinition &r_graph) const { return to_core_graph(r_graph); }
	lts::TaskGraphDefinition to_core_desc() const { return to_core_graph(); }
	lts::Status to_core_definition(lts::TaskGraphDefinition &r_graph) const { return to_core_graph(r_graph); }
	lts::TaskGraphDefinition to_core_definition() const { return to_core_graph(); }
	bool to_core(lts::TaskGraphDefinition &r_graph) const { return to_core_graph(r_graph).ok(); }
	lts::Status validate_core() const;
	std::uint64_t get_core_fingerprint() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
	StringName entry_node_identifier;
	PackedStringArray terminal_outcomes;
	TypedArray<LevelTaskNodeDefinition> nodes;
	TypedArray<LevelTaskEdgeDefinition> edges;
	int max_transitions_per_advance = lts::MAX_TRANSITIONS_PER_ADVANCE;
};

class LevelTaskLevelAnchorDefinition : public Resource {
	GDCLASS(LevelTaskLevelAnchorDefinition, Resource)

public:
	enum AnchorKind {
		ANCHOR_POINT = 0,
		ANCHOR_TRANSFORM = 1,
		ANCHOR_AREA = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_kind(AnchorKind p_kind);
	AnchorKind get_kind() const { return kind; }
	void set_required(bool p_required);
	bool get_required() const { return required; }
	void set_binding_label(const String &p_label);
	String get_binding_label() const { return binding_label; }

	lts::Status to_core_anchor(lts::LevelAnchorDefinition &r_anchor) const;
	lts::LevelAnchorDefinition to_core_anchor() const {
		lts::LevelAnchorDefinition anchor;
		to_core_anchor(anchor);
		return anchor;
	}
	lts::Status to_core_desc(lts::LevelAnchorDefinition &r_anchor) const { return to_core_anchor(r_anchor); }
	lts::LevelAnchorDefinition to_core_desc() const { return to_core_anchor(); }
	bool to_core(lts::LevelAnchorDefinition &r_anchor) const { return to_core_anchor(r_anchor).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	AnchorKind kind = ANCHOR_POINT;
	bool required = true;
	String binding_label;
};

class LevelTaskLevelExitDefinition : public Resource {
	GDCLASS(LevelTaskLevelExitDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_target_level_identifier(const StringName &p_identifier);
	StringName get_target_level_identifier() const { return target_level_identifier; }
	void set_target_anchor_identifier(const StringName &p_identifier);
	StringName get_target_anchor_identifier() const { return target_anchor_identifier; }
	void set_outcome_identifier(const StringName &p_identifier);
	StringName get_outcome_identifier() const { return outcome_identifier; }

	lts::Status to_core_exit(lts::LevelExitDefinition &r_exit) const;
	lts::LevelExitDefinition to_core_exit() const {
		lts::LevelExitDefinition exit;
		to_core_exit(exit);
		return exit;
	}
	lts::Status to_core_desc(lts::LevelExitDefinition &r_exit) const { return to_core_exit(r_exit); }
	lts::LevelExitDefinition to_core_desc() const { return to_core_exit(); }
	bool to_core(lts::LevelExitDefinition &r_exit) const { return to_core_exit(r_exit).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	StringName target_level_identifier;
	StringName target_anchor_identifier;
	StringName outcome_identifier;
};

class LevelTaskLevelDefinition : public Resource {
	GDCLASS(LevelTaskLevelDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_display_name_key(const StringName &p_key);
	StringName get_display_name_key() const { return display_name_key; }
	void set_description_key(const StringName &p_key);
	StringName get_description_key() const { return description_key; }
	void set_scene_resource(const String &p_resource);
	String get_scene_resource() const { return scene_resource; }
	void set_availability_rules(const TypedArray<LevelTaskFactPredicate> &p_rules);
	TypedArray<LevelTaskFactPredicate> get_availability_rules() const { return availability_rules; }
	void set_entry_graph_identifiers(const PackedStringArray &p_identifiers);
	PackedStringArray get_entry_graph_identifiers() const { return entry_graph_identifiers; }
	void set_anchors(const TypedArray<LevelTaskLevelAnchorDefinition> &p_anchors);
	TypedArray<LevelTaskLevelAnchorDefinition> get_anchors() const { return anchors; }
	void set_exits(const TypedArray<LevelTaskLevelExitDefinition> &p_exits);
	TypedArray<LevelTaskLevelExitDefinition> get_exits() const { return exits; }

	lts::Status to_core_level(lts::LevelDefinition &r_level) const;
	lts::LevelDefinition to_core_level() const {
		lts::LevelDefinition level;
		to_core_level(level);
		return level;
	}
	lts::Status to_core_desc(lts::LevelDefinition &r_level) const { return to_core_level(r_level); }
	lts::LevelDefinition to_core_desc() const { return to_core_level(); }
	lts::Status to_core_definition(lts::LevelDefinition &r_level) const { return to_core_level(r_level); }
	lts::LevelDefinition to_core_definition() const { return to_core_level(); }
	bool to_core(lts::LevelDefinition &r_level) const { return to_core_level(r_level).ok(); }
	lts::Status validate_core() const;
	std::uint64_t get_core_fingerprint() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::LEVEL_DEFINITION_SCHEMA_VERSION;
	StringName display_name_key;
	StringName description_key;
	String scene_resource;
	TypedArray<LevelTaskFactPredicate> availability_rules;
	PackedStringArray entry_graph_identifiers;
	TypedArray<LevelTaskLevelAnchorDefinition> anchors;
	TypedArray<LevelTaskLevelExitDefinition> exits;
};

class LevelTaskConversationChoiceDefinition : public Resource {
	GDCLASS(LevelTaskConversationChoiceDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_label_key(const StringName &p_key);
	StringName get_label_key() const { return label_key; }
	void set_target_step_identifier(const StringName &p_identifier);
	StringName get_target_step_identifier() const { return target_step_identifier; }
	void set_conditions(const TypedArray<LevelTaskFactPredicate> &p_conditions);
	TypedArray<LevelTaskFactPredicate> get_conditions() const { return conditions; }

	lts::Status to_core_choice(lts::ConversationChoiceDefinition &r_choice) const;
	lts::ConversationChoiceDefinition to_core_choice() const {
		lts::ConversationChoiceDefinition choice;
		to_core_choice(choice);
		return choice;
	}
	lts::Status to_core_desc(lts::ConversationChoiceDefinition &r_choice) const { return to_core_choice(r_choice); }
	lts::ConversationChoiceDefinition to_core_desc() const { return to_core_choice(); }
	lts::Status to_core_definition(lts::ConversationChoiceDefinition &r_choice) const { return to_core_choice(r_choice); }
	lts::ConversationChoiceDefinition to_core_definition() const { return to_core_choice(); }
	bool to_core(lts::ConversationChoiceDefinition &r_choice) const { return to_core_choice(r_choice).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	StringName label_key;
	StringName target_step_identifier;
	TypedArray<LevelTaskFactPredicate> conditions;
};

class LevelTaskConversationStepDefinition : public Resource {
	GDCLASS(LevelTaskConversationStepDefinition, Resource)

public:
	enum StepKind {
		STEP_LINE = 0,
		STEP_CHOICE = 1,
		STEP_CONDITION = 2,
		STEP_EXTERNAL_ACTION = 3,
		STEP_JUMP = 4,
		STEP_OUTCOME = 5,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_kind(StepKind p_kind);
	StepKind get_kind() const { return kind; }

	void set_speaker_identifier(const StringName &p_identifier);
	StringName get_speaker_identifier() const { return speaker_identifier; }
	void set_line_key(const StringName &p_key);
	StringName get_line_key() const { return line_key; }
	void set_parameters(const TypedArray<LevelTaskLocalizedParameter> &p_parameters);
	TypedArray<LevelTaskLocalizedParameter> get_parameters() const { return parameters; }
	void set_next_step_identifier(const StringName &p_identifier);
	StringName get_next_step_identifier() const { return next_step_identifier; }

	void set_provider_identifier(const StringName &p_identifier);
	StringName get_provider_identifier() const { return provider_identifier; }
	void set_conditions(const TypedArray<LevelTaskFactPredicate> &p_conditions);
	TypedArray<LevelTaskFactPredicate> get_conditions() const { return conditions; }
	void set_true_step_identifier(const StringName &p_identifier);
	StringName get_true_step_identifier() const { return true_step_identifier; }
	void set_false_step_identifier(const StringName &p_identifier);
	StringName get_false_step_identifier() const { return false_step_identifier; }
	void set_success_step_identifier(const StringName &p_identifier);
	StringName get_success_step_identifier() const { return success_step_identifier; }
	void set_failure_step_identifier(const StringName &p_identifier);
	StringName get_failure_step_identifier() const { return failure_step_identifier; }

	void set_choices(const TypedArray<LevelTaskConversationChoiceDefinition> &p_choices);
	TypedArray<LevelTaskConversationChoiceDefinition> get_choices() const { return choices; }
	void set_target_step_identifier(const StringName &p_identifier);
	StringName get_target_step_identifier() const { return target_step_identifier; }
	void set_outcome_identifier(const StringName &p_identifier);
	StringName get_outcome_identifier() const { return outcome_identifier; }

	lts::Status to_core_step(lts::ConversationStepDefinition &r_step) const;
	lts::ConversationStepDefinition to_core_step() const {
		lts::ConversationStepDefinition step;
		to_core_step(step);
		return step;
	}
	lts::Status to_core_desc(lts::ConversationStepDefinition &r_step) const { return to_core_step(r_step); }
	lts::ConversationStepDefinition to_core_desc() const { return to_core_step(); }
	lts::Status to_core_definition(lts::ConversationStepDefinition &r_step) const { return to_core_step(r_step); }
	lts::ConversationStepDefinition to_core_definition() const { return to_core_step(); }
	bool to_core(lts::ConversationStepDefinition &r_step) const { return to_core_step(r_step).ok(); }
	lts::Status validate_core() const;

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	StepKind kind = STEP_LINE;

	StringName speaker_identifier;
	StringName line_key;
	TypedArray<LevelTaskLocalizedParameter> parameters;
	StringName next_step_identifier;

	StringName provider_identifier;
	TypedArray<LevelTaskFactPredicate> conditions;
	StringName true_step_identifier;
	StringName false_step_identifier;
	StringName success_step_identifier;
	StringName failure_step_identifier;

	TypedArray<LevelTaskConversationChoiceDefinition> choices;
	StringName target_step_identifier;
	StringName outcome_identifier;
};

class LevelTaskSpeakerDefinition : public Resource {
	GDCLASS(LevelTaskSpeakerDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_display_name_key(const StringName &p_key);
	StringName get_display_name_key() const { return display_name_key; }
	void set_portrait_key(const StringName &p_key);
	StringName get_portrait_key() const { return portrait_key; }

	lts::Status to_core_speaker(lts::SpeakerDefinition &r_speaker) const;
	lts::SpeakerDefinition to_core_speaker() const {
		lts::SpeakerDefinition speaker;
		to_core_speaker(speaker);
		return speaker;
	}
	lts::Status to_core_desc(lts::SpeakerDefinition &r_speaker) const { return to_core_speaker(r_speaker); }
	lts::SpeakerDefinition to_core_desc() const { return to_core_speaker(); }
	lts::Status to_core_definition(lts::SpeakerDefinition &r_speaker) const { return to_core_speaker(r_speaker); }
	lts::SpeakerDefinition to_core_definition() const { return to_core_speaker(); }
	bool to_core(lts::SpeakerDefinition &r_speaker) const { return to_core_speaker(r_speaker).ok(); }
	lts::Status validate_core() const;
	std::uint64_t get_core_fingerprint() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::SPEAKER_DEFINITION_SCHEMA_VERSION;
	StringName display_name_key;
	StringName portrait_key;
};

class LevelTaskConversationDefinition : public Resource {
	GDCLASS(LevelTaskConversationDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_entry_label(const StringName &p_label);
	StringName get_entry_label() const { return entry_label; }
	void set_speaker_identifiers(const PackedStringArray &p_identifiers);
	PackedStringArray get_speaker_identifiers() const { return speaker_identifiers; }
	void set_terminal_outcomes(const PackedStringArray &p_outcomes);
	PackedStringArray get_terminal_outcomes() const { return terminal_outcomes; }
	void set_steps(const TypedArray<LevelTaskConversationStepDefinition> &p_steps);
	TypedArray<LevelTaskConversationStepDefinition> get_steps() const { return steps; }
	void set_max_steps_per_advance(int p_limit);
	int get_max_steps_per_advance() const { return max_steps_per_advance; }
	void set_max_jumps_per_advance(int p_limit);
	int get_max_jumps_per_advance() const { return max_jumps_per_advance; }

	lts::Status to_core_conversation(lts::ConversationDefinition &r_conversation) const;
	lts::ConversationDefinition to_core_conversation() const {
		lts::ConversationDefinition conversation;
		to_core_conversation(conversation);
		return conversation;
	}
	lts::Status to_core_desc(lts::ConversationDefinition &r_conversation) const { return to_core_conversation(r_conversation); }
	lts::ConversationDefinition to_core_desc() const { return to_core_conversation(); }
	lts::Status to_core_definition(lts::ConversationDefinition &r_conversation) const { return to_core_conversation(r_conversation); }
	lts::ConversationDefinition to_core_definition() const { return to_core_conversation(); }
	bool to_core(lts::ConversationDefinition &r_conversation) const { return to_core_conversation(r_conversation).ok(); }
	lts::Status validate_core() const;
	std::uint64_t get_core_fingerprint() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::CONVERSATION_DEFINITION_SCHEMA_VERSION;
	StringName entry_label;
	PackedStringArray speaker_identifiers;
	PackedStringArray terminal_outcomes;
	TypedArray<LevelTaskConversationStepDefinition> steps;
	int max_steps_per_advance = lts::MAX_CONVERSATION_STEPS_PER_ADVANCE;
	int max_jumps_per_advance = lts::MAX_JUMPS_PER_ADVANCE;
};

class LevelTaskProviderDeclaration : public Resource {
	GDCLASS(LevelTaskProviderDeclaration, Resource)

public:
	enum ProviderKind {
		PROVIDER_FACT = 0,
		PROVIDER_EVENT = 1,
		PROVIDER_CONDITION = 2,
		PROVIDER_ACTION = 3,
		PROVIDER_REWARD = 4,
		PROVIDER_LEVEL_TRANSITION = 5,
		PROVIDER_CONVERSATION = 6,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }
	void set_kind(ProviderKind p_kind);
	ProviderKind get_kind() const { return kind; }
	void set_request_type(LevelTaskValue::ValueType p_type);
	LevelTaskValue::ValueType get_request_type() const { return request_type; }
	void set_response_type(LevelTaskValue::ValueType p_type);
	LevelTaskValue::ValueType get_response_type() const { return response_type; }
	void set_max_request_bytes(int p_bytes);
	int get_max_request_bytes() const { return max_request_bytes; }
	void set_max_response_bytes(int p_bytes);
	int get_max_response_bytes() const { return max_response_bytes; }
	void set_deterministic(bool p_deterministic);
	bool get_deterministic() const { return deterministic; }
	void set_authority_only(bool p_authority_only);
	bool get_authority_only() const { return authority_only; }

	lts::Status to_core_provider(lts::ProviderDeclaration &r_provider) const;
	lts::ProviderDeclaration to_core_provider() const {
		lts::ProviderDeclaration provider;
		to_core_provider(provider);
		return provider;
	}
	lts::Status to_core_desc(lts::ProviderDeclaration &r_provider) const { return to_core_provider(r_provider); }
	lts::ProviderDeclaration to_core_desc() const { return to_core_provider(); }
	lts::Status to_core_definition(lts::ProviderDeclaration &r_provider) const { return to_core_provider(r_provider); }
	lts::ProviderDeclaration to_core_definition() const { return to_core_provider(); }
	bool to_core(lts::ProviderDeclaration &r_provider) const { return to_core_provider(r_provider).ok(); }
	lts::Status validate_core() const;
	std::uint64_t get_core_fingerprint() const;

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = lts::PROVIDER_DEFINITION_SCHEMA_VERSION;
	ProviderKind kind = PROVIDER_FACT;
	LevelTaskValue::ValueType request_type = LevelTaskValue::VALUE_NONE;
	LevelTaskValue::ValueType response_type = LevelTaskValue::VALUE_NONE;
	int max_request_bytes = 0;
	int max_response_bytes = 0;
	bool deterministic = true;
	bool authority_only = true;
};

// C++ source compatibility aliases.  The registered Godot names retain the
// LevelTask prefix (the package's working Godot class convention), while
// callers may use the shorter domain names when including this header.
using LevelDefinition = LevelTaskLevelDefinition;
using TaskGraphDefinition = LevelTaskGraphDefinition;
using TaskNodeDefinition = LevelTaskNodeDefinition;
using TaskEdgeDefinition = LevelTaskEdgeDefinition;
using ConversationDefinition = LevelTaskConversationDefinition;
using ConversationStepDefinition = LevelTaskConversationStepDefinition;
using ConversationChoiceDefinition = LevelTaskConversationChoiceDefinition;
using SpeakerDefinition = LevelTaskSpeakerDefinition;
using ProviderDeclaration = LevelTaskProviderDeclaration;

} // namespace godot

VARIANT_ENUM_CAST(LevelTaskValue::ValueType);
VARIANT_ENUM_CAST(LevelTaskFactPredicate::ComparisonOperator);
VARIANT_ENUM_CAST(LevelTaskPortDefinition::PortDirection);
VARIANT_ENUM_CAST(LevelTaskNodeDefinition::NodeKind);
VARIANT_ENUM_CAST(LevelTaskLevelAnchorDefinition::AnchorKind);
VARIANT_ENUM_CAST(LevelTaskConversationStepDefinition::StepKind);
VARIANT_ENUM_CAST(LevelTaskProviderDeclaration::ProviderKind);

#endif // LEVEL_TASK_SYSTEM_RESOURCES_DEFINITION_RESOURCES_H
