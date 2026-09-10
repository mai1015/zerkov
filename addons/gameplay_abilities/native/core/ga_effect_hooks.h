#ifndef GAMEPLAY_ABILITIES_CORE_EFFECT_HOOKS_H
#define GAMEPLAY_ABILITIES_CORE_EFFECT_HOOKS_H

#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "core/ga_target_types.h"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// Typed calculation hooks (task 5.7) let a game supply arbitrary,
// server-authoritative logic beyond the v1 declarative `MagnitudeSource` set
// (`ga_effects.h`) WITHOUT letting that logic silently leak onto a
// predicting client.
//
// Two structurally distinct interfaces exist on purpose:
//   - `AuthorityCalculationHook` may do anything deterministic ON THE SERVER.
//   - `PredictionSafeCalculationHook` is a SEPARATE base class an author
//     must deliberately implement; it cannot be produced by casting or
//     reinterpreting an `AuthorityCalculationHook`, so "register an
//     authority-only hook where prediction-safe is required" is a compile
//     error, not a runtime policy check that could be forgotten.
// `validate_prediction_safe` is the runtime conformance check section 8
// (client prediction) must run before trusting a `PredictionSafeCalculationHook`
// instance; `EffectRuntime` itself never predicts and therefore never calls
// `validate_prediction_safe` -- it only ever invokes `AuthorityCalculationHook`s.
namespace ga {

// Read-only, value-typed inputs available to a calculation hook. Deliberately
// NOT a pointer/reference to any scene object, Godot object, or live
// container: the caller (`EffectRuntime::apply`) resolves and copies exactly
// the values a hook is allowed to see from the SAME stable transaction
// snapshot magnitude resolution uses, which is what makes "operate only on a
// stable snapshot" a mechanical property of this struct rather than a
// convention a hook author has to remember.
struct CalculationContext {
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	std::int32_t level = 1;
	Tick tick = 0;
	DefinitionId effect_definition = INVALID_DEFINITION_ID;

	std::vector<std::pair<DefinitionId, Fixed>> source_attributes;
	std::vector<std::pair<DefinitionId, Fixed>> target_attributes;
	std::vector<std::pair<std::string, Fixed>> set_by_caller;
	TargetEffectContext target_context;

	// Linear scans over bounded (<= MAX_ATTRIBUTES / MAX_SET_BY_CALLER)
	// vectors -- there is no expectation a hook calls these in a hot loop.
	Status find_source_attribute(DefinitionId p_id, Fixed &r_out) const;
	Status find_target_attribute(DefinitionId p_id, Fixed &r_out) const;
	Status find_set_by_caller(const std::string &p_field, Fixed &r_out) const;
};

// Authority-only calculation hook. Its resolved `Fixed` result is recorded
// on the authoritative effect-application lifecycle event (see
// `ga_effect_runtime.h`) precisely so a client never recomputes it locally
// -- it only ever replicates the recorded number. A hook that returns a
// non-OK `Status` fails the WHOLE effect transaction with
// `StatusCode::HOOK_FAILED` and a bounded diagnostic; nothing it would have
// produced (handle, tag, modifier, cue, partial attribute change) survives.
class AuthorityCalculationHook {
public:
	virtual ~AuthorityCalculationHook() = default;
	virtual Status calculate(const CalculationContext &p_context, Fixed &r_out) = 0;
};

// Prediction-safe calculation hook. Implementations MUST be pure functions
// of `CalculationContext` alone: no wall clock, no RNG, no scene/physics
// query, no unrestricted callback into game code. The capability flags
// below are how an implementation HONESTLY self-declares whether it meets
// that bar; `validate_prediction_safe` is the enforcement point section 8
// calls before ever trusting one of these for a predicted command.
class PredictionSafeCalculationHook {
public:
	virtual ~PredictionSafeCalculationHook() = default;
	virtual Status calculate(const CalculationContext &p_context, Fixed &r_out) = 0;

	virtual bool depends_on_time() const { return false; }
	virtual bool depends_on_randomness() const { return false; }
	virtual bool depends_on_scene_or_physics() const { return false; }
	virtual bool uses_unrestricted_callback() const { return false; }
};

// Bit flags identifying which forbidden capability(ies) a hook declared,
// packed into a `Status::detail` so a single diagnostic can name every
// offending capability at once instead of only the first.
constexpr std::uint64_t PREDICTION_UNSAFE_TIME = 1ULL << 0;
constexpr std::uint64_t PREDICTION_UNSAFE_RANDOMNESS = 1ULL << 1;
constexpr std::uint64_t PREDICTION_UNSAFE_SCENE_OR_PHYSICS = 1ULL << 2;
constexpr std::uint64_t PREDICTION_UNSAFE_UNRESTRICTED_CALLBACK = 1ULL << 3;

// Rejects `p_hook` if it declares ANY forbidden dependency, with
// `StatusCode::PREDICTION_NOT_SAFE` / `DiagnosticId::HOOK_CAPABILITY_DENIED`
// and `detail` set to the OR of every `PREDICTION_UNSAFE_*` flag it
// declared. Returns `ok_status()` only if every capability flag is false.
Status validate_prediction_safe(const PredictionSafeCalculationHook &p_hook);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_EFFECT_HOOKS_H
