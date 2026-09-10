#include "core/lts_catalog.h"

#include "core/lts_hash.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace lts {

namespace {

template <typename T>
const T *find_definition(const std::vector<T> &p_definitions, const std::string &p_identifier) {
	const auto found = std::lower_bound(
			p_definitions.begin(),
			p_definitions.end(),
			p_identifier,
			[](const T &p_definition, const std::string &p_id) {
				return p_definition.identifier < p_id;
			});
	if (found == p_definitions.end() || found->identifier != p_identifier) {
		return nullptr;
	}
	return &*found;
}

template <typename T>
void sort_definitions(std::vector<T> &r_definitions) {
	std::sort(r_definitions.begin(), r_definitions.end(), [](const T &p_a, const T &p_b) {
		return p_a < p_b;
	});
}

template <typename T>
void sort_definitions_with_sources(std::vector<T> &r_definitions, std::vector<std::string> &r_sources) {
	if (r_definitions.size() != r_sources.size()) {
		// Sources are diagnostics-only.  A mismatch can only be introduced by a
		// caller copying an old object across a source-layout change; preserving
		// content is safer than indexing outside the parallel vector.
		r_sources.resize(r_definitions.size());
	}
	std::vector<std::size_t> order(r_definitions.size());
	for (std::size_t index = 0; index < order.size(); ++index) {
		order[index] = index;
	}
	std::sort(order.begin(), order.end(), [&](std::size_t p_a, std::size_t p_b) {
		if (r_definitions[p_a] < r_definitions[p_b]) return true;
		if (r_definitions[p_b] < r_definitions[p_a]) return false;
		return p_a < p_b;
	});

	std::vector<T> definitions;
	std::vector<std::string> sources;
	definitions.reserve(r_definitions.size());
	sources.reserve(r_sources.size());
	for (const std::size_t index : order) {
		definitions.push_back(std::move(r_definitions[index]));
		sources.push_back(std::move(r_sources[index]));
	}
	r_definitions = std::move(definitions);
	r_sources = std::move(sources);
}

std::string bounded_path(const std::string &p_path) {
	if (p_path.size() <= MAX_DIAGNOSTIC_PATH_BYTES) {
		return p_path;
	}
	return p_path.substr(0, MAX_DIAGNOSTIC_PATH_BYTES);
}

std::string resource_path(const char *p_kind, const std::string &p_identifier) {
	std::string path(p_kind);
	path.push_back('.');
	path += p_identifier.empty() ? std::string("<invalid>") : p_identifier;
	return bounded_path(path);
}

std::string child_path(const std::string &p_base, const std::string &p_field, const std::string &p_value = std::string()) {
	std::string path = p_base;
	path.push_back('.');
	path += p_field;
	if (!p_value.empty()) {
		path.push_back('.');
		path += p_value;
	}
	return bounded_path(path);
}

std::string occurrence_path(
		const char *p_kind,
		const std::string &p_identifier,
		std::size_t p_index,
		const std::vector<std::string> &p_sources) {
	if (p_index < p_sources.size() && !p_sources[p_index].empty()) {
		return bounded_path(p_sources[p_index]);
	}
	std::string path = resource_path(p_kind, p_identifier);
	path += ".definitions[";
	path += std::to_string(p_index);
	path.push_back(']');
	return bounded_path(path);
}

void reset_report(CatalogValidationReport &r_report) {
	r_report.status = ok_status();
	r_report.findings.clear();
	r_report.total_finding_count = 0;
	r_report.truncated = false;
}

void append_finding(
		CatalogValidationReport &r_report,
		const Status &p_status,
		const std::string &p_path,
		const std::string &p_related_path = std::string()) {
	if (p_status.ok()) {
		return;
	}
	if (r_report.total_finding_count != std::numeric_limits<std::uint32_t>::max()) {
		++r_report.total_finding_count;
	}
	if (r_report.findings.size() < MAX_CATALOG_DIAGNOSTICS) {
		r_report.findings.push_back(CatalogDiagnostic{ p_status, bounded_path(p_path), bounded_path(p_related_path) });
	} else {
		r_report.truncated = true;
	}
}

void finish_report(CatalogValidationReport &r_report) {
	std::sort(r_report.findings.begin(), r_report.findings.end());
	if (r_report.total_finding_count > r_report.findings.size()) {
		r_report.truncated = true;
	}
	r_report.status = r_report.findings.empty() ? ok_status() : r_report.findings.front().status;
}

Status source_path_status(const std::string &p_source_path) {
	if (p_source_path.size() > MAX_DIAGNOSTIC_PATH_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_source_path.size());
	}
	return ok_status();
}

Status duplicate_status(const std::string &p_identifier) {
	return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, hash_string(p_identifier));
}

template <typename T>
bool has_identifier(const std::vector<T> &p_definitions, const std::string &p_identifier) {
	for (const T &definition : p_definitions) {
		if (definition.identifier == p_identifier) return true;
	}
	return false;
}

template <typename T>
void append_duplicate_findings(
		const std::vector<T> &p_definitions,
		const std::vector<std::string> &p_sources,
		const char *p_kind,
		CatalogValidationReport &r_report) {
	for (std::size_t index = 1; index < p_definitions.size(); ++index) {
		if (p_definitions[index - 1].identifier != p_definitions[index].identifier) {
			continue;
		}
		const std::string first_path = occurrence_path(p_kind, p_definitions[index].identifier, index - 1, p_sources);
		const std::string second_path = occurrence_path(p_kind, p_definitions[index].identifier, index, p_sources);
		append_finding(r_report, duplicate_status(p_definitions[index].identifier),
				resource_path(p_kind, p_definitions[index].identifier), first_path + " <-> " + second_path);
	}
}

template <typename T>
void append_local_validation(
		std::vector<T> &r_definitions,
		const char *p_kind,
		CatalogValidationReport &r_report) {
	for (T &definition : r_definitions) {
		const Status status = validate_and_canonicalize(definition);
		if (!status.ok()) {
			append_finding(r_report, status, resource_path(p_kind, definition.identifier));
		}
	}
}

