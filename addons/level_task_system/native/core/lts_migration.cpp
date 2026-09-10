#include "core/lts_migration.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace lts {

namespace {

enum class SlotDefinitionKind : std::uint8_t {
	NONE = 0,
	LEVEL = 1,
	TASK_GRAPH = 2,
	CONVERSATION = 3,
	SPEAKER = 4,
	PROVIDER = 5,
};

struct Slot {
	const std::string *value = nullptr;
	std::string path;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	std::string nested_owner_identifier;
	bool definition = false;
};

struct MappingMatch {
	std::size_t mapping_index = 0;
	const Slot *slot = nullptr;
};

struct SavedSlot {
	const SavedInstanceReference *reference = nullptr;
	const std::string *value = nullptr;
	std::string path;
	std::string field;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	std::string nested_owner_identifier;
};

std::string bounded_path(const std::string &p_path) {
	if (p_path.size() <= MAX_DIAGNOSTIC_PATH_BYTES) return p_path;
	return p_path.substr(0, MAX_DIAGNOSTIC_PATH_BYTES);
}

std::string append_field(const std::string &p_base, const std::string &p_field) {
	std::string result = p_base;
	if (!result.empty()) result.push_back('.');
	result += p_field;
	return bounded_path(result);
}

std::string append_index(const std::string &p_base, const std::string &p_field, std::size_t p_index) {
	std::string result = append_field(p_base, p_field);
	result.push_back('[');
	result += std::to_string(p_index);
	result.push_back(']');
	return bounded_path(result);
}

std::string resource_path(const char *p_kind, const std::string &p_identifier) {
	std::string result(p_kind);
	result.push_back('.');
	result += p_identifier.empty() ? std::string("<invalid>") : p_identifier;
	return bounded_path(result);
}

std::string fallback_save_path(const SavedInstanceReference &p_reference) {
	if (!p_reference.path.empty()) return bounded_path(p_reference.path);
	std::string result = "save";
	if (!p_reference.scope_identifier.empty()) {
		result.push_back('.');
		result += p_reference.scope_identifier;
	}
	if (!p_reference.instance_identifier.empty()) {
		result += ".instance.";
		result += p_reference.instance_identifier;
	}
	result += ".identifier";
	return bounded_path(result);
}

Status invalid_argument(DiagnosticId p_diagnostic = DiagnosticId::NONE, std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status invalid_reference(const std::string &p_identifier) {
	// Use the same bounded, deterministic detail convention as catalog
	// reference validation without exposing a migration-specific status enum.
	std::uint64_t hash = UINT64_C(14695981039346656037);
	for (const unsigned char byte : p_identifier) {
		hash ^= static_cast<std::uint64_t>(byte);
		hash *= UINT64_C(1099511628211);
	}
	return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash);
}

bool is_nested_local_kind(RenameLocalKind p_kind) {
	return p_kind == RenameLocalKind::TASK_PORT || p_kind == RenameLocalKind::CONVERSATION_CHOICE ||
			p_kind == RenameLocalKind::PARAMETER;
}

RenameGlobalKind global_kind_for_owner(RenameOwnerKind p_owner_kind) {
	switch (p_owner_kind) {
		case RenameOwnerKind::LEVEL:
			return RenameGlobalKind::LEVEL;
		case RenameOwnerKind::TASK_GRAPH:
			return RenameGlobalKind::TASK_GRAPH;
		case RenameOwnerKind::CONVERSATION:
			return RenameGlobalKind::CONVERSATION;
		case RenameOwnerKind::SPEAKER:
			return RenameGlobalKind::SPEAKER;
		case RenameOwnerKind::PROVIDER:
			return RenameGlobalKind::PROVIDER;
		case RenameOwnerKind::NONE:
			break;
	}
	return RenameGlobalKind::ANY;
}

bool global_kind_matches(RenameGlobalKind p_selector, RenameGlobalKind p_actual) {
	return p_selector == RenameGlobalKind::ANY || p_selector == p_actual;
}

bool owner_matches(const RenameMapping &p_mapping, const Slot &p_slot) {
	return p_mapping.owner_kind == p_slot.owner_kind && p_mapping.owner_identifier == p_slot.owner_identifier &&
			(p_mapping.nested_owner_identifier.empty() || p_mapping.nested_owner_identifier == p_slot.nested_owner_identifier);
}

bool owner_matches(const RenameMapping &p_mapping, const SavedSlot &p_slot) {
	return p_mapping.owner_kind == p_slot.owner_kind && p_mapping.owner_identifier == p_slot.owner_identifier &&
			(p_mapping.nested_owner_identifier.empty() || p_mapping.nested_owner_identifier == p_slot.nested_owner_identifier);
}

bool mapping_matches(const RenameMapping &p_mapping, const Slot &p_slot) {
	if (p_slot.value == nullptr || *p_slot.value != p_mapping.old_identifier) return false;
	if (p_mapping.scope != p_slot.scope) return false;
	if (p_mapping.scope == RenameIdentifierScope::GLOBAL) {
		return global_kind_matches(p_mapping.global_kind, p_slot.global_kind);
	}
	if (!owner_matches(p_mapping, p_slot)) return false;
	return p_mapping.local_kind == RenameLocalKind::ANY || p_mapping.local_kind == p_slot.local_kind;
}

bool mapping_matches(const RenameMapping &p_mapping, const SavedSlot &p_slot) {
	if (p_slot.value == nullptr || *p_slot.value != p_mapping.old_identifier) return false;
	if (p_mapping.scope != p_slot.scope) return false;
	if (p_mapping.scope == RenameIdentifierScope::GLOBAL) {
		return global_kind_matches(p_mapping.global_kind, p_slot.global_kind);
	}
	if (!owner_matches(p_mapping, p_slot)) return false;
	return p_mapping.local_kind == RenameLocalKind::ANY || p_mapping.local_kind == p_slot.local_kind;
}

void add_slot(std::vector<Slot> &r_slots, const std::string &p_value, const std::string &p_path,
		RenameIdentifierScope p_scope, RenameGlobalKind p_global_kind, RenameOwnerKind p_owner_kind,
		const std::string &p_owner_identifier, RenameLocalKind p_local_kind, bool p_definition,
		const std::string &p_nested_owner_identifier = std::string()) {
	r_slots.push_back(Slot{ &p_value, bounded_path(p_path), p_scope, p_global_kind, p_owner_kind,
			p_owner_identifier, p_local_kind, p_nested_owner_identifier, p_definition });
}

void add_global_slot(std::vector<Slot> &r_slots, const std::string &p_value, const std::string &p_path,
		RenameGlobalKind p_kind, bool p_definition = false) {
	add_slot(r_slots, p_value, p_path, RenameIdentifierScope::GLOBAL, p_kind, RenameOwnerKind::NONE,
			std::string(), RenameLocalKind::ANY, p_definition);
}

void add_local_slot(std::vector<Slot> &r_slots, const std::string &p_value, const std::string &p_path,
		RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier,
		RenameLocalKind p_local_kind, const std::string &p_nested_owner_identifier = std::string()) {
	add_slot(r_slots, p_value, p_path, RenameIdentifierScope::LOCAL, RenameGlobalKind::ANY, p_owner_kind,
			p_owner_identifier, p_local_kind, false, p_nested_owner_identifier);
}

void collect_value_slots(std::vector<Slot> &r_slots, const Value &p_value, const std::string &p_path,
		RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier,
		RenameLocalKind p_local_kind, const std::string &p_nested_owner_identifier = std::string()) {
	if (p_value.type != ValueType::IDENTIFIER) return;
	const std::string *value = std::get_if<std::string>(&p_value.payload);
	if (value == nullptr) return;
	add_slot(r_slots, *value, p_path, RenameIdentifierScope::GLOBAL, RenameGlobalKind::IDENTIFIER_VALUE,
			p_owner_kind, p_owner_identifier, p_local_kind, false, p_nested_owner_identifier);
}

void collect_predicate_slots(std::vector<Slot> &r_slots, const FactPredicate &p_predicate,
		const std::string &p_base_path, RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier,
		RenameLocalKind p_local_kind = RenameLocalKind::ANY, const std::string &p_nested_owner_identifier = std::string()) {
	add_global_slot(r_slots, p_predicate.provider_identifier, append_field(p_base_path, "provider"), RenameGlobalKind::PROVIDER);
	add_global_slot(r_slots, p_predicate.fact_identifier, append_field(p_base_path, "fact"), RenameGlobalKind::FACT);
	collect_value_slots(r_slots, p_predicate.expected, append_field(p_base_path, "expected"), p_owner_kind,
			p_owner_identifier, p_local_kind, p_nested_owner_identifier);
}

void collect_catalog_slots(const LevelTaskCatalog &p_catalog, std::vector<Slot> &r_slots) {
	for (const LevelDefinition &level : p_catalog.levels()) {
		const std::string level_path = resource_path("level", level.identifier);
		const std::string level_owner = level.identifier;
		add_global_slot(r_slots, level.identifier, level_path, RenameGlobalKind::LEVEL, true);
		add_local_slot(r_slots, level.display_name_key, append_field(level_path, "display_name_key"), RenameOwnerKind::LEVEL,
				level_owner, RenameLocalKind::LOCALIZATION_KEY);
		add_local_slot(r_slots, level.description_key, append_field(level_path, "description_key"), RenameOwnerKind::LEVEL,
				level_owner, RenameLocalKind::LOCALIZATION_KEY);
		for (std::size_t index = 0; index < level.availability_rules.size(); ++index) {
			collect_predicate_slots(r_slots, level.availability_rules[index], append_index(level_path, "availability", index),
					RenameOwnerKind::LEVEL, level_owner);
		}
		for (std::size_t index = 0; index < level.entry_graph_identifiers.size(); ++index) {
			add_global_slot(r_slots, level.entry_graph_identifiers[index], append_index(level_path, "entry_graph", index),
					RenameGlobalKind::TASK_GRAPH);
		}
		for (const LevelAnchorDefinition &anchor : level.anchors) {
			const std::string anchor_path = append_field(level_path, "anchor." + anchor.identifier);
			add_local_slot(r_slots, anchor.identifier, anchor_path, RenameOwnerKind::LEVEL, level_owner,
					RenameLocalKind::LEVEL_ANCHOR);
		}
		for (const LevelExitDefinition &exit : level.exits) {
			const std::string exit_path = append_field(level_path, "exit." + exit.identifier);
			add_local_slot(r_slots, exit.identifier, exit_path, RenameOwnerKind::LEVEL, level_owner,
					RenameLocalKind::LEVEL_EXIT);
			add_global_slot(r_slots, exit.target_level_identifier, append_field(exit_path, "target_level"), RenameGlobalKind::LEVEL);
			add_local_slot(r_slots, exit.target_anchor_identifier, append_field(exit_path, "target_anchor"), RenameOwnerKind::LEVEL,
					exit.target_level_identifier, RenameLocalKind::LEVEL_ANCHOR);
			add_local_slot(r_slots, exit.outcome_identifier, append_field(exit_path, "outcome"), RenameOwnerKind::LEVEL,
					level_owner, RenameLocalKind::LEVEL_OUTCOME);
		}
	}

	for (const TaskGraphDefinition &graph : p_catalog.task_graphs()) {
		const std::string graph_path = resource_path("task", graph.identifier);
		const std::string graph_owner = graph.identifier;
		add_global_slot(r_slots, graph.identifier, graph_path, RenameGlobalKind::TASK_GRAPH, true);
		add_local_slot(r_slots, graph.entry_node_identifier, append_field(graph_path, "entry"), RenameOwnerKind::TASK_GRAPH,
				graph_owner, RenameLocalKind::TASK_NODE);
		for (std::size_t index = 0; index < graph.terminal_outcomes.size(); ++index) {
			add_local_slot(r_slots, graph.terminal_outcomes[index], append_index(graph_path, "terminal_outcome", index),
					RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_OUTCOME);
		}
		for (const TaskNodeDefinition &node : graph.nodes) {
			const std::string node_path = append_field(graph_path, "node." + node.identifier);
			add_local_slot(r_slots, node.identifier, node_path, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_NODE);
			for (const TaskPortDefinition &port : node.ports) {
				add_local_slot(r_slots, port.identifier, append_field(node_path, "port." + port.identifier), RenameOwnerKind::TASK_GRAPH,
						graph_owner, RenameLocalKind::TASK_PORT, node.identifier);
			}
			add_global_slot(r_slots, node.provider_identifier, append_field(node_path, "provider"), RenameGlobalKind::PROVIDER);
			for (std::size_t index = 0; index < node.filters.size(); ++index) {
				collect_predicate_slots(r_slots, node.filters[index], append_index(node_path, "filter", index), RenameOwnerKind::TASK_GRAPH,
						graph_owner);
			}
			for (std::size_t index = 0; index < node.parameters.size(); ++index) {
				collect_value_slots(r_slots, node.parameters[index], append_index(node_path, "parameter", index), RenameOwnerKind::TASK_GRAPH,
						graph_owner, RenameLocalKind::PARAMETER, node.identifier);
			}
			const std::string conversation_owner = node.conversation_identifier;
			add_global_slot(r_slots, node.conversation_identifier, append_field(node_path, "conversation"), RenameGlobalKind::CONVERSATION);
			add_local_slot(r_slots, node.conversation_entry_label, append_field(node_path, "conversation_entry"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			for (std::size_t index = 0; index < node.accepted_outcomes.size(); ++index) {
				add_local_slot(r_slots, node.accepted_outcomes[index], append_index(node_path, "conversation_outcome", index),
						RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::CONVERSATION_OUTCOME);
			}
			add_global_slot(r_slots, node.subgraph_identifier, append_field(node_path, "subgraph"), RenameGlobalKind::TASK_GRAPH);
			add_local_slot(r_slots, node.outcome_identifier, append_field(node_path, "outcome"), RenameOwnerKind::TASK_GRAPH,
					graph_owner, RenameLocalKind::TASK_OUTCOME);
		}
		for (const TaskEdgeDefinition &edge : graph.edges) {
			const std::string edge_path = append_field(graph_path, "edge." + edge.identifier);
			add_local_slot(r_slots, edge.identifier, edge_path, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_EDGE);
			add_local_slot(r_slots, edge.from_node_identifier, append_field(edge_path, "from_node"), RenameOwnerKind::TASK_GRAPH,
					graph_owner, RenameLocalKind::TASK_NODE);
			add_local_slot(r_slots, edge.from_port_identifier, append_field(edge_path, "from_port"), RenameOwnerKind::TASK_GRAPH,
					graph_owner, RenameLocalKind::TASK_PORT, edge.from_node_identifier);
			add_local_slot(r_slots, edge.to_node_identifier, append_field(edge_path, "to_node"), RenameOwnerKind::TASK_GRAPH,
					graph_owner, RenameLocalKind::TASK_NODE);
			add_local_slot(r_slots, edge.to_port_identifier, append_field(edge_path, "to_port"), RenameOwnerKind::TASK_GRAPH,
					graph_owner, RenameLocalKind::TASK_PORT, edge.to_node_identifier);
		}
	}

	for (const ConversationDefinition &conversation : p_catalog.conversations()) {
		const std::string conversation_path = resource_path("conversation", conversation.identifier);
		const std::string conversation_owner = conversation.identifier;
		add_global_slot(r_slots, conversation.identifier, conversation_path, RenameGlobalKind::CONVERSATION, true);
		add_local_slot(r_slots, conversation.entry_label, append_field(conversation_path, "entry"), RenameOwnerKind::CONVERSATION,
				conversation_owner, RenameLocalKind::CONVERSATION_STEP);
		for (std::size_t index = 0; index < conversation.speaker_identifiers.size(); ++index) {
			add_global_slot(r_slots, conversation.speaker_identifiers[index], append_index(conversation_path, "speaker", index), RenameGlobalKind::SPEAKER);
		}
		for (std::size_t index = 0; index < conversation.terminal_outcomes.size(); ++index) {
			add_local_slot(r_slots, conversation.terminal_outcomes[index], append_index(conversation_path, "terminal_outcome", index),
					RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::CONVERSATION_OUTCOME);
		}
		for (const ConversationStepDefinition &step : conversation.steps) {
			const std::string step_path = append_field(conversation_path, "step." + step.identifier);
			add_local_slot(r_slots, step.identifier, step_path, RenameOwnerKind::CONVERSATION, conversation_owner,
					RenameLocalKind::CONVERSATION_STEP);
			add_global_slot(r_slots, step.speaker_identifier, append_field(step_path, "speaker"), RenameGlobalKind::SPEAKER);
			add_local_slot(r_slots, step.line_key, append_field(step_path, "line"), RenameOwnerKind::CONVERSATION, conversation_owner,
					RenameLocalKind::LOCALIZATION_KEY);
			for (std::size_t index = 0; index < step.parameters.size(); ++index) {
				const std::string parameter_path = append_index(step_path, "parameter", index);
				add_local_slot(r_slots, step.parameters[index].identifier, append_field(parameter_path, "identifier"),
						RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::PARAMETER, step.identifier);
				collect_value_slots(r_slots, step.parameters[index].value, append_field(parameter_path, "value"), RenameOwnerKind::CONVERSATION,
						conversation_owner, RenameLocalKind::PARAMETER, step.identifier);
			}
			add_local_slot(r_slots, step.next_step_identifier, append_field(step_path, "next"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			add_global_slot(r_slots, step.provider_identifier, append_field(step_path, "provider"), RenameGlobalKind::PROVIDER);
			for (std::size_t index = 0; index < step.conditions.size(); ++index) {
				collect_predicate_slots(r_slots, step.conditions[index], append_index(step_path, "condition", index), RenameOwnerKind::CONVERSATION,
						conversation_owner);
			}
			add_local_slot(r_slots, step.true_step_identifier, append_field(step_path, "true"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			add_local_slot(r_slots, step.false_step_identifier, append_field(step_path, "false"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			add_local_slot(r_slots, step.success_step_identifier, append_field(step_path, "success"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			add_local_slot(r_slots, step.failure_step_identifier, append_field(step_path, "failure"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			for (const ConversationChoiceDefinition &choice : step.choices) {
				const std::string choice_path = append_field(step_path, "choice." + choice.identifier);
				add_local_slot(r_slots, choice.identifier, choice_path, RenameOwnerKind::CONVERSATION, conversation_owner,
						RenameLocalKind::CONVERSATION_CHOICE, step.identifier);
				add_local_slot(r_slots, choice.label_key, append_field(choice_path, "label"), RenameOwnerKind::CONVERSATION,
						conversation_owner, RenameLocalKind::LOCALIZATION_KEY, step.identifier);
				add_local_slot(r_slots, choice.target_step_identifier, append_field(choice_path, "target"), RenameOwnerKind::CONVERSATION,
						conversation_owner, RenameLocalKind::CONVERSATION_STEP);
				for (std::size_t index = 0; index < choice.conditions.size(); ++index) {
					collect_predicate_slots(r_slots, choice.conditions[index], append_index(choice_path, "condition", index),
							RenameOwnerKind::CONVERSATION, conversation_owner);
				}
			}
			add_local_slot(r_slots, step.target_step_identifier, append_field(step_path, "target"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_STEP);
			add_local_slot(r_slots, step.outcome_identifier, append_field(step_path, "outcome"), RenameOwnerKind::CONVERSATION,
					conversation_owner, RenameLocalKind::CONVERSATION_OUTCOME);
		}
	}

	for (const SpeakerDefinition &speaker : p_catalog.speakers()) {
		const std::string speaker_path = resource_path("speaker", speaker.identifier);
		add_global_slot(r_slots, speaker.identifier, speaker_path, RenameGlobalKind::SPEAKER, true);
		add_local_slot(r_slots, speaker.display_name_key, append_field(speaker_path, "display_name_key"), RenameOwnerKind::SPEAKER,
				speaker.identifier, RenameLocalKind::LOCALIZATION_KEY);
		add_local_slot(r_slots, speaker.portrait_key, append_field(speaker_path, "portrait_key"), RenameOwnerKind::SPEAKER,
				speaker.identifier, RenameLocalKind::LOCALIZATION_KEY);
	}

	for (const ProviderDeclaration &provider : p_catalog.providers()) {
		add_global_slot(r_slots, provider.identifier, resource_path("provider", provider.identifier), RenameGlobalKind::PROVIDER, true);
	}
}

void collect_saved_slots(const std::vector<SavedInstanceReference> &p_references, std::vector<SavedSlot> &r_slots) {
	for (const SavedInstanceReference &reference : p_references) {
		const std::string path = fallback_save_path(reference);
		r_slots.push_back(SavedSlot{ &reference, &reference.identifier, path, "identifier", reference.scope,
				reference.global_kind, reference.owner_kind, reference.owner_identifier, reference.local_kind,
				reference.nested_owner_identifier });
		if (!reference.owner_identifier.empty()) {
			const RenameGlobalKind owner_global_kind = global_kind_for_owner(reference.owner_kind);
			r_slots.push_back(SavedSlot{ &reference, &reference.owner_identifier, append_field(path, "owner_identifier"),
					"owner_identifier", RenameIdentifierScope::GLOBAL, owner_global_kind, RenameOwnerKind::NONE,
					std::string(), RenameLocalKind::ANY, std::string() });
		}
	}
}

Status validate_saved_reference(const SavedInstanceReference &p_reference) {
	if (!is_known_rename_scope(p_reference.scope) || !is_known_rename_global_kind(p_reference.global_kind) ||
			!is_known_rename_owner_kind(p_reference.owner_kind) || !is_known_rename_local_kind(p_reference.local_kind)) {
		return invalid_argument(DiagnosticId::INVALID_ENUM);
	}
	if (p_reference.path.size() > MAX_DIAGNOSTIC_PATH_BYTES || p_reference.instance_identifier.size() > MAX_IDENTIFIER_BYTES ||
			p_reference.scope_identifier.size() > MAX_IDENTIFIER_BYTES || p_reference.owner_identifier.size() > MAX_IDENTIFIER_BYTES ||
			p_reference.nested_owner_identifier.size() > MAX_IDENTIFIER_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED);
	}
	if (p_reference.identifier.empty()) return invalid_argument(DiagnosticId::IDENTIFIER_EMPTY);
	Status status = p_reference.scope == RenameIdentifierScope::GLOBAL ? validate_identifier(p_reference.identifier) :
			validate_local_identifier(p_reference.identifier);
	if (!status.ok()) return status;
	if (!p_reference.instance_identifier.empty()) {
		status = validate_identifier(p_reference.instance_identifier);
		if (!status.ok()) return status;
	}
	if (!p_reference.scope_identifier.empty()) {
		status = validate_identifier(p_reference.scope_identifier);
		if (!status.ok()) return status;
	}
	if (p_reference.scope == RenameIdentifierScope::GLOBAL) {
		if (p_reference.owner_kind != RenameOwnerKind::NONE || !p_reference.owner_identifier.empty() ||
				p_reference.local_kind != RenameLocalKind::ANY || !p_reference.nested_owner_identifier.empty()) {
			return invalid_argument();
		}
		return ok_status();
	}
	if (p_reference.global_kind != RenameGlobalKind::ANY || p_reference.owner_kind == RenameOwnerKind::NONE ||
			p_reference.owner_identifier.empty()) {
		return invalid_argument();
	}
	status = validate_identifier(p_reference.owner_identifier);
	if (!status.ok()) return status;
	if (!p_reference.nested_owner_identifier.empty()) {
		status = validate_local_identifier(p_reference.nested_owner_identifier);
		if (!status.ok()) return status;
	}
	return ok_status();
}

Status validate_mapping(const RenameMapping &p_mapping) {
	if (!is_known_rename_scope(p_mapping.scope) || !is_known_rename_global_kind(p_mapping.global_kind) ||
			!is_known_rename_owner_kind(p_mapping.owner_kind) || !is_known_rename_local_kind(p_mapping.local_kind)) {
		return invalid_argument(DiagnosticId::INVALID_ENUM);
	}
	if (p_mapping.old_identifier.empty() || p_mapping.new_identifier.empty()) {
		return invalid_argument(DiagnosticId::IDENTIFIER_EMPTY);
	}
	if (p_mapping.old_identifier == p_mapping.new_identifier) return invalid_argument();
	Status status = p_mapping.scope == RenameIdentifierScope::GLOBAL ? validate_identifier(p_mapping.old_identifier) :
			validate_local_identifier(p_mapping.old_identifier);
	if (!status.ok()) return status;
	status = p_mapping.scope == RenameIdentifierScope::GLOBAL ? validate_identifier(p_mapping.new_identifier) :
			validate_local_identifier(p_mapping.new_identifier);
	if (!status.ok()) return status;
	if (p_mapping.scope == RenameIdentifierScope::GLOBAL) {
		if (p_mapping.owner_kind != RenameOwnerKind::NONE || !p_mapping.owner_identifier.empty() ||
				p_mapping.local_kind != RenameLocalKind::ANY || !p_mapping.nested_owner_identifier.empty()) {
			return invalid_argument();
		}
		return ok_status();
	}
	if (p_mapping.global_kind != RenameGlobalKind::ANY || p_mapping.owner_kind == RenameOwnerKind::NONE ||
			p_mapping.owner_identifier.empty()) {
		return invalid_argument();
	}
	status = validate_identifier(p_mapping.owner_identifier);
	if (!status.ok()) return status;
	if (!p_mapping.nested_owner_identifier.empty()) {
		status = validate_local_identifier(p_mapping.nested_owner_identifier);
		if (!status.ok()) return status;
	}
	if (is_nested_local_kind(p_mapping.local_kind) && p_mapping.local_kind != RenameLocalKind::ANY &&
			p_mapping.nested_owner_identifier.empty()) {
		// A nested namespace may only be omitted when the matching scan proves
		// there is exactly one nested owner; that inference happens below.
	}
	return ok_status();
}

bool mapping_domains_overlap(const RenameMapping &p_left, const RenameMapping &p_right) {
	if (p_left.scope != p_right.scope || p_left.old_identifier != p_right.old_identifier) return false;
	if (p_left.scope == RenameIdentifierScope::GLOBAL) {
		return global_kind_matches(p_left.global_kind, p_right.global_kind) ||
				global_kind_matches(p_right.global_kind, p_left.global_kind);
	}
	if (p_left.owner_kind != p_right.owner_kind || p_left.owner_identifier != p_right.owner_identifier) return false;
	if (!p_left.nested_owner_identifier.empty() && !p_right.nested_owner_identifier.empty() &&
			p_left.nested_owner_identifier != p_right.nested_owner_identifier) {
		return false;
	}
	return p_left.local_kind == RenameLocalKind::ANY || p_right.local_kind == RenameLocalKind::ANY ||
			p_left.local_kind == p_right.local_kind;
}

Status normalize_local_mapping(RenameMapping &r_mapping, const std::vector<Slot> &p_catalog_slots,
		const std::vector<SavedSlot> &p_saved_slots) {
	if (r_mapping.scope != RenameIdentifierScope::LOCAL) return ok_status();
	std::set<RenameLocalKind> kinds;
	std::set<std::string> nested_owners;
	for (const Slot &slot : p_catalog_slots) {
		if (slot.value == nullptr || *slot.value != r_mapping.old_identifier || !mapping_matches(r_mapping, slot)) continue;
		kinds.insert(slot.local_kind);
		if (!slot.nested_owner_identifier.empty()) nested_owners.insert(slot.nested_owner_identifier);
	}
	for (const SavedSlot &slot : p_saved_slots) {
		if (slot.value == nullptr || *slot.value != r_mapping.old_identifier || !mapping_matches(r_mapping, slot)) continue;
		kinds.insert(slot.local_kind);
		if (!slot.nested_owner_identifier.empty()) nested_owners.insert(slot.nested_owner_identifier);
	}
	if (kinds.empty()) return invalid_reference(r_mapping.old_identifier);
	if (r_mapping.local_kind == RenameLocalKind::ANY) {
		if (kinds.size() != 1) return invalid_argument();
		r_mapping.local_kind = *kinds.begin();
	}
	if (is_nested_local_kind(r_mapping.local_kind) && r_mapping.nested_owner_identifier.empty() && nested_owners.size() > 1) {
		return invalid_argument();
	}
	if (!r_mapping.nested_owner_identifier.empty() && nested_owners.find(r_mapping.nested_owner_identifier) == nested_owners.end()) {
		return invalid_reference(r_mapping.nested_owner_identifier);
	}
	return ok_status();
}

Status append_affected(const Slot &p_slot, const RenameMapping &p_mapping, std::vector<RenameAffectedPath> &r_paths) {
	if (r_paths.size() >= MAX_RENAME_AFFECTED_PATHS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_paths.size() + 1);
	}
	RenameAffectedPath affected;
	affected.path = p_slot.path;
	affected.old_identifier = p_mapping.old_identifier;
	affected.new_identifier = p_mapping.new_identifier;
	affected.scope = p_slot.scope;
	affected.global_kind = p_slot.global_kind;
	affected.owner_kind = p_slot.owner_kind;
	affected.owner_identifier = p_slot.owner_identifier;
	affected.local_kind = p_slot.local_kind;
	affected.nested_owner_identifier = p_slot.nested_owner_identifier;
	affected.definition = p_slot.definition;
	r_paths.push_back(std::move(affected));
	return ok_status();
}

Status append_saved_affected(const SavedSlot &p_slot, const RenameMapping &p_mapping,
		std::vector<SavedInstanceMigrationEntry> &r_entries) {
	if (r_entries.size() >= MAX_RENAME_SAVED_INSTANCE_ENTRIES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_entries.size() + 1);
	}
	SavedInstanceMigrationEntry entry;
	entry.path = p_slot.path;
	entry.field = p_slot.field;
	entry.old_identifier = p_mapping.old_identifier;
	entry.new_identifier = p_mapping.new_identifier;
	entry.scope = p_slot.scope;
	entry.global_kind = p_slot.global_kind;
	entry.owner_kind = p_slot.owner_kind;
	entry.owner_identifier = p_slot.owner_identifier;
	entry.local_kind = p_slot.local_kind;
	entry.nested_owner_identifier = p_slot.nested_owner_identifier;
	if (p_slot.reference != nullptr) {
		entry.instance_identifier = p_slot.reference->instance_identifier;
		entry.scope_identifier = p_slot.reference->scope_identifier;
	}
	r_entries.push_back(std::move(entry));
	return ok_status();
}

} // namespace

bool is_known_rename_scope(RenameIdentifierScope p_scope) {
	return p_scope == RenameIdentifierScope::GLOBAL || p_scope == RenameIdentifierScope::LOCAL;
}

bool is_known_rename_global_kind(RenameGlobalKind p_kind) {
	switch (p_kind) {
		case RenameGlobalKind::ANY:
		case RenameGlobalKind::LEVEL:
		case RenameGlobalKind::TASK_GRAPH:
		case RenameGlobalKind::CONVERSATION:
		case RenameGlobalKind::SPEAKER:
		case RenameGlobalKind::PROVIDER:
		case RenameGlobalKind::FACT:
		case RenameGlobalKind::IDENTIFIER_VALUE:
			return true;
	}
	return false;
}

bool is_known_rename_owner_kind(RenameOwnerKind p_kind) {
	switch (p_kind) {
		case RenameOwnerKind::NONE:
		case RenameOwnerKind::LEVEL:
		case RenameOwnerKind::TASK_GRAPH:
		case RenameOwnerKind::CONVERSATION:
		case RenameOwnerKind::SPEAKER:
		case RenameOwnerKind::PROVIDER:
			return true;
	}
	return false;
}

bool is_known_rename_local_kind(RenameLocalKind p_kind) {
	switch (p_kind) {
		case RenameLocalKind::ANY:
		case RenameLocalKind::TASK_NODE:
		case RenameLocalKind::TASK_PORT:
		case RenameLocalKind::TASK_EDGE:
		case RenameLocalKind::TASK_OUTCOME:
		case RenameLocalKind::CONVERSATION_STEP:
		case RenameLocalKind::CONVERSATION_CHOICE:
		case RenameLocalKind::CONVERSATION_OUTCOME:
		case RenameLocalKind::LEVEL_ANCHOR:
		case RenameLocalKind::LEVEL_EXIT:
		case RenameLocalKind::LEVEL_OUTCOME:
		case RenameLocalKind::LOCALIZATION_KEY:
		case RenameLocalKind::PARAMETER:
			return true;
	}
	return false;
}

bool RenameMapping::operator==(const RenameMapping &p_other) const {
	return old_identifier == p_other.old_identifier && new_identifier == p_other.new_identifier && scope == p_other.scope &&
			global_kind == p_other.global_kind && owner_kind == p_other.owner_kind && owner_identifier == p_other.owner_identifier &&
			local_kind == p_other.local_kind && nested_owner_identifier == p_other.nested_owner_identifier;
}

bool SavedInstanceReference::operator==(const SavedInstanceReference &p_other) const {
	return path == p_other.path && identifier == p_other.identifier && scope == p_other.scope && global_kind == p_other.global_kind &&
			owner_kind == p_other.owner_kind && owner_identifier == p_other.owner_identifier && local_kind == p_other.local_kind &&
			nested_owner_identifier == p_other.nested_owner_identifier && instance_identifier == p_other.instance_identifier &&
			scope_identifier == p_other.scope_identifier;
}

bool RenameAffectedPath::operator==(const RenameAffectedPath &p_other) const {
	return path == p_other.path && old_identifier == p_other.old_identifier && new_identifier == p_other.new_identifier &&
			scope == p_other.scope && global_kind == p_other.global_kind && owner_kind == p_other.owner_kind &&
			owner_identifier == p_other.owner_identifier && local_kind == p_other.local_kind &&
			nested_owner_identifier == p_other.nested_owner_identifier && definition == p_other.definition;
}

bool RenameAffectedPath::operator<(const RenameAffectedPath &p_other) const {
	if (path != p_other.path) return path < p_other.path;
	if (old_identifier != p_other.old_identifier) return old_identifier < p_other.old_identifier;
	if (new_identifier != p_other.new_identifier) return new_identifier < p_other.new_identifier;
	if (scope != p_other.scope) return static_cast<std::uint8_t>(scope) < static_cast<std::uint8_t>(p_other.scope);
	if (global_kind != p_other.global_kind) return static_cast<std::uint8_t>(global_kind) < static_cast<std::uint8_t>(p_other.global_kind);
	if (owner_kind != p_other.owner_kind) return static_cast<std::uint8_t>(owner_kind) < static_cast<std::uint8_t>(p_other.owner_kind);
	if (owner_identifier != p_other.owner_identifier) return owner_identifier < p_other.owner_identifier;
	if (local_kind != p_other.local_kind) return static_cast<std::uint8_t>(local_kind) < static_cast<std::uint8_t>(p_other.local_kind);
	if (nested_owner_identifier != p_other.nested_owner_identifier) return nested_owner_identifier < p_other.nested_owner_identifier;
	return definition < p_other.definition;
}

bool SavedInstanceMigrationEntry::operator==(const SavedInstanceMigrationEntry &p_other) const {
	return path == p_other.path && field == p_other.field && old_identifier == p_other.old_identifier &&
			new_identifier == p_other.new_identifier && scope == p_other.scope && global_kind == p_other.global_kind &&
			owner_kind == p_other.owner_kind && owner_identifier == p_other.owner_identifier && local_kind == p_other.local_kind &&
			nested_owner_identifier == p_other.nested_owner_identifier && instance_identifier == p_other.instance_identifier &&
			scope_identifier == p_other.scope_identifier;
}

bool SavedInstanceMigrationEntry::operator<(const SavedInstanceMigrationEntry &p_other) const {
	if (path != p_other.path) return path < p_other.path;
	if (field != p_other.field) return field < p_other.field;
	if (old_identifier != p_other.old_identifier) return old_identifier < p_other.old_identifier;
	if (new_identifier != p_other.new_identifier) return new_identifier < p_other.new_identifier;
	if (scope != p_other.scope) return static_cast<std::uint8_t>(scope) < static_cast<std::uint8_t>(p_other.scope);
	if (global_kind != p_other.global_kind) return static_cast<std::uint8_t>(global_kind) < static_cast<std::uint8_t>(p_other.global_kind);
	if (owner_kind != p_other.owner_kind) return static_cast<std::uint8_t>(owner_kind) < static_cast<std::uint8_t>(p_other.owner_kind);
	if (owner_identifier != p_other.owner_identifier) return owner_identifier < p_other.owner_identifier;
	if (local_kind != p_other.local_kind) return static_cast<std::uint8_t>(local_kind) < static_cast<std::uint8_t>(p_other.local_kind);
	if (nested_owner_identifier != p_other.nested_owner_identifier) return nested_owner_identifier < p_other.nested_owner_identifier;
	if (instance_identifier != p_other.instance_identifier) return instance_identifier < p_other.instance_identifier;
	return scope_identifier < p_other.scope_identifier;
}

bool local_mapping_matches(const RenameMapping &p_mapping, const std::string &p_value,
		RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier, RenameLocalKind p_local_kind,
		const std::string &p_nested_owner_identifier) {
	return p_mapping.scope == RenameIdentifierScope::LOCAL && p_value == p_mapping.old_identifier &&
			p_mapping.owner_kind == p_owner_kind && p_mapping.owner_identifier == p_owner_identifier &&
			(p_mapping.local_kind == RenameLocalKind::ANY || p_mapping.local_kind == p_local_kind) &&
			(p_mapping.nested_owner_identifier.empty() || p_mapping.nested_owner_identifier == p_nested_owner_identifier);
}

bool global_mapping_matches(const RenameMapping &p_mapping, const std::string &p_value, RenameGlobalKind p_global_kind) {
	return p_mapping.scope == RenameIdentifierScope::GLOBAL && p_value == p_mapping.old_identifier &&
			global_kind_matches(p_mapping.global_kind, p_global_kind);
}

void rewrite_global(std::string &r_value, RenameGlobalKind p_kind, const std::vector<RenameMapping> &p_mappings) {
	if (r_value.empty()) return;
	for (const RenameMapping &mapping : p_mappings) {
		if (global_mapping_matches(mapping, r_value, p_kind)) {
			r_value = mapping.new_identifier;
			return;
		}
	}
}

void rewrite_local(std::string &r_value, RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier,
		RenameLocalKind p_local_kind, const std::vector<RenameMapping> &p_mappings,
		const std::string &p_nested_owner_identifier = std::string()) {
	if (r_value.empty()) return;
	for (const RenameMapping &mapping : p_mappings) {
		if (local_mapping_matches(mapping, r_value, p_owner_kind, p_owner_identifier, p_local_kind, p_nested_owner_identifier)) {
			r_value = mapping.new_identifier;
			return;
		}
	}
}

void rewrite_value(Value &r_value, const std::vector<RenameMapping> &p_mappings) {
	if (r_value.type != ValueType::IDENTIFIER) return;
	std::string *value = std::get_if<std::string>(&r_value.payload);
	if (value != nullptr) rewrite_global(*value, RenameGlobalKind::IDENTIFIER_VALUE, p_mappings);
}

void rewrite_predicate(FactPredicate &r_predicate, const std::vector<RenameMapping> &p_mappings) {
	rewrite_global(r_predicate.provider_identifier, RenameGlobalKind::PROVIDER, p_mappings);
	rewrite_global(r_predicate.fact_identifier, RenameGlobalKind::FACT, p_mappings);
	rewrite_value(r_predicate.expected, p_mappings);
}

void rewrite_level(LevelDefinition &r_level, const std::vector<RenameMapping> &p_mappings) {
	const std::string level_owner = r_level.identifier;
	rewrite_global(r_level.identifier, RenameGlobalKind::LEVEL, p_mappings);
	rewrite_local(r_level.display_name_key, RenameOwnerKind::LEVEL, level_owner, RenameLocalKind::LOCALIZATION_KEY, p_mappings);
	rewrite_local(r_level.description_key, RenameOwnerKind::LEVEL, level_owner, RenameLocalKind::LOCALIZATION_KEY, p_mappings);
	for (FactPredicate &predicate : r_level.availability_rules) rewrite_predicate(predicate, p_mappings);
	for (std::string &graph_identifier : r_level.entry_graph_identifiers) {
		rewrite_global(graph_identifier, RenameGlobalKind::TASK_GRAPH, p_mappings);
	}
	for (LevelAnchorDefinition &anchor : r_level.anchors) {
		rewrite_local(anchor.identifier, RenameOwnerKind::LEVEL, level_owner, RenameLocalKind::LEVEL_ANCHOR, p_mappings);
	}
	for (LevelExitDefinition &exit : r_level.exits) {
		const std::string target_level_owner = exit.target_level_identifier;
		rewrite_local(exit.identifier, RenameOwnerKind::LEVEL, level_owner, RenameLocalKind::LEVEL_EXIT, p_mappings);
		rewrite_global(exit.target_level_identifier, RenameGlobalKind::LEVEL, p_mappings);
		rewrite_local(exit.target_anchor_identifier, RenameOwnerKind::LEVEL, target_level_owner, RenameLocalKind::LEVEL_ANCHOR,
				p_mappings);
		rewrite_local(exit.outcome_identifier, RenameOwnerKind::LEVEL, level_owner, RenameLocalKind::LEVEL_OUTCOME, p_mappings);
	}
}

void rewrite_task_graph(TaskGraphDefinition &r_graph, const std::vector<RenameMapping> &p_mappings) {
	const std::string graph_owner = r_graph.identifier;
	rewrite_global(r_graph.identifier, RenameGlobalKind::TASK_GRAPH, p_mappings);
	rewrite_local(r_graph.entry_node_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_NODE, p_mappings);
	for (std::string &outcome : r_graph.terminal_outcomes) {
		rewrite_local(outcome, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_OUTCOME, p_mappings);
	}
	for (TaskNodeDefinition &node : r_graph.nodes) {
		const std::string node_owner = node.identifier;
		const std::string conversation_owner = node.conversation_identifier;
		rewrite_local(node.identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_NODE, p_mappings);
		for (TaskPortDefinition &port : node.ports) {
			rewrite_local(port.identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_PORT, p_mappings, node_owner);
		}
		rewrite_global(node.provider_identifier, RenameGlobalKind::PROVIDER, p_mappings);
		for (FactPredicate &predicate : node.filters) rewrite_predicate(predicate, p_mappings);
		for (Value &parameter : node.parameters) rewrite_value(parameter, p_mappings);
		rewrite_global(node.conversation_identifier, RenameGlobalKind::CONVERSATION, p_mappings);
		rewrite_local(node.conversation_entry_label, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		for (std::string &outcome : node.accepted_outcomes) {
			rewrite_local(outcome, RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::CONVERSATION_OUTCOME, p_mappings);
		}
		rewrite_global(node.subgraph_identifier, RenameGlobalKind::TASK_GRAPH, p_mappings);
		rewrite_local(node.outcome_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_OUTCOME, p_mappings);
	}
	for (TaskEdgeDefinition &edge : r_graph.edges) {
		const std::string from_node_owner = edge.from_node_identifier;
		const std::string to_node_owner = edge.to_node_identifier;
		rewrite_local(edge.identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_EDGE, p_mappings);
		rewrite_local(edge.from_node_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_NODE, p_mappings);
		rewrite_local(edge.from_port_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_PORT, p_mappings,
			from_node_owner);
		rewrite_local(edge.to_node_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_NODE, p_mappings);
		rewrite_local(edge.to_port_identifier, RenameOwnerKind::TASK_GRAPH, graph_owner, RenameLocalKind::TASK_PORT, p_mappings,
			to_node_owner);
	}
}

void rewrite_conversation(ConversationDefinition &r_conversation, const std::vector<RenameMapping> &p_mappings) {
	const std::string conversation_owner = r_conversation.identifier;
	rewrite_global(r_conversation.identifier, RenameGlobalKind::CONVERSATION, p_mappings);
	rewrite_local(r_conversation.entry_label, RenameOwnerKind::CONVERSATION, conversation_owner,
			RenameLocalKind::CONVERSATION_STEP, p_mappings);
	for (std::string &speaker : r_conversation.speaker_identifiers) rewrite_global(speaker, RenameGlobalKind::SPEAKER, p_mappings);
	for (std::string &outcome : r_conversation.terminal_outcomes) {
		rewrite_local(outcome, RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::CONVERSATION_OUTCOME, p_mappings);
	}
	for (ConversationStepDefinition &step : r_conversation.steps) {
		const std::string step_owner = step.identifier;
		rewrite_local(step.identifier, RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_global(step.speaker_identifier, RenameGlobalKind::SPEAKER, p_mappings);
		rewrite_local(step.line_key, RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::LOCALIZATION_KEY, p_mappings);
		for (LocalizedParameter &parameter : step.parameters) {
			rewrite_local(parameter.identifier, RenameOwnerKind::CONVERSATION, conversation_owner, RenameLocalKind::PARAMETER, p_mappings,
					step_owner);
			rewrite_value(parameter.value, p_mappings);
		}
		rewrite_local(step.next_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_global(step.provider_identifier, RenameGlobalKind::PROVIDER, p_mappings);
		for (FactPredicate &predicate : step.conditions) rewrite_predicate(predicate, p_mappings);
		rewrite_local(step.true_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_local(step.false_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_local(step.success_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_local(step.failure_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		for (ConversationChoiceDefinition &choice : step.choices) {
			const std::string choice_owner = choice.identifier;
			rewrite_local(choice.identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
					RenameLocalKind::CONVERSATION_CHOICE, p_mappings, step_owner);
			rewrite_local(choice.label_key, RenameOwnerKind::CONVERSATION, conversation_owner,
					RenameLocalKind::LOCALIZATION_KEY, p_mappings, step_owner);
			rewrite_local(choice.target_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
					RenameLocalKind::CONVERSATION_STEP, p_mappings);
			for (FactPredicate &predicate : choice.conditions) rewrite_predicate(predicate, p_mappings);
			(void)choice_owner;
		}
		rewrite_local(step.target_step_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_STEP, p_mappings);
		rewrite_local(step.outcome_identifier, RenameOwnerKind::CONVERSATION, conversation_owner,
				RenameLocalKind::CONVERSATION_OUTCOME, p_mappings);
	}
}

void rewrite_speaker(SpeakerDefinition &r_speaker, const std::vector<RenameMapping> &p_mappings) {
	const std::string speaker_owner = r_speaker.identifier;
	rewrite_global(r_speaker.identifier, RenameGlobalKind::SPEAKER, p_mappings);
	rewrite_local(r_speaker.display_name_key, RenameOwnerKind::SPEAKER, speaker_owner, RenameLocalKind::LOCALIZATION_KEY, p_mappings);
	rewrite_local(r_speaker.portrait_key, RenameOwnerKind::SPEAKER, speaker_owner, RenameLocalKind::LOCALIZATION_KEY, p_mappings);
}

void rewrite_provider(ProviderDeclaration &r_provider, const std::vector<RenameMapping> &p_mappings) {
	rewrite_global(r_provider.identifier, RenameGlobalKind::PROVIDER, p_mappings);
}

void rewrite_catalog_definitions(const LevelTaskCatalog &p_source, const std::vector<RenameMapping> &p_mappings,
		std::vector<LevelDefinition> &r_levels, std::vector<TaskGraphDefinition> &r_graphs,
		std::vector<ConversationDefinition> &r_conversations, std::vector<SpeakerDefinition> &r_speakers,
		std::vector<ProviderDeclaration> &r_providers) {
	r_levels = p_source.levels();
	r_graphs = p_source.task_graphs();
	r_conversations = p_source.conversations();
	r_speakers = p_source.speakers();
	r_providers = p_source.providers();
	for (LevelDefinition &level : r_levels) rewrite_level(level, p_mappings);
	for (TaskGraphDefinition &graph : r_graphs) rewrite_task_graph(graph, p_mappings);
	for (ConversationDefinition &conversation : r_conversations) rewrite_conversation(conversation, p_mappings);
	for (SpeakerDefinition &speaker : r_speakers) rewrite_speaker(speaker, p_mappings);
	for (ProviderDeclaration &provider : r_providers) rewrite_provider(provider, p_mappings);
}

Status build_rewritten_catalog(const LevelTaskCatalog &p_source, const std::vector<RenameMapping> &p_mappings,
		LevelTaskCatalog &r_candidate) {
	std::vector<LevelDefinition> levels;
	std::vector<TaskGraphDefinition> graphs;
	std::vector<ConversationDefinition> conversations;
	std::vector<SpeakerDefinition> speakers;
	std::vector<ProviderDeclaration> providers;
	rewrite_catalog_definitions(p_source, p_mappings, levels, graphs, conversations, speakers, providers);

	LevelTaskCatalog candidate;
	for (const LevelDefinition &level : levels) {
		const Status status = candidate.add_level(level);
		if (!status.ok()) return status;
	}
	for (const TaskGraphDefinition &graph : graphs) {
		const Status status = candidate.add_task_graph(graph);
		if (!status.ok()) return status;
	}
	for (const ConversationDefinition &conversation : conversations) {
		const Status status = candidate.add_conversation(conversation);
		if (!status.ok()) return status;
	}
	for (const SpeakerDefinition &speaker : speakers) {
		const Status status = candidate.add_speaker(speaker);
		if (!status.ok()) return status;
	}
	for (const ProviderDeclaration &provider : providers) {
		const Status status = candidate.add_provider(provider);
		if (!status.ok()) return status;
	}
	const Status status = candidate.seal();
	if (!status.ok()) return status;
	r_candidate = std::move(candidate);
	return ok_status();
}

bool same_saved_path(const SavedInstanceReference &p_left, const SavedInstanceReference &p_right) {
	return fallback_save_path(p_left) == fallback_save_path(p_right);
}

bool has_matching_mapping(const std::vector<RenameMapping> &p_mappings, const SavedSlot &p_slot,
		std::size_t &r_mapping_index) {
	bool found = false;
	for (std::size_t index = 0; index < p_mappings.size(); ++index) {
		if (!mapping_matches(p_mappings[index], p_slot)) continue;
		if (found) return false;
		found = true;
		r_mapping_index = index;
	}
	return found;
}

bool has_saved_entry(const RenamePlan &p_plan, const SavedInstanceMigrationEntry &p_expected) {
	return std::find(p_plan.saved_instance_entries.begin(), p_plan.saved_instance_entries.end(), p_expected) !=
			p_plan.saved_instance_entries.end();
}

SavedInstanceMigrationEntry make_saved_entry(const SavedSlot &p_slot, const RenameMapping &p_mapping) {
	SavedInstanceMigrationEntry entry;
	entry.path = p_slot.path;
	entry.field = p_slot.field;
	entry.old_identifier = p_mapping.old_identifier;
	entry.new_identifier = p_mapping.new_identifier;
	entry.scope = p_slot.scope;
	entry.global_kind = p_slot.global_kind;
	entry.owner_kind = p_slot.owner_kind;
	entry.owner_identifier = p_slot.owner_identifier;
	entry.local_kind = p_slot.local_kind;
	entry.nested_owner_identifier = p_slot.nested_owner_identifier;
	if (p_slot.reference != nullptr) {
		entry.instance_identifier = p_slot.reference->instance_identifier;
		entry.scope_identifier = p_slot.reference->scope_identifier;
	}
	return entry;
}

Status validate_saved_collection(const std::vector<SavedInstanceReference> &p_references) {
	if (p_references.size() > MAX_RENAME_SAVED_INSTANCE_ENTRIES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_references.size());
	}
	for (const SavedInstanceReference &reference : p_references) {
		const Status status = validate_saved_reference(reference);
		if (!status.ok()) return status;
	}
	for (std::size_t index = 0; index < p_references.size(); ++index) {
		for (std::size_t other = index + 1; other < p_references.size(); ++other) {
			if (same_saved_path(p_references[index], p_references[other])) return invalid_argument();
		}
	}
	return ok_status();
}

Status validate_plan_for_source(const LevelTaskCatalog &p_source_catalog, const RenamePlan &p_plan) {
	if (!p_source_catalog.sealed()) return make_status(StatusCode::CATALOG_NOT_SEALED);
	if (!p_plan.valid || !p_plan.status.ok() || !p_plan.preview_only || p_plan.source_catalog_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		return invalid_argument();
	}
	if (p_plan.source_catalog_fingerprint != p_source_catalog.fingerprint()) {
		return make_status(StatusCode::CATALOG_FINGERPRINT_MISMATCH, DiagnosticId::CATALOG_FINGERPRINT_DIFFERS,
				p_source_catalog.fingerprint());
	}
	if (p_plan.mappings.empty() || p_plan.mappings.size() > MAX_RENAME_MAPPINGS ||
			p_plan.affected_paths.size() > MAX_RENAME_AFFECTED_PATHS ||
			p_plan.saved_instance_entries.size() > MAX_RENAME_SAVED_INSTANCE_ENTRIES) {
		return invalid_argument();
	}
	for (const RenameMapping &mapping : p_plan.mappings) {
		const Status status = validate_mapping(mapping);
		if (!status.ok()) return status;
	}
	return ok_status();
}

Status validate_mapping_overlap(const std::vector<RenameMapping> &p_mappings) {
	for (std::size_t index = 0; index < p_mappings.size(); ++index) {
		for (std::size_t other = index + 1; other < p_mappings.size(); ++other) {
			if (!mapping_domains_overlap(p_mappings[index], p_mappings[other])) continue;
			// Two mappings which can select the same slot are ambiguous even if
			// they happen to carry the same target; accepting duplicates would
			// make the preview dependent on mapping order.
			return invalid_argument();
		}
		for (std::size_t other = 0; other < index; ++other) {
			if (!mapping_domains_overlap(p_mappings[index], p_mappings[other])) continue;
			return invalid_argument();
		}
	}
	return ok_status();
}

Status LevelTaskMigrationPlanner::preview(const LevelTaskCatalog &p_catalog,
		const std::vector<RenameMapping> &p_mappings,
		const std::vector<SavedInstanceReference> &p_saved_instances,
		RenamePlan &r_plan) {
	// Reset the caller's output before any validation.  No partially built
	// preview is observable when an input is rejected.
	r_plan = RenamePlan{};
	if (!p_catalog.sealed()) {
		r_plan.status = make_status(StatusCode::CATALOG_NOT_SEALED);
		return r_plan.status;
	}
	if (p_mappings.empty() || p_mappings.size() > MAX_RENAME_MAPPINGS) {
		r_plan.status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_mappings.size());
		return r_plan.status;
	}
	Status status = validate_saved_collection(p_saved_instances);
	if (!status.ok()) {
		r_plan.status = status;
		return status;
	}

	std::vector<Slot> catalog_slots;
	std::vector<SavedSlot> saved_slots;
	collect_catalog_slots(p_catalog, catalog_slots);
	collect_saved_slots(p_saved_instances, saved_slots);

	std::vector<RenameMapping> mappings = p_mappings;
	for (RenameMapping &mapping : mappings) {
		status = validate_mapping(mapping);
		if (!status.ok()) {
			r_plan.status = status;
			return status;
		}
		status = normalize_local_mapping(mapping, catalog_slots, saved_slots);
		if (!status.ok()) {
			r_plan.status = status;
			return status;
		}
	}
	status = validate_mapping_overlap(mappings);
	if (!status.ok()) {
		r_plan.status = status;
		return status;
	}

	std::vector<std::size_t> mapping_match_counts(mappings.size(), 0);
	for (const Slot &slot : catalog_slots) {
		std::size_t matching_mapping = 0;
		bool matched = false;
		for (std::size_t index = 0; index < mappings.size(); ++index) {
			if (!mapping_matches(mappings[index], slot)) continue;
			if (matched) {
				status = invalid_argument();
				r_plan.status = status;
				return status;
			}
			matched = true;
			matching_mapping = index;
		}
		if (matched) {
			++mapping_match_counts[matching_mapping];
			status = append_affected(slot, mappings[matching_mapping], r_plan.affected_paths);
			if (!status.ok()) {
				r_plan.status = status;
				return status;
			}
		}
	}
	for (const SavedSlot &slot : saved_slots) {
		std::size_t matching_mapping = 0;
		if (!has_matching_mapping(mappings, slot, matching_mapping)) {
			// false means either no mapping or overlapping mappings.  Distinguish
			// the latter with a small second pass so malformed plans fail closed.
			std::size_t count = 0;
			for (const RenameMapping &mapping : mappings) {
				if (mapping_matches(mapping, slot)) ++count;
			}
			if (count > 1) {
				status = invalid_argument();
				r_plan.status = status;
				return status;
			}
			continue;
		}
		++mapping_match_counts[matching_mapping];
		status = append_saved_affected(slot, mappings[matching_mapping], r_plan.saved_instance_entries);
		if (!status.ok()) {
			r_plan.status = status;
			return status;
		}
	}
	for (std::size_t index = 0; index < mappings.size(); ++index) {
		if (mapping_match_counts[index] == 0) {
			status = invalid_reference(mappings[index].old_identifier);
			r_plan.status = status;
			return status;
		}
	}

	std::sort(r_plan.affected_paths.begin(), r_plan.affected_paths.end());
	std::sort(r_plan.saved_instance_entries.begin(), r_plan.saved_instance_entries.end());
	LevelTaskCatalog candidate;
	status = build_rewritten_catalog(p_catalog, mappings, candidate);
	if (!status.ok()) {
		r_plan.status = status;
		r_plan.affected_paths.clear();
		r_plan.saved_instance_entries.clear();
		return status;
	}

	r_plan.status = ok_status();
	r_plan.source_catalog_fingerprint = p_catalog.fingerprint();
	r_plan.mappings = std::move(mappings);
	r_plan.preview_only = true;
	r_plan.valid = true;
	return r_plan.status;
}

Status LevelTaskMigrationPlanner::apply(const LevelTaskCatalog &p_source_catalog,
		const RenamePlan &p_plan, LevelTaskCatalog &r_destination_catalog) {
	if (static_cast<const void *>(&p_source_catalog) == static_cast<const void *>(&r_destination_catalog)) {
		return invalid_argument();
	}
	Status status = validate_plan_for_source(p_source_catalog, p_plan);
	if (!status.ok()) return status;
	LevelTaskCatalog candidate;
	status = build_rewritten_catalog(p_source_catalog, p_plan.mappings, candidate);
	if (!status.ok()) return status;
	r_destination_catalog = std::move(candidate);
	return ok_status();
}

Status LevelTaskMigrationPlanner::apply_saved_instance_migrations(const RenamePlan &p_plan,
		const std::vector<SavedInstanceReference> &p_source,
		std::vector<SavedInstanceReference> &r_destination) {
	if (!p_plan.ok() || !p_plan.preview_only || p_plan.mappings.empty()) return invalid_argument();
	Status status = validate_saved_collection(p_source);
	if (!status.ok()) return status;
	std::vector<SavedSlot> saved_slots;
	collect_saved_slots(p_source, saved_slots);
	std::vector<SavedInstanceReference> candidate = p_source;
	for (std::size_t ref_index = 0; ref_index < candidate.size(); ++ref_index) {
		SavedInstanceReference &reference = candidate[ref_index];
		// The source slot metadata is used for selecting mappings.  Reconstruct
		// the two possible fields against the original reference, not the
		// candidate, so an owner rename cannot change local-scope resolution.
		for (const SavedSlot &slot : saved_slots) {
			if (slot.reference != &p_source[ref_index]) continue;
			std::size_t mapping_index = 0;
			if (!has_matching_mapping(p_plan.mappings, slot, mapping_index)) continue;
			const SavedInstanceMigrationEntry expected = make_saved_entry(slot, p_plan.mappings[mapping_index]);
			if (!has_saved_entry(p_plan, expected)) return invalid_argument();
			if (slot.field == "identifier") {
				reference.identifier = p_plan.mappings[mapping_index].new_identifier;
			} else if (slot.field == "owner_identifier") {
				reference.owner_identifier = p_plan.mappings[mapping_index].new_identifier;
			}
		}
	}
	r_destination = std::move(candidate);
	return ok_status();
}

Status LevelTaskMigrationPlanner::apply(const LevelTaskCatalog &p_source_catalog,
		const RenamePlan &p_plan, LevelTaskCatalog &r_destination_catalog,
		const std::vector<SavedInstanceReference> &p_source_saved_instances,
		std::vector<SavedInstanceReference> &r_destination_saved_instances) {
	if (static_cast<const void *>(&p_source_catalog) == static_cast<const void *>(&r_destination_catalog)) {
		return invalid_argument();
	}
	Status status = validate_plan_for_source(p_source_catalog, p_plan);
	if (!status.ok()) return status;
	LevelTaskCatalog catalog_candidate;
	status = build_rewritten_catalog(p_source_catalog, p_plan.mappings, catalog_candidate);
	if (!status.ok()) return status;
	std::vector<SavedInstanceReference> saved_candidate;
	status = apply_saved_instance_migrations(p_plan, p_source_saved_instances, saved_candidate);
	if (!status.ok()) return status;
	r_destination_catalog = std::move(catalog_candidate);
	r_destination_saved_instances = std::move(saved_candidate);
	return ok_status();
}

} // namespace lts
