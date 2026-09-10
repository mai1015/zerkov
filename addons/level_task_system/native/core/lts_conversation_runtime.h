#ifndef LEVEL_TASK_SYSTEM_CORE_CONVERSATION_RUNTIME_H
#define LEVEL_TASK_SYSTEM_CORE_CONVERSATION_RUNTIME_H

#include "core/lts_definitions.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"
#include "core/lts_values.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace lts {

// Conversation facts are a bounded host projection. This runtime-only bound
// mirrors the standalone task runtime's initial 256-entry fact ceiling while
// remaining independent of that task-graph implementation.
constexpr std::size_t MAX_CONVERSATION_FACTS = 256;

// The definition layer deliberately has no mutable fact store.  The runtime
// accepts this small, closed value projection from its host.  Fact entries are
// canonicalized by (provider, fact) and duplicate keys are rejected, making
// lookup independent of insertion order.
struct ConversationFact {
	std::string provider_identifier;
	std::string fact_identifier;
	Value value;

	Status validate() const;
	bool operator==(const ConversationFact &p_other) const {
		return provider_identifier == p_other.provider_identifier && fact_identifier == p_other.fact_identifier &&
				value == p_other.value;
	}
	bool operator!=(const ConversationFact &p_other) const { return !(*this == p_other); }
	bool operator<(const ConversationFact &p_other) const;
};

struct ConversationFactSnapshot {
	std::vector<ConversationFact> facts;

	Status add(const ConversationFact &p_fact);
	Status add_fact(const ConversationFact &p_fact) { return add(p_fact); }
	Status set(const ConversationFact &p_fact);
	Status set_fact(const ConversationFact &p_fact) { return set(p_fact); }
	Status upsert(const ConversationFact &p_fact) { return set(p_fact); }
	void clear() { facts.clear(); }
	std::size_t size() const { return facts.size(); }
	bool empty() const { return facts.empty(); }
	Status validate() const;
	Status validate_and_canonicalize();
	const Value *find(const std::string &p_provider_identifier, const std::string &p_fact_identifier) const;
	bool matches(const FactPredicate &p_predicate) const;
	Status evaluate(const FactPredicate &p_predicate, bool &r_matches) const;
	Status evaluate_all(const std::vector<FactPredicate> &p_predicates, bool &r_matches) const;
	bool operator==(const ConversationFactSnapshot &p_other) const { return facts == p_other.facts; }
	bool operator!=(const ConversationFactSnapshot &p_other) const { return !(*this == p_other); }
};

using ConversationFacts = ConversationFactSnapshot;
using ConversationFactValues = ConversationFactSnapshot;
using ConversationFactValue = ConversationFact;
using FactValue = ConversationFact;

Status validate_and_canonicalize(ConversationFact &r_fact);
Status validate_and_canonicalize(ConversationFactSnapshot &r_snapshot);

// A frame is a projection of the current definition/runtime state.  It has no
// renderer, Node, Object, input callback, or localized display text; the host
// resolves the keys and decides how/when to advance it.
enum class ConversationFrameKind : std::uint8_t {
	NONE = 0,
	LINE = 1,
	CHOICE = 2,
	EXTERNAL_ACTION = 3,
	OUTCOME = 4,
	ACTION_REQUEST = EXTERNAL_ACTION,
	TERMINAL = OUTCOME,
};

struct ConversationChoiceFrame {
	std::string identifier;
	std::string label_key;

	Status validate() const;
	bool operator==(const ConversationChoiceFrame &p_other) const {
		return identifier == p_other.identifier && label_key == p_other.label_key;
	}
	bool operator!=(const ConversationChoiceFrame &p_other) const { return !(*this == p_other); }
};

// Stable, typed request emitted for an EXTERNAL_ACTION step.  The provider
// owns the meaning of `parameters`; this core never invokes it or retains a
// callable/object reference.
struct ConversationActionRequest {
	std::string request_identifier;
	std::string conversation_identifier;
	std::string instance_identifier;
	std::string scope_identifier;
	std::string step_identifier;
	std::string provider_identifier;
	std::uint64_t frame_revision = 0;
	std::vector<LocalizedParameter> parameters;

	Status validate() const;
	bool operator==(const ConversationActionRequest &p_other) const;
	bool operator!=(const ConversationActionRequest &p_other) const { return !(*this == p_other); }
};

using ExternalActionRequest = ConversationActionRequest;

