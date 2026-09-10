#ifndef INVENTORY_SYSTEM_CORE_STATUS_H
#define INVENTORY_SYSTEM_CORE_STATUS_H

#include <cstdint>

// Core operations return stable values rather than logging or throwing.
// Numeric values are append-only because results eventually cross persistence
// and protocol boundaries.
namespace inv {

enum class StatusCode : std::uint16_t {
	OK = 0,

	INVALID_ARGUMENT = 1,
	NOT_FOUND = 2,
	ALREADY_EXISTS = 3,
	OUT_OF_BOUNDS = 4,
	ARITHMETIC_ERROR = 5,
	LIMIT_EXCEEDED = 6,
	NOT_SUPPORTED = 7,
	INTERNAL_ERROR = 8,

	INVALID_IDENTIFIER = 20,
	DUPLICATE_DEFINITION = 21,
	UNKNOWN_DEFINITION = 22,
	INVALID_REFERENCE = 23,
	CATALOG_SEALED = 24,
	CATALOG_NOT_SEALED = 25,
	HASH_COLLISION = 26,
	DEPENDENCY_MISSING = 27,
	DEPENDENCY_CYCLE = 28,
	INCOMPATIBLE_DEFINITION = 29,

	MANIFEST_MISMATCH = 40,
	PROTOCOL_MISMATCH = 41,
	SCHEMA_MISMATCH = 42,
	FEATURE_UNSUPPORTED = 43,
	ENCODE_FAILED = 44,
	DECODE_FAILED = 45,
	PAYLOAD_TOO_LARGE = 46,

	REVISION_MISMATCH = 60,
	DUPLICATE_COMMAND = 61,
	PERMISSION_DENIED = 62,
	ROLE_VIOLATION = 63,
	INVARIANT_VIOLATION = 64,
	COMMAND_REJECTED = 65,
	SNAPSHOT_REQUIRED = 66,
	// Authenticated network gateway admission.  Values are append-only so
	// existing protocol/persistence status numbers remain stable.
	SESSION_NOT_READY = 67,
	RATE_LIMITED = 68,
};

enum class DiagnosticId : std::uint16_t {
	NONE = 0,

	IDENTIFIER_EMPTY_SEGMENT = 1,
	IDENTIFIER_BAD_CHARACTER = 2,
	IDENTIFIER_NOT_NAMESPACED = 3,
	IDENTIFIER_TOO_LONG = 4,
	IDENTIFIER_TOO_MANY_SEGMENTS = 5,
	SOURCE_LABEL_TOO_LONG = 6,

	DEFINITION_DUPLICATE = 20,
	DEFINITION_HASH_COLLISION = 21,
	DEFINITION_UNKNOWN_REFERENCE = 22,
	CATALOG_ALREADY_SEALED = 23,
	CATALOG_REQUIRES_SEAL = 24,
	SCHEMA_VERSION_UNSUPPORTED = 25,
	COUNT_LIMIT_EXCEEDED = 26,
	BYTE_LIMIT_EXCEEDED = 27,
	INVALID_ENUM = 28,
	VALUE_OUT_OF_RANGE = 29,
	OVERFLOW_DETECTED = 30,
	TRUNCATED_PAYLOAD = 31,

	FEATURE_DUPLICATE = 40,
	FEATURE_DEPENDENCY_MISSING = 41,
	FEATURE_DEPENDENCY_CYCLE = 42,
	FEATURE_PHASE_INVALID = 43,
	FEATURE_REQUIRED = 44,
	FEATURE_INCOMPATIBLE = 45,
	AUTHORITY_CALLBACK_FORBIDDEN = 46,

	LAYOUT_REQUIRED = 60,
	LAYOUT_INVALID = 61,
	GRID_DIMENSION_INVALID = 62,
	SLOT_DUPLICATE = 63,
	SLOT_CARDINALITY_INVALID = 64,
	LIST_CAPACITY_INVALID = 65,
	NESTING_CONFIGURATION_INVALID = 66,
	MASS_CAPACITY_INVALID = 67,
	STACK_LIMIT_INVALID = 68,
	ITEM_FOOTPRINT_INVALID = 69,
	TRAIT_DUPLICATE = 70,
	TRAIT_UNKNOWN = 71,
	TRAIT_VERSION_MISMATCH = 72,
	TRAIT_PAYLOAD_TOO_LARGE = 73,
	PROFILE_ROOT_MISSING = 74,
	PROFILE_LIMIT_INVALID = 75,
	ITEM_CONTAINER_MISSING = 76,

	MANIFEST_FINGERPRINT_DIFFERS = 90,
	PROTOCOL_VERSION_DIFFERS = 91,
	FEATURE_SET_UNSUPPORTED = 92,
	CANONICAL_ORDER_VIOLATION = 93,

	REVISION_STALE = 110,
	OWNERSHIP_DUPLICATE = 111,
	PLACEMENT_OVERLAP = 112,
	PLACEMENT_OUT_OF_BOUNDS = 113,
	CONTAINMENT_CYCLE = 114,
	NESTING_DEPTH_EXCEEDED = 115,

