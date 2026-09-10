#ifndef INVENTORY_SYSTEM_PROTOCOL_PERSISTENCE_H
#define INVENTORY_SYSTEM_PROTOCOL_PERSISTENCE_H

#include "core/inv_catalog.h"
#include "core/inv_identity_authority.h"
#include "core/inv_ids.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"
#include "protocol/inv_protocol_types.h"

#include <cstdint>
#include <map>

// Versioned persistence records and migrations (tasks.md 6.8; inventory-
// protocol spec, "Versioned Persistence Records"; docs/inventory/
// compatibility.md "Persistence compatibility"). No database, save slot,
// encryption, compression, or account ownership is chosen here -- those
// remain game-owned (design.md "Authority, protocol, and persistence").
// PersistenceAdapter is a pure interface; InMemoryPersistenceAdapter is a
// reference/test implementation only.
namespace inv::protocol {

// Pure storage-boundary interface. store()/load() take/return an ALREADY
// canonically-encoded-inside PersistenceRecord (see protocol/
// inv_protocol_types.h's PersistenceRecord::canonical_snapshot_bytes doc
// comment) -- an adapter never re-derives or re-validates the embedded
// snapshot bytes itself; that is make_persistence_record()'s/
// load_inventory()'s job, both below. A real adapter's store() commits at
// its OWN storage boundary atomically (inventory-protocol spec: "Persistence
// adapters MUST write atomically at their storage boundary"); a game-owned
// commit failure is reported back through this Status, never silently
// swallowed or retried here.
struct PersistenceAdapter {
	virtual ~PersistenceAdapter() = default;
	virtual Status store(const PersistenceRecord &p_record) = 0;
	virtual Status load(InventoryId p_inventory, PersistenceRecord &r_record) = 0;
};

// Reference/test-only in-memory adapter (no database chosen; see file
// comment). Keyed by PersistenceRecord::inventory; store() overwrites any
// existing record for that inventory (matches a real adapter's "latest
// revision wins" save-slot semantics), load() reports NOT_FOUND for an
// unknown inventory.
class InMemoryPersistenceAdapter : public PersistenceAdapter {
public:
	Status store(const PersistenceRecord &p_record) override;
	Status load(InventoryId p_inventory, PersistenceRecord &r_record) override;

private:
	std::map<InventoryId, PersistenceRecord> records_;
};

// Builds a complete, hashed PersistenceRecord for p_runtime's CURRENT
// canonical state (always VisibilityScope::OWNER -- persistence stores
// canonical truth; redaction is a wire/observer concern handled by protocol/
// inv_visibility.h, never a storage concern). p_catalog must be sealed.
Status make_persistence_record(const DefinitionCatalog &p_catalog, const InventoryRuntime &p_runtime, PersistenceRecord &r_record);

// Validates p_record completely (schema version, manifest algorithm/
// fingerprint, record_hash, decoded snapshot's own identity fields agreeing
// with the record's) and, only if every check passes, decodes and installs
// it atomically via core::restore() (inventory-protocol spec: "A load
// either validates/migrates the complete record and atomically replaces
// covered state, or changes nothing"). p_authority behaves exactly like
// core::restore()'s parameter of the same name. On ANY failure r_runtime is
// left completely untouched.
Status load_inventory(const DefinitionCatalog &p_catalog, const PersistenceRecord &p_record, IdentityAuthority *p_authority, InventoryRuntime &r_runtime);

// Explicit N -> N+1 value transformation (compatibility.md: "Migration
// functions are explicit N -> N+1 value transformations with golden
// input/output fixtures"). A conforming implementation validates
// p_record.persistence_schema_version equals its own declared N before
// touching anything, advances it to N+1 on success, and refreshes
// p_record.record_hash (compute_persistence_record_hash()) to match its own
// transformed content -- migrate_record() below does not do this for it.
using MigrationFn = Status (*)(PersistenceRecord &p_record);

// Registered N -> N+1 migration steps (compatibility.md: "Skipped versions
// run a reviewed chain"). The CURRENT real schema is PERSISTENCE_SCHEMA_
// VERSION (1); this slice ships no real migration (there is nothing to
// migrate FROM yet) -- see native/tests/inv_test_persistence.cpp for a
// TEST-ONLY synthetic 1->2 registration proving chain mechanics without
// bumping the real constant.
class MigrationChain {
public:
	// Registers p_fn as the step from p_from_version to p_from_version + 1.
	// Rejects a second registration for the same p_from_version (a chain has
	// exactly one step per version) and a null p_fn.
	Status register_migration(std::uint16_t p_from_version, MigrationFn p_fn);

	// Runs the chain starting at p_record.persistence_schema_version,
	// applying each registered N->N+1 step in order until the version
	// equals p_target. A gap (no registered step for the CURRENT version
	// while short of p_target) is rejected before any step runs; p_target
	// older than the record's current version is rejected the same way (no
	// downgrade path). Every step must itself report success (see
	// MigrationFn's doc comment); the FIRST step failure aborts the whole
	// call and leaves r_record completely untouched -- migration only
	// touches r_record once the full chain to p_target has been proven
	// reachable and every step along it has actually succeeded on a working
	// copy.
	Status migrate_record(PersistenceRecord &r_record, std::uint16_t p_target) const;

private:
	std::map<std::uint16_t, MigrationFn> migrations_;
};

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_PERSISTENCE_H