// Frame fields intentionally remain usable for both timeline and chat-style
// hosts.  For a line, speaker/line_key/parameters are populated.  For a
// choice, choices contains only currently available choices.  For an action,
// action_request is populated and the host must acknowledge/reject/timeout
// it.  For an outcome, terminal is true and outcome_identifier is populated.
struct ConversationFrame {
	ConversationFrameKind kind = ConversationFrameKind::NONE;
	std::uint64_t revision = 0;
	std::string step_identifier;
	std::string speaker_identifier;
	std::string line_key;
	std::vector<LocalizedParameter> parameters;
	std::vector<ConversationChoiceFrame> choices;
	std::optional<ConversationActionRequest> action_request;
	std::string outcome_identifier;
	bool terminal = false;

	Status validate() const;
	bool is_line() const { return kind == ConversationFrameKind::LINE; }
	bool is_choice() const { return kind == ConversationFrameKind::CHOICE; }
	bool is_external_action() const { return kind == ConversationFrameKind::EXTERNAL_ACTION; }
	bool is_outcome() const { return kind == ConversationFrameKind::OUTCOME; }
	const std::string &localization_key() const { return line_key; }
};

enum class ConversationInstanceStatus : std::uint8_t {
	INACTIVE = 0,
	LINE = 1,
	CHOICE = 2,
	WAITING_FOR_ACTION = 3,
	TERMINAL = 4,
	WAITING_FOR_LINE = LINE,
	WAITING_FOR_CHOICE = CHOICE,
	ACTION_PENDING = WAITING_FOR_ACTION,
	COMPLETED = TERMINAL,
};

// ConversationInstance is deliberately value-based and engine-independent.
// A configured instance owns a canonical copy of its definition and all
// mutable progress.  Mutations use a temporary state and publish it only
// after complete validation and bounded traversal succeed.
class ConversationInstance {
public:
	ConversationInstance() = default;
	explicit ConversationInstance(const ConversationDefinition &p_definition) { configure(p_definition); }

	ConversationInstance(const ConversationInstance &) = default;
	ConversationInstance(ConversationInstance &&) noexcept = default;
	ConversationInstance &operator=(const ConversationInstance &) = default;
	ConversationInstance &operator=(ConversationInstance &&) noexcept = default;

	// Configure copies/canonicalizes a definition.  It is legal before a start
	// and resets any prior instance only after the new definition validates.
	Status configure(const ConversationDefinition &p_definition);
	Status set_definition(const ConversationDefinition &p_definition) { return configure(p_definition); }
	bool has_definition() const { return definition_valid_; }
	const ConversationDefinition &definition() const { return definition_; }
	std::uint64_t definition_fingerprint() const { return definition_fingerprint_; }

	// Start from the configured definition's entry label (or an explicit local
	// label). Instance/scope/handle identifiers are global stable IDs. The
	// optional task integration handle is opaque to this runtime and is carried
	// through snapshots for the task-graph bridge.
	Status start(
			const std::string &p_instance_identifier,
			const std::string &p_scope_identifier,
			const ConversationFactSnapshot &p_facts = ConversationFactSnapshot{},
			const std::string &p_entry_label = std::string(),
			const std::string &p_task_integration_handle = std::string());

	Status start(
			const ConversationDefinition &p_definition,
			const std::string &p_instance_identifier,
			const std::string &p_scope_identifier,
			const ConversationFactSnapshot &p_facts = ConversationFactSnapshot{},
			const std::string &p_entry_label = std::string(),
			const std::string &p_task_integration_handle = std::string());

	// Argument-order convenience for adapters that resolve a definition and
	// facts together. These wrappers are intentionally equivalent to start().
	Status start(
			const ConversationDefinition &p_definition,
			const ConversationFactSnapshot &p_facts,
			const std::string &p_instance_identifier,
			const std::string &p_scope_identifier,
			const std::string &p_entry_label = std::string(),
			const std::string &p_task_integration_handle = std::string()) {
		return start(p_definition, p_instance_identifier, p_scope_identifier, p_facts, p_entry_label,
				p_task_integration_handle);
	}

	Status begin(
			const std::string &p_instance_identifier,
			const std::string &p_scope_identifier,
			const ConversationFactSnapshot &p_facts = ConversationFactSnapshot{},
			const std::string &p_entry_label = std::string(),
			const std::string &p_task_integration_handle = std::string()) {
		return start(p_instance_identifier, p_scope_identifier, p_facts, p_entry_label, p_task_integration_handle);
	}

