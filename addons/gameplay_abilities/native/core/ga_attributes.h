#ifndef GAMEPLAY_ABILITIES_CORE_ATTRIBUTES_H
#define GAMEPLAY_ABILITIES_CORE_ATTRIBUTES_H

#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// Immutable gameplay-attribute definitions and the registry that validates
// and seals them. See ga_attribute_state.h for the per-component runtime
// state (AttributeSet) built on top of these definitions.
//
// A definition is authored with plain decimal (`double`) magnitudes -- the
// only representation an editor or resource file can produce -- and this
// file's registration path is the boundary where those magnitudes take their
// one and only trip through `fixed_quantize` into the canonical fixed-point
// representation (see the rule documented on `ga::fixed_quantize` in
// ga_fixed.h). Once registered, a definition never changes: the addon has no
// "edit definition" API, only "register a new session's definitions and
// seal()".
namespace ga {

// One immutable attribute definition. Every field here is already in
// canonical fixed-point form -- callers never re-quantize a `Fixed` they read
// out of a sealed `AttributeRegistry`.
struct AttributeDefinition {
	DefinitionId id = INVALID_DEFINITION_ID;
	std::string identifier; // e.g. "attribute.vitals.health"

	Fixed default_base = Fixed::zero();

	bool has_min = false;
	Fixed min_value = Fixed::zero();
	bool has_max = false;
	Fixed max_value = Fixed::zero();

	// Presentation-only; never quantized, never part of the manifest
	// fingerprint (see `AttributeRegistry::contribute_manifest`).
	std::string display_name;
};

// Validates and registers `AttributeDefinition`s for one session, exactly
// like `ga::IdentifierTable`'s two-phase life cycle (register everything,
// then `seal()`): a `DefinitionId` is not assigned to any definition until
// `seal()` computes the dense, peer-reproducible 1..N ordering over sorted
// identifiers. Registering after `seal()` fails with
// `StatusCode::REGISTRY_SEALED`.
class AttributeRegistry {
public:
	// Validates `p_identifier`'s grammar and every numeric field, then stores
	// the definition under a pending (not-yet-assigned) id. `r_id` is always
	// set to `INVALID_DEFINITION_ID` -- see class comment and
	// `ga::IdentifierTable::intern` for why ids don't exist before `seal()`.
	//
	// Validation order (each step below only runs if the previous one
	// passed), chosen so a failed registration never consumes an identifier
	// slot a corrected retry could otherwise use:
	//   1. Capacity: `StatusCode::CAPACITY_EXCEEDED` past `MAX_ATTRIBUTES`.
	//   2. Identifier grammar: the identifier validator's own `Status`.
	//   3. Display name length: `StatusCode::OUT_OF_BOUNDS` /
	//      `DiagnosticId::BYTE_LIMIT_EXCEEDED` past `MAX_STRING_BYTES`.
	//   4. Quantization of `p_default_base`, then `p_min_value` (if
	//      `p_has_min`), then `p_max_value` (if `p_has_max`): on failure,
	//      `StatusCode::INVALID_ARGUMENT` / `DiagnosticId::VALUE_NOT_REPRESENTABLE`,
	//      `detail == hash_string(p_identifier)` (identifies the offending
	//      definition; the current status enum has one diagnostic for "a
	//      quantized field was unrepresentable" and does not further
	//      distinguish default/min/max -- see ga_status.h).
	//   5. Bounds: if both present and `min > max`,
	//      `StatusCode::INVALID_BOUNDS` / `DiagnosticId::BOUNDS_INVERTED`,
	//      `detail == hash_string(p_identifier)`.
	//   6. Interning into the identifier table (grammar re-validated there is
	//      redundant but harmless): `StatusCode::DUPLICATE_DEFINITION` if
	//      this identifier was already registered.
	Status register_attribute(const std::string &p_identifier,
			double p_default_base,
			bool p_has_min, double p_min_value,
			bool p_has_max, double p_max_value,
			const std::string &p_display_name,
			DefinitionId &r_id);

	// Assigns dense ids 1..N in identifier byte order (see class comment).
	// A second call fails with `StatusCode::REGISTRY_SEALED`.
	Status seal();
	bool sealed() const { return is_sealed; }

	// Every definition, or nullptr if unknown or not yet sealed.
	const AttributeDefinition *find(DefinitionId p_id) const;
	const AttributeDefinition *find(const std::string &p_identifier) const;
	DefinitionId id_of(const std::string &p_identifier) const;

	// Canonical order (ascending id, i.e. ascending identifier byte order).
	// Empty before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	std::size_t size() const;

	// Contributes one manifest entry per sealed definition, in canonical
	// order, whose canonical byte encoding carries exactly the quantized
	// integers (`default_base.raw`, and `min_value.raw`/`max_value.raw` when
	// present) -- never the display name, which is presentation-only and
	// must not perturb the content fingerprint. Fails with
	// `StatusCode::REGISTRY_SEALED` (inverted: not-yet-sealed) if called
	// before `seal()`, surfaced via `DiagnosticId::NONE` and
	// `StatusCode::INVALID_ARGUMENT` since "not sealed yet" is a caller
	// ordering bug rather than a data problem.
	Status contribute_manifest(ManifestBuilder &p_builder) const;

private:
	std::map<std::string, AttributeDefinition> pending; // keyed by identifier; ids not yet assigned
	std::vector<AttributeDefinition> sealed_definitions; // index 0 unused; valid after seal()
	IdentifierTable id_table;
	bool is_sealed = false;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_ATTRIBUTES_H