	ITEM_CONTAINER_CYCLE = 116,
	ITEM_CONTAINER_CHAIN_TOO_DEEP = 117,

	// Runtime-state mutation-primitive diagnostics (core/inv_runtime_state.*).
	FILTER_TRAIT_MISMATCH = 118, // Required/blocked trait filter rejected a placement (slot or container level).
	SLOT_UNKNOWN = 119, // Named-slot identifier is not declared on the target container definition.
	LIST_ORDINAL_INVALID = 120, // Ordered-list insertion ordinal is outside the current dense sequence.

	// Derived-query diagnostics (task 4.5: core/inv_runtime_state.* mass/
	// capacity queries).
	CAPACITY_FEATURE_UNAVAILABLE = 121, // Mass- or count-capacity query target lacks an explicit capacity, or the owning profile does not enable the matching inventory.feature.*_capacity module; the query reports this instead of inventing 0 or infinite.

	// Transaction-pipeline diagnostics (task 5.x: core/inv_transaction.*).
	ACCESS_DENIED = 122, // ContainerConstraints.access_mask lacks the INSERT/REMOVE/MOVE bit the transaction phase needed.
	MASS_CAPACITY_EXCEEDED = 123, // The destination container's projected mass would exceed its declared (feature-gated) mass capacity.
	STACK_DEFINITION_MISMATCH = 124, // MergeStacks named two items whose item_definition differs.
	IDEMPOTENCY_PAYLOAD_MISMATCH = 125, // A command_id was reused with a different canonical payload_fingerprint.

	// Multi-inventory transaction diagnostics (task 5.3-5.9: loot/transfer,
	// drop/settlement, auto-placement/quick-transfer, reference commands,
	// reentrant submission queueing).
	TRANSACTION_QUEUED = 126, // submit() was called reentrantly (from inside a notification) and the command was queued rather than executed immediately; StatusCode stays OK.
	IDENTITY_AUTHORITY_MISMATCH = 127, // A multi-inventory command named runtimes that do not share one IdentityAuthority (or one lacks an authority entirely).
	REVISION_COVERAGE_INVALID = 128, // CommandHeader::expected_revisions is not an exact bijection with the command's touched inventories (missing, extra, or duplicate entries).
	INVENTORY_NOT_IN_TRANSACTION_SET = 129, // A command named an InventoryId that is not among the runtimes passed to submit().
	RETENTION_NOT_ELIGIBLE = 130, // A SettleInventory RETAIN entry named an item whose current container's retention class is neither PROTECTED nor BOUND.
	SETTLEMENT_PLAN_INVALID = 131, // A SettleInventory plan is structurally invalid (empty, oversized, duplicate item, or an entry naming an unknown item).
	PLACEMENT_CANDIDATE_EXHAUSTED = 132, // AutoPlaceItem's documented candidate search found no fully-valid destination.
	QUICK_TRANSFER_INCOMPLETE = 133, // QuickTransferItem could not place the complete requested quantity and allow_partial was false.
	EXTERNAL_OWNER_INVALID = 134, // DropItem/SettleInventory RELEASE_TO named the invalid (zero) ExternalOwnerId.
	PENDING_QUEUE_FULL = 135, // A reentrant submission was rejected outright because the pipeline's queued-transaction bound was already reached.
	DUPLICATE_RESULT_REPLAY = 136, // An idempotency cache hit replayed a recorded accepted result; events are not re-emitted (detail = original event count). Matches the zerkov_v1 "duplicate_result_replay" outcome.

	// Session/protocol compatibility diagnostics (task 6.3:
	// protocol/inv_protocol_compat.*). Each names one axis of
	// compatibility.md's six-item session-compatibility list; the other three
	// axes (protocol version, required feature bits, manifest fingerprint)
	// reuse PROTOCOL_VERSION_DIFFERS/FEATURE_SET_UNSUPPORTED/
	// MANIFEST_FINGERPRINT_DIFFERS above rather than duplicating them here.
	SESSION_MASS_UNIT_MISMATCH = 137, // SessionHello::mass_unit differs between local and remote.
	SESSION_MANIFEST_ALGORITHM_MISMATCH = 138, // SessionHello::manifest_algorithm differs between local and remote.
	SESSION_LIMIT_DIGEST_MISMATCH = 139, // SessionHello::hard_limit_digest differs between local and remote.
	SESSION_IDENTIFIER_DIGEST_MISMATCH = 140, // SessionHello::identifier_dictionary_digest differs between local and remote.

	// Bounded-decoding diagnostics shared by every protocol/inv_protocol_
	// codec.* decoder (task 6.9; inventory-protocol spec, "Bounded Untrusted
	// Decoding": "trailing authority data MUST fail closed").
	TRAILING_PAYLOAD_BYTES = 141, // A decoded envelope left unconsumed bytes after every expected field was read.

	// Visibility-safe projection (task 6.7: protocol/inv_visibility.*;
	// core/inv_snapshot.cpp's restore()).
	VISIBILITY_RESTORE_REQUIRES_OWNER = 142, // restore() was given a snapshot whose `visibility` field is not OWNER (a projected/redacted snapshot is for encoding only, never for restoring canonical state).

