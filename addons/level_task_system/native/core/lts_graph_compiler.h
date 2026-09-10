#ifndef LEVEL_TASK_SYSTEM_CORE_GRAPH_COMPILER_H
#define LEVEL_TASK_SYSTEM_CORE_GRAPH_COMPILER_H

#include "core/lts_definitions.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <memory>
#include <string>
#include <vector>

namespace lts {

// ---------------------------------------------------------------------------
// Typed node and port registry
// ---------------------------------------------------------------------------

// A port with this maximum is bounded, but may accept more than one edge.
// This is used for gate inputs and output fan-out.  A normal input has a
// maximum of one connection; an output is allowed to fan out up to the
// package port ceiling unless a descriptor supplies a smaller bound.
constexpr std::size_t TASK_PORT_UNBOUNDED = MAX_PORTS_PER_TASK_NODE;

struct TaskNodePortDescriptor {
	std::string identifier;
	TaskPortDirection direction = TaskPortDirection::OUTPUT;
	ValueType value_type = ValueType::NONE;
	bool required = false;
	std::size_t min_connections = 0;
	std::size_t max_connections = 1;
	bool dynamic = false;
	std::vector<std::string> aliases;

	Status validate() const;
	bool accepts_identifier(const std::string &p_identifier) const;
	bool operator==(const TaskNodePortDescriptor &p_other) const;
	bool operator!=(const TaskNodePortDescriptor &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskNodePortDescriptor &p_other) const;
};

using TaskPortDescriptor = TaskNodePortDescriptor;
using TaskNodePortSpec = TaskNodePortDescriptor;
using TaskNodePortDefinition = TaskNodePortDescriptor;

struct TaskNodeTypeDescriptor {
	TaskNodeKind kind = TaskNodeKind::ENTRY;
	std::string identifier;
	std::vector<TaskNodePortDescriptor> ports;
	bool dynamic_inputs = false;
	bool dynamic_outputs = false;
	bool terminal = false;

	Status validate() const;
	const TaskNodePortDescriptor *find_port(const std::string &p_identifier) const;
	const TaskNodePortDescriptor *get_port(const std::string &p_identifier) const { return find_port(p_identifier); }
	const std::vector<TaskNodePortDescriptor> &port_definitions() const { return ports; }
	bool operator==(const TaskNodeTypeDescriptor &p_other) const;
	bool operator!=(const TaskNodeTypeDescriptor &p_other) const { return !(*this == p_other); }
};

using TaskNodeDescriptor = TaskNodeTypeDescriptor;

// The registry is deliberately independent from a catalog.  It describes
// the closed V1 vocabulary and can be extended by an adapter before sealing,
// while graph references are resolved through TaskGraphValidationHooks below.
class TaskNodeRegistry {
public:
	TaskNodeRegistry();

	// Returns a registry populated with the V1 node families.  The default
	// constructor is equivalent, but leaves the registry open for an adapter
	// that wants to register an application node before sealing.
	static TaskNodeRegistry make_default();
	static const TaskNodeRegistry &default_registry();

	Status register_node_type(const TaskNodeTypeDescriptor &p_descriptor);
	Status register_descriptor(const TaskNodeTypeDescriptor &p_descriptor) { return register_node_type(p_descriptor); }
	Status register_type(const TaskNodeTypeDescriptor &p_descriptor) { return register_node_type(p_descriptor); }
	Status register_node(const TaskNodeTypeDescriptor &p_descriptor) { return register_node_type(p_descriptor); }
	Status seal();
	bool is_sealed() const { return sealed_; }

	const TaskNodeTypeDescriptor *find(TaskNodeKind p_kind) const;
	const TaskNodeTypeDescriptor *find_node_type(TaskNodeKind p_kind) const { return find(p_kind); }
	const TaskNodeTypeDescriptor *get(TaskNodeKind p_kind) const { return find(p_kind); }
	const TaskNodeTypeDescriptor *get_node_type(TaskNodeKind p_kind) const { return find(p_kind); }
	bool contains(TaskNodeKind p_kind) const { return find(p_kind) != nullptr; }
	std::vector<TaskNodeKind> kinds() const;
	const std::vector<TaskNodeTypeDescriptor> &descriptors() const { return descriptors_; }