	bool started() const { return instance_status_ != ConversationInstanceStatus::INACTIVE; }
	bool active() const { return started() && !terminal(); }
	bool terminal() const { return instance_status_ == ConversationInstanceStatus::TERMINAL; }
	bool is_terminal() const { return terminal(); }
	bool waiting_for_choice() const { return instance_status_ == ConversationInstanceStatus::CHOICE; }
	bool waiting_for_action() const { return instance_status_ == ConversationInstanceStatus::WAITING_FOR_ACTION; }
	ConversationInstanceStatus status() const { return instance_status_; }
	ConversationInstanceStatus state() const { return status(); }
	std::uint64_t revision() const { return revision_; }
	std::uint64_t frame_revision() const { return frame_.revision; }
	const std::string &instance_identifier() const { return instance_identifier_; }
	const std::string &scope_identifier() const { return scope_identifier_; }
	const std::string &task_integration_handle() const { return task_integration_handle_; }
	const std::string &current_step_identifier() const { return current_step_identifier_; }
	const std::string &outcome_identifier() const { return terminal_outcome_identifier_; }
	const ConversationFactSnapshot &facts() const { return facts_; }

	const ConversationFrame &frame() const { return frame_; }
	const ConversationFrame &current_frame() const { return frame_; }
	const std::vector<ConversationChoiceFrame> &available_choices() const { return frame_.choices; }
	bool has_pending_request() const { return pending_request_.has_value(); }
	const ConversationActionRequest *pending_request() const {
		return pending_request_.has_value() ? &pending_request_.value() : nullptr;
	}
	const ConversationActionRequest *pending_action_request() const { return pending_request(); }

	// Update the fact snapshot used for all subsequent condition/choice
	// evaluation. A choice frame is rebuilt and receives a new revision, so a
	// choice obtained under the old facts cannot be submitted accidentally.
	Status set_facts(const ConversationFactSnapshot &p_facts);
	Status update_facts(const ConversationFactSnapshot &p_facts) { return set_facts(p_facts); }

	// A line is a yielded frame; advancing it does not require a renderer and
	// follows its authored next_step_identifier. The revision is mandatory for
	// stale-input rejection. The no-argument form is a local/single-owner
	// convenience and uses the current frame revision.
	Status continue_line(std::uint64_t p_frame_revision);
	Status continue_line() { return continue_line(frame_.revision); }
	Status advance_line(std::uint64_t p_frame_revision) { return continue_line(p_frame_revision); }
	Status advance_line() { return continue_line(); }
	Status continue_frame(std::uint64_t p_frame_revision) { return continue_line(p_frame_revision); }

	// A choice is accepted only when its identifier is in the currently exposed
	// choices and its revision exactly matches the yielded choice frame.
	Status select_choice(const std::string &p_choice_identifier, std::uint64_t p_frame_revision);
	Status select_choice(std::uint64_t p_frame_revision, const std::string &p_choice_identifier) {
		return select_choice(p_choice_identifier, p_frame_revision);
	}
	Status select_choice(const std::string &p_choice_identifier) { return select_choice(p_choice_identifier, frame_.revision); }
	Status choose(const std::string &p_choice_identifier, std::uint64_t p_frame_revision) {
		return select_choice(p_choice_identifier, p_frame_revision);
	}
	Status choose(const std::string &p_choice_identifier) { return select_choice(p_choice_identifier); }

	// Action acknowledgements are idempotent by request identifier. Reject and
	// timeout intentionally follow the authored failure edge because V1 action
	// definitions expose success/failure targets only. A response is validated
	// as a closed bounded Value but is otherwise owned by the provider adapter.
	Status acknowledge_action(
			const std::string &p_request_identifier,
			bool p_success,
			const Value &p_response = Value::none());
	Status acknowledge_action(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision,
			bool p_success,
			const Value &p_response = Value::none());
	Status acknowledge(const std::string &p_request_identifier, bool p_success, const Value &p_response = Value::none()) {
		return acknowledge_action(p_request_identifier, p_success, p_response);
	}
	Status acknowledge_request(const std::string &p_request_identifier, bool p_success, const Value &p_response = Value::none()) {
		return acknowledge_action(p_request_identifier, p_success, p_response);
	}
	Status reject_action(const std::string &p_request_identifier);
	Status reject_action(const std::string &p_request_identifier, std::uint64_t p_frame_revision);
	Status reject(const std::string &p_request_identifier) { return reject_action(p_request_identifier); }
	Status reject_request(const std::string &p_request_identifier) { return reject_action(p_request_identifier); }
	Status timeout_action(const std::string &p_request_identifier);
	Status timeout_action(const std::string &p_request_identifier, std::uint64_t p_frame_revision);
	Status timeout(const std::string &p_request_identifier) { return timeout_action(p_request_identifier); }
	Status timeout_request(const std::string &p_request_identifier) { return timeout_action(p_request_identifier); }