template <typename T>
void append_count_limit(
		const std::vector<T> &p_definitions,
		std::size_t p_limit,
		DiagnosticId p_diagnostic,
		const char *p_kind,
		CatalogValidationReport &r_report) {
	if (p_definitions.size() > p_limit) {
		append_finding(
				r_report,
				make_status(StatusCode::LIMIT_EXCEEDED, p_diagnostic, p_definitions.size()),
				std::string("catalog.") + p_kind);
	}
}

void append_missing_reference(
		const char *p_kind,
		const std::string &p_owner,
		const std::string &p_field,
		const std::string &p_reference,
		CatalogValidationReport &r_report,
		DiagnosticId p_diagnostic = DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
		StatusCode p_code = StatusCode::INVALID_REFERENCE) {
	const Status status = make_status(p_code, p_diagnostic, hash_string(p_reference));
	append_finding(r_report, status, child_path(resource_path(p_kind, p_owner), p_field, p_reference));
}

template <typename T>
const T *find_local_record(const std::vector<T> &p_records, const std::string &p_identifier) {
	for (const T &record : p_records) {
		if (record.identifier == p_identifier) return &record;
	}
	return nullptr;
}

const TaskPortDefinition *find_port(const TaskNodeDefinition &p_node, const std::string &p_identifier) {
	for (const TaskPortDefinition &port : p_node.ports) {
		if (port.identifier == p_identifier) return &port;
	}
	return nullptr;
}

bool contains_local_identifier(const std::vector<std::string> &p_values, const std::string &p_identifier) {
	return std::binary_search(p_values.begin(), p_values.end(), p_identifier, local_identifier_less);
}

bool contains_global_identifier(const std::vector<std::string> &p_values, const std::string &p_identifier) {
	return std::binary_search(p_values.begin(), p_values.end(), p_identifier, identifier_less);
}

bool is_terminal(TaskNodeKind p_kind) {
	return p_kind == TaskNodeKind::SUCCESS_TERMINAL || p_kind == TaskNodeKind::FAILURE_TERMINAL ||
			p_kind == TaskNodeKind::CANCELLED_TERMINAL;
}

bool is_required_provider_kind(TaskNodeKind p_node_kind, ProviderKind &r_expected_kind) {
	switch (p_node_kind) {
		case TaskNodeKind::OBJECTIVE:
			r_expected_kind = ProviderKind::EVENT;
			return true;
		case TaskNodeKind::CONDITION:
			r_expected_kind = ProviderKind::CONDITION;
			return true;
		case TaskNodeKind::EXTERNAL_ACTION:
			r_expected_kind = ProviderKind::ACTION;
			return true;
		case TaskNodeKind::REWARD_REQUEST:
			r_expected_kind = ProviderKind::REWARD;
			return true;
		default:
			return false;
	}
}

bool provider_kind_compatible(ProviderKind p_actual, ProviderKind p_expected) {
	return p_actual == p_expected;
}

void validate_provider_reference(
		const std::vector<ProviderDeclaration> &p_providers,
		const std::string &p_owner_path,
		const char *p_field,
		const std::string &p_provider_identifier,
		ProviderKind p_expected_kind,
		CatalogValidationReport &r_report) {
	const ProviderDeclaration *provider = find_definition(p_providers, p_provider_identifier);
	if (provider == nullptr) {
		append_finding(
				r_report,
				make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_provider_identifier)),
				child_path(p_owner_path, p_field, p_provider_identifier));
		return;
	}
	if (!provider_kind_compatible(provider->kind, p_expected_kind)) {
		append_finding(
				r_report,
				make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::PROVIDER_KIND_INVALID,
						static_cast<std::uint8_t>(provider->kind)),
				child_path(p_owner_path, p_field, p_provider_identifier));
	}
}

void validate_fact_predicate_provider(
		const std::vector<ProviderDeclaration> &p_providers,
		const std::string &p_owner_path,
		const FactPredicate &p_predicate,
		CatalogValidationReport &r_report) {
	validate_provider_reference(
			p_providers,
			p_owner_path,
			"predicate_provider",
			p_predicate.provider_identifier,
			ProviderKind::FACT,
			r_report);
}

