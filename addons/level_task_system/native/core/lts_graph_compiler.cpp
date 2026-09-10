#include "core/lts_graph_compiler.h"

#include "core/lts_hash.h"
#include "core/lts_identifier.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <map>
#include <set>
#include <tuple>
#include <utility>

namespace lts {

namespace {

TaskNodePortDescriptor make_port(
		const char *p_identifier,
		TaskPortDirection p_direction,
		bool p_required,
		std::size_t p_min_connections,
		std::size_t p_max_connections,
		std::initializer_list<const char *> p_aliases = {}) {
	TaskNodePortDescriptor port;
	port.identifier = p_identifier;
	port.direction = p_direction;
	port.value_type = ValueType::NONE;
	port.required = p_required;
	port.min_connections = p_min_connections;
	port.max_connections = p_max_connections;
	for (const char *alias : p_aliases) port.aliases.emplace_back(alias);
	return port;
}

TaskNodeTypeDescriptor make_descriptor(TaskNodeKind p_kind, const char *p_identifier, bool p_terminal = false) {
	TaskNodeTypeDescriptor descriptor;
	descriptor.kind = p_kind;
	descriptor.identifier = p_identifier;
	descriptor.terminal = p_terminal;
	return descriptor;
}

void add_input(TaskNodeTypeDescriptor &r_descriptor, bool p_dynamic = false) {
	TaskNodePortDescriptor port = make_port("input", TaskPortDirection::INPUT, !p_dynamic, p_dynamic ? 0 : 1,
			p_dynamic ? 1 : 1, { "in" });
	port.dynamic = p_dynamic;
	r_descriptor.ports.push_back(port);
}

void add_output(
		TaskNodeTypeDescriptor &r_descriptor,
		const char *p_identifier,
		bool p_required = false,
		std::initializer_list<const char *> p_aliases = {}) {
	r_descriptor.ports.push_back(make_port(p_identifier, TaskPortDirection::OUTPUT, p_required, p_required ? 1 : 0,
			TASK_PORT_UNBOUNDED, p_aliases));
}

std::string bounded_path(const std::string &p_path) {
	if (p_path.size() <= MAX_DIAGNOSTIC_PATH_BYTES) return p_path;
	// Keep the beginning (resource/node) and the end (field/port) so a
	// diagnostic remains useful while retaining the fixed path bound.
	const std::size_t suffix_size = MAX_DIAGNOSTIC_PATH_BYTES / 3;
	const std::size_t prefix_size = MAX_DIAGNOSTIC_PATH_BYTES - suffix_size - 3;
	return p_path.substr(0, prefix_size) + "..." + p_path.substr(p_path.size() - suffix_size);
}

std::string graph_path(const TaskGraphDefinition &p_graph) {
	return bounded_path("task." + p_graph.identifier);
}

std::string node_path(const TaskGraphDefinition &p_graph, const std::string &p_node_identifier) {
	return bounded_path(graph_path(p_graph) + ".node." + p_node_identifier);
}

std::string edge_path(const TaskGraphDefinition &p_graph, const std::string &p_edge_identifier) {
	return bounded_path(graph_path(p_graph) + ".edge." + p_edge_identifier);
}

std::string port_path(
		const TaskGraphDefinition &p_graph,
		const TaskEdgeDefinition &p_edge,
		const char *p_side,
		const std::string &p_port_identifier) {
	return bounded_path(edge_path(p_graph, p_edge.identifier) + "." + p_side + ".port." + p_port_identifier);
}

Status report_error(
		Status p_status,
		DiagnosticId p_default_diagnostic,
		const std::string &p_path,
		std::vector<Diagnostic> *r_diagnostics) {
	if (r_diagnostics != nullptr) {
		Diagnostic finding;
		finding.id = p_status.diagnostic == DiagnosticId::NONE ? p_default_diagnostic : p_status.diagnostic;
		finding.detail = p_status.detail;
		finding.path = bounded_path(p_path);
		r_diagnostics->push_back(finding);
	}
	return p_status;
}

Status compiler_error(
		StatusCode p_code,
		DiagnosticId p_diagnostic,
		std::uint64_t p_detail,
		const std::string &p_path,
		std::vector<Diagnostic> *r_diagnostics) {
	return report_error(make_status(p_code, p_diagnostic, p_detail), p_diagnostic, p_path, r_diagnostics);
}

const TaskNodePortDescriptor *find_descriptor_port(
		const TaskNodeTypeDescriptor &p_descriptor,
		const std::string &p_identifier) {
	return p_descriptor.find_port(p_identifier);
}

bool has_port_identifier(const std::vector<TaskPortDefinition> &p_ports, const std::string &p_identifier) {
	for (const TaskPortDefinition &port : p_ports) {
		if (port.identifier == p_identifier) return true;
	}
	return false;
}

std::size_t port_index(const std::map<std::string, std::size_t> &p_indices, const std::string &p_identifier) {
	const auto found = p_indices.find(p_identifier);
	return found == p_indices.end() ? std::numeric_limits<std::size_t>::max() : found->second;
}

struct WorkingPort {
	TaskPortDefinition definition;
	std::size_t min_connections = 0;
	std::size_t max_connections = 1;
	bool dynamic = false;
};

struct WorkingNode {
	TaskNodeDefinition definition;
	const TaskNodeTypeDescriptor *descriptor = nullptr;
	std::vector<WorkingPort> ports;
	std::map<std::string, std::size_t> port_indices;
};

const TaskNodePortDescriptor *descriptor_port_for_canonical(
		const TaskNodeTypeDescriptor &p_descriptor,
		const TaskPortDefinition &p_port) {
	const TaskNodePortDescriptor *descriptor_port = find_descriptor_port(p_descriptor, p_port.identifier);
	return descriptor_port;
}

Status append_working_port(
		WorkingNode &r_node,
		const TaskPortDefinition &p_port,
		const TaskNodePortDescriptor *p_descriptor_port,
		const TaskGraphCompileLimits &p_limits,
		std::vector<Diagnostic> *r_diagnostics,
		const std::string &p_path) {
	TaskPortDefinition port = p_port;
	Status status = port.validate();
	if (!status.ok()) {
		return report_error(status, DiagnosticId::GRAPH_PORT_INVALID, p_path, r_diagnostics);
	}
	if (p_descriptor_port != nullptr) {
		// Built-in control ports use NONE as their default (a control edge does
		// not carry a runtime payload), but an authored resource may choose one
		// of the closed V1 value types for a named port.  The registry still fixes
		// its direction/name/cardinality; edge compatibility checks effective
		// authored types below.  A descriptor with a non-NONE type remains strict.
		if (port.direction != p_descriptor_port->direction ||
				(p_descriptor_port->value_type != ValueType::NONE && port.value_type != p_descriptor_port->value_type)) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID,
					static_cast<std::uint8_t>(port.value_type), p_path, r_diagnostics);
		}
		port.identifier = p_descriptor_port->identifier;
	}
	if (r_node.port_indices.find(port.identifier) != r_node.port_indices.end()) {
		return compiler_error(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID,
				r_node.port_indices.size(), p_path, r_diagnostics);
	}