	// Replica ordered-delta application (task 6.4: protocol/inv_replica.*).
	REPLICA_DUPLICATE_DELTA = 143, // InventoryReplica::apply_delta() was given a delta whose successor_revision <= the replica's last-applied revision; non-fatal, state unchanged.
	REPLICA_REVISION_GAP = 144, // InventoryReplica::apply_delta() was given a delta whose predecessor_revision is newer than the replica's last-applied revision (or the replica already needs a resync); needs_resync is set.
	REPLICA_IMPOSSIBLE_TRANSITION = 145, // InventoryReplica::apply_delta()'s predecessor_revision is older than the replica's last-applied revision without being a duplicate (successor_revision also newer), or every op/audit application onto the clone failed; needs_resync is set.

	// Persistence records and migrations (task 6.8: protocol/inv_persistence.*).
	PERSISTENCE_SCHEMA_VERSION_UNSUPPORTED = 146, // load_inventory()/MigrationChain::migrate_record() was given a persistence_schema_version this build does not recognize or cannot reach.
	PERSISTENCE_RECORD_HASH_MISMATCH = 147, // load_inventory() recomputed compute_persistence_record_hash() and it differs from the stored PersistenceRecord::record_hash.
	PERSISTENCE_RECORD_IDENTITY_MISMATCH = 148, // The decoded canonical_snapshot_bytes' own profile_identifier/inventory/revision disagree with the enclosing PersistenceRecord's matching fields.
	PERSISTENCE_MIGRATION_GAP = 149, // MigrationChain::migrate_record() found no registered N->N+1 step for the record's current version, or the requested target version cannot be reached (including a target older than the record's current version).

	// Authority-only prepared quantity reservations. These values are not
	// persisted or replicated; they coordinate exact consumption across
	// independently authoritative systems.
	RESERVATION_ID_INVALID = 150,
	RESERVATION_CONFLICT = 151,
	RESERVATION_INSUFFICIENT_QUANTITY = 152,
	RESERVATION_STATE_INVALID = 153,
	RESERVATION_SOURCE_POLICY_INVALID = 154,
	// inventory-transactions delta (tasks.md 8.11): expire()/teardown was
	// called before the reservation's caller-supplied deadline_tick has
	// elapsed. Distinct from RESERVATION_STATE_INVALID (a lifecycle-stage
	// error) -- this is purely a "not due yet" signal.
	RESERVATION_NOT_DUE = 155,

	// Optional staged container discovery. Discovery revisions and tasks are
	// session-scoped authority state, separate from canonical inventory
	// revisions (core/inv_discovery.*).
	DISCOVERY_POLICY_INVALID = 156,
	DISCOVERY_FEATURE_REQUIRED = 157,
	DISCOVERY_RECIPIENT_LIMIT = 158,
	DISCOVERY_RECIPIENT_UNKNOWN = 159,
	DISCOVERY_BUSY = 160,
	DISCOVERY_REVISION_STALE = 161,
	DISCOVERY_NOT_INDEXED = 162,
	DISCOVERY_TOKEN_INVALID = 163,
	DISCOVERY_TASK_NOT_FOUND = 164,
	DISCOVERY_ELAPSED_INVALID = 165,
	DISCOVERY_TARGET_STALE = 166,
	DISCOVERY_QUERY_REDACTED = 167,

	// Appended for component-safe stacking; stable existing diagnostic values
	// above remain unchanged.
	STACK_COMPONENT_MISMATCH = 168,
	STACK_PROVIDED_CONTAINER_UNSUPPORTED = 169,
	// Authority lifecycle operations are rejected while a synchronous signal
	// callback is executing, so callers cannot erase the runtime that owns the
	// currently-emitted payload.
	AUTHORITY_LIFECYCLE_BUSY = 170,

	// Authenticated inventory gateway diagnostics (Task 4.6).  These are
	// deliberately appended; earlier values are compatibility-sensitive.
	SESSION_UNKNOWN = 171,
	CONNECTION_EPOCH_MISMATCH = 172,
	AUTHORITY_EPOCH_MISMATCH = 173,
	ACTOR_MISMATCH = 174,
	COMMAND_NOT_ALLOWLISTED = 175,
	AUTHORITY_ONLY_COMMAND = 176,
	COMMAND_SEQUENCE_STALE = 177,
	COMMAND_SEQUENCE_CONFLICT = 178,
	GATEWAY_CALLBACK_MISSING = 179,
	GATEWAY_TOUCHED_SET_INVALID = 180,
	INVENTORY_ACCESS_DENIED = 181,
	OBSERVER_GRANT_MISSING = 182,
	RESYNC_IDENTITY_MISMATCH = 183,
	COMMAND_REPLAY_IN_FLIGHT = 184,
	OBSERVER_FEATURE_REQUIRED = 185,
	COMMAND_ID_ALLOCATOR_FAILED = 186,
	COMMAND_RATE_EXCEEDED = 187,
	RESYNC_RATE_EXCEEDED = 188,
	GATEWAY_REENTRANT = 189,
	SESSION_RETIRED = 190,
	SESSION_HELLO_REQUIRED = 191,
};

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

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_STATUS_H