void validate_task_graph_references(
		const std::vector<TaskGraphDefinition> &p_graphs,
		const std::vector<ConversationDefinition> &p_conversations,
		const std::vector<ProviderDeclaration> &p_providers,
		const TaskGraphDefinition &p_graph,
		CatalogValidationReport &r_report) {
	const std::string graph_path = resource_path("task", p_graph.identifier);
	std::map<std::string, std::size_t> node_indices;
	for (std::size_t index = 0; index < p_graph.nodes.size(); ++index) {
		node_indices.emplace(p_graph.nodes[index].identifier, index);
	}

	std::size_t entry_count = 0;
	std::vector<std::size_t> terminal_indices;
	for (std::size_t index = 0; index < p_graph.nodes.size(); ++index) {
		const TaskNodeDefinition &node = p_graph.nodes[index];
		if (node.kind == TaskNodeKind::ENTRY) ++entry_count;
		if (is_terminal(node.kind)) terminal_indices.push_back(index);

		ProviderKind expected_provider_kind = ProviderKind::FACT;
		if (is_required_provider_kind(node.kind, expected_provider_kind) && !node.provider_identifier.empty()) {
			validate_provider_reference(
					p_providers,
					child_path(graph_path, "node", node.identifier),
					"provider",
					node.provider_identifier,
					expected_provider_kind,
					r_report);
		}
		for (const FactPredicate &predicate : node.filters) {
			validate_fact_predicate_provider(
					p_providers,
					child_path(graph_path, "node", node.identifier),
					predicate,
					r_report);
		}

		if (node.kind == TaskNodeKind::CONVERSATION && !node.conversation_identifier.empty()) {
			const ConversationDefinition *conversation = find_definition(p_conversations, node.conversation_identifier);
			if (conversation == nullptr) {
				append_missing_reference(
						"task",
						p_graph.identifier,
						std::string("node.") + node.identifier + ".conversation",
						node.conversation_identifier,
						r_report,
						DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
			} else {
				if (find_local_record(conversation->steps, node.conversation_entry_label) == nullptr) {
					append_missing_reference(
							"task",
							p_graph.identifier,
								std::string("node.") + node.identifier + ".conversation_entry",
							node.conversation_entry_label,
							r_report,
							DiagnosticId::CONVERSATION_ENTRY_INVALID);
				}
				for (const std::string &outcome : node.accepted_outcomes) {
					if (!contains_local_identifier(conversation->terminal_outcomes, outcome)) {
						append_missing_reference(
								"task",
								p_graph.identifier,
								std::string("node.") + node.identifier + ".conversation_outcome",
								outcome,
								r_report,
								DiagnosticId::CONVERSATION_OUTCOME_INVALID);
					}
				}
			}
		}
		if (node.kind == TaskNodeKind::SUBGRAPH && !node.subgraph_identifier.empty() &&
				find_definition(p_graphs, node.subgraph_identifier) == nullptr) {
			append_missing_reference(
					"task",
					p_graph.identifier,
					std::string("node.") + node.identifier + ".subgraph",
					node.subgraph_identifier,
					r_report,
					DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		}
	}

	const auto entry = node_indices.find(p_graph.entry_node_identifier);
	if (entry == node_indices.end()) {
		append_finding(
				r_report,
				make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_ENTRY_INVALID,
						hash_string(p_graph.entry_node_identifier)),
				child_path(graph_path, "entry", p_graph.entry_node_identifier));
	} else if (p_graph.nodes[entry->second].kind != TaskNodeKind::ENTRY) {
		append_finding(
				r_report,
				make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::GRAPH_ENTRY_INVALID,
						static_cast<std::uint8_t>(p_graph.nodes[entry->second].kind)),
				child_path(graph_path, "entry", p_graph.entry_node_identifier));
	}
	if (entry_count != 1) {
		append_finding(
				r_report,
				make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_ENTRY_INVALID, entry_count),
				child_path(graph_path, "entry_count"));
	}

	std::set<std::string> terminal_outcomes;
	for (const std::string &outcome : p_graph.terminal_outcomes) terminal_outcomes.insert(outcome);
	for (const std::size_t index : terminal_indices) {
		const TaskNodeDefinition &terminal = p_graph.nodes[index];
		if (terminal_outcomes.find(terminal.outcome_identifier) == terminal_outcomes.end()) {
			append_finding(
					r_report,
					make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_OUTCOME_INVALID,
							hash_string(terminal.outcome_identifier)),
					child_path(graph_path, std::string("node.") + terminal.identifier + ".outcome", terminal.outcome_identifier));
		}
	}
	for (const std::string &outcome : p_graph.terminal_outcomes) {
		bool found_terminal = false;
		for (const std::size_t index : terminal_indices) {
			if (p_graph.nodes[index].outcome_identifier == outcome) {
				found_terminal = true;
				break;
			}
		}
		if (!found_terminal) {
			append_finding(
					r_report,
					make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_OUTCOME_INVALID, hash_string(outcome)),
					child_path(graph_path, "terminal_outcome", outcome));
		}
	}

	std::vector<std::vector<std::size_t>> adjacency(p_graph.nodes.size());
	std::vector<std::vector<std::size_t>> reverse_adjacency(p_graph.nodes.size());
	std::set<std::pair<std::string, std::string>> destination_ports;
	for (const TaskEdgeDefinition &edge : p_graph.edges) {
		const std::string edge_path = child_path(graph_path, "edge", edge.identifier);
		const auto from = node_indices.find(edge.from_node_identifier);
		const auto to = node_indices.find(edge.to_node_identifier);
		if (from == node_indices.end()) {
			append_missing_reference("task", p_graph.identifier, std::string("edge.") + edge.identifier + ".from_node",
					edge.from_node_identifier, r_report, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		}
		if (to == node_indices.end()) {
			append_missing_reference("task", p_graph.identifier, std::string("edge.") + edge.identifier + ".to_node",
					edge.to_node_identifier, r_report, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		}
		if (from == node_indices.end() || to == node_indices.end()) continue;

		const TaskPortDefinition *from_port = find_port(p_graph.nodes[from->second], edge.from_port_identifier);
		const TaskPortDefinition *to_port = find_port(p_graph.nodes[to->second], edge.to_port_identifier);
		if (from_port == nullptr) {
			append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_PORT_INVALID,
					hash_string(edge.from_port_identifier)), child_path(edge_path, "from_port", edge.from_port_identifier));
		}
		if (to_port == nullptr) {
			append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_PORT_INVALID,
					hash_string(edge.to_port_identifier)), child_path(edge_path, "to_port", edge.to_port_identifier));
		}
		if (from_port == nullptr || to_port == nullptr) continue;
		if (from_port->direction != TaskPortDirection::OUTPUT || to_port->direction != TaskPortDirection::INPUT) {
			append_finding(r_report, make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID), edge_path);
		}
		if (from_port->value_type != to_port->value_type) {
			const std::uint64_t detail = (static_cast<std::uint64_t>(static_cast<std::uint8_t>(from_port->value_type)) << 32) |
					static_cast<std::uint8_t>(to_port->value_type);
			append_finding(r_report, make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID, detail), edge_path);
		}
		const auto destination_key = std::make_pair(edge.to_node_identifier, edge.to_port_identifier);
		if (!destination_ports.insert(destination_key).second) {
			append_finding(r_report, make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_EDGE_DUPLICATE,
					hash_string(edge.to_node_identifier + "." + edge.to_port_identifier)), edge_path);
		}
		adjacency[from->second].push_back(to->second);
		reverse_adjacency[to->second].push_back(from->second);
	}

	// A graph is a DAG in V1.  The DFS is bounded by the already-validated
	// MAX_NODES_PER_TASK_GRAPH limit and reports one deterministic finding per
	// back-edge rather than recursing indefinitely.
	enum class Visit : std::uint8_t { UNVISITED, VISITING, VISITED };
	std::vector<Visit> visits(p_graph.nodes.size(), Visit::UNVISITED);
	std::function<void(std::size_t)> visit = [&](std::size_t p_index) {
		if (visits[p_index] == Visit::VISITED) return;
		if (visits[p_index] == Visit::VISITING) {
			append_finding(r_report, make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_ENTRY_INVALID, p_index),
					child_path(graph_path, "cycle", p_graph.nodes[p_index].identifier));
			return;
		}
		visits[p_index] = Visit::VISITING;
		for (const std::size_t next : adjacency[p_index]) visit(next);
		visits[p_index] = Visit::VISITED;
	};
	for (std::size_t index = 0; index < p_graph.nodes.size(); ++index) visit(index);

	if (entry != node_indices.end()) {
		std::vector<bool> reachable(p_graph.nodes.size(), false);
		std::vector<std::size_t> pending{ entry->second };
		reachable[entry->second] = true;
		for (std::size_t cursor = 0; cursor < pending.size(); ++cursor) {
			for (const std::size_t next : adjacency[pending[cursor]]) {
				if (!reachable[next]) {
					reachable[next] = true;
					pending.push_back(next);
				}
			}
		}
		for (std::size_t index = 0; index < reachable.size(); ++index) {
			if (!reachable[index]) {
				append_finding(r_report, make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, index),
						child_path(graph_path, "unreachable", p_graph.nodes[index].identifier));
			}
		}

		std::vector<bool> can_reach_terminal(p_graph.nodes.size(), false);
		pending.clear();
		for (const std::size_t terminal : terminal_indices) {
			if (!can_reach_terminal[terminal]) {
				can_reach_terminal[terminal] = true;
				pending.push_back(terminal);
			}
		}
		for (std::size_t cursor = 0; cursor < pending.size(); ++cursor) {
			for (const std::size_t previous : reverse_adjacency[pending[cursor]]) {
				if (!can_reach_terminal[previous]) {
					can_reach_terminal[previous] = true;
					pending.push_back(previous);
				}
			}
		}
		for (std::size_t index = 0; index < can_reach_terminal.size(); ++index) {
			if (!can_reach_terminal[index]) {
				append_finding(r_report, make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_OUTCOME_INVALID, index),
						child_path(graph_path, "no_terminal", p_graph.nodes[index].identifier));
			}
		}
	}
}