	// Resolve an authored node's effective ports.  This copies the descriptor
	// data, maps known aliases to canonical names, and adds dynamic ports where
	// the node family permits them.  The graph compiler uses this operation so
	// authored definitions remain untouched.
	Status resolve_ports(const TaskNodeDefinition &p_node, std::vector<TaskPortDefinition> &r_ports) const;

private:
	std::vector<TaskNodeTypeDescriptor> descriptors_;
	bool sealed_ = false;

	void add_builtin_descriptors();
};

using TaskNodeTypeRegistry = TaskNodeRegistry;
using TaskGraphNodeRegistry = TaskNodeRegistry;

const char *task_node_kind_name(TaskNodeKind p_kind);

// ---------------------------------------------------------------------------
// Catalog/subgraph seams
// ---------------------------------------------------------------------------

// The compiler does not include or know about a future LevelTaskCatalog.  A
// catalog, editor, or server may implement this seam to check references it
// owns.  The default implementations are intentionally no-ops: local graph
// validation remains useful before a catalog exists, while a supplied hook
// can fail closed for unknown providers/resources.
class TaskGraphValidationHooks {
public:
	virtual ~TaskGraphValidationHooks() = default;

	virtual Status validate_provider(
			const std::string &p_provider_identifier,
			ProviderKind p_expected_kind,
			const TaskNodeDefinition &p_node) const;

	virtual Status validate_conversation(
			const std::string &p_conversation_identifier,
			const std::string &p_entry_label,
			const std::vector<std::string> &p_accepted_outcomes,
			const TaskNodeDefinition &p_node) const;

	// A resolver may return a definition for recursive subgraph validation.  A
	// null result means the reference was intentionally left unresolved (for
	// example while validating a single resource in an editor).  Returning a
	// non-OK status rejects the graph.  The returned definition must outlive
	// the compiler call and must not be mutated by the compiler.
	virtual Status resolve_subgraph(
			const std::string &p_subgraph_identifier,
			const TaskGraphDefinition *&r_definition) const;

	// Optional whole-graph hook for a catalog to inspect additional local
	// metadata after the native definition validator has run.
	virtual Status validate_graph(const TaskGraphDefinition &p_graph) const;
};

// A callback-friendly hook bundle for embedders that do not want to subclass
// TaskGraphValidationHooks.  Empty callbacks have the same no-op semantics
// as the base class.
struct TaskGraphValidationCallbacks : public TaskGraphValidationHooks {
	using ProviderCallback = std::function<Status(const std::string &, ProviderKind, const TaskNodeDefinition &)>;
	using ConversationCallback = std::function<Status(
			const std::string &, const std::string &, const std::vector<std::string> &, const TaskNodeDefinition &)>;
	using SubgraphCallback = std::function<Status(const std::string &, const TaskGraphDefinition *&)>;
	using GraphCallback = std::function<Status(const TaskGraphDefinition &)>;

	ProviderCallback provider;
	ConversationCallback conversation;
	SubgraphCallback subgraph;
	GraphCallback graph;

