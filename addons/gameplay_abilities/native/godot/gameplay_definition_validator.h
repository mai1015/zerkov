#ifndef GAMEPLAY_ABILITIES_GODOT_DEFINITION_VALIDATOR_H
#define GAMEPLAY_ABILITIES_GODOT_DEFINITION_VALIDATOR_H

#include "resources/gameplay_ability_definition.h"
#include "resources/gameplay_attribute_definition.h"
#include "resources/gameplay_cue_definition.h"
#include "resources/gameplay_definition_catalog.h"
#include "resources/gameplay_effect_definition.h"
#include "resources/gameplay_tag_definition.h"
#include "resources/gameplay_tag_query_resource.h"
#include "resources/gameplay_target_data_schema.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

// This is the one file in native/godot/ allowed to `#include "core/*.h"`
// directly (see native/resources/*.h, which deliberately never do) -- it is
// the adapter that runs the engine-independent core's OWN validators
// (`ga::validate_identifier`, the registries' `register_*`/`seal()`,
// `ga::fixed_quantize`, `ga::TagQuery::build_requirements`,
// `ga::ManifestBuilder`) over authored Resource data, so authoring-time
// validation can never silently drift from what a running session actually
// enforces.
namespace godot {

// Runs the core's own registries/validators over a set of authored
// gameplay-ability definition resources and reports the result as a bounded,
// structured findings array -- never `push_error` spam (task 9.2).
//
// Each finding is a Dictionary: {severity, resource_path, field, code, message}.
//   severity:      "error" (this addon has no non-fatal authoring warnings yet)
//   resource_path: the offending resource's path, or an addressable fallback
//                  such as "<tags[3]>" for an unsaved/anonymous slot
//   field:         the best-effort authored property name the problem traces
//                  to (may be empty when the core cannot distinguish it)
//   code:          a stable lowercase snake_case string -- either a
//                  `ga::DiagnosticId`/`ga::StatusCode` name lowercased, or one
//                  of this validator's own authoring-only codes
//                  (`null_resource`, `overflow_effect_cycle`, `schema_bounds`)
//   message:       a human-readable, bounded explanation
//
// `validate()` also records the resulting content-manifest fingerprint
// (`ga::ManifestBuilder::build`) so a caller (or a test) can prove that
// re-running validation over the same, unchanged assets reproduces the exact
// same fingerprint -- the property that makes multiplayer content
// compatibility checkable before shipping (see design.md "Stable identities
// and immutable definitions").
//
// Prediction-eligibility conformance (task 8.1's "reject definitions/hooks
// that use operations outside the v1 prediction-safe set") is a SEPARATE
// pass from `validate()` above: it depends on ability and behavior-hook
// definitions that are a distinct authoring set from tags/attributes/
// effects/cues (see `GameplayAbilityComponent`'s own Dictionary-shaped
// ability input), so `validate()` never calls it implicitly. See
// `validate_prediction_eligibility_seam()` below -- now fully implemented
// (task 8.1/9.1) -- for that pass; call it explicitly once ability
// resources exist for a session.
class GameplayDefinitionValidator : public RefCounted {
	GDCLASS(GameplayDefinitionValidator, RefCounted)

public:
	// Validates one complete authoring set in one pass: tags and attributes
	// are registered and sealed first (effects and standalone queries need
	// both sealed), cues are registered before effects reference them, then
	// effects are registered/sealed, standalone tag queries and target-data
	// schemas are checked, and finally every sealed registry (plus manual
	// target-schema entries) contributes to one content manifest.
	//
	// Findings accumulate across every stage that can still run meaningfully;
	// if tags or attributes fail to seal, later stages that require them are
	// skipped (each skip itself becomes a bounded finding) rather than
	// crashing or producing misleading downstream diagnostics.
	Array validate(const TypedArray<GameplayTagDefinition> &p_tags,
			const TypedArray<GameplayAttributeDefinition> &p_attributes,
			const TypedArray<GameplayEffectDefinition> &p_effects,
			const TypedArray<GameplayCueDefinition> &p_cues,
			const TypedArray<GameplayTagQueryResource> &p_tag_queries,
			const TypedArray<GameplayTargetDataSchema> &p_target_schemas);

	// State from the most recent `validate()` call. `get_last_manifest_ok()`
	// is false if manifest assembly could not complete (e.g. a registry
	// failed to seal); the fingerprint/entry-count/tick-rate are only
	// meaningful when it is true.
	bool get_last_manifest_ok() const { return last_manifest_ok; }
	int64_t get_last_manifest_fingerprint() const { return last_manifest_fingerprint; }
	int get_last_manifest_entry_count() const { return last_manifest_entry_count; }
	int get_last_manifest_tick_rate() const { return last_manifest_tick_rate; }