void validate_level_references(
		const std::vector<LevelDefinition> &p_levels,
		const std::vector<TaskGraphDefinition> &p_graphs,
		const std::vector<ProviderDeclaration> &p_providers,
		const LevelDefinition &p_level,
		CatalogValidationReport &r_report) {
	const std::string level_path = resource_path("level", p_level.identifier);
	for (const FactPredicate &predicate : p_level.availability_rules) {
		validate_fact_predicate_provider(p_providers, level_path, predicate, r_report);
	}
	for (const std::string &graph_identifier : p_level.entry_graph_identifiers) {
		if (find_definition(p_graphs, graph_identifier) == nullptr) {
			append_missing_reference("level", p_level.identifier, "entry_graph", graph_identifier, r_report,
					DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID);
		}
	}
	for (const LevelExitDefinition &exit : p_level.exits) {
		const std::string exit_path = child_path(level_path, "exit", exit.identifier);
		const LevelDefinition *target_level = find_definition(p_levels, exit.target_level_identifier);
		if (target_level == nullptr) {
			append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_EXIT_INVALID,
					hash_string(exit.target_level_identifier)), child_path(exit_path, "target_level", exit.target_level_identifier));
			continue;
		}
		if (find_definition(target_level->anchors, exit.target_anchor_identifier) == nullptr) {
			append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_ANCHOR_INVALID,
					hash_string(exit.target_anchor_identifier)), child_path(exit_path, "target_anchor", exit.target_anchor_identifier));
		}
	}
}

