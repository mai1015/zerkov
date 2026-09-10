#ifndef GAMEPLAY_ABILITIES_CORE_STATUS_H
#define GAMEPLAY_ABILITIES_CORE_STATUS_H

#include <cstdint>

// The deterministic core never logs and never throws: it reports every refusal
// as a value so callers, replication, and tests observe the same reason on every
// peer. Enum values are additive — append, never renumber, because they cross
// the network boundary inside rejection results.
namespace ga {

enum class StatusCode : std::uint16_t {
	OK = 0,

	// Generic validation
	INVALID_ARGUMENT = 1,
	NOT_FOUND = 2,
	ALREADY_EXISTS = 3,
	OUT_OF_BOUNDS = 4,
	ARITHMETIC_ERROR = 5,
	CAPACITY_EXCEEDED = 6,
	NOT_SUPPORTED = 7,
	INTERNAL_ERROR = 8,

	// Registry / definitions
	INVALID_IDENTIFIER = 20,
	DUPLICATE_DEFINITION = 21,
	UNKNOWN_DEFINITION = 22,
	INVALID_REFERENCE = 23,
	REGISTRY_SEALED = 24,
	MANIFEST_MISMATCH = 25,

	// Tags
	UNKNOWN_TAG = 40,
	UNKNOWN_TAG_SOURCE = 41,
	TAG_COUNT_UNDERFLOW = 42,
	INVALID_QUERY = 43,

	// Attributes
	UNKNOWN_ATTRIBUTE = 60,
	INVALID_BOUNDS = 61,
	INSUFFICIENT_ATTRIBUTE = 62,
	UNKNOWN_MODIFIER = 63,

	// Effects
	UNKNOWN_EFFECT = 80,
	INVALID_EFFECT_SPEC = 81,
	EFFECT_REQUIREMENTS_FAILED = 82,
	EFFECT_IMMUNE = 83,
	EFFECT_STACK_REJECTED = 84,
	UNKNOWN_EFFECT_HANDLE = 85,
	MISSING_SET_BY_CALLER = 86,
	UNDECLARED_SET_BY_CALLER = 87,
	HOOK_FAILED = 88,

	// Abilities
	UNKNOWN_ABILITY = 100,
	ABILITY_NOT_GRANTED = 101,
	ABILITY_ALREADY_GRANTED = 102,
	ABILITY_ALREADY_ACTIVE = 103,
	ABILITY_MISSING_TAG = 104,
	ABILITY_BLOCKED_TAG = 105,
	ABILITY_ON_COOLDOWN = 106,
	ABILITY_COST_UNAFFORDABLE = 107,
	ABILITY_INVALID_TARGET = 108,
	ABILITY_ALREADY_ENDED = 109,
	ABILITY_REVOKED = 110,
	ABILITY_POLICY_VIOLATION = 111,
	RECURSION_LIMIT = 112,
	CAPABILITY_VIOLATION = 113,

	// Roles, authority, and networking
	ROLE_VIOLATION = 140,
	NOT_AUTHORITY = 141,
	NOT_OWNER = 142,
	PERMISSION_DENIED = 143,
	NETWORK_UNAVAILABLE = 144,
	PROTOCOL_MISMATCH = 145,
	SESSION_MISMATCH = 146,
	STALE_COMMAND = 147,
	DUPLICATE_COMMAND = 148,
	RATE_LIMITED = 149,
	SEQUENCE_GAP = 150,
	DECODE_FAILED = 151,
	PAYLOAD_TOO_LARGE = 152,
	SNAPSHOT_REQUIRED = 153,
	UNKNOWN_NETWORK_IDENTITY = 154,

	// Prediction
	PREDICTION_UNAVAILABLE = 180,
	PREDICTION_NOT_SAFE = 181,
	PREDICTION_REJECTED = 182,
	PREDICTION_JOURNAL_FULL = 183,
	PREDICTION_BASELINE_LOST = 184,
	PREDICTION_UNKNOWN_KEY = 185,