	// True when `p_findings` contains no "error" severity entry.
	static bool is_ok(const Array &p_findings);

	// One-line-per-finding bounded report, suitable for logs or CI output.
	static String format(const Array &p_findings);

	// Task 8.1/9.1 seam, now wired: validates that every authored ability
	// marked `PREDICTION_PREDICTABLE` actually stays inside the v1
	// prediction-safe operation set. Never called by `validate()` (abilities
	// are a separate authoring set from tags/attributes/effects/cues, see
	// `GameplayAbilityComponent`'s own Dictionary-shaped ability input) --
	// call this explicitly once ability resources exist for a session.
	//
	// Builds its own sealed `TagRegistry`/`AttributeRegistry`/`EffectRegistry`/
	// `ga::AbilityRegistry` from `p_tags`/`p_attributes`/`p_effects`/`p_cues`/
	// `p_abilities` (identical stage order to `validate()`), then for every
	// ability whose `prediction_policy == PREDICTION_PREDICTABLE`, runs
	// `ga::validate_prediction_eligibility` -- NOT
	// `ga::AbilityRegistry::register_ability`'s own weaker inline check --
	// against the sealed effect registry. This matters: the inline check
	// `register_ability` performs (`ga_abilities.cpp`'s file-local
	// `check_effect_prediction_safe`) does not recurse into a stackable
	// effect's `overflow_effect` chain, so a predictable ability naming a
	// cost/cooldown/commit effect whose OWN overflow effect is unsafe (e.g.
	// periodic) can register successfully yet still be prediction-unsafe.
	// `ga::validate_prediction_eligibility` (native/core/ga_prediction.h)
	// recurses exactly one level into that chain (matching
	// `EffectRuntime::apply_internal`'s own single-hop overflow-application
	// guard), so this authoring-time seam always uses the stricter check and
	// rejects what `register_ability` alone would silently accept.
	//
	// A malformed ability (bad identifier, unresolved tag/effect reference,
	// capacity overflow, etc.) is also reported here, using the same
	// `{severity, resource_path, field, code, message}` finding shape
	// `validate()` uses, so a caller can run this as a complete "are these
	// abilities safe to ship" pass rather than needing a separate malformed-
	// ability check first.
	static Array validate_prediction_eligibility_seam(const TypedArray<GameplayTagDefinition> &p_tags,
			const TypedArray<GameplayAttributeDefinition> &p_attributes,
			const TypedArray<GameplayEffectDefinition> &p_effects, const TypedArray<GameplayCueDefinition> &p_cues,
			const TypedArray<GameplayAbilityDefinition> &p_abilities);

	// Task 1.5: validates one complete `GameplayDefinitionCatalog` in a
	// single pass -- tags, attributes, cues, effects, target-data schemas
	// (the same stages/order `validate()` above already runs, reusing its
	// exact Resource -> core-desc conversions and finding shapes), PLUS
	// abilities (registered against the sealed tag/effect registries, the
	// same registration `validate_prediction_eligibility_seam` already
	// performs before its own stricter prediction-safety pass -- this method
	// does NOT run that stricter pass; call
	// `validate_prediction_eligibility_seam` separately if a catalog's
	// abilities also need it) and tag reactions (identifier presence and
	// per-catalog uniqueness only -- cross-reference and cycle validation
	// against `effect_definitions` land in a later change, see
	// `GameplayTagReactionDefinition`'s own header comment).
	//
	// Findings use the same `{severity, resource_path, field, code,
	// message}` shape as `validate()`; `field` names the catalog collection
	// property (`tag_definitions`, `attribute_definitions`, ...,
	// `tag_reactions`) rather than the legacy component-array names.
	// `get_last_manifest_*` reflects THIS call once it returns -- calling
	// `validate_catalog()` overwrites whatever a prior `validate()`/
	// `validate_catalog()` call left behind, matching `validate()`'s own
	// documented state-sharing contract. The resulting manifest additionally
	// contributes every valid ability and tag-reaction entry (via
	// `ga::contribute_tag_reaction_manifest`, native/core/ga_tag_reactions.h)
	// so two catalogs that only differ in reaction behavior produce
	// different fingerprints (specs/gameplay-definition-authoring/spec.md
	// "Canonical Catalog Identity").
	Array validate_catalog(const Ref<GameplayDefinitionCatalog> &p_catalog);

protected:
	static void _bind_methods();

private:
	bool last_manifest_ok = false;
	int64_t last_manifest_fingerprint = 0;
	int last_manifest_entry_count = 0;
	int last_manifest_tick_rate = 0;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_DEFINITION_VALIDATOR_H