	Status validate_provider(
			const std::string &p_provider_identifier,
			ProviderKind p_expected_kind,
			const TaskNodeDefinition &p_node) const override;
	Status validate_conversation(
			const std::string &p_conversation_identifier,
			const std::string &p_entry_label,
			const std::vector<std::string> &p_accepted_outcomes,
			const TaskNodeDefinition &p_node) const override;
	Status resolve_subgraph(
			const std::string &p_subgraph_identifier,
			const TaskGraphDefinition *&r_definition) const override;
	Status validate_graph(const TaskGraphDefinition &p_graph) const override;
};

using TaskGraphCompilerHooks = TaskGraphValidationHooks;
using TaskGraphCatalogHooks = TaskGraphValidationHooks;

// ---------------------------------------------------------------------------
// Compiler limits and diagnostics
// ---------------------------------------------------------------------------

struct TaskGraphCompileLimits {
	std::size_t max_nodes = MAX_NODES_PER_TASK_GRAPH;
	std::size_t max_edges = MAX_EDGES_PER_TASK_GRAPH;
	std::size_t max_ports_per_node = MAX_PORTS_PER_TASK_NODE;
	std::size_t max_terminal_outcomes = MAX_TERMINAL_OUTCOMES;
	std::size_t max_fan_out = MAX_PORTS_PER_TASK_NODE;
	std::uint32_t max_transitions_per_advance = MAX_TRANSITIONS_PER_ADVANCE;
	std::uint32_t max_subgraph_depth = MAX_SUBGRAPH_DEPTH;
	// Zero means use the package-sized derived budget.  A positive value lets
	// an editor/simulator choose a smaller budget without changing hard caps.
	std::uint32_t max_work_units = 0;

	Status validate() const;
	std::uint32_t derived_work_budget() const;
};

using TaskGraphCompilerLimits = TaskGraphCompileLimits;

struct TaskGraphCompileOptions {
	TaskGraphCompileLimits limits;
	const TaskNodeRegistry *registry = nullptr;
	const TaskGraphValidationHooks *hooks = nullptr;
	bool require_all_nodes_reachable = true;
	bool require_all_terminals_reachable = true;
	bool require_terminal_for_each_declared_outcome = true;
};

using TaskGraphCompilerOptions = TaskGraphCompileOptions;

// ---------------------------------------------------------------------------
// Immutable canonical DAG
// ---------------------------------------------------------------------------

struct CanonicalTaskNode {
	TaskNodeDefinition definition;
	std::uint32_t canonical_index = 0;
	std::vector<std::uint32_t> incoming_edge_indices;
	std::vector<std::uint32_t> outgoing_edge_indices;

	const std::string &identifier() const { return definition.identifier; }
	TaskNodeKind kind() const { return definition.kind; }
};

struct CanonicalTaskEdge {
	TaskEdgeDefinition definition;
	std::uint32_t from_node_index = 0;
	std::uint32_t to_node_index = 0;

	const std::string &identifier() const { return definition.identifier; }
};

// A successful compilation creates one of these values.  Its public API only
// exposes const views; the compiler builds a temporary and publishes it after
// every validation pass succeeds, so callers cannot observe a partially
// compiled graph.
class CanonicalTaskGraph {
public:
	CanonicalTaskGraph() = default;

	bool valid() const { return valid_; }
	bool is_valid() const { return valid_; }
	const TaskGraphDefinition &definition() const { return definition_; }
	const TaskGraphDefinition &canonical_definition() const { return definition_; }
	const TaskGraphDefinition &graph() const { return definition_; }
	const std::vector<CanonicalTaskNode> &nodes() const { return nodes_; }
	const std::vector<CanonicalTaskNode> &canonical_nodes() const { return nodes_; }
	const std::vector<CanonicalTaskEdge> &edges() const { return edges_; }
	const std::vector<CanonicalTaskEdge> &canonical_edges() const { return edges_; }
	const std::vector<std::uint32_t> &topological_order() const { return topological_order_; }
	const std::vector<std::uint32_t> &node_order() const { return topological_order_; }
	const std::vector<std::uint32_t> &terminal_node_indices() const { return terminal_node_indices_; }
	std::uint32_t entry_node_index() const { return entry_node_index_; }
	std::uint64_t fingerprint() const { return fingerprint_; }
	std::uint32_t work_units() const { return work_units_; }
	std::size_t node_count() const { return nodes_.size(); }
	std::size_t edge_count() const { return edges_.size(); }

	const CanonicalTaskNode *find_node(const std::string &p_identifier) const;
	const CanonicalTaskEdge *find_edge(const std::string &p_identifier) const;
	const CanonicalTaskNode &node(std::size_t p_index) const;
	const CanonicalTaskEdge &edge(std::size_t p_index) const;