	WorkingPort working;
	working.definition = port;
	working.dynamic = p_descriptor_port == nullptr || p_descriptor_port->dynamic;
	working.min_connections = p_descriptor_port == nullptr ? (port.required ? 1 : 0) : p_descriptor_port->min_connections;
	working.max_connections = p_descriptor_port == nullptr ?
			(port.direction == TaskPortDirection::OUTPUT ? p_limits.max_fan_out : 1) : p_descriptor_port->max_connections;
	if (port.required) working.min_connections = std::max<std::size_t>(working.min_connections, 1);
	if (working.max_connections == 0 || working.min_connections > working.max_connections) {
		return compiler_error(StatusCode::OUT_OF_BOUNDS, DiagnosticId::BOUNDS_INVERTED,
				working.max_connections, p_path, r_diagnostics);
	}
	if (working.max_connections > (port.direction == TaskPortDirection::OUTPUT ? p_limits.max_fan_out : TASK_PORT_UNBOUNDED)) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT,
				working.max_connections, p_path, r_diagnostics);
	}
	r_node.port_indices[port.identifier] = r_node.ports.size();
	r_node.ports.push_back(working);
	return ok_status();
}

Status build_working_nodes(
		const TaskGraphDefinition &p_graph,
		const TaskNodeRegistry &p_registry,
		const TaskGraphCompileLimits &p_limits,
		std::vector<WorkingNode> &r_nodes,
		std::map<std::string, std::size_t> &r_node_indices,
		std::vector<Diagnostic> *r_diagnostics) {
	r_nodes.clear();
	r_node_indices.clear();
	r_nodes.reserve(p_graph.nodes.size());

	for (std::size_t node_index = 0; node_index < p_graph.nodes.size(); ++node_index) {
		const TaskNodeDefinition &node = p_graph.nodes[node_index];
		if (r_node_indices.find(node.identifier) != r_node_indices.end()) {
			return compiler_error(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_NODE_DUPLICATE,
					node_index, node_path(p_graph, node.identifier), r_diagnostics);
		}
		const TaskNodeTypeDescriptor *descriptor = p_registry.find(node.kind);
		if (descriptor == nullptr) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
				static_cast<std::uint8_t>(node.kind), node_path(p_graph, node.identifier), r_diagnostics);
		}

		WorkingNode working;
		working.definition = node;
		working.descriptor = descriptor;
		std::vector<TaskPortDefinition> effective_ports;
		Status status = p_registry.resolve_ports(node, effective_ports);
		if (!status.ok()) {
			return report_error(status, DiagnosticId::GRAPH_PORT_INVALID, node_path(p_graph, node.identifier), r_diagnostics);
		}
		if (effective_ports.size() > p_limits.max_ports_per_node) {
			return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT,
					effective_ports.size(), node_path(p_graph, node.identifier), r_diagnostics);
		}
		for (const TaskPortDefinition &port : effective_ports) {
			const TaskNodePortDescriptor *descriptor_port = descriptor_port_for_canonical(*descriptor, port);
			status = append_working_port(working, port, descriptor_port, p_limits, r_diagnostics,
					node_path(p_graph, node.identifier) + ".port." + port.identifier);
			if (!status.ok()) return status;
		}
		working.definition.ports.clear();
		for (const WorkingPort &port : working.ports) working.definition.ports.push_back(port.definition);
		std::sort(working.definition.ports.begin(), working.definition.ports.end());
		// Keep the working vector in the same canonical order as the definition.
		std::sort(working.ports.begin(), working.ports.end(), [](const WorkingPort &p_a, const WorkingPort &p_b) {
			return p_a.definition.identifier < p_b.definition.identifier;
		});
		working.port_indices.clear();
		for (std::size_t index = 0; index < working.ports.size(); ++index) {
			working.port_indices[working.ports[index].definition.identifier] = index;
		}
		r_node_indices[node.identifier] = r_nodes.size();
		r_nodes.push_back(std::move(working));
	}

	return ok_status();
}

Status add_dynamic_edge_ports(
		const TaskGraphDefinition &p_graph,
		std::vector<WorkingNode> &r_nodes,
		const std::map<std::string, std::size_t> &p_node_indices,
		const TaskGraphCompileLimits &p_limits,
		std::vector<Diagnostic> *r_diagnostics) {
	for (const TaskEdgeDefinition &edge : p_graph.edges) {
		const auto from_found = p_node_indices.find(edge.from_node_identifier);
		const auto to_found = p_node_indices.find(edge.to_node_identifier);
		if (from_found == p_node_indices.end() || to_found == p_node_indices.end()) continue;
		WorkingNode &from_node = r_nodes[from_found->second];
		WorkingNode &to_node = r_nodes[to_found->second];

		if (port_index(from_node.port_indices, edge.from_port_identifier) == std::numeric_limits<std::size_t>::max()) {
			const TaskNodePortDescriptor *known = from_node.descriptor->find_port(edge.from_port_identifier);
			if (known != nullptr) {
				// An alias should have been canonicalized by resolve_ports.  This
				// branch is only possible for a malformed descriptor/adapter.
				continue;
			}
			if (!from_node.descriptor->dynamic_outputs) continue;
			TaskPortDefinition port;
			port.identifier = edge.from_port_identifier;
			port.direction = TaskPortDirection::OUTPUT;
			port.value_type = ValueType::NONE;
			Status status = append_working_port(from_node, port, nullptr, p_limits, r_diagnostics,
					node_path(p_graph, from_node.definition.identifier) + ".port." + edge.from_port_identifier);
			if (!status.ok()) return status;
		}

		if (port_index(to_node.port_indices, edge.to_port_identifier) == std::numeric_limits<std::size_t>::max()) {
			const TaskNodePortDescriptor *known = to_node.descriptor->find_port(edge.to_port_identifier);
			if (known != nullptr) continue;
			if (!to_node.descriptor->dynamic_inputs) continue;
			TaskPortDefinition port;
			port.identifier = edge.to_port_identifier;
			port.direction = TaskPortDirection::INPUT;
			port.value_type = ValueType::NONE;
			Status status = append_working_port(to_node, port, nullptr, p_limits, r_diagnostics,
					node_path(p_graph, to_node.definition.identifier) + ".port." + edge.to_port_identifier);
			if (!status.ok()) return status;
		}
	}

	for (WorkingNode &node : r_nodes) {
		if (node.ports.size() > p_limits.max_ports_per_node) {
			return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT,
					node.ports.size(), node_path(p_graph, node.definition.identifier), r_diagnostics);
		}
		std::sort(node.ports.begin(), node.ports.end(), [](const WorkingPort &p_a, const WorkingPort &p_b) {
			return p_a.definition.identifier < p_b.definition.identifier;
		});
		node.port_indices.clear();
		node.definition.ports.clear();
		for (std::size_t index = 0; index < node.ports.size(); ++index) {
			node.port_indices[node.ports[index].definition.identifier] = index;
			node.definition.ports.push_back(node.ports[index].definition);
		}
	}
	return ok_status();
}