void validate_conversation_references(
		const std::vector<ConversationDefinition> &p_conversations,
		const std::vector<SpeakerDefinition> &p_speakers,
		const std::vector<ProviderDeclaration> &p_providers,
		const ConversationDefinition &p_conversation,
		CatalogValidationReport &r_report) {
	const std::string conversation_path = resource_path("conversation", p_conversation.identifier);
	if (find_local_record(p_conversation.steps, p_conversation.entry_label) == nullptr) {
		append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_ENTRY_INVALID,
				hash_string(p_conversation.entry_label)), child_path(conversation_path, "entry", p_conversation.entry_label));
	}
	for (const std::string &speaker_identifier : p_conversation.speaker_identifiers) {
		if (find_definition(p_speakers, speaker_identifier) == nullptr) {
			append_missing_reference("conversation", p_conversation.identifier, "speaker", speaker_identifier, r_report,
					DiagnosticId::CONVERSATION_SPEAKER_INVALID);
		}
	}
	for (const ConversationStepDefinition &step : p_conversation.steps) {
		const std::string step_path = child_path(conversation_path, "step", step.identifier);
		if (!step.speaker_identifier.empty()) {
			if (find_definition(p_speakers, step.speaker_identifier) == nullptr) {
				append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_SPEAKER_INVALID,
						hash_string(step.speaker_identifier)), child_path(step_path, "speaker", step.speaker_identifier));
			} else if (!contains_global_identifier(p_conversation.speaker_identifiers, step.speaker_identifier)) {
				append_finding(r_report, make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::CONVERSATION_SPEAKER_INVALID,
						hash_string(step.speaker_identifier)), child_path(step_path, "speaker_not_declared", step.speaker_identifier));
			}
		}
		for (const FactPredicate &predicate : step.conditions) {
			validate_fact_predicate_provider(p_providers, step_path, predicate, r_report);
		}
		if (step.kind == ConversationStepKind::CONDITION && !step.provider_identifier.empty()) {
			validate_provider_reference(p_providers, step_path, "provider", step.provider_identifier,
					ProviderKind::CONDITION, r_report);
		}
		if (step.kind == ConversationStepKind::EXTERNAL_ACTION && !step.provider_identifier.empty()) {
			validate_provider_reference(p_providers, step_path, "provider", step.provider_identifier,
					ProviderKind::ACTION, r_report);
		}
		auto validate_step_target = [&](const char *p_field, const std::string &p_target) {
			if (!p_target.empty() && find_local_record(p_conversation.steps, p_target) == nullptr) {
				append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
						hash_string(p_target)), child_path(step_path, p_field, p_target));
			}
		};
		validate_step_target("next", step.next_step_identifier);
		validate_step_target("true", step.true_step_identifier);
		validate_step_target("false", step.false_step_identifier);
		validate_step_target("success", step.success_step_identifier);
		validate_step_target("failure", step.failure_step_identifier);
		validate_step_target("target", step.target_step_identifier);
		if (step.kind == ConversationStepKind::OUTCOME && !contains_local_identifier(p_conversation.terminal_outcomes, step.outcome_identifier)) {
			append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_OUTCOME_INVALID,
					hash_string(step.outcome_identifier)), child_path(step_path, "outcome", step.outcome_identifier));
		}
		for (const ConversationChoiceDefinition &choice : step.choices) {
			if (find_local_record(p_conversation.steps, choice.target_step_identifier) == nullptr) {
				append_finding(r_report, make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
								hash_string(choice.target_step_identifier)), child_path(step_path, std::string("choice.") + choice.identifier + ".target",
							choice.target_step_identifier));
			}
			for (const FactPredicate &predicate : choice.conditions) {
				validate_fact_predicate_provider(p_providers, child_path(step_path, "choice", choice.identifier), predicate, r_report);
			}
		}
	}
	(void)p_conversations; // kept in the signature for future conversation recursion checks
}

void validate_subgraph_cycles(
		const std::vector<TaskGraphDefinition> &p_graphs,
		CatalogValidationReport &r_report) {
	std::map<std::string, std::size_t> graph_indices;
	for (std::size_t index = 0; index < p_graphs.size(); ++index) graph_indices.emplace(p_graphs[index].identifier, index);
	std::vector<std::vector<std::size_t>> adjacency(p_graphs.size());
	for (std::size_t index = 0; index < p_graphs.size(); ++index) {
		for (const TaskNodeDefinition &node : p_graphs[index].nodes) {
			if (node.kind != TaskNodeKind::SUBGRAPH || node.subgraph_identifier.empty()) continue;
			const auto target = graph_indices.find(node.subgraph_identifier);
			if (target != graph_indices.end()) adjacency[index].push_back(target->second);
		}
	}
	enum class Visit : std::uint8_t { UNVISITED, VISITING, VISITED };
	std::vector<Visit> visits(p_graphs.size(), Visit::UNVISITED);
	std::function<void(std::size_t)> visit = [&](std::size_t p_index) {
		if (visits[p_index] == Visit::VISITED) return;
		if (visits[p_index] == Visit::VISITING) {
			append_finding(r_report, make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_index),
					child_path(resource_path("task", p_graphs[p_index].identifier), "subgraph_cycle"));
			return;
		}
		visits[p_index] = Visit::VISITING;
		for (const std::size_t next : adjacency[p_index]) visit(next);
		visits[p_index] = Visit::VISITED;
	};
	for (std::size_t index = 0; index < p_graphs.size(); ++index) visit(index);
}

void write_u8(std::vector<std::uint8_t> &r_bytes, std::uint8_t p_value) {
	r_bytes.push_back(p_value);
}

void write_u16(std::vector<std::uint8_t> &r_bytes, std::uint16_t p_value) {
	for (int shift = 0; shift < 16; shift += 8) write_u8(r_bytes, static_cast<std::uint8_t>((p_value >> shift) & 0xffU));
}

void write_u32(std::vector<std::uint8_t> &r_bytes, std::uint32_t p_value) {
	for (int shift = 0; shift < 32; shift += 8) write_u8(r_bytes, static_cast<std::uint8_t>((p_value >> shift) & 0xffU));
}

void write_u64(std::vector<std::uint8_t> &r_bytes, std::uint64_t p_value) {
	for (int shift = 0; shift < 64; shift += 8) write_u8(r_bytes, static_cast<std::uint8_t>((p_value >> shift) & 0xffULL));
}

void write_i64(std::vector<std::uint8_t> &r_bytes, std::int64_t p_value) {
	write_u64(r_bytes, static_cast<std::uint64_t>(p_value));
}

void write_bool(std::vector<std::uint8_t> &r_bytes, bool p_value) {
	write_u8(r_bytes, p_value ? 1U : 0U);
}

void write_string(std::vector<std::uint8_t> &r_bytes, const std::string &p_value) {
	write_u32(r_bytes, static_cast<std::uint32_t>(p_value.size()));
	r_bytes.insert(r_bytes.end(), p_value.begin(), p_value.end());
}