	// Snapshot encoding is a bounded little-endian V1 envelope. Decode always
	// validates into a temporary state, including definition fingerprint and
	// reconstructed frame, before replacing this instance.
	Status encode_snapshot(std::vector<std::uint8_t> &r_bytes) const;
	Status snapshot(std::vector<std::uint8_t> &r_bytes) const { return encode_snapshot(r_bytes); }
	Status save_snapshot(std::vector<std::uint8_t> &r_bytes) const { return encode_snapshot(r_bytes); }
	Status restore_snapshot(const std::vector<std::uint8_t> &p_bytes);
	Status restore(const std::vector<std::uint8_t> &p_bytes) { return restore_snapshot(p_bytes); }

	// Static convenience for a fresh owner. It is fail-atomic with respect to
	// the destination too: the destination is replaced only after definition
	// configuration, decode, compatibility, and frame reconstruction succeed.
	static Status restore_snapshot(
			const ConversationDefinition &p_definition,
			const std::vector<std::uint8_t> &p_bytes,
			ConversationInstance &r_instance);
	static Status from_snapshot(
			const ConversationDefinition &p_definition,
			const std::vector<std::uint8_t> &p_bytes,
			ConversationInstance &r_instance) {
		return restore_snapshot(p_definition, p_bytes, r_instance);
	}

private:
	struct ResolvedRequest {
		std::string request_identifier;
		std::uint8_t outcome = 0; // 1=success, 2=failure, 3=timeout.

		bool operator==(const ResolvedRequest &p_other) const {
			return request_identifier == p_other.request_identifier && outcome == p_other.outcome;
		}
	};

	struct RuntimeState {
		ConversationInstanceStatus instance_status = ConversationInstanceStatus::INACTIVE;
		std::uint64_t revision = 0;
		std::string instance_identifier;
		std::string scope_identifier;
		std::string task_integration_handle;
		std::string current_step_identifier;
		std::string terminal_outcome_identifier;
		ConversationFactSnapshot facts;
		ConversationFrame frame;
		std::optional<ConversationActionRequest> pending_request;
		std::vector<ResolvedRequest> resolved_requests;
	};

	ConversationDefinition definition_;
	std::uint64_t definition_fingerprint_ = INVALID_CATALOG_FINGERPRINT;
	bool definition_valid_ = false;

	ConversationInstanceStatus instance_status_ = ConversationInstanceStatus::INACTIVE;
	std::uint64_t revision_ = 0;
	std::string instance_identifier_;
	std::string scope_identifier_;
	std::string task_integration_handle_;
	std::string current_step_identifier_;
	std::string terminal_outcome_identifier_;
	ConversationFactSnapshot facts_;
	ConversationFrame frame_;
	std::optional<ConversationActionRequest> pending_request_;
	std::vector<ResolvedRequest> resolved_requests_;

	Status validate_runtime_definition(const ConversationDefinition &p_definition) const;
	Status start_with_definition(
			const ConversationDefinition &p_definition,
			const std::string &p_instance_identifier,
			const std::string &p_scope_identifier,
			const ConversationFactSnapshot &p_facts,
			const std::string &p_entry_label,
			const std::string &p_task_integration_handle);

	RuntimeState capture_state() const;
	void publish(const RuntimeState &p_state);
	Status process_until_yield(RuntimeState &r_state) const;
	Status process_until_yield_for_definition(const ConversationDefinition &p_definition, RuntimeState &r_state) const;
	Status build_frame_for_step(RuntimeState &r_state, const ConversationStepDefinition &p_step) const;
	Status rebuild_current_frame(RuntimeState &r_state) const;
	Status enter_next_step(RuntimeState &r_state, const std::string &p_step_identifier) const;
	Status advance_revision(RuntimeState &r_state) const;
	Status remember_resolved(RuntimeState &r_state, const std::string &p_request_identifier, std::uint8_t p_outcome) const;
	Status acknowledge_action_internal(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision,
			std::uint8_t p_outcome,
			const Value &p_response);
	Status validate_action_request_match(
			const RuntimeState &p_state,
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision,
			bool p_revision_supplied,
			std::uint8_t p_outcome) const;

	Status decode_snapshot(const std::vector<std::uint8_t> &p_bytes, RuntimeState &r_state) const;
};

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_CONVERSATION_RUNTIME_H