ProviderKind provider_kind_for_node(TaskNodeKind p_kind) {
	switch (p_kind) {
		case TaskNodeKind::OBJECTIVE:
			return ProviderKind::EVENT;
		case TaskNodeKind::CONDITION:
			return ProviderKind::CONDITION;
		case TaskNodeKind::EXTERNAL_ACTION:
			return ProviderKind::ACTION;
		case TaskNodeKind::REWARD_REQUEST:
			return ProviderKind::REWARD;
		default:
			return ProviderKind::FACT;
	}
}

bool is_terminal_kind(TaskNodeKind p_kind) {
	return p_kind == TaskNodeKind::SUCCESS_TERMINAL || p_kind == TaskNodeKind::FAILURE_TERMINAL ||
			p_kind == TaskNodeKind::CANCELLED_TERMINAL;
}

std::uint32_t saturating_work_units(std::size_t p_nodes, std::size_t p_edges, std::uint32_t p_transitions) {
	const std::uint64_t total = static_cast<std::uint64_t>(p_nodes) + static_cast<std::uint64_t>(p_edges) +
			static_cast<std::uint64_t>(p_transitions);
	return total > std::numeric_limits<std::uint32_t>::max() ? std::numeric_limits<std::uint32_t>::max() :
			static_cast<std::uint32_t>(total);
}

} // namespace

// ---------------------------------------------------------------------------
// Typed node and port registry
// ---------------------------------------------------------------------------

Status TaskNodePortDescriptor::validate() const {
	TaskPortDefinition port;
	port.identifier = identifier;
	port.direction = direction;
	port.value_type = value_type;
	Status status = port.validate();
	if (!status.ok()) return status;
	if (min_connections > max_connections || max_connections == 0 || max_connections > TASK_PORT_UNBOUNDED ||
			(required && min_connections == 0)) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::BOUNDS_INVERTED, max_connections);
	}
	if (aliases.size() > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, aliases.size());
	}
	for (const std::string &alias : aliases) {
		status = validate_local_identifier(alias);
		if (!status.ok()) return status;
		if (alias == identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID);
		}
	}
	for (std::size_t index = 0; index < aliases.size(); ++index) {
		for (std::size_t other = index + 1; other < aliases.size(); ++other) {
			if (aliases[index] == aliases[other]) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID, other);
			}
		}
	}
	return ok_status();
}

bool TaskNodePortDescriptor::accepts_identifier(const std::string &p_identifier) const {
	if (identifier == p_identifier) return true;
	return std::find(aliases.begin(), aliases.end(), p_identifier) != aliases.end();
}

bool TaskNodePortDescriptor::operator==(const TaskNodePortDescriptor &p_other) const {
	return identifier == p_other.identifier && direction == p_other.direction && value_type == p_other.value_type &&
			required == p_other.required && min_connections == p_other.min_connections &&
			max_connections == p_other.max_connections && dynamic == p_other.dynamic && aliases == p_other.aliases;
}

bool TaskNodePortDescriptor::operator<(const TaskNodePortDescriptor &p_other) const {
	return std::tie(identifier, direction, value_type, required, min_connections, max_connections, dynamic, aliases) <
			std::tie(p_other.identifier, p_other.direction, p_other.value_type, p_other.required,
					p_other.min_connections, p_other.max_connections, p_other.dynamic, p_other.aliases);
}

Status TaskNodeTypeDescriptor::validate() const {
	if (!is_known_task_node_kind(kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(kind));
	}
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	if (ports.size() > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, ports.size());
	}
	std::set<std::string> names;
	for (const TaskNodePortDescriptor &port : ports) {
		status = port.validate();
		if (!status.ok()) return status;
		if (!names.insert(port.identifier).second) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID);
		}
		for (const std::string &alias : port.aliases) {
			if (!names.insert(alias).second) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID);
			}
		}
	}
	if (terminal && (dynamic_inputs || dynamic_outputs)) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID);
	}
	return ok_status();
}

const TaskNodePortDescriptor *TaskNodeTypeDescriptor::find_port(const std::string &p_identifier) const {
	for (const TaskNodePortDescriptor &port : ports) {
		if (port.accepts_identifier(p_identifier)) return &port;
	}
	return nullptr;
}

bool TaskNodeTypeDescriptor::operator==(const TaskNodeTypeDescriptor &p_other) const {
	return kind == p_other.kind && identifier == p_other.identifier && ports == p_other.ports &&
			dynamic_inputs == p_other.dynamic_inputs && dynamic_outputs == p_other.dynamic_outputs && terminal == p_other.terminal;
}

TaskNodeRegistry::TaskNodeRegistry() {
	add_builtin_descriptors();
}

TaskNodeRegistry TaskNodeRegistry::make_default() {
	return TaskNodeRegistry();
}

const TaskNodeRegistry &TaskNodeRegistry::default_registry() {
	static const TaskNodeRegistry registry = []() {
		TaskNodeRegistry result;
		result.seal();
		return result;
	}();
	return registry;
}

void TaskNodeRegistry::add_builtin_descriptors() {
	TaskNodeTypeDescriptor entry = make_descriptor(TaskNodeKind::ENTRY, "entry");
	entry.ports.push_back(make_port("entry", TaskPortDirection::OUTPUT, true, 1, TASK_PORT_UNBOUNDED, { "next" }));
	descriptors_.push_back(entry);

	TaskNodeTypeDescriptor objective = make_descriptor(TaskNodeKind::OBJECTIVE, "objective");
	add_input(objective);
	add_output(objective, "success");
	add_output(objective, "next");
	add_output(objective, "failure");
	add_output(objective, "timeout");
	add_output(objective, "cancelled");
	descriptors_.push_back(objective);

	TaskNodeTypeDescriptor condition = make_descriptor(TaskNodeKind::CONDITION, "condition");
	add_input(condition);
	add_output(condition, "true");
	add_output(condition, "false");
	descriptors_.push_back(condition);

	TaskNodeTypeDescriptor all_gate = make_descriptor(TaskNodeKind::ALL_GATE, "all_gate");
	all_gate.dynamic_inputs = true;
	add_output(all_gate, "all", false, { "success" });
	descriptors_.push_back(all_gate);

	TaskNodeTypeDescriptor any_gate = make_descriptor(TaskNodeKind::ANY_GATE, "any_gate");
	any_gate.dynamic_inputs = true;
	add_output(any_gate, "any", false, { "success" });
	descriptors_.push_back(any_gate);

	TaskNodeTypeDescriptor external_action = make_descriptor(TaskNodeKind::EXTERNAL_ACTION, "external_action");
	add_input(external_action);
	add_output(external_action, "accepted");
	add_output(external_action, "rejected");
	add_output(external_action, "success");
	add_output(external_action, "failure");
	add_output(external_action, "timeout");
	add_output(external_action, "cancelled");
	descriptors_.push_back(external_action);

	TaskNodeTypeDescriptor conversation = make_descriptor(TaskNodeKind::CONVERSATION, "conversation");
	add_input(conversation);
	conversation.dynamic_outputs = true;
	descriptors_.push_back(conversation);

	TaskNodeTypeDescriptor subgraph = make_descriptor(TaskNodeKind::SUBGRAPH, "subgraph");
	add_input(subgraph);
	subgraph.dynamic_outputs = true;
	descriptors_.push_back(subgraph);

	TaskNodeTypeDescriptor reward = make_descriptor(TaskNodeKind::REWARD_REQUEST, "reward_request");
	add_input(reward);
	add_output(reward, "accepted");
	add_output(reward, "rejected");
	add_output(reward, "success");
	add_output(reward, "failure");
	add_output(reward, "timeout");
	add_output(reward, "cancelled");
	descriptors_.push_back(reward);

	TaskNodeTypeDescriptor success = make_descriptor(TaskNodeKind::SUCCESS_TERMINAL, "success_terminal", true);
	add_input(success);
	descriptors_.push_back(success);
	TaskNodeTypeDescriptor failure = make_descriptor(TaskNodeKind::FAILURE_TERMINAL, "failure_terminal", true);
	add_input(failure);
	descriptors_.push_back(failure);
	TaskNodeTypeDescriptor cancelled = make_descriptor(TaskNodeKind::CANCELLED_TERMINAL, "cancelled_terminal", true);
	add_input(cancelled);
	descriptors_.push_back(cancelled);
}