	// Ability tasks
	UNKNOWN_ABILITY_TASK = 200,
	ABILITY_TASK_ALREADY_TERMINAL = 201,
	INVALID_ABILITY_TASK = 202,
	ABILITY_TASK_TIMED_OUT = 203,
	ABILITY_TASK_CANCELLED = 204,
	ABILITY_TASK_INPUT_REJECTED = 205,

	// Typed targeting
	UNKNOWN_TARGET_SCHEMA = 220,
	INVALID_TARGET_DATA = 221,
	UNKNOWN_TARGET_SESSION = 222,
	TARGET_SESSION_ALREADY_TERMINAL = 223,
	TARGET_PROVIDER_REJECTED = 224,
	TARGET_BATCH_REJECTED = 225,
};

// A stable, bounded diagnostic identity. Diagnostics never carry untrusted
// client strings; presentation maps these to localized text.
enum class DiagnosticId : std::uint16_t {
	NONE = 0,
	IDENTIFIER_EMPTY_SEGMENT = 1,
	IDENTIFIER_BAD_CHARACTER = 2,
	IDENTIFIER_NOT_NAMESPACED = 3,
	IDENTIFIER_TOO_LONG = 4,
	IDENTIFIER_TOO_MANY_SEGMENTS = 5,
	DEFINITION_DUPLICATE = 6,
	DEFINITION_UNKNOWN_REFERENCE = 7,
	VALUE_NOT_REPRESENTABLE = 8,
	BOUNDS_INVERTED = 9,
	TICK_RATE_UNSUPPORTED = 10,
	QUERY_TOO_DEEP = 11,
	QUERY_TOO_MANY_OPERANDS = 12,
	COUNT_LIMIT_EXCEEDED = 13,
	BYTE_LIMIT_EXCEEDED = 14,
	TRUNCATED_PAYLOAD = 15,
	INVALID_ENUM = 16,
	MANIFEST_FINGERPRINT_DIFFERS = 17,
	PROTOCOL_VERSION_DIFFERS = 18,
	FEATURE_UNSUPPORTED = 19,
	OVERFLOW_DETECTED = 20,
	DIVIDE_BY_ZERO = 21,
	STACK_LIMIT_REACHED = 22,
	PERIOD_INVALID = 23,
	DURATION_INVALID = 24,
	HOOK_CAPABILITY_DENIED = 25,
	OWNER_FREED = 26,
	BASELINE_MISSING = 27,
	SEQUENCE_OUT_OF_ORDER = 28,
	TARGET_NOT_RELEVANT = 29,
	TARGET_RULE_REJECTED = 30,
	// Finding 4: a networked activation's `pending_remote_effects` (task
	// 6.13's accepted-but-not-locally-applicable remote-target hook
	// commands) came back non-empty from `GameplayAbilityNetworkBridge::
	// _rpc_activation_command`'s own `request_activation` call, but nothing
	// is connected to this bridge's `remote_effects_pending` signal to route
	// it anywhere -- the accepted command would otherwise be silently
	// dropped a second time (the FIRST drop this addon already closed: see
	// `AbilityDiagnosticKind::PENDING_REMOTE_EFFECT_DROPPED`'s own doc
	// comment, ga_ability_component.h -- that core-side diagnostic can never
	// fire from this call path because the Godot-facing `request_activation`
	// always supplies a real destination for the list). Paired with a
	// bounded `network_diagnostic` (never `PENDING_REMOTE_EFFECT_DROPPED`
	// itself, which is a DIFFERENT enum scoped to `native/godot/` only) so a
	// game missing this wiring has something to observe instead of gameplay
	// silently not happening.
	REMOTE_EFFECT_UNCONSUMED = 31,
	// Task 3.4 (add-global-tag-catalog-and-reactions-2026-07-25, "Model
	// reactions as immutable registered definitions" / design.md decision 5,
	// "Reject static cycles and bound dynamic chains"): `TagReactionRegistry::
	// seal` found a conservative dependency-graph cycle -- a reaction chain
	// whose target effects' granted tags can, through zero or more further
	// reactions, satisfy a reaction operand already on the chain, INCLUDING a
	// length-one self-loop (a reaction whose own target effect grants a tag
	// matching its own operand; see specs/gameplay-effects/spec.md "Reaction
	// effect grants its own trigger tag"). Paired with
	// `StatusCode::INVALID_REFERENCE`; see `TagReactionCycleConflict` for the
	// readable involved reaction/effect path (native/core/ga_tag_reactions.h).
	REACTION_CYCLE = 32,
	// Task 5.3 (add-global-tag-catalog-and-reactions-2026-07-25, "Godot
	// adapter, snapshots, and networking" / design.md decision 6, "Execute
	// only on authority and restore without replay"; specs/
	// gameplay-ability-networking/spec.md "Snapshot contains an invalid
	// reaction binding"): `AbilityComponent::restore_tag_reaction_bindings`
	// (native/core/ga_ability_component.h) rejected a restored `WHILE_PRESENT`
	// binding -- an unknown reaction identity, a reaction whose registered
	// mode is not `WHILE_PRESENT`, an effect handle `effects()` does not
	// recognize as active, or an active handle whose definition does not
	// match that reaction's own registered target effect. Paired with
	// `StatusCode::UNKNOWN_DEFINITION`/`UNKNOWN_EFFECT_HANDLE`/
	// `INVALID_REFERENCE` depending on which check failed; see that method's
	// own doc comment for the exact mapping. `detail` carries the offending
	// reaction id or effect handle value.
	INVALID_REACTION_BINDING = 33,
	INVALID_TASK_KIND = 34,
	INVALID_TASK_PAYLOAD = 35,
	TASK_PARENT_MISSING = 36,
	TASK_DEADLINE_INVALID = 37,
	TASK_SEQUENCE_REJECTED = 38,
	INVALID_TARGET_KIND = 39,
	INVALID_TARGET_SCHEMA = 40,
	INVALID_TARGET_COORDINATE = 41,
	INVALID_TARGET_PROVENANCE = 42,
	TARGET_PROVIDER_MISMATCH = 43,
	TARGET_SESSION_STALE = 44,
	TARGET_BATCH_ROLLED_BACK = 45,
	// design.md, "Cross-component application uses a prepared batch": the
	// coordinator serializes one prepared batch at a time per participating
	// authority world. `GameplayAbilityWorldCoordinator::prepare_batch`
	// returns this (paired with `StatusCode::CAPABILITY_VIOLATION`, mirroring
	// how `authority_provider_running` guards provider-hook re-entry) when a
	// previously prepared batch is still outstanding -- neither committed nor
	// discarded via `discard_batch` -- rather than preparing a second batch
	// against magnitudes that would be frozen against stale state by the
	// time the first one commits. See ga_targeting.h/.cpp.
	TARGET_BATCH_IN_FLIGHT = 46,
};

// Returned by every fallible core operation. `detail` carries the identifier,
// handle, or index the failure refers to so callers can build a bounded message
// without the core formatting strings.
struct Status {
	StatusCode code = StatusCode::OK;
	DiagnosticId diagnostic = DiagnosticId::NONE;
	std::uint64_t detail = 0;