	bool operator==(const CanonicalTaskGraph &p_other) const;
	bool operator!=(const CanonicalTaskGraph &p_other) const { return !(*this == p_other); }

private:
	friend class TaskGraphCompiler;

	TaskGraphDefinition definition_;
	std::vector<CanonicalTaskNode> nodes_;
	std::vector<CanonicalTaskEdge> edges_;
	std::vector<std::uint32_t> topological_order_;
	std::vector<std::uint32_t> terminal_node_indices_;
	std::uint32_t entry_node_index_ = 0;
	std::uint64_t fingerprint_ = INVALID_CATALOG_FINGERPRINT;
	std::uint32_t work_units_ = 0;
	bool valid_ = false;
};

using CompiledTaskGraph = CanonicalTaskGraph;
using TaskGraphCompilation = CanonicalTaskGraph;

struct TaskGraphCompileResult {
	Status status;
	std::shared_ptr<const CanonicalTaskGraph> graph;
	std::vector<Diagnostic> diagnostics;

	bool ok() const { return status.ok() && graph != nullptr && graph->valid(); }
};

// ---------------------------------------------------------------------------
// Graph compiler
// ---------------------------------------------------------------------------

class TaskGraphCompiler {
public:
	TaskGraphCompiler();
	explicit TaskGraphCompiler(const TaskGraphCompileOptions &p_options);
	TaskGraphCompiler(
			const TaskNodeRegistry &p_registry,
			const TaskGraphValidationHooks *p_hooks = nullptr,
			const TaskGraphCompileLimits &p_limits = TaskGraphCompileLimits{});

	const TaskGraphCompileOptions &options() const { return options_; }
	const TaskNodeRegistry &registry() const;

	Status validate(const TaskGraphDefinition &p_graph, std::vector<Diagnostic> *r_diagnostics = nullptr) const;

	Status compile(
			const TaskGraphDefinition &p_graph,
			CanonicalTaskGraph &r_compiled,
			std::vector<Diagnostic> *r_diagnostics = nullptr) const;
	Status compile_graph(
			const TaskGraphDefinition &p_graph,
			CanonicalTaskGraph &r_compiled,
			std::vector<Diagnostic> *r_diagnostics = nullptr) const {
		return compile(p_graph, r_compiled, r_diagnostics);
	}

	Status compile(
			const TaskGraphDefinition &p_graph,
			std::shared_ptr<const CanonicalTaskGraph> &r_compiled,
			std::vector<Diagnostic> *r_diagnostics = nullptr) const;

	TaskGraphCompileResult compile(const TaskGraphDefinition &p_graph) const;

private:
	TaskGraphCompileOptions options_;

	Status compile_internal(
			const TaskGraphDefinition &p_graph,
			CanonicalTaskGraph *r_compiled,
			std::vector<Diagnostic> *r_diagnostics,
			std::vector<std::string> &r_subgraph_stack,
			std::uint32_t p_depth) const;
};

using GraphCompiler = TaskGraphCompiler;

Status compile_task_graph(
		const TaskGraphDefinition &p_graph,
		CanonicalTaskGraph &r_compiled,
		const TaskGraphCompileOptions &p_options = TaskGraphCompileOptions{},
		std::vector<Diagnostic> *r_diagnostics = nullptr);

inline Status compile_graph(
		const TaskGraphDefinition &p_graph,
		CanonicalTaskGraph &r_compiled,
		const TaskGraphCompileOptions &p_options = TaskGraphCompileOptions{},
		std::vector<Diagnostic> *r_diagnostics = nullptr) {
	return compile_task_graph(p_graph, r_compiled, p_options, r_diagnostics);
}

Status validate_task_graph(
		const TaskGraphDefinition &p_graph,
		const TaskGraphCompileOptions &p_options = TaskGraphCompileOptions{},
		std::vector<Diagnostic> *r_diagnostics = nullptr);

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_GRAPH_COMPILER_H