void write_catalog_limits(std::vector<std::uint8_t> &r_bytes) {
	// Keep this list in the same declaration order as lts_limits.h.  Every
	// runtime-affecting V1 limit is a compatibility input to the fingerprint.
	write_u64(r_bytes, MAX_IDENTIFIER_BYTES);
	write_u64(r_bytes, MAX_IDENTIFIER_SEGMENTS);
	write_u64(r_bytes, MAX_IDENTIFIER_SEGMENT_BYTES);
	write_u64(r_bytes, MAX_STRING_BYTES);
	write_u64(r_bytes, MAX_LOCALIZATION_KEY_BYTES);
	write_u64(r_bytes, MAX_SCENE_RESOURCE_BYTES);
	write_u64(r_bytes, MAX_DIAGNOSTIC_PATH_BYTES);
	write_u64(r_bytes, MAX_LEVEL_DEFINITIONS);
	write_u64(r_bytes, MAX_TASK_GRAPH_DEFINITIONS);
	write_u64(r_bytes, MAX_CONVERSATION_DEFINITIONS);
	write_u64(r_bytes, MAX_SPEAKER_DEFINITIONS);
	write_u64(r_bytes, MAX_PROVIDER_DECLARATIONS);
	write_u64(r_bytes, MAX_ENTRY_GRAPHS_PER_LEVEL);
	write_u64(r_bytes, MAX_AVAILABILITY_RULES);
	write_u64(r_bytes, MAX_ANCHORS_PER_LEVEL);
	write_u64(r_bytes, MAX_EXITS_PER_LEVEL);
	write_u64(r_bytes, MAX_NODES_PER_TASK_GRAPH);
	write_u64(r_bytes, MAX_EDGES_PER_TASK_GRAPH);
	write_u64(r_bytes, MAX_PORTS_PER_TASK_NODE);
	write_u64(r_bytes, MAX_TERMINAL_OUTCOMES);
	write_u64(r_bytes, MAX_NODE_PARAMETERS);
	write_u64(r_bytes, MAX_NODE_FILTERS);
	write_u64(r_bytes, MAX_STEPS_PER_CONVERSATION);
	write_u64(r_bytes, MAX_SPEAKERS_PER_CONVERSATION);
	write_u64(r_bytes, MAX_CHOICES_PER_CONVERSATION_STEP);
	write_u64(r_bytes, MAX_CHOICE_CONDITIONS);
	write_u64(r_bytes, MAX_LINE_PARAMETERS);
	write_u64(r_bytes, MAX_VALUE_BYTES);
	write_u64(r_bytes, MAX_PROVIDER_PAYLOAD_BYTES);
	write_u64(r_bytes, MAX_PARAMETERS_BYTES);
	write_u64(r_bytes, MAX_LOCALIZED_PARAMETERS);
	write_u64(r_bytes, MAX_EVENT_FILTERS);
	write_u64(r_bytes, MAX_OBJECTIVE_TARGET);
	write_u64(r_bytes, MAX_TRANSITIONS_PER_ADVANCE);
	write_u64(r_bytes, MAX_CONVERSATION_STEPS_PER_ADVANCE);
	write_u64(r_bytes, MAX_JUMPS_PER_ADVANCE);
	write_u64(r_bytes, MAX_SUBGRAPH_DEPTH);
	write_u64(r_bytes, MAX_PENDING_REQUESTS);
	write_u64(r_bytes, MAX_EVENTS_PER_ADVANCE);
	write_u64(r_bytes, MAX_TRACE_RECORDS);
	write_u64(r_bytes, MAX_STATE_CHANGE_RECORDS);
	write_u64(r_bytes, MAX_SNAPSHOT_BYTES);
	write_u64(r_bytes, MAX_ANCHOR_BINDING_LABEL_BYTES);
}

template <typename T>
void write_definition_collection(
		std::vector<std::uint8_t> &r_bytes,
		const char *p_kind,
		const std::vector<T> &p_definitions) {
	write_string(r_bytes, p_kind);
	write_u32(r_bytes, static_cast<std::uint32_t>(p_definitions.size()));
	for (const T &definition : p_definitions) {
		write_string(r_bytes, definition.identifier);
		write_u16(r_bytes, definition.schema_version);
		write_u64(r_bytes, definition.fingerprint());
	}
}

void write_catalog_header(std::vector<std::uint8_t> &r_bytes) {
	write_string(r_bytes, CATALOG_FINGERPRINT_ALGORITHM);
	write_u16(r_bytes, CANONICAL_FORMAT_VERSION);
	write_u16(r_bytes, RESOURCE_SCHEMA_VERSION);
	write_u16(r_bytes, LEVEL_DEFINITION_SCHEMA_VERSION);
	write_u16(r_bytes, TASK_GRAPH_DEFINITION_SCHEMA_VERSION);
	write_u16(r_bytes, CONVERSATION_DEFINITION_SCHEMA_VERSION);
	write_u16(r_bytes, SPEAKER_DEFINITION_SCHEMA_VERSION);
	write_u16(r_bytes, PROVIDER_DEFINITION_SCHEMA_VERSION);
	write_u16(r_bytes, PROTOCOL_VERSION);
	write_u16(r_bytes, SNAPSHOT_SCHEMA_VERSION);
	write_u16(r_bytes, API_VERSION_MAJOR);
	write_u16(r_bytes, API_VERSION_MINOR);
	write_u16(r_bytes, API_VERSION_PATCH);
	write_i64(r_bytes, FIXED_SCALE);
	write_bool(r_bytes, CORE_EXECUTES_AUTHORED_CODE);
	write_catalog_limits(r_bytes);
}

std::uint64_t fingerprint_bytes(const std::vector<std::uint8_t> &p_bytes) {
	Hasher hasher;
	for (const std::uint8_t byte : p_bytes) hasher.write_u8(byte);
	return hasher.digest();
}

void encode_catalog(
		const std::vector<LevelDefinition> &p_levels,
		const std::vector<TaskGraphDefinition> &p_graphs,
		const std::vector<ConversationDefinition> &p_conversations,
		const std::vector<SpeakerDefinition> &p_speakers,
		const std::vector<ProviderDeclaration> &p_providers,
		std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	write_catalog_header(r_bytes);
	// Fixed kind order is part of the V1 canonical contract.  Each collection
	// is already sorted by its global identifier at this point.
	write_definition_collection(r_bytes, "level", p_levels);
	write_definition_collection(r_bytes, "task_graph", p_graphs);
	write_definition_collection(r_bytes, "conversation", p_conversations);
	write_definition_collection(r_bytes, "speaker", p_speakers);
	write_definition_collection(r_bytes, "provider", p_providers);
}