Status TaskNodeRegistry::register_node_type(const TaskNodeTypeDescriptor &p_descriptor) {
	if (sealed_) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	Status status = p_descriptor.validate();
	if (!status.ok()) return status;
	if (find(p_descriptor.kind) != nullptr) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::DEFINITION_DUPLICATE,
				static_cast<std::uint8_t>(p_descriptor.kind));
	}
	descriptors_.push_back(p_descriptor);
	std::sort(descriptors_.begin(), descriptors_.end(), [](const TaskNodeTypeDescriptor &p_a, const TaskNodeTypeDescriptor &p_b) {
		return static_cast<std::uint8_t>(p_a.kind) < static_cast<std::uint8_t>(p_b.kind);
	});
	return ok_status();
}

Status TaskNodeRegistry::seal() {
	for (const TaskNodeTypeDescriptor &descriptor : descriptors_) {
		Status status = descriptor.validate();
		if (!status.ok()) return status;
	}
	std::sort(descriptors_.begin(), descriptors_.end(), [](const TaskNodeTypeDescriptor &p_a, const TaskNodeTypeDescriptor &p_b) {
		return static_cast<std::uint8_t>(p_a.kind) < static_cast<std::uint8_t>(p_b.kind);
	});
	sealed_ = true;
	return ok_status();
}

const TaskNodeTypeDescriptor *TaskNodeRegistry::find(TaskNodeKind p_kind) const {
	for (const TaskNodeTypeDescriptor &descriptor : descriptors_) {
		if (descriptor.kind == p_kind) return &descriptor;
	}
	return nullptr;
}

std::vector<TaskNodeKind> TaskNodeRegistry::kinds() const {
	std::vector<TaskNodeKind> result;
	result.reserve(descriptors_.size());
	for (const TaskNodeTypeDescriptor &descriptor : descriptors_) result.push_back(descriptor.kind);
	std::sort(result.begin(), result.end(), [](TaskNodeKind p_a, TaskNodeKind p_b) {
		return static_cast<std::uint8_t>(p_a) < static_cast<std::uint8_t>(p_b);
	});
	return result;
}

Status TaskNodeRegistry::resolve_ports(const TaskNodeDefinition &p_node, std::vector<TaskPortDefinition> &r_ports) const {
	r_ports.clear();
	const TaskNodeTypeDescriptor *descriptor = find(p_node.kind);
	if (descriptor == nullptr) {
		return make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
				static_cast<std::uint8_t>(p_node.kind));
	}
	Status status = descriptor->validate();
	if (!status.ok()) return status;
	status = p_node.validate();
	if (!status.ok()) return status;

	std::map<std::string, TaskPortDefinition> resolved;
	for (const TaskPortDefinition &authored_port : p_node.ports) {
		const TaskNodePortDescriptor *known = descriptor->find_port(authored_port.identifier);
		if (known == nullptr &&
				((authored_port.direction == TaskPortDirection::INPUT && !descriptor->dynamic_inputs) ||
						(authored_port.direction == TaskPortDirection::OUTPUT && !descriptor->dynamic_outputs))) {
			return make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID);
		}
		TaskPortDefinition port = authored_port;
		if (known != nullptr) {
			if (port.direction != known->direction ||
					(known->value_type != ValueType::NONE && port.value_type != known->value_type)) {
				return make_status(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID);
			}
			port.identifier = known->identifier;
			port.required = port.required || known->required;
		}
		if (resolved.find(port.identifier) != resolved.end()) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID);
		}
		resolved[port.identifier] = port;
	}

	// Static ports are part of the registry contract even when the author did
	// not repeat them in a Resource.  This lets compact definitions use the
	// initial V1 vocabulary while still allowing explicit type checks.
	for (const TaskNodePortDescriptor &descriptor_port : descriptor->ports) {
		if (resolved.find(descriptor_port.identifier) != resolved.end()) continue;
		TaskPortDefinition port;
		port.identifier = descriptor_port.identifier;
		port.direction = descriptor_port.direction;
		port.value_type = descriptor_port.value_type;
		port.required = descriptor_port.required;
		resolved[port.identifier] = port;
	}

	if (p_node.kind == TaskNodeKind::CONVERSATION) {
		for (const std::string &outcome : p_node.accepted_outcomes) {
			if (resolved.find(outcome) != resolved.end()) continue;
			TaskPortDefinition port;
			port.identifier = outcome;
			port.direction = TaskPortDirection::OUTPUT;
			port.value_type = ValueType::NONE;
			resolved[port.identifier] = port;
		}
	}

	r_ports.reserve(resolved.size());
	for (const auto &entry : resolved) r_ports.push_back(entry.second);
	if (r_ports.size() > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, r_ports.size());
	}
	return ok_status();
}

const char *task_node_kind_name(TaskNodeKind p_kind) {
	switch (p_kind) {
		case TaskNodeKind::ENTRY:
			return "entry";
		case TaskNodeKind::OBJECTIVE:
			return "objective";
		case TaskNodeKind::CONDITION:
			return "condition";
		case TaskNodeKind::ALL_GATE:
			return "all_gate";
		case TaskNodeKind::ANY_GATE:
			return "any_gate";
		case TaskNodeKind::EXTERNAL_ACTION:
			return "external_action";
		case TaskNodeKind::CONVERSATION:
			return "conversation";
		case TaskNodeKind::SUBGRAPH:
			return "subgraph";
		case TaskNodeKind::REWARD_REQUEST:
			return "reward_request";
		case TaskNodeKind::SUCCESS_TERMINAL:
			return "success_terminal";
		case TaskNodeKind::FAILURE_TERMINAL:
			return "failure_terminal";
		case TaskNodeKind::CANCELLED_TERMINAL:
			return "cancelled_terminal";
	}
	return "unknown";
}

// ---------------------------------------------------------------------------
// Catalog/subgraph seams
// ---------------------------------------------------------------------------

