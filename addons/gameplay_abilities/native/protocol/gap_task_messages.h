#ifndef GAMEPLAY_ABILITIES_PROTOCOL_TASK_MESSAGES_H
#define GAMEPLAY_ABILITIES_PROTOCOL_TASK_MESSAGES_H

#include "core/ga_ability_component.h"
#include "core/ga_ability_tasks.h"
#include "core/ga_bytes.h"
#include "core/ga_tick.h"
#include "protocol/gap_command_gate.h"

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace ga::proto {

// Body version for the additive task DTOs. The outer envelope still carries
// GA_PROTOCOL_VERSION; this value makes stored/replayed body fixtures
// independently reject an incompatible shape.
constexpr std::uint16_t TASK_MESSAGE_VERSION = 1;

struct TaskInputCommandDto {
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	AbilityTaskKind expected_kind = AbilityTaskKind::WAIT_LOGICAL_INPUT;
	DefinitionId logical_input = INVALID_DEFINITION_ID;
	LogicalInputPhase phase = LogicalInputPhase::PRESS;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	Tick issued_tick = 0;
};

// A role-filtered state entry used for owner snapshots, reconnect, and
// resynchronization. It is a value copy: no runtime container or callback is
// exposed to protocol callers.
struct TaskStateDto {
	ActiveAbilityTask task;
};

Status encode_task_input(const TaskInputCommandDto &p_command,
		std::vector<std::uint8_t> &r_bytes);
Status decode_task_input(const std::vector<std::uint8_t> &p_bytes,
		TaskInputCommandDto &r_command);

Status encode_task_states(const std::vector<TaskStateDto> &p_states,
		AbilityTaskVisibility p_max_visibility, std::vector<std::uint8_t> &r_bytes);
Status decode_task_states(const std::vector<std::uint8_t> &p_bytes,
		std::vector<TaskStateDto> &r_states);

// A whitelist observer-safe projection of one active task, carried in the
// public state feed's additive observable-task section
// (`GameplayAbilityNetworkBridge::encode_public_state`/`decode_public_state`,
// gated by `FeatureSet::OBSERVER_TASK_STATE` -- see ga_version.h). Spec
// "Observer-Safe Task Record Fields": `ActiveAbilityTask` also carries
// prediction keys, change provenance, `last_input_sequence`, and the full
// `AbilityTaskRequest` (tag queries, logical input identities, authority
// prediction keys, target schemas) -- none of that is a field on this
// struct, so none of it can ever be written to observer payload bytes by
// `encode_observer_task_section` no matter what the caller passes in.
//
// `ability_identifier` deliberately mirrors the public grant list's own
// representation (a resolved identifier string, the same one
// `GameplayAbilityComponent::get_grant` already exposes as
// `"ability_identifier"`) rather than a raw `DefinitionId`: this addon's
// `AbilityRegistry` is a core-owned, non-owning reference the protocol layer
// has no handle to, so identifier resolution can only happen where the
// registry actually lives (the Godot bridge's served component) -- and doing
// it that way means an observer correlates a task's owning ability against
// `public_state_updated`'s own `granted_abilities` list without a second,
// DefinitionId-keyed lookup, and hidden-ability suppression
// (`hidden_ability_identifiers`) applies identically to both lists. See
// `GameplayAbilityNetworkBridge::encode_public_state` for exactly where this
// is resolved (through the SAME per-spec grant lookup the grant-list section
// itself already uses) and where a hidden identifier causes the whole record
// to be omitted -- never encoded with a blanked identity, which would still
// telegraph "something is casting."
struct ObserverTaskRecord {
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	ExecutionId execution = INVALID_EXECUTION_ID;
	std::string ability_identifier;
	AbilityTaskKind kind = AbilityTaskKind::WAIT_TICKS;
	Tick start_tick = 0;
	// Authoritative deadline presence/tick -- `AbilityTaskRequest::has_deadline`/
	// `deadline_tick`, the tick this task times out at. Deliberately NOT
	// `ActiveAbilityTask::due_tick`, which is `AbilityTaskRuntime`'s internal
	// wakeup-scheduling detail for `WAIT_TICKS` (when the runtime next
	// rechecks the task), not a fact about the task's own authored deadline;
	// only a `WAIT_TICKS` task ever has a meaningful `due_tick` at all, while
	// `has_deadline`/`deadline_tick` apply uniformly across every task kind.
	bool has_deadline = false;
	Tick deadline_tick = 0; // meaningful only when has_deadline is true; 0 otherwise
};

// Encodes `p_records` -- already selected for `OBSERVABLE` visibility,
// authoritative provenance, and hidden-ability suppression by the caller
// (see `ObserverTaskRecord`'s own doc comment; this function trusts its
// input's selection and does not re-derive it) -- as an additive section
// appended directly to `p_writer`: a bare count-prefixed record list with no
// message header or version field of its own, matching
// `GameplayAbilityNetworkBridge::encode_public_state`'s existing flat style
// for its attribute/tag/ability sections (compatibility for this section is
// gated at the handshake by `FeatureSet::OBSERVER_TASK_STATE`, per the
// protocol-2 precedent -- not by a per-section version tag). Sorted
// ascending by task handle before writing, so repeated encodes of the same
// input are byte-identical regardless of the caller's own iteration order
// (matching `encode_task_states`'s own canonical-ordering convention). Fails
// if `p_records.size()` exceeds `MAX_ACTIVE_ABILITY_TASKS`, or if any record
// is missing a required identity field (`task`, `execution`, or
// `ability_identifier`) or names an out-of-range `kind`.
Status encode_observer_task_section(const std::vector<ObserverTaskRecord> &p_records, ByteWriter &p_writer);

// Selects and projects the subset of `p_tasks` eligible for the observable-
// task section, natively and testably (no Godot dependency), so the
// selection rule itself -- not just the byte codec -- is directly covered
// by native tests. Two filters, in order:
//   1. `ga::task_visible_to(task.request.visibility, AbilityTaskVisibility::OBSERVABLE)`
//      -- the SAME shared audience filter every other task-state encoder
//      uses (ga_ability_tasks.h); `OWNER_ONLY`/`INTERNAL` tasks never reach
//      `p_resolve_ability_identifier` at all.
//   2. `task.provenance == ChangeProvenance::AUTHORITATIVE` -- a defensive
//      check. `encode_public_state` (the only caller) runs only on
//      authority (`push_full_state` returns early for `ROLE_NETWORK_CLIENT`),
//      so this should already be true of every candidate; it is enforced
//      HERE too so a predicted, unconfirmed task structurally can never
//      reach an observer even if that call-site guarantee ever regressed
//      (spec "Predicted task is not shown to observers").
// `p_resolve_ability_identifier` is called only for a task that survives
// both filters above; it must resolve `task`'s owning ability to the SAME
// identifier string the public grant list uses (see `ObserverTaskRecord`'s
// own doc comment on why a string, not a `DefinitionId`) and return whether
// the record should proceed at all -- `false` (an unresolvable OR
// hidden-ability-filtered identifier) OMITS that task's record entirely,
// never with a blanked identity. Passing an empty/unset callable admits no
// records. Output is unsorted and not yet validated for wire encoding --
// pass it to `encode_observer_task_section` for that.
void select_observer_task_records(const std::vector<ActiveAbilityTask> &p_tasks,
		const std::function<bool(const ActiveAbilityTask &, std::string &)> &p_resolve_ability_identifier,
		std::vector<ObserverTaskRecord> &r_records);

// Decodes a section `encode_observer_task_section` wrote. Reads directly
// from `p_reader`'s current cursor and leaves any bytes beyond this section
// for the caller (there is no section-local version tag or trailing-byte
// check here -- see the encoder's own doc comment); the caller decides
// whether more sections follow. Fails closed -- `r_records` is only ever
// populated on a fully valid decode, matching "no partial task section
// reaches the public state consumer" -- on: a count beyond
// `MAX_ACTIVE_ABILITY_TASKS`; a non-ascending or repeated task handle (the
// same canonical-ordering contract `decode_task_states` enforces); an
// out-of-range `kind`; or a missing/empty `ability_identifier`.
Status decode_observer_task_section(ByteReader &p_reader, std::vector<ObserverTaskRecord> &r_records);

// Runs the ordinary inbound-command choke point first, then validates the
// command against the live execution/task identity and finally advances the
// task through AbilityComponent's normal deterministic path. Duplicate
// commands replay their cached result and never invoke the task callback.
Status admit_and_apply_task_input(const TaskInputCommandDto &p_command,
		PeerId p_peer, SessionId p_session, Tick p_authority_tick,
		const SessionTiming &p_timing, CommandGate &p_gate,
		CommandSequenceTracker &p_sequences, AbilityComponent &p_component,
		InboundCommandVerdict &r_verdict, AbilityTaskTransitionResult &r_result);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_TASK_MESSAGES_H
