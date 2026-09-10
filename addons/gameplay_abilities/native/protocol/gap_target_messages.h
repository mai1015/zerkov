#ifndef GAMEPLAY_ABILITIES_PROTOCOL_TARGET_MESSAGES_H
#define GAMEPLAY_ABILITIES_PROTOCOL_TARGET_MESSAGES_H

#include "core/ga_targeting.h"
#include "protocol/gap_command_gate.h"

#include <cstdint>
#include <vector>

namespace ga::proto {

constexpr std::uint16_t TARGET_MESSAGE_VERSION = 1;

struct TargetCommandDto {
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	TargetSessionId target_session = INVALID_TARGET_SESSION_ID;
	DefinitionId schema = INVALID_DEFINITION_ID;
	std::uint16_t schema_version = 0;
	TargetSessionCommandKind kind =
			TargetSessionCommandKind::SUBMIT;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	CommandSeq session_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	Tick issued_tick = 0;
	bool has_intent = false;
	TargetValue intent;
};

struct TargetOutcomeDto {
	TargetSessionEvent event;
	bool has_validated_data = false;
	CanonicalTargetIntent canonical_intent;
	TargetValue result;
	std::vector<TargetEntityOutcome> outcomes;
};

Status encode_target_command(const TargetCommandDto &p_command,
		const TargetSchemaRegistry &p_schemas,
		std::vector<std::uint8_t> &r_bytes);
Status decode_target_command(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchemaRegistry &p_schemas,
		TargetCommandDto &r_command);

Status encode_target_outcome(const TargetOutcomeDto &p_outcome,
		const TargetSchemaRegistry &p_schemas,
		TargetResultVisibility p_audience,
		std::vector<std::uint8_t> &r_bytes);
Status decode_target_outcome(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchemaRegistry &p_schemas,
		TargetOutcomeDto &r_outcome);

// Network choke point: authenticates the component owner and global command
// sequence/rate before the coordinator validates the live execution, task,
// target session, schema, per-session sequence, deadline, and intent.
Status admit_and_apply_target_command(
		const TargetCommandDto &p_command, PeerId p_peer,
		SessionId p_session, Tick p_authority_tick,
		const SessionTiming &p_timing, CommandGate &p_gate,
		CommandSequenceTracker &p_sequences,
		GameplayAbilityWorldCoordinator &p_coordinator,
		AbilityComponent &p_component,
		InboundCommandVerdict &r_verdict,
		TargetSessionCommandResult &r_result);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_TARGET_MESSAGES_H
