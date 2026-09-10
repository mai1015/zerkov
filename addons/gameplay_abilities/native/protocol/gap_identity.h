#ifndef GAMEPLAY_ABILITIES_PROTOCOL_IDENTITY_H
#define GAMEPLAY_ABILITIES_PROTOCOL_IDENTITY_H

#include "core/ga_bytes.h"
#include "core/ga_ids.h"
#include "core/ga_status.h"

#include <cstdint>
#include <unordered_set>

// Stable Network Gameplay Identities.
//
// Godot's `ObjectID`, `RID`, node paths, memory addresses, allocation order,
// and local resource instance identity MUST NEVER be transmitted as, or
// derived into, an authoritative network identity. They are per-process
// artifacts of engine allocation order and would silently break replication,
// snapshots, and reconciliation the instant two peers -- or two runs on the
// same peer -- allocated engine objects in a different order. Every
// identity that crosses the wire is one of:
//   - a `ga::DefinitionId`, interned and sealed by a `ga::IdentifierTable`
//     from an authored namespaced identifier string (see ga_ids.h); or
//   - a scoped runtime `ga::Handle<Tag>` (`EntityId`, `AbilitySpecId`,
//     `EffectHandle`, `ExecutionId`, ...), assigned by a session-local
//     monotonic allocator with no relationship to any pointer or engine
//     allocation order.
// The godot adapter layer (native/godot/, out of scope here) is the only
// place engine object references are resolved to/from these values; core
// and protocol code never see an ObjectID/RID/NodePath.
//
// `SessionScope` is the structural enforcement point for the "Unknown
// network identity is received" scenario: decoding or validating an
// identity can only ever ask "is this currently live," never manufacture a
// new live entry for one it has not seen. There is no "get or create"
// method anywhere on this class, so a caller cannot accidentally implement
// implicit placeholder creation through this API even by mistake --
// registering a live identity requires a separate, explicit call from code
// that already created (or already knows of) the real object.
namespace ga::proto {

// Encodes/decodes a `ga::DefinitionId` (a plain uint32_t, not a
// `ga::Handle<Tag>`, so it has no existing wire helper in ga_ids.h). Every
// `ga::Handle<Tag>` runtime identity (EntityId, AbilitySpecId, EffectHandle,
// ExecutionId, CommandSeq, EventSeq, PredictionKey, ...) already has a
// generic wire encoding via `ga::handle_write`/`ga::handle_read` in
// ga_ids.h -- callers use those directly rather than a second wrapper here.
inline void write_definition_id(ByteWriter &p_writer, DefinitionId p_id) {
	p_writer.write_u32(p_id);
}

inline bool read_definition_id(ByteReader &p_reader, DefinitionId &r_id) {
	return p_reader.read_u32(r_id);
}

// Tracks which runtime identities are currently live for one session (one
// connected peer's view of the world it is allowed to reference) and
// validates a decoded identity against that set and against a sealed
// `ga::IdentifierTable`. Scope covers the identity kinds a decoded packet
// can name a *specific existing runtime object* by: entities, granted
// ability specs, active effect handles, and in-flight executions -- see the
// "Stable Network Gameplay Identities" requirement's "entity, definition, or
// runtime handle" wording. Monotonic per-component sequence numbers
// (`CommandSeq`, `EventSeq`) are validated by ordering rules owned by the
// command/event-stream code that consumes them (tasks 7.6-7.8), not
// membership in a set here; `PredictionKey`/`SourceToken`/`GameplayEventId`
// are owned by the prediction journal (task 8.x). Later agents needing
// scope tracking for those kinds should follow this same
// register-explicitly / validate-read-only pattern rather than inventing a
// second mechanism.
class SessionScope {
public:
	explicit SessionScope(const IdentifierTable *p_identifiers = nullptr) :
			identifiers(p_identifiers) {}

	// Rebinds the sealed identifier table this scope validates definitions
	// against (e.g. once the session's manifest handshake completes).
	void set_identifier_table(const IdentifierTable *p_identifiers) { identifiers = p_identifiers; }

	// Registration: called only by code that just created (or already
	// authoritatively knows of) the real object -- never by a decoder.
	void mark_entity_live(EntityId p_id) { entities.insert(p_id.value); }
	void mark_entity_retired(EntityId p_id) { entities.erase(p_id.value); }
	void mark_ability_spec_live(AbilitySpecId p_id) { ability_specs.insert(p_id.value); }
	void mark_ability_spec_retired(AbilitySpecId p_id) { ability_specs.erase(p_id.value); }
	void mark_effect_live(EffectHandle p_id) { effects.insert(p_id.value); }
	void mark_effect_retired(EffectHandle p_id) { effects.erase(p_id.value); }
	void mark_execution_live(ExecutionId p_id) { executions.insert(p_id.value); }
	void mark_execution_retired(ExecutionId p_id) { executions.erase(p_id.value); }

	// Validation: read-only membership tests. `ga::INVALID_*` (value == 0)
	// is never live in any scope, so it is always rejected here too.
	// Returns StatusCode::UNKNOWN_NETWORK_IDENTITY with `detail` set to the
	// rejected raw handle value on failure.
	Status validate_entity(EntityId p_id) const { return validate_in_set(entities, p_id.value); }
	Status validate_ability_spec(AbilitySpecId p_id) const { return validate_in_set(ability_specs, p_id.value); }
	Status validate_effect(EffectHandle p_id) const { return validate_in_set(effects, p_id.value); }
	Status validate_execution(ExecutionId p_id) const { return validate_in_set(executions, p_id.value); }

	// Validates a decoded `DefinitionId` against the bound `IdentifierTable`:
	// rejected (StatusCode::UNKNOWN_NETWORK_IDENTITY, detail = p_id) if no
	// table is bound, the table is not yet sealed (ids are meaningless
	// before `seal()` -- see ga_ids.h), `p_id == INVALID_DEFINITION_ID`, or
	// the table has no entry for `p_id`.
	Status validate_definition(DefinitionId p_id) const;

	std::size_t live_entity_count() const { return entities.size(); }
	std::size_t live_ability_spec_count() const { return ability_specs.size(); }
	std::size_t live_effect_count() const { return effects.size(); }
	std::size_t live_execution_count() const { return executions.size(); }

private:
	static Status validate_in_set(const std::unordered_set<std::uint64_t> &p_set, std::uint64_t p_value) {
		if (p_value == 0 || p_set.find(p_value) == p_set.end()) {
			return make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY, DiagnosticId::NONE, p_value);
		}
		return ok_status();
	}

	const IdentifierTable *identifiers = nullptr;
	std::unordered_set<std::uint64_t> entities;
	std::unordered_set<std::uint64_t> ability_specs;
	std::unordered_set<std::uint64_t> effects;
	std::unordered_set<std::uint64_t> executions;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_IDENTITY_H
