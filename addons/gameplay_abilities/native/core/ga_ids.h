#ifndef GAMEPLAY_ABILITIES_CORE_IDS_H
#define GAMEPLAY_ABILITIES_CORE_IDS_H

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// Two distinct identity concepts live in this file. Keep them separated:
//
//   1. Content identity (DefinitionId / IdentifierTable) is stable across
//      every peer because it is derived from an authored, namespaced
//      identifier string and assigned deterministically at seal() time.
//   2. Runtime identity (EntityId, AbilitySpecId, ...) is scoped and
//      monotonic. It is assigned by a session-local allocator and carries no
//      relationship to any definition, pointer, or allocation order.
namespace ga {

// ============================================================================
// 1. Content identity
// ============================================================================

using DefinitionId = std::uint32_t;
constexpr DefinitionId INVALID_DEFINITION_ID = 0;

// Interns validated namespaced identifiers (see ga_identifier.h) into dense,
// peer-reproducible ids.
//
// Ids are NOT assigned at `intern()` time -- registration order is an
// unspecified artifact of content load order and must never leak into the id
// space. Instead, `seal()` sorts every registered identifier by raw byte
// order (`ga::identifier_less`) and assigns ids 1..N in that order. Two
// tables built from the same set of identifiers, interned in any order on any
// peer, therefore assign identical ids to identical names and produce an
// identical `fingerprint()`.
class IdentifierTable {
public:
	// Validates `p_identifier` (see `validate_identifier`) and registers it.
	//
	// `r_id` is always set to `INVALID_DEFINITION_ID`: no id exists yet, since
	// ids are assigned only at `seal()` time (see class comment). Call
	// `lookup()`, `name_of()`, or `canonical_order()` after `seal()` to obtain
	// the definitive id.
	//
	// Fails with:
	//   - the identifier grammar's own `Status` if `p_identifier` is invalid.
	//   - `StatusCode::DUPLICATE_DEFINITION` / `DiagnosticId::DEFINITION_DUPLICATE`,
	//     `detail == 0`, if this exact identifier was already interned.
	//   - `StatusCode::DUPLICATE_DEFINITION` / `DiagnosticId::DEFINITION_DUPLICATE`,
	//     `detail == <colliding FNV1a64 hash>`, if a DIFFERENT already-interned
	//     identifier happens to share `p_identifier`'s content hash. This
	//     addon's status enum has no dedicated hash-collision code, so the
	//     collision is distinguished only by `detail`; the table never
	//     silently favors one identifier over the other in this case.
	//   - `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	Status intern(const std::string &p_identifier, DefinitionId &r_id);

	// The identifier's assigned id, or `INVALID_DEFINITION_ID` if the table
	// is not sealed yet or the name was never registered.
	DefinitionId lookup(const std::string &p_identifier) const;

	// The registered name for `p_id`, or nullptr if unknown or the table is
	// not sealed yet.
	const std::string *name_of(DefinitionId p_id) const;

	// Every assigned id, sorted by identifier byte order (NOT insertion or
	// hash order). Empty before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	bool sealed() const { return is_sealed; }

	// Assigns dense ids 1..N to every registered identifier in ascending
	// byte order (see class comment). A second call fails with
	// `StatusCode::REGISTRY_SEALED`.
	Status seal();

	// FNV1a64 over the canonical sorted (identifier, assigned id) pairs.
	// Meaningful only after `seal()` -- before that every id is still 0.
	std::uint64_t fingerprint() const;

private:
	std::map<std::string, DefinitionId> entries;
	std::map<std::uint64_t, std::string> hash_index;
	std::vector<std::string> id_to_name; // index 0 unused; valid after seal()
	bool is_sealed = false;
};

// ============================================================================
// 2. Runtime identity
// ============================================================================
//
// Godot's `ObjectID`, `RID`, node paths, resource UIDs, and raw memory
// addresses must NEVER be used as, or converted into, any identity below.
// They are per-process artifacts of allocation order and would silently
// break replication, snapshots, and reconciliation the moment two peers (or
// two runs on the same peer) allocated engine objects in a different order.
// The godot adapter layer resolves these ids to/from engine objects at the
// boundary; core and protocol only ever see the value types below.

// A phantom-tagged handle so `EntityId` and `AbilitySpecId` (etc.) are
// distinct C++ types that cannot be assigned or compared to one another,
// while sharing one implementation instead of ten hand-duplicated structs.
template <typename Tag>
struct Handle {
	std::uint64_t value = 0;