	bool ok() const { return code == StatusCode::OK; }

	bool operator==(const Status &p_other) const {
		return code == p_other.code && diagnostic == p_other.diagnostic && detail == p_other.detail;
	}
	bool operator!=(const Status &p_other) const { return !(*this == p_other); }
};

inline Status ok_status() {
	return Status{};
}

inline Status make_status(StatusCode p_code, DiagnosticId p_diagnostic = DiagnosticId::NONE, std::uint64_t p_detail = 0) {
	return Status{ p_code, p_diagnostic, p_detail };
}

// Wire and snapshot decoders must reject numeric gaps between the additive
// enum ranges. Checking only `raw <= last_value` would admit unassigned
// values (for example StatusCode 9 or 114).
inline bool is_known_status_code(std::uint16_t p_raw) {
	switch (static_cast<StatusCode>(p_raw)) {
		case StatusCode::OK:
		case StatusCode::INVALID_ARGUMENT:
		case StatusCode::NOT_FOUND:
		case StatusCode::ALREADY_EXISTS:
		case StatusCode::OUT_OF_BOUNDS:
		case StatusCode::ARITHMETIC_ERROR:
		case StatusCode::CAPACITY_EXCEEDED:
		case StatusCode::NOT_SUPPORTED:
		case StatusCode::INTERNAL_ERROR:
		case StatusCode::INVALID_IDENTIFIER:
		case StatusCode::DUPLICATE_DEFINITION:
		case StatusCode::UNKNOWN_DEFINITION:
		case StatusCode::INVALID_REFERENCE:
		case StatusCode::REGISTRY_SEALED:
		case StatusCode::MANIFEST_MISMATCH:
		case StatusCode::UNKNOWN_TAG:
		case StatusCode::UNKNOWN_TAG_SOURCE:
		case StatusCode::TAG_COUNT_UNDERFLOW:
		case StatusCode::INVALID_QUERY:
		case StatusCode::UNKNOWN_ATTRIBUTE:
		case StatusCode::INVALID_BOUNDS:
		case StatusCode::INSUFFICIENT_ATTRIBUTE:
		case StatusCode::UNKNOWN_MODIFIER:
		case StatusCode::UNKNOWN_EFFECT:
		case StatusCode::INVALID_EFFECT_SPEC:
		case StatusCode::EFFECT_REQUIREMENTS_FAILED:
		case StatusCode::EFFECT_IMMUNE:
		case StatusCode::EFFECT_STACK_REJECTED:
		case StatusCode::UNKNOWN_EFFECT_HANDLE:
		case StatusCode::MISSING_SET_BY_CALLER:
		case StatusCode::UNDECLARED_SET_BY_CALLER:
		case StatusCode::HOOK_FAILED:
		case StatusCode::UNKNOWN_ABILITY:
		case StatusCode::ABILITY_NOT_GRANTED:
		case StatusCode::ABILITY_ALREADY_GRANTED:
		case StatusCode::ABILITY_ALREADY_ACTIVE:
		case StatusCode::ABILITY_MISSING_TAG:
		case StatusCode::ABILITY_BLOCKED_TAG:
		case StatusCode::ABILITY_ON_COOLDOWN:
		case StatusCode::ABILITY_COST_UNAFFORDABLE:
		case StatusCode::ABILITY_INVALID_TARGET:
		case StatusCode::ABILITY_ALREADY_ENDED:
		case StatusCode::ABILITY_REVOKED:
		case StatusCode::ABILITY_POLICY_VIOLATION:
		case StatusCode::RECURSION_LIMIT:
		case StatusCode::CAPABILITY_VIOLATION:
		case StatusCode::ROLE_VIOLATION:
		case StatusCode::NOT_AUTHORITY:
		case StatusCode::NOT_OWNER:
		case StatusCode::PERMISSION_DENIED:
		case StatusCode::NETWORK_UNAVAILABLE:
		case StatusCode::PROTOCOL_MISMATCH:
		case StatusCode::SESSION_MISMATCH:
		case StatusCode::STALE_COMMAND:
		case StatusCode::DUPLICATE_COMMAND:
		case StatusCode::RATE_LIMITED:
		case StatusCode::SEQUENCE_GAP:
		case StatusCode::DECODE_FAILED:
		case StatusCode::PAYLOAD_TOO_LARGE:
		case StatusCode::SNAPSHOT_REQUIRED:
		case StatusCode::UNKNOWN_NETWORK_IDENTITY:
		case StatusCode::PREDICTION_UNAVAILABLE:
		case StatusCode::PREDICTION_NOT_SAFE:
		case StatusCode::PREDICTION_REJECTED:
		case StatusCode::PREDICTION_JOURNAL_FULL:
		case StatusCode::PREDICTION_BASELINE_LOST:
		case StatusCode::PREDICTION_UNKNOWN_KEY:
		case StatusCode::UNKNOWN_ABILITY_TASK:
		case StatusCode::ABILITY_TASK_ALREADY_TERMINAL:
		case StatusCode::INVALID_ABILITY_TASK:
		case StatusCode::ABILITY_TASK_TIMED_OUT:
		case StatusCode::ABILITY_TASK_CANCELLED:
		case StatusCode::ABILITY_TASK_INPUT_REJECTED:
		case StatusCode::UNKNOWN_TARGET_SCHEMA:
		case StatusCode::INVALID_TARGET_DATA:
		case StatusCode::UNKNOWN_TARGET_SESSION:
		case StatusCode::TARGET_SESSION_ALREADY_TERMINAL:
		case StatusCode::TARGET_PROVIDER_REJECTED:
		case StatusCode::TARGET_BATCH_REJECTED:
			return true;
	}
	return false;
}

inline bool is_known_diagnostic_id(std::uint16_t p_raw) {
	switch (static_cast<DiagnosticId>(p_raw)) {
		case DiagnosticId::NONE:
		case DiagnosticId::IDENTIFIER_EMPTY_SEGMENT:
		case DiagnosticId::IDENTIFIER_BAD_CHARACTER:
		case DiagnosticId::IDENTIFIER_NOT_NAMESPACED:
		case DiagnosticId::IDENTIFIER_TOO_LONG:
		case DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS:
		case DiagnosticId::DEFINITION_DUPLICATE:
		case DiagnosticId::DEFINITION_UNKNOWN_REFERENCE:
		case DiagnosticId::VALUE_NOT_REPRESENTABLE:
		case DiagnosticId::BOUNDS_INVERTED:
		case DiagnosticId::TICK_RATE_UNSUPPORTED:
		case DiagnosticId::QUERY_TOO_DEEP:
		case DiagnosticId::QUERY_TOO_MANY_OPERANDS:
		case DiagnosticId::COUNT_LIMIT_EXCEEDED:
		case DiagnosticId::BYTE_LIMIT_EXCEEDED:
		case DiagnosticId::TRUNCATED_PAYLOAD:
		case DiagnosticId::INVALID_ENUM:
		case DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS:
		case DiagnosticId::PROTOCOL_VERSION_DIFFERS:
		case DiagnosticId::FEATURE_UNSUPPORTED:
		case DiagnosticId::OVERFLOW_DETECTED:
		case DiagnosticId::DIVIDE_BY_ZERO:
		case DiagnosticId::STACK_LIMIT_REACHED:
		case DiagnosticId::PERIOD_INVALID:
		case DiagnosticId::DURATION_INVALID:
		case DiagnosticId::HOOK_CAPABILITY_DENIED:
		case DiagnosticId::OWNER_FREED:
		case DiagnosticId::BASELINE_MISSING:
		case DiagnosticId::SEQUENCE_OUT_OF_ORDER:
		case DiagnosticId::TARGET_NOT_RELEVANT:
		case DiagnosticId::TARGET_RULE_REJECTED:
		case DiagnosticId::REMOTE_EFFECT_UNCONSUMED:
		case DiagnosticId::REACTION_CYCLE:
		case DiagnosticId::INVALID_REACTION_BINDING:
		case DiagnosticId::INVALID_TASK_KIND:
		case DiagnosticId::INVALID_TASK_PAYLOAD:
		case DiagnosticId::TASK_PARENT_MISSING:
		case DiagnosticId::TASK_DEADLINE_INVALID:
		case DiagnosticId::TASK_SEQUENCE_REJECTED:
		case DiagnosticId::INVALID_TARGET_KIND:
		case DiagnosticId::INVALID_TARGET_SCHEMA:
		case DiagnosticId::INVALID_TARGET_COORDINATE:
		case DiagnosticId::INVALID_TARGET_PROVENANCE:
		case DiagnosticId::TARGET_PROVIDER_MISMATCH:
		case DiagnosticId::TARGET_SESSION_STALE:
		case DiagnosticId::TARGET_BATCH_ROLLED_BACK:
		case DiagnosticId::TARGET_BATCH_IN_FLIGHT:
			return true;
	}
	return false;
}

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_STATUS_H
