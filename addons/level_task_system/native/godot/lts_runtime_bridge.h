#ifndef LEVEL_TASK_SYSTEM_GODOT_RUNTIME_BRIDGE_H
#define LEVEL_TASK_SYSTEM_GODOT_RUNTIME_BRIDGE_H

// A deliberately small Godot-facing owner for the engine-independent task
// and conversation runtimes.  This class is an editor/simulator façade only:
// it copies closed Dictionary data into native values, owns at most one task
// instance and one conversation instance, and never resolves a Node, scene,
// authority, provider callback, or live game object.

#include "core/lts_conversation_runtime.h"
#include "core/lts_graph_compiler.h"
#include "core/lts_task_runtime.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace godot {

// `LevelTaskRuntimeBridge` is intentionally stateful so an editor drawer can
// keep a simulator session without exposing native C++ objects to GDScript.
// Every mutating method returns a bounded result Dictionary with `ok`,
// `code`, `diagnostic`, and `detail`, plus a deterministic summary/trace.
class LevelTaskRuntimeBridge : public RefCounted {
	GDCLASS(LevelTaskRuntimeBridge, RefCounted)

public:
	LevelTaskRuntimeBridge() = default;
	~LevelTaskRuntimeBridge() override = default;

	// -- Task graph compilation and isolated simulation ---------------------
	Dictionary compile_task_graph(const Dictionary &p_definition);
	Dictionary start_task_graph(
			const Dictionary &p_definition,
			const String &p_instance_identifier = String(),
			const String &p_scope_key = String(),
			const Dictionary &p_facts = Dictionary());
	Dictionary set_task_facts(const Dictionary &p_facts);
	Dictionary set_synthetic_facts(const Dictionary &p_facts) { return set_task_facts(p_facts); }
	Dictionary inject_task_event(const Dictionary &p_event);
	Dictionary inject_event(const Dictionary &p_event) { return inject_task_event(p_event); }
	Dictionary step_task(int64_t p_tick = -1);
	Dictionary run_task(int64_t p_max_steps = 64);
	Dictionary acknowledge_task_request(
			const String &p_request_identifier,
			const String &p_outcome_identifier = String(),
			const Dictionary &p_response = Dictionary());
	Dictionary reject_task_request(const String &p_request_identifier, const Dictionary &p_response = Dictionary());
	Dictionary timeout_task_request(const String &p_request_identifier);
	Dictionary reset_task();
	Dictionary reset() { return reset_task(); }
	Dictionary get_task_summary() const;
	Array get_task_trace() const;

	// -- Conversation compilation and isolated chat preview -----------------
	Dictionary compile_conversation(const Dictionary &p_definition);
	Dictionary start_conversation(
			const Dictionary &p_definition,
			const String &p_instance_identifier = String(),
			const String &p_scope_identifier = String(),
			const Dictionary &p_facts = Dictionary(),
			const String &p_entry_label = String(),
			const String &p_task_integration_handle = String());
	Dictionary set_conversation_facts(const Dictionary &p_facts);
	Dictionary set_preview_facts(const Dictionary &p_facts) { return set_conversation_facts(p_facts); }
	Dictionary step_conversation(int64_t p_frame_revision = -1);
	Dictionary continue_conversation(int64_t p_frame_revision = -1) { return step_conversation(p_frame_revision); }
	Dictionary run_conversation(int64_t p_max_steps = 64);
	Dictionary select_conversation_choice(const String &p_choice_identifier, int64_t p_frame_revision = -1);
	Dictionary select_choice(const String &p_choice_identifier, int64_t p_frame_revision = -1) {
		return select_conversation_choice(p_choice_identifier, p_frame_revision);
	}
	Dictionary acknowledge_conversation_action(
			const String &p_request_identifier,
			bool p_success,
			const Dictionary &p_response = Dictionary());
	Dictionary reject_conversation_action(const String &p_request_identifier);
	Dictionary timeout_conversation_action(const String &p_request_identifier);
	Dictionary restart_conversation(const String &p_entry_label = String());
	Dictionary restart(const String &p_entry_label = String()) { return restart_conversation(p_entry_label); }
	Dictionary get_conversation_summary() const;
	Array get_conversation_trace() const;

	// Read-only aliases make the bridge convenient for a generic simulator
	// drawer without introducing a second mutable state store.
	Dictionary task_summary() const { return get_task_summary(); }
	Array task_trace() const { return get_task_trace(); }
	Dictionary conversation_summary() const { return get_conversation_summary(); }
	Array conversation_trace() const { return get_conversation_trace(); }

protected:
	static void _bind_methods();

private:
	struct ConversationTraceEntry {
		std::uint64_t revision = 0;
		std::uint32_t ordinal = 0;
		std::string kind;
		std::string step_identifier;
		std::string choice_identifier;
		std::string outcome_identifier;
		std::string request_identifier;
	};

	std::shared_ptr<const lts::CanonicalTaskGraph> task_graph;
	std::unique_ptr<lts::TaskGraphInstance> task_instance;
	lts::TaskRuntimeLimits task_limits;
	lts::TaskFactSnapshot task_facts;
	std::vector<lts::TaskEvent> task_event_queue;
	std::string task_instance_identifier;
	std::string task_scope_key;
	std::uint64_t task_tick = 0;
	bool task_has_tick = false;

	lts::ConversationDefinition conversation_definition;
	bool conversation_configured = false;
	std::unique_ptr<lts::ConversationInstance> conversation_instance;
	lts::ConversationFactSnapshot conversation_facts;
	std::string conversation_instance_identifier;
	std::string conversation_scope_identifier;
	std::string conversation_entry_label;
	std::string conversation_task_integration_handle;
	std::vector<ConversationTraceEntry> conversation_trace_entries;
	bool conversation_trace_truncated = false;

	static Dictionary status_dictionary(const lts::Status &p_status);
	static Dictionary failure_result(const lts::Status &p_status);

	Dictionary task_result(const lts::TaskAdvanceResult &p_result) const;
	Dictionary task_summary_for(const lts::TaskGraphInstance *p_instance) const;
	Dictionary conversation_result(const lts::Status &p_status) const;
	Dictionary conversation_summary_for(const lts::ConversationInstance *p_instance) const;

	void append_conversation_trace(
			const char *p_kind,
			const std::string &p_step_identifier = std::string(),
			const std::string &p_choice_identifier = std::string(),
			const std::string &p_outcome_identifier = std::string(),
			const std::string &p_request_identifier = std::string());
	void clear_conversation_trace();
};

using LtsRuntimeBridge = LevelTaskRuntimeBridge;

} // namespace godot

#endif // LEVEL_TASK_SYSTEM_GODOT_RUNTIME_BRIDGE_H