	constexpr explicit operator bool() const { return value != 0; }
	bool operator==(const Handle &p_other) const { return value == p_other.value; }
	bool operator!=(const Handle &p_other) const { return value != p_other.value; }
	bool operator<(const Handle &p_other) const { return value < p_other.value; }
};

struct EntityIdTag {};
struct AbilitySpecIdTag {};
struct EffectHandleTag {};
struct ExecutionIdTag {};
struct CommandSeqTag {};
struct EventSeqTag {};
struct PredictionKeyTag {};
struct TransactionIdTag {};
struct SourceTokenTag {};
struct GameplayEventIdTag {};
struct AbilityTaskHandleTag {};
struct TargetSessionIdTag {};
struct TargetBatchIdTag {};

using EntityId = Handle<EntityIdTag>; // A networked component's authority-assigned identity.
using AbilitySpecId = Handle<AbilitySpecIdTag>; // A granted ability on one component.
using EffectHandle = Handle<EffectHandleTag>; // An active duration/infinite effect instance.
using ExecutionId = Handle<ExecutionIdTag>; // One in-flight ability activation.
using CommandSeq = Handle<CommandSeqTag>; // Per-component client->server command ordering.
using EventSeq = Handle<EventSeqTag>; // Per-component authoritative event stream ordering.
using PredictionKey = Handle<PredictionKeyTag>; // Ties a predicted command to its journal entry.
using TransactionId = Handle<TransactionIdTag>; // One committed (or rolled back) mutation transaction.
using SourceToken = Handle<SourceTokenTag>; // Ref-counted ownership token for tags/effects.
using GameplayEventId = Handle<GameplayEventIdTag>; // One logical gameplay event (cue/notification) instance.
using AbilityTaskHandle = Handle<AbilityTaskHandleTag>; // One execution-owned deterministic ability task.
using TargetSessionId = Handle<TargetSessionIdTag>; // One execution-owned target-acquisition session.
using TargetBatchId = Handle<TargetBatchIdTag>; // One prepared cross-component target application.

constexpr EntityId INVALID_ENTITY_ID{ 0 };
constexpr AbilitySpecId INVALID_ABILITY_SPEC_ID{ 0 };
constexpr EffectHandle INVALID_EFFECT_HANDLE{ 0 };
constexpr ExecutionId INVALID_EXECUTION_ID{ 0 };
constexpr CommandSeq INVALID_COMMAND_SEQ{ 0 };
constexpr EventSeq INVALID_EVENT_SEQ{ 0 };
constexpr PredictionKey INVALID_PREDICTION_KEY{ 0 };
constexpr TransactionId INVALID_TRANSACTION_ID{ 0 };
constexpr SourceToken INVALID_SOURCE_TOKEN{ 0 };
constexpr GameplayEventId INVALID_GAMEPLAY_EVENT_ID{ 0 };
constexpr AbilityTaskHandle INVALID_ABILITY_TASK_HANDLE{ 0 };
constexpr TargetSessionId INVALID_TARGET_SESSION_ID{ 0 };
constexpr TargetBatchId INVALID_TARGET_BATCH_ID{ 0 };

// Monotonic allocator shared by every handle type above via one template
// (one instance per scope, e.g. one `HandleAllocator<EffectHandle>` per
// component). Allocation starts at 1 so 0 stays reserved for INVALID_*.
template <class T>
class HandleAllocator {
public:
	T allocate() {
		++next;
		return T{ next };
	}

	std::uint64_t next_raw() const { return next; }

	// Restores the counter from a snapshot. Rejects a value that would move
	// the counter backwards (which would risk re-issuing a handle already
	// held by live runtime state) with `StatusCode::INVALID_ARGUMENT` /
	// `DiagnosticId::SEQUENCE_OUT_OF_ORDER`.
	Status restore_from(std::uint64_t p_raw) {
		if (p_raw < next) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_raw);
		}
		next = p_raw;
		return ok_status();
	}

	// Canonical snapshot/reconciliation replacement. The caller must first
	// validate that `p_raw` is at least every live handle encoded in the same
	// snapshot. Unlike `restore_from`, this intentionally permits moving the
	// allocator backward: rolling back a rejected prediction must restore the
	// exact confirmed allocator epoch or replay would allocate different
	// handles. Runtime code must never use this as a general-purpose setter.
	void restore_exact(std::uint64_t p_raw) { next = p_raw; }

private:
	std::uint64_t next = 0;
};

// Canonical little-endian write/read/hash, shared by every handle type above
// via one template instead of ten hand-written copies.
template <class Tag>
void handle_write(ByteWriter &p_writer, Handle<Tag> p_value) {
	p_writer.write_u64(p_value.value);
}

template <class Tag>
bool handle_read(ByteReader &p_reader, Handle<Tag> &r_value) {
	return p_reader.read_u64(r_value.value);
}

template <class Tag>
void handle_hash(Hasher &p_hasher, Handle<Tag> p_value) {
	p_hasher.write_u64(p_value.value);
}

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_IDS_H