Status TaskGraphValidationHooks::validate_provider(
		const std::string &, ProviderKind, const TaskNodeDefinition &) const {
	return ok_status();
}

Status TaskGraphValidationHooks::validate_conversation(
		const std::string &, const std::string &, const std::vector<std::string> &, const TaskNodeDefinition &) const {
	return ok_status();
}

Status TaskGraphValidationHooks::resolve_subgraph(
		const std::string &, const TaskGraphDefinition *&r_definition) const {
	r_definition = nullptr;
	return ok_status();
}

Status TaskGraphValidationHooks::validate_graph(const TaskGraphDefinition &) const {
	return ok_status();
}

Status TaskGraphValidationCallbacks::validate_provider(
		const std::string &p_provider_identifier,
		ProviderKind p_expected_kind,
		const TaskNodeDefinition &p_node) const {
	return provider ? provider(p_provider_identifier, p_expected_kind, p_node) : ok_status();
}

Status TaskGraphValidationCallbacks::validate_conversation(
		const std::string &p_conversation_identifier,
		const std::string &p_entry_label,
		const std::vector<std::string> &p_accepted_outcomes,
		const TaskNodeDefinition &p_node) const {
	return conversation ? conversation(p_conversation_identifier, p_entry_label, p_accepted_outcomes, p_node) : ok_status();
}

Status TaskGraphValidationCallbacks::resolve_subgraph(
		const std::string &p_subgraph_identifier,
		const TaskGraphDefinition *&r_definition) const {
	if (!subgraph) {
		r_definition = nullptr;
		return ok_status();
	}
	return subgraph(p_subgraph_identifier, r_definition);
}

Status TaskGraphValidationCallbacks::validate_graph(const TaskGraphDefinition &p_graph) const {
	return graph ? graph(p_graph) : ok_status();
}

// ---------------------------------------------------------------------------
// Compiler limits and diagnostics
// ---------------------------------------------------------------------------

Status TaskGraphCompileLimits::validate() const {
	if (max_nodes == 0 || max_nodes > MAX_NODES_PER_TASK_GRAPH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT, max_nodes);
	}
	if (max_edges > MAX_EDGES_PER_TASK_GRAPH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_EDGE_LIMIT, max_edges);
	}
	if (max_ports_per_node == 0 || max_ports_per_node > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, max_ports_per_node);
	}
	if (max_terminal_outcomes == 0 || max_terminal_outcomes > MAX_TERMINAL_OUTCOMES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_OUTCOME_INVALID, max_terminal_outcomes);
	}
	if (max_fan_out == 0 || max_fan_out > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, max_fan_out);
	}
	if (max_transitions_per_advance == 0 || max_transitions_per_advance > MAX_TRANSITIONS_PER_ADVANCE) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE, max_transitions_per_advance);
	}
	if (max_subgraph_depth == 0 || max_subgraph_depth > MAX_SUBGRAPH_DEPTH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, max_subgraph_depth);
	}
	const std::uint32_t hard_budget = derived_work_budget();
	if (max_work_units > hard_budget) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::VALUE_OUT_OF_RANGE, max_work_units);
	}
	return ok_status();
}

std::uint32_t TaskGraphCompileLimits::derived_work_budget() const {
	const std::uint64_t budget = static_cast<std::uint64_t>(MAX_NODES_PER_TASK_GRAPH) +
			static_cast<std::uint64_t>(MAX_EDGES_PER_TASK_GRAPH) +
			static_cast<std::uint64_t>(MAX_TRANSITIONS_PER_ADVANCE);
	return budget > std::numeric_limits<std::uint32_t>::max() ? std::numeric_limits<std::uint32_t>::max() :
			static_cast<std::uint32_t>(budget);
}

// ---------------------------------------------------------------------------
// Immutable canonical DAG
// ---------------------------------------------------------------------------

const CanonicalTaskNode *CanonicalTaskGraph::find_node(const std::string &p_identifier) const {
	for (const CanonicalTaskNode &node : nodes_) {
		if (node.definition.identifier == p_identifier) return &node;
	}
	return nullptr;
}

const CanonicalTaskEdge *CanonicalTaskGraph::find_edge(const std::string &p_identifier) const {
	for (const CanonicalTaskEdge &edge : edges_) {
		if (edge.definition.identifier == p_identifier) return &edge;
	}
	return nullptr;
}

const CanonicalTaskNode &CanonicalTaskGraph::node(std::size_t p_index) const {
	static const CanonicalTaskNode empty;
	return p_index < nodes_.size() ? nodes_[p_index] : empty;
}

const CanonicalTaskEdge &CanonicalTaskGraph::edge(std::size_t p_index) const {
	static const CanonicalTaskEdge empty;
	return p_index < edges_.size() ? edges_[p_index] : empty;
}

bool CanonicalTaskGraph::operator==(const CanonicalTaskGraph &p_other) const {
	return valid_ == p_other.valid_ && fingerprint_ == p_other.fingerprint_ && definition_ == p_other.definition_ &&
			topological_order_ == p_other.topological_order_ && terminal_node_indices_ == p_other.terminal_node_indices_;
}

// ---------------------------------------------------------------------------
// Graph compiler
// ---------------------------------------------------------------------------

TaskGraphCompiler::TaskGraphCompiler() {
	options_.registry = &TaskNodeRegistry::default_registry();
}

TaskGraphCompiler::TaskGraphCompiler(const TaskGraphCompileOptions &p_options) : options_(p_options) {
	if (options_.registry == nullptr) options_.registry = &TaskNodeRegistry::default_registry();
}

TaskGraphCompiler::TaskGraphCompiler(
		const TaskNodeRegistry &p_registry,
		const TaskGraphValidationHooks *p_hooks,
		const TaskGraphCompileLimits &p_limits) {
	options_.registry = &p_registry;
	options_.hooks = p_hooks;
	options_.limits = p_limits;
}

const TaskNodeRegistry &TaskGraphCompiler::registry() const {
	return options_.registry != nullptr ? *options_.registry : TaskNodeRegistry::default_registry();
}

Status TaskGraphCompiler::validate(const TaskGraphDefinition &p_graph, std::vector<Diagnostic> *r_diagnostics) const {
	std::vector<std::string> subgraph_stack;
	return compile_internal(p_graph, nullptr, r_diagnostics, subgraph_stack, 0);
}

Status TaskGraphCompiler::compile(
		const TaskGraphDefinition &p_graph,
		CanonicalTaskGraph &r_compiled,
		std::vector<Diagnostic> *r_diagnostics) const {
	CanonicalTaskGraph candidate;
	std::vector<std::string> subgraph_stack;
	Status status = compile_internal(p_graph, &candidate, r_diagnostics, subgraph_stack, 0);
	if (!status.ok()) {
		r_compiled = CanonicalTaskGraph{};
		return status;
	}
	r_compiled = std::move(candidate);
	return ok_status();
}