template <typename T>
Status add_definition(
		std::vector<T> &r_definitions,
		std::vector<std::string> &r_sources,
		const T &p_definition,
		const std::string &p_source_path,
		std::size_t p_limit,
		const char *p_kind,
		DiagnosticId p_limit_diagnostic,
		bool &r_is_sealed,
		std::vector<CatalogDiagnostic> &r_last_diagnostics,
		std::uint32_t &r_last_diagnostic_count,
		bool &r_last_diagnostics_truncated,
		CatalogFingerprint &r_fingerprint) {
	r_last_diagnostics.clear();
	r_last_diagnostic_count = 0;
	r_last_diagnostics_truncated = false;
	if (r_is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::NONE);
	}
	r_fingerprint = INVALID_CATALOG_FINGERPRINT;
	Status status = source_path_status(p_source_path);
	if (!status.ok()) return status;
	if (r_definitions.size() >= p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, p_limit_diagnostic, r_definitions.size() + 1);
	}
	T copy = p_definition;
	status = validate_and_canonicalize(copy);
	if (!status.ok()) return status;
	for (std::size_t index = 0; index < r_definitions.size(); ++index) {
		if (r_definitions[index].identifier == copy.identifier) {
			const Status duplicate = duplicate_status(copy.identifier);
			r_last_diagnostics.push_back(CatalogDiagnostic{
					duplicate,
					resource_path(p_kind, copy.identifier),
					occurrence_path(p_kind, copy.identifier, index, r_sources) });
			r_last_diagnostic_count = 1;
			return duplicate;
		}
	}
	r_definitions.push_back(std::move(copy));
	r_sources.push_back(p_source_path);
	return ok_status();
}

template <typename T>
Status resolve_definition(
		const std::vector<T> &p_definitions,
		bool p_sealed,
		const std::string &p_identifier,
		const T *&r_definition) {
	r_definition = nullptr;
	if (!p_sealed) return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::NONE);
	const Status id_status = validate_identifier(p_identifier);
	if (!id_status.ok()) return id_status;
	r_definition = find_definition(p_definitions, p_identifier);
	if (r_definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_identifier));
	}
	return ok_status();
}

} // namespace

void LevelTaskCatalog::clear_last_diagnostics() {
	last_diagnostics.clear();
	last_diagnostic_count = 0;
	last_diagnostics_truncated = false;
}

void LevelTaskCatalog::remember_status(const Status &p_status, const std::string &p_path) {
	clear_last_diagnostics();
	if (!p_status.ok()) {
		last_diagnostics.push_back(CatalogDiagnostic{ p_status, bounded_path(p_path), std::string() });
		last_diagnostic_count = 1;
	}
}

Status LevelTaskCatalog::add_level(const LevelDefinition &p_definition, const std::string &p_source_path) {
	return add_definition(
			level_definitions, level_source_paths, p_definition, p_source_path, MAX_LEVEL_DEFINITIONS, "level",
			DiagnosticId::COUNT_LIMIT_EXCEEDED, is_sealed, last_diagnostics, last_diagnostic_count,
			last_diagnostics_truncated, catalog_fingerprint);
}

Status LevelTaskCatalog::add_task_graph(const TaskGraphDefinition &p_definition, const std::string &p_source_path) {
	return add_definition(
			task_graph_definitions, task_graph_source_paths, p_definition, p_source_path, MAX_TASK_GRAPH_DEFINITIONS, "task_graph",
			DiagnosticId::GRAPH_NODE_LIMIT, is_sealed, last_diagnostics, last_diagnostic_count,
			last_diagnostics_truncated, catalog_fingerprint);
}

Status LevelTaskCatalog::add_conversation(const ConversationDefinition &p_definition, const std::string &p_source_path) {
	return add_definition(
			conversation_definitions, conversation_source_paths, p_definition, p_source_path, MAX_CONVERSATION_DEFINITIONS, "conversation",
			DiagnosticId::CONVERSATION_STEP_LIMIT, is_sealed, last_diagnostics, last_diagnostic_count,
			last_diagnostics_truncated, catalog_fingerprint);
}

Status LevelTaskCatalog::add_speaker(const SpeakerDefinition &p_definition, const std::string &p_source_path) {
	return add_definition(
			speaker_definitions, speaker_source_paths, p_definition, p_source_path, MAX_SPEAKER_DEFINITIONS, "speaker",
			DiagnosticId::COUNT_LIMIT_EXCEEDED, is_sealed, last_diagnostics, last_diagnostic_count,
			last_diagnostics_truncated, catalog_fingerprint);
}

Status LevelTaskCatalog::add_provider(const ProviderDeclaration &p_definition, const std::string &p_source_path) {
	return add_definition(
			provider_definitions, provider_source_paths, p_definition, p_source_path, MAX_PROVIDER_DECLARATIONS, "provider",
			DiagnosticId::COUNT_LIMIT_EXCEEDED, is_sealed, last_diagnostics, last_diagnostic_count,
			last_diagnostics_truncated, catalog_fingerprint);
}

