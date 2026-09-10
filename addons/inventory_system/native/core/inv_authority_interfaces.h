#ifndef INVENTORY_SYSTEM_CORE_AUTHORITY_INTERFACES_H
#define INVENTORY_SYSTEM_CORE_AUTHORITY_INTERFACES_H

#include "core/inv_commands.h"
#include "core/inv_status.h"

#include <cstdint>
#include <string>

// Game-owned, value-only authority interfaces (tasks.md 6.6; inventory-
// protocol spec, "Game-Owned Authority Permission": "Client-declared
// inventory ownership, node authority, external metric, protected-retention
// result, derived capacity, or resulting placement MUST NOT grant mutation
// permission or be trusted as authoritative output."). core/inv_transaction.h's
// existing PermissionProvider already follows this discipline (its check()
// takes only const CommandHeader&/Command& and returns a Status -- design.md:
// "It does not receive mutable internal containers"); this file extends the
// SAME documented boundary with one more game-owned interface rather than
// changing PermissionProvider's shape.
//
// COMPILE-TIME guarantee, not a runtime check: every virtual method below
// takes ONLY const references to already-decoded, already-bounded value
// types (CommandHeader) and writes its answer through an out-parameter --
// neither method's signature has any parameter capable of exposing or
// mutating InventoryRuntime, InventoryTransactionPipeline, or any other
// canonical core object. A malicious or buggy implementation cannot reach
// canonical storage through this interface no matter what it does inside
// its own method body, because nothing here ever hands it a pointer or
// reference to canonical storage in the first place. See
// native/tests/inv_test_authority_interfaces.cpp for the executable proof
// (a hostile implementation that captures a global pointer to canonical
// state still cannot MUTATE that state through anything this interface
// handed it) and for the companion proof that a client-computed final
// result (e.g. "my final mass is X") has no representable field anywhere in
// core/inv_commands.h's Command variant -- there is no such field to smuggle
// one through, by construction, not by a runtime rejection.
namespace inv {

// Stable, human-readable metric identifiers a game names when calling
// ExternalMetricProvider::fixed_value() (hashed with hash_string() at the
// call site -- core/inv_hash.h -- exactly like every other stable-string-to-
// u64 identity in this codebase, e.g. DiagnosticId detail fields). Not an
// exhaustive enum: a game may name any identifier its own adapter/policy
// understands; this one constant is the example the inventory-protocol spec
// calls out ("a Strength capacity bonus") and the one
// InventoryTransactionPipeline itself queries once per submission when an
// ExternalMetricProvider is configured (see core/inv_transaction.cpp).
inline const std::string EXTERNAL_METRIC_MASS_CAPACITY_BONUS = "inventory.metric.mass_capacity_bonus";

// Game-owned bounded fixed-value input (tasks.md 6.6). Supplied BY VALUE,
// resolved fresh before every submission's mutation phases -- never cached
// across commands and never trusted from the command itself (a client-
// declared final capacity/mass value has no representable field in
// core/inv_commands.h's Command variant; see this file's header comment).
// This slice plumbs and validates the call (a failing provider rejects the
// transaction cleanly BEFORE simulate()/mutation, exactly like
// PermissionProvider::check() failing); consuming the returned value in a
// V1 constraint (e.g. folding a Strength-derived capacity bonus into
// container_mass_capacity()'s check) is a later integration concern --
// design.md "Gameplay Abilities integration": "Capacity bonuses ... cross
// the boundary as versioned fixed-value projections coordinated by the
// authoritative game or adapter."
struct ExternalMetricProvider {
	virtual ~ExternalMetricProvider() = default;

	// p_metric_identifier_hash is fnv1a64 of a stable metric identifier
	// string (e.g. hash_string(EXTERNAL_METRIC_MASS_CAPACITY_BONUS)).
	// p_header is the already-decoded, already-bounded command header the
	// pipeline is currently processing (actor/expected-revisions identity
	// only -- never a Command, since no V1 metric needs to see the command
	// payload itself and a narrower signature is a narrower attack surface).
	// A non-OK Status rejects the enclosing transaction before any
	// mutation; r_value is left at its caller-supplied default (never read
	// by the pipeline) on failure.
	virtual Status fixed_value(std::uint64_t p_metric_identifier_hash, const CommandHeader &p_header, std::int64_t &r_value) const = 0;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_AUTHORITY_INTERFACES_H
