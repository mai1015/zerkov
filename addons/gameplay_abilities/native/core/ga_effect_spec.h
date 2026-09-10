#ifndef GAMEPLAY_ABILITIES_CORE_EFFECT_SPEC_H
#define GAMEPLAY_ABILITIES_CORE_EFFECT_SPEC_H

#include "core/ga_effects.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_target_types.h"

#include <string>
#include <vector>

// A value-oriented binding of a registered effect definition to the
// concrete parties and inputs one application needs (task 5.1). An
// `EffectSpec` is deliberately just data -- no scene-object identity, no
// callback, nothing that stops it from being copied, journaled (prediction,
// section 8), or replicated (protocol, section 7) as plain bytes.
//
// Trust boundary (read this before wiring a network command handler to
// this struct): a client may propose `definition` (from its own granted-
// content dictionary), `target`, `level`, `context_tag`, `target_data`, and
// the declared `set_by_caller` VALUES it computed locally. A client must
// NEVER be able to supply -- and this struct has no field that WOULD let it
// supply -- an authority-issued `EffectHandle`, a resolved instant-effect
// magnitude, or a server-computed random result. Those only ever originate
// from `EffectRuntime::apply()` running on the authority (see
// ga_effect_runtime.h). `validate_effect_spec` below only ever reads state
// (the sealed registry); it never mutates anything, so a rejected spec
// leaves every component untouched.
namespace ga {

// One caller-supplied value for a declared `SET_BY_CALLER` magnitude field.
struct SetByCallerMagnitude {
	std::string field; // must match a `SetByCallerFieldDesc::identifier` on the definition
	Fixed value = Fixed::zero();
};

struct EffectSpec {
	DefinitionId definition = INVALID_DEFINITION_ID;
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	std::int32_t level = 1;

	// Opaque, value-oriented application context (e.g. the granting ability's
	// own `DefinitionId`, widened to carry either an ability or a direct
	// system-applied origin). Never a pointer, `ObjectID`, or `RID`.
	std::uint64_t context_tag = 0;

	// Bounded additional target entities (<= MAX_TARGETS_PER_COMMAND) for
	// effects whose behavior is target-data-shaped; v1 does not define a
	// generic target-data schema (see design.md non-goals), so this is
	// intentionally just a bounded list of entity identities.
	std::vector<EntityId> target_data;

	// Present only for coordinator-admitted typed targeting. It cannot
	// authorize application by itself; it is bounded immutable context for
	// calculations, lifecycle/cues, and retained active-effect state.
	TargetEffectContext target_context;

	std::vector<SetByCallerMagnitude> set_by_caller; // <= MAX_SET_BY_CALLER
};

// Validates `p_spec` against `p_registry` (which must be sealed). Never
// touches any runtime component state -- see file comment. Fails, in this
// order, with:
//   - `StatusCode::UNKNOWN_EFFECT` if `p_spec.definition` is not registered.
//   - `StatusCode::CAPACITY_EXCEEDED` if `set_by_caller.size() > MAX_SET_BY_CALLER`
//     or `target_data.size() > MAX_TARGETS_PER_COMMAND`.
//   - `StatusCode::UNDECLARED_SET_BY_CALLER`, `detail == hash_string(field)`,
//     if a supplied field does not match any field the definition declares,
//     or if the same field is supplied more than once.
//   - `StatusCode::MISSING_SET_BY_CALLER`, `detail == hash_string(field)`, if
//     a field the definition marks `required` is absent from `p_spec`.
Status validate_effect_spec(const EffectSpec &p_spec, const EffectRegistry &p_registry);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_EFFECT_SPEC_H