Status LevelTaskCatalog::validate_and_canonicalize_in_place(CatalogValidationReport &r_report) {
	reset_report(r_report);

	append_count_limit(level_definitions, MAX_LEVEL_DEFINITIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED, "levels", r_report);
	append_count_limit(task_graph_definitions, MAX_TASK_GRAPH_DEFINITIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED, "task_graphs", r_report);
	append_count_limit(conversation_definitions, MAX_CONVERSATION_DEFINITIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED, "conversations", r_report);
	append_count_limit(speaker_definitions, MAX_SPEAKER_DEFINITIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED, "speakers", r_report);
	append_count_limit(provider_definitions, MAX_PROVIDER_DECLARATIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED, "providers", r_report);

	// Definitions are sorted only after local canonicalization.  The parallel
	// source vectors are diagnostics-only and do not affect this ordering.
	append_local_validation(level_definitions, "level", r_report);
	append_local_validation(task_graph_definitions, "task_graph", r_report);
	append_local_validation(conversation_definitions, "conversation", r_report);
	append_local_validation(speaker_definitions, "speaker", r_report);
	append_local_validation(provider_definitions, "provider", r_report);
	sort_definitions_with_sources(level_definitions, level_source_paths);
	sort_definitions_with_sources(task_graph_definitions, task_graph_source_paths);
	sort_definitions_with_sources(conversation_definitions, conversation_source_paths);
	sort_definitions_with_sources(speaker_definitions, speaker_source_paths);
	sort_definitions_with_sources(provider_definitions, provider_source_paths);

	append_duplicate_findings(level_definitions, level_source_paths, "level", r_report);
	append_duplicate_findings(task_graph_definitions, task_graph_source_paths, "task_graph", r_report);
	append_duplicate_findings(conversation_definitions, conversation_source_paths, "conversation", r_report);
	append_duplicate_findings(speaker_definitions, speaker_source_paths, "speaker", r_report);
	append_duplicate_findings(provider_definitions, provider_source_paths, "provider", r_report);

	// Cross-resource checks intentionally run even when one local definition is
	// malformed.  This gives editor callers a useful bounded set of findings in
	// one pass; all lookups remain bounded by the hard collection limits.
	for (const LevelDefinition &level : level_definitions) {
		validate_level_references(level_definitions, task_graph_definitions, provider_definitions, level, r_report);
	}
	for (const TaskGraphDefinition &graph : task_graph_definitions) {
		validate_task_graph_references(task_graph_definitions, conversation_definitions, provider_definitions, graph, r_report);
	}
	validate_subgraph_cycles(task_graph_definitions, r_report);
	for (const ConversationDefinition &conversation : conversation_definitions) {
		validate_conversation_references(conversation_definitions, speaker_definitions, provider_definitions, conversation, r_report);
	}

	finish_report(r_report);
	return r_report.status;
}

Status LevelTaskCatalog::validate() const {
	CatalogValidationReport report;
	return validate(report);
}

Status LevelTaskCatalog::validate(CatalogValidationReport &r_report) const {
	LevelTaskCatalog candidate = *this;
	const Status status = candidate.validate_and_canonicalize_in_place(r_report);
	return status;
}

Status LevelTaskCatalog::seal() {
	clear_last_diagnostics();
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::NONE);
	}

	LevelTaskCatalog candidate = *this;
	CatalogValidationReport report;
	const Status status = candidate.validate_and_canonicalize_in_place(report);
	if (!status.ok()) {
		last_diagnostics = report.findings;
		last_diagnostic_count = report.total_finding_count;
		last_diagnostics_truncated = report.truncated;
		return status;
	}

	std::vector<std::uint8_t> canonical_bytes;
	encode_catalog(
			candidate.level_definitions,
			candidate.task_graph_definitions,
			candidate.conversation_definitions,
			candidate.speaker_definitions,
			candidate.provider_definitions,
			canonical_bytes);
	const CatalogFingerprint computed_fingerprint = fingerprint_bytes(canonical_bytes);
	if (computed_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		const Status fingerprint_status = make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::VALUE_NOT_REPRESENTABLE);
		last_diagnostics.push_back(CatalogDiagnostic{ fingerprint_status, "catalog.fingerprint", std::string() });
		last_diagnostic_count = 1;
		return fingerprint_status;
	}
	candidate.catalog_fingerprint = computed_fingerprint;
	candidate.is_sealed = true;
	candidate.clear_last_diagnostics();
	*this = std::move(candidate);
	return ok_status();
}

const LevelDefinition *LevelTaskCatalog::find_level(const std::string &p_identifier) const {
	return is_sealed ? find_definition(level_definitions, p_identifier) : nullptr;
}

const TaskGraphDefinition *LevelTaskCatalog::find_task_graph(const std::string &p_identifier) const {
	return is_sealed ? find_definition(task_graph_definitions, p_identifier) : nullptr;
}

const ConversationDefinition *LevelTaskCatalog::find_conversation(const std::string &p_identifier) const {
	return is_sealed ? find_definition(conversation_definitions, p_identifier) : nullptr;
}

const SpeakerDefinition *LevelTaskCatalog::find_speaker(const std::string &p_identifier) const {
	return is_sealed ? find_definition(speaker_definitions, p_identifier) : nullptr;
}

const ProviderDeclaration *LevelTaskCatalog::find_provider(const std::string &p_identifier) const {
	return is_sealed ? find_definition(provider_definitions, p_identifier) : nullptr;
}

Status LevelTaskCatalog::resolve_level(const std::string &p_identifier, const LevelDefinition *&r_definition) const {
	return resolve_definition(level_definitions, is_sealed, p_identifier, r_definition);
}

Status LevelTaskCatalog::resolve_task_graph(const std::string &p_identifier, const TaskGraphDefinition *&r_definition) const {
	return resolve_definition(task_graph_definitions, is_sealed, p_identifier, r_definition);
}

Status LevelTaskCatalog::resolve_conversation(const std::string &p_identifier, const ConversationDefinition *&r_definition) const {
	return resolve_definition(conversation_definitions, is_sealed, p_identifier, r_definition);
}

Status LevelTaskCatalog::resolve_speaker(const std::string &p_identifier, const SpeakerDefinition *&r_definition) const {
	return resolve_definition(speaker_definitions, is_sealed, p_identifier, r_definition);
}

Status LevelTaskCatalog::resolve_provider(const std::string &p_identifier, const ProviderDeclaration *&r_definition) const {
	return resolve_definition(provider_definitions, is_sealed, p_identifier, r_definition);
}

Status LevelTaskCatalog::encode_canonical(std::vector<std::uint8_t> &r_bytes) const {
	r_bytes.clear();
	if (!is_sealed) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::NONE);
	}
	::lts::encode_catalog(
			level_definitions,
			task_graph_definitions,
			conversation_definitions,
			speaker_definitions,
			provider_definitions,
			r_bytes);
	return ok_status();
}

} // namespace lts