Status TaskGraphCompiler::compile(
		const TaskGraphDefinition &p_graph,
		std::shared_ptr<const CanonicalTaskGraph> &r_compiled,
		std::vector<Diagnostic> *r_diagnostics) const {
	CanonicalTaskGraph candidate;
	std::vector<std::string> subgraph_stack;
	Status status = compile_internal(p_graph, &candidate, r_diagnostics, subgraph_stack, 0);
	if (!status.ok()) {
		r_compiled.reset();
		return status;
	}
	r_compiled = std::make_shared<const CanonicalTaskGraph>(std::move(candidate));
	return ok_status();
}

TaskGraphCompileResult TaskGraphCompiler::compile(const TaskGraphDefinition &p_graph) const {
	TaskGraphCompileResult result;
	result.status = compile(p_graph, result.graph, &result.diagnostics);
	return result;
}

Status TaskGraphCompiler::compile_internal(
		const TaskGraphDefinition &p_graph,
		CanonicalTaskGraph *r_compiled,
		std::vector<Diagnostic> *r_diagnostics,
		std::vector<std::string> &r_subgraph_stack,
		std::uint32_t p_depth) const {
	Status status = options_.limits.validate();
	if (!status.ok()) return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, graph_path(p_graph), r_diagnostics);

	if (p_depth > options_.limits.max_subgraph_depth) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
				p_depth, graph_path(p_graph), r_diagnostics);
	}
	if (std::find(r_subgraph_stack.begin(), r_subgraph_stack.end(), p_graph.identifier) != r_subgraph_stack.end()) {
		return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
				p_depth, graph_path(p_graph), r_diagnostics);
	}
	r_subgraph_stack.push_back(p_graph.identifier);
	struct StackGuard {
		std::vector<std::string> &stack;
		~StackGuard() { stack.pop_back(); }
	} stack_guard{ r_subgraph_stack };

	TaskGraphDefinition graph = p_graph;
	if (graph.nodes.size() > options_.limits.max_nodes) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT, graph.nodes.size(),
				graph_path(graph), r_diagnostics);
	}
	if (graph.edges.size() > options_.limits.max_edges) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_EDGE_LIMIT, graph.edges.size(),
				graph_path(graph), r_diagnostics);
	}
	if (graph.terminal_outcomes.size() > options_.limits.max_terminal_outcomes) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_OUTCOME_INVALID,
				graph.terminal_outcomes.size(), graph_path(graph), r_diagnostics);
	}
	status = graph.validate_and_canonicalize();
	if (!status.ok()) return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, graph_path(graph), r_diagnostics);
	if (graph.max_transitions_per_advance > options_.limits.max_transitions_per_advance) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				graph.max_transitions_per_advance, graph_path(graph) + ".max_transitions_per_advance", r_diagnostics);
	}
	if (options_.hooks != nullptr) {
		status = options_.hooks->validate_graph(graph);
		if (!status.ok()) return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, graph_path(graph), r_diagnostics);
	}

	if (graph.nodes.size() > options_.limits.max_nodes || graph.edges.size() > options_.limits.max_edges) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT,
				std::max(graph.nodes.size(), graph.edges.size()), graph_path(graph), r_diagnostics);
	}

	std::vector<WorkingNode> working_nodes;
	std::map<std::string, std::size_t> node_indices;
	status = build_working_nodes(graph, registry(), options_.limits, working_nodes, node_indices, r_diagnostics);
	if (!status.ok()) return status;

	const auto entry_found = node_indices.find(graph.entry_node_identifier);
	if (entry_found == node_indices.end()) {
		return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_ENTRY_INVALID,
				0, graph_path(graph) + ".entry", r_diagnostics);
	}
	std::size_t entry_count = 0;
	std::size_t entry_index = 0;
	for (std::size_t index = 0; index < working_nodes.size(); ++index) {
		if (working_nodes[index].definition.kind == TaskNodeKind::ENTRY) {
			++entry_count;
			entry_index = index;
		}
	}
	if (entry_count != 1 || entry_index != entry_found->second) {
		return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_ENTRY_INVALID,
				entry_count, graph_path(graph) + ".entry", r_diagnostics);
	}

	status = add_dynamic_edge_ports(graph, working_nodes, node_indices, options_.limits, r_diagnostics);
	if (!status.ok()) return status;

	std::vector<CanonicalTaskEdge> canonical_edges;
	canonical_edges.reserve(graph.edges.size());
	std::set<std::tuple<std::size_t, std::string, std::size_t, std::string>> endpoints;
	std::vector<std::size_t> incoming_counts;
	std::vector<std::size_t> outgoing_counts;
	std::vector<std::vector<std::size_t>> incoming_port_counts;
	std::vector<std::vector<std::size_t>> outgoing_port_counts;
	incoming_port_counts.resize(working_nodes.size());
	outgoing_port_counts.resize(working_nodes.size());
	for (std::size_t index = 0; index < working_nodes.size(); ++index) {
		incoming_port_counts[index].assign(working_nodes[index].ports.size(), 0);
		outgoing_port_counts[index].assign(working_nodes[index].ports.size(), 0);
		incoming_counts.push_back(0);
		outgoing_counts.push_back(0);
	}

	for (const TaskEdgeDefinition &edge : graph.edges) {
		const auto from_node_found = node_indices.find(edge.from_node_identifier);
		const auto to_node_found = node_indices.find(edge.to_node_identifier);
		if (from_node_found == node_indices.end() || to_node_found == node_indices.end()) {
			return compiler_error(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, 0,
					edge_path(graph, edge.identifier), r_diagnostics);
		}
		const std::size_t from_node_index = from_node_found->second;
		const std::size_t to_node_index = to_node_found->second;
		std::size_t from_port_index = port_index(working_nodes[from_node_index].port_indices, edge.from_port_identifier);
		std::size_t to_port_index = port_index(working_nodes[to_node_index].port_indices, edge.to_port_identifier);
		const TaskNodePortDescriptor *from_descriptor_port = nullptr;
		const TaskNodePortDescriptor *to_descriptor_port = nullptr;
		if (from_port_index == std::numeric_limits<std::size_t>::max()) {
			from_descriptor_port = working_nodes[from_node_index].descriptor->find_port(edge.from_port_identifier);
			if (from_descriptor_port != nullptr) {
				from_port_index = port_index(working_nodes[from_node_index].port_indices, from_descriptor_port->identifier);
			}
		}
		if (to_port_index == std::numeric_limits<std::size_t>::max()) {
			to_descriptor_port = working_nodes[to_node_index].descriptor->find_port(edge.to_port_identifier);
			if (to_descriptor_port != nullptr) {
				to_port_index = port_index(working_nodes[to_node_index].port_indices, to_descriptor_port->identifier);
			}
		}
		if (from_port_index == std::numeric_limits<std::size_t>::max() || to_port_index == std::numeric_limits<std::size_t>::max()) {
			return compiler_error(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_PORT_INVALID, 0,
					edge_path(graph, edge.identifier), r_diagnostics);
		}
		WorkingPort &from_port = working_nodes[from_node_index].ports[from_port_index];
		WorkingPort &to_port = working_nodes[to_node_index].ports[to_port_index];
		if (from_port.definition.direction != TaskPortDirection::OUTPUT || to_port.definition.direction != TaskPortDirection::INPUT) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID, 0,
					port_path(graph, edge, "from", edge.from_port_identifier), r_diagnostics);
		}
		if (from_port.definition.value_type != to_port.definition.value_type) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID,
					(static_cast<std::uint8_t>(from_port.definition.value_type) << 8U) |
							static_cast<std::uint8_t>(to_port.definition.value_type),
					port_path(graph, edge, "to", edge.to_port_identifier), r_diagnostics);
		}

		CanonicalTaskEdge canonical_edge;
		canonical_edge.definition = edge;
		canonical_edge.definition.from_port_identifier = from_port.definition.identifier;
		canonical_edge.definition.to_port_identifier = to_port.definition.identifier;
		canonical_edge.from_node_index = static_cast<std::uint32_t>(from_node_index);
		canonical_edge.to_node_index = static_cast<std::uint32_t>(to_node_index);
		const auto endpoint = std::make_tuple(from_node_index, from_port.definition.identifier, to_node_index,
				to_port.definition.identifier);
		if (!endpoints.insert(endpoint).second) {
			return compiler_error(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_EDGE_DUPLICATE,
				canonical_edges.size(), edge_path(graph, edge.identifier), r_diagnostics);
		}
		canonical_edges.push_back(std::move(canonical_edge));
		++outgoing_port_counts[from_node_index][from_port_index];
		++incoming_port_counts[to_node_index][to_port_index];
		++outgoing_counts[from_node_index];
		++incoming_counts[to_node_index];
	}

	std::vector<std::uint32_t> terminal_indices;
	std::map<std::string, std::size_t> terminal_outcome_counts;
	for (std::size_t node_index = 0; node_index < working_nodes.size(); ++node_index) {
		const WorkingNode &node = working_nodes[node_index];
		const bool terminal = node.descriptor->terminal || is_terminal_kind(node.definition.kind);
		if (terminal) {
			terminal_indices.push_back(static_cast<std::uint32_t>(node_index));
			if (!has_port_identifier(node.definition.ports, "input")) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID, 0,
						node_path(graph, node.definition.identifier), r_diagnostics);
			}
			if (node.definition.outcome_identifier.empty() ||
					std::find(graph.terminal_outcomes.begin(), graph.terminal_outcomes.end(), node.definition.outcome_identifier) ==
							graph.terminal_outcomes.end()) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_OUTCOME_INVALID, 0,
						node_path(graph, node.definition.identifier) + ".outcome", r_diagnostics);
			}
			++terminal_outcome_counts[node.definition.outcome_identifier];
		} else if (!node.definition.outcome_identifier.empty()) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_OUTCOME_INVALID, 0,
				node_path(graph, node.definition.identifier) + ".outcome", r_diagnostics);
		}

		for (std::size_t port_index_value = 0; port_index_value < node.ports.size(); ++port_index_value) {
			const WorkingPort &port = node.ports[port_index_value];
			const std::size_t count = port.definition.direction == TaskPortDirection::INPUT ?
					incoming_port_counts[node_index][port_index_value] : outgoing_port_counts[node_index][port_index_value];
			if (count < port.min_connections || count > port.max_connections) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID, count,
						node_path(graph, node.definition.identifier) + ".port." + port.definition.identifier, r_diagnostics);
			}
		}

		if (node.definition.kind == TaskNodeKind::ALL_GATE || node.definition.kind == TaskNodeKind::ANY_GATE) {
			if (incoming_counts[node_index] == 0) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID, 0,
						node_path(graph, node.definition.identifier), r_diagnostics);
			}
		} else if (terminal) {
			if (incoming_counts[node_index] == 0 || outgoing_counts[node_index] != 0) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_PORT_INVALID,
						incoming_counts[node_index], node_path(graph, node.definition.identifier), r_diagnostics);
			}
		} else if (node.definition.kind == TaskNodeKind::ENTRY) {
			if (incoming_counts[node_index] != 0 || outgoing_counts[node_index] == 0) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_ENTRY_INVALID,
						outgoing_counts[node_index], node_path(graph, node.definition.identifier), r_diagnostics);
			}
		} else if (outgoing_counts[node_index] == 0) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, 0,
					node_path(graph, node.definition.identifier), r_diagnostics);
		}
	}

	if (terminal_indices.empty()) {
		return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_OUTCOME_INVALID, 0,
				graph_path(graph) + ".terminals", r_diagnostics);
	}
	for (const std::string &outcome : graph.terminal_outcomes) {
		if (options_.require_terminal_for_each_declared_outcome && terminal_outcome_counts.find(outcome) == terminal_outcome_counts.end()) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_OUTCOME_INVALID, 0,
					graph_path(graph) + ".outcome." + outcome, r_diagnostics);
		}
	}

	std::vector<std::vector<std::size_t>> adjacency(working_nodes.size());
	std::vector<std::vector<std::size_t>> reverse_adjacency(working_nodes.size());
	for (const CanonicalTaskEdge &edge : canonical_edges) {
		adjacency[edge.from_node_index].push_back(edge.to_node_index);
		reverse_adjacency[edge.to_node_index].push_back(edge.from_node_index);
	}

	std::vector<bool> reachable(working_nodes.size(), false);
	std::vector<std::size_t> queue;
	queue.push_back(entry_index);
	reachable[entry_index] = true;
	for (std::size_t cursor = 0; cursor < queue.size(); ++cursor) {
		const std::size_t node_index = queue[cursor];
		for (std::size_t next : adjacency[node_index]) {
			if (!reachable[next]) {
				reachable[next] = true;
				queue.push_back(next);
			}
		}
	}
	if (options_.require_all_nodes_reachable) {
		for (std::size_t index = 0; index < reachable.size(); ++index) {
			if (!reachable[index]) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, index,
						node_path(graph, working_nodes[index].definition.identifier), r_diagnostics);
			}
		}
	}
	if (options_.require_all_terminals_reachable) {
		for (std::uint32_t terminal_index : terminal_indices) {
			if (!reachable[terminal_index]) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
						terminal_index, node_path(graph, working_nodes[terminal_index].definition.identifier), r_diagnostics);
			}
		}
	}

	std::vector<bool> can_reach_terminal(working_nodes.size(), false);
	queue.clear();
	for (std::uint32_t terminal_index : terminal_indices) {
		can_reach_terminal[terminal_index] = true;
		queue.push_back(terminal_index);
	}
	for (std::size_t cursor = 0; cursor < queue.size(); ++cursor) {
		const std::size_t node_index = queue[cursor];
		for (std::size_t previous : reverse_adjacency[node_index]) {
			if (!can_reach_terminal[previous]) {
				can_reach_terminal[previous] = true;
				queue.push_back(previous);
			}
		}
	}
	for (std::size_t index = 0; index < working_nodes.size(); ++index) {
		if (reachable[index] && !can_reach_terminal[index]) {
			return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, index,
					node_path(graph, working_nodes[index].definition.identifier), r_diagnostics);
		}
	}

	std::vector<std::size_t> indegrees(working_nodes.size(), 0);
	for (const CanonicalTaskEdge &edge : canonical_edges) ++indegrees[edge.to_node_index];
	std::set<std::size_t> ready;
	for (std::size_t index = 0; index < indegrees.size(); ++index) {
		if (indegrees[index] == 0) ready.insert(index);
	}
	std::vector<std::uint32_t> topological_order;
	topological_order.reserve(working_nodes.size());
	while (!ready.empty()) {
		const std::size_t node_index = *ready.begin();
		ready.erase(ready.begin());
		topological_order.push_back(static_cast<std::uint32_t>(node_index));
		for (std::size_t next : adjacency[node_index]) {
			if (--indegrees[next] == 0) ready.insert(next);
		}
	}
	if (topological_order.size() != working_nodes.size()) {
		for (std::size_t index = 0; index < indegrees.size(); ++index) {
			if (indegrees[index] != 0) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
						index, node_path(graph, working_nodes[index].definition.identifier), r_diagnostics);
			}
		}
		return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, 0,
				graph_path(graph), r_diagnostics);
	}

	const std::uint32_t work_units = saturating_work_units(
			working_nodes.size(), canonical_edges.size(), graph.max_transitions_per_advance);
	const std::uint32_t work_budget = options_.limits.max_work_units == 0 ? options_.limits.derived_work_budget() :
			options_.limits.max_work_units;
	if (work_units > work_budget) {
		return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, work_units,
				graph_path(graph) + ".work_budget", r_diagnostics);
	}

	// Provider, conversation, and subgraph checks are late enough that all
	// local topology diagnostics remain deterministic, but early enough that a
	// failing hook never publishes a canonical graph.
	for (const WorkingNode &node : working_nodes) {
		const TaskNodeDefinition &definition = node.definition;
		if (options_.hooks != nullptr) {
			if (!definition.provider_identifier.empty() &&
					(definition.kind == TaskNodeKind::OBJECTIVE || definition.kind == TaskNodeKind::CONDITION ||
							definition.kind == TaskNodeKind::EXTERNAL_ACTION || definition.kind == TaskNodeKind::REWARD_REQUEST)) {
				status = options_.hooks->validate_provider(definition.provider_identifier,
						provider_kind_for_node(definition.kind), definition);
				if (!status.ok()) {
					return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
							node_path(graph, definition.identifier) + ".provider." + definition.provider_identifier, r_diagnostics);
				}
			}
			if (definition.kind == TaskNodeKind::CONVERSATION) {
				status = options_.hooks->validate_conversation(definition.conversation_identifier,
						definition.conversation_entry_label, definition.accepted_outcomes, definition);
				if (!status.ok()) {
					return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
						node_path(graph, definition.identifier) + ".conversation." + definition.conversation_identifier,
						r_diagnostics);
				}
			}
		}
		if (definition.kind == TaskNodeKind::SUBGRAPH) {
			if (definition.subgraph_identifier == graph.identifier ||
					std::find(r_subgraph_stack.begin(), r_subgraph_stack.end(), definition.subgraph_identifier) != r_subgraph_stack.end()) {
				return compiler_error(StatusCode::GRAPH_INVALID, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_depth,
						node_path(graph, definition.identifier) + ".subgraph." + definition.subgraph_identifier, r_diagnostics);
			}
			if (p_depth >= options_.limits.max_subgraph_depth) {
				return compiler_error(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_depth,
						node_path(graph, definition.identifier) + ".subgraph." + definition.subgraph_identifier, r_diagnostics);
			}
			if (options_.hooks != nullptr) {
				const TaskGraphDefinition *subgraph = nullptr;
				status = options_.hooks->resolve_subgraph(definition.subgraph_identifier, subgraph);
				if (!status.ok()) {
					return report_error(status, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
							node_path(graph, definition.identifier) + ".subgraph." + definition.subgraph_identifier,
						r_diagnostics);
				}
				if (subgraph != nullptr) {
					if (subgraph->identifier != definition.subgraph_identifier) {
						return compiler_error(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
								hash_string(subgraph->identifier),
								node_path(graph, definition.identifier) + ".subgraph." + definition.subgraph_identifier,
							r_diagnostics);
					}
					status = compile_internal(*subgraph, nullptr, r_diagnostics, r_subgraph_stack, p_depth + 1);
					if (!status.ok()) return status;
				}
			}
		}
	}

	if (r_compiled == nullptr) return ok_status();
	// Publish the effective registry ports and canonical alias spellings as
	// part of the canonical definition.  This keeps implicit and explicit V1
	// port authoring semantically identical and makes the resulting fingerprint
	// describe the actual DAG consumed by runtime code.
	for (std::size_t index = 0; index < working_nodes.size(); ++index) {
		graph.nodes[index] = working_nodes[index].definition;
	}
	for (std::size_t index = 0; index < canonical_edges.size(); ++index) {
		graph.edges[index] = canonical_edges[index].definition;
	}
	r_compiled->definition_ = std::move(graph);
	r_compiled->nodes_.clear();
	r_compiled->nodes_.reserve(working_nodes.size());
	for (std::size_t index = 0; index < working_nodes.size(); ++index) {
		CanonicalTaskNode node;
		node.definition = std::move(working_nodes[index].definition);
		node.canonical_index = static_cast<std::uint32_t>(index);
		r_compiled->nodes_.push_back(std::move(node));
	}
	r_compiled->edges_ = std::move(canonical_edges);
	for (std::size_t edge_index = 0; edge_index < r_compiled->edges_.size(); ++edge_index) {
		const CanonicalTaskEdge &edge = r_compiled->edges_[edge_index];
		r_compiled->nodes_[edge.from_node_index].outgoing_edge_indices.push_back(static_cast<std::uint32_t>(edge_index));
		r_compiled->nodes_[edge.to_node_index].incoming_edge_indices.push_back(static_cast<std::uint32_t>(edge_index));
	}
	r_compiled->topological_order_ = std::move(topological_order);
	r_compiled->terminal_node_indices_ = std::move(terminal_indices);
	r_compiled->entry_node_index_ = static_cast<std::uint32_t>(entry_index);
	r_compiled->work_units_ = work_units;
	r_compiled->fingerprint_ = r_compiled->definition_.fingerprint();
	if (r_compiled->fingerprint_ == INVALID_CATALOG_FINGERPRINT) {
		return compiler_error(StatusCode::INTERNAL_ERROR, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, 0,
				graph_path(r_compiled->definition_), r_diagnostics);
	}
	r_compiled->valid_ = true;
	return ok_status();
}

Status compile_task_graph(
		const TaskGraphDefinition &p_graph,
		CanonicalTaskGraph &r_compiled,
		const TaskGraphCompileOptions &p_options,
		std::vector<Diagnostic> *r_diagnostics) {
	return TaskGraphCompiler(p_options).compile(p_graph, r_compiled, r_diagnostics);
}

Status validate_task_graph(
		const TaskGraphDefinition &p_graph,
		const TaskGraphCompileOptions &p_options,
		std::vector<Diagnostic> *r_diagnostics) {
	return TaskGraphCompiler(p_options).validate(p_graph, r_diagnostics);
}

} // namespace lts
