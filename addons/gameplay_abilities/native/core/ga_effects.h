#ifndef GAMEPLAY_ABILITIES_CORE_EFFECTS_H
#define GAMEPLAY_ABILITIES_CORE_EFFECTS_H

#include "core/ga_attribute_state.h"
#include "core/ga_attributes.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_status.h"
#include "core/ga_tag_query.h"
#include "core/ga_tags.h"

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

// Immutable gameplay-effect *definitions* (task 5.1) and the registry that
// validates and seals them (task 5.4/5.5 field shapes). Runtime instances
// (`ActiveEffect`) and the mutating `EffectRuntime` live in
// `ga_effect_runtime.h`; this file only ever describes content, never holds
// per-component state.
//
// Two-phase life cycle, exactly like `TagRegistry`/`AttributeRegistry`:
// register every `EffectDefinitionDesc` (author-facing, string references),
// then `seal()`, which assigns dense ids AND resolves the one reference this
// file cannot validate eagerly -- a stacking policy's overflow effect, which
// may forward- or self-reference another effect identifier not yet
// registered at the time this effect was described (see `StackingPolicyDesc`
// and `EffectRegistry::seal`).
//
// Every OTHER cross-registry reference (attribute, tag, cue) is validated
// immediately in `register_effect`, because the `TagRegistry`/
// `AttributeRegistry` passed in are required to already be sealed (tags and
// attributes are built and sealed before effects -- see design.md's
// migration plan) and this registry's own cue identifiers are registered
// with `register_cue` up front, before any effect can reference them.
namespace ga {

// ---------------------------------------------------------------------------
// Lifetime policy
// ---------------------------------------------------------------------------

enum class EffectDuration : std::uint8_t {
	INSTANT = 0,
	DURATION = 1,
	INFINITE = 2,
};

// ---------------------------------------------------------------------------
// Declarative magnitude sources (v1 -- see design.md "Gameplay effects")
// ---------------------------------------------------------------------------

enum class MagnitudeSourceKind : std::uint8_t {
	CONSTANT = 0,
	ABILITY_LEVEL = 1,
	SOURCE_ATTRIBUTE = 2,
	TARGET_ATTRIBUTE = 3,
	SET_BY_CALLER = 4,
};

// Author-facing description of one magnitude source. `coefficient` is a
// plain decimal (quantized once at registration, like every other authored
// magnitude in this addon -- see `fixed_quantize`). Resolution is always
// `coefficient * raw_value`, where `raw_value` depends on `kind`:
//   CONSTANT          -> 1 (so the resolved value is simply `coefficient`)
//   ABILITY_LEVEL     -> the applying `EffectSpec::level`, as a whole number
//   SOURCE_ATTRIBUTE  -> the source entity's CURRENT value of `attribute`
//   TARGET_ATTRIBUTE  -> the target entity's CURRENT value of `attribute`
//   SET_BY_CALLER     -> the caller-supplied magnitude for `set_by_caller_field`
// See `ga_effect_runtime.h` (`EffectRuntime::apply`) for exactly when and
// against what stable snapshot this multiplication happens.
struct MagnitudeSourceDesc {
	MagnitudeSourceKind kind = MagnitudeSourceKind::CONSTANT;
	double coefficient = 1.0;
	std::string attribute; // SOURCE_ATTRIBUTE / TARGET_ATTRIBUTE only
	std::string set_by_caller_field; // SET_BY_CALLER only; must name a field this same effect declares
};

// Resolved (sealed) counterpart of `MagnitudeSourceDesc`: `attribute` is
// already a `DefinitionId` and `coefficient` is already `Fixed`.
struct MagnitudeSource {
	MagnitudeSourceKind kind = MagnitudeSourceKind::CONSTANT;
	Fixed coefficient = Fixed::one();
	DefinitionId attribute = INVALID_DEFINITION_ID;
	std::string set_by_caller_field;
};

// ---------------------------------------------------------------------------
// Declared modifiers
// ---------------------------------------------------------------------------

struct ModifierDeclarationDesc {
	std::string target_attribute;
	ModifierOp op = ModifierOp::ADD;
	MagnitudeSourceDesc magnitude;
	std::int32_t priority = 0;
};

// `declaration_index` is deliberately NOT a field here: it is always this
// declaration's own index within `EffectDefinition::modifiers`, exactly the
// way `AttributeModifier::declaration_index` is meant to be used (see
// ga_attribute_state.h).
struct ModifierDeclaration {
	DefinitionId target_attribute = INVALID_DEFINITION_ID;
	ModifierOp op = ModifierOp::ADD;
	MagnitudeSource magnitude;
	std::int32_t priority = 0;
};

// ---------------------------------------------------------------------------
// Tag requirements
// ---------------------------------------------------------------------------

struct TagOperandDesc {
	std::string tag;
	TagMatchMode mode = TagMatchMode::EXACT;
};

// Author-facing shape for one `TagQuery::build_requirements` call: an
// implicit AND of an all-list, an any-list, and a none-list, any of which may
// be empty (see ga_tag_query.h).
struct TagRequirementDesc {
	std::vector<TagOperandDesc> all;
	std::vector<TagOperandDesc> any;
	std::vector<TagOperandDesc> none;
};

// ---------------------------------------------------------------------------
// Stacking policy (task 5.5)
// ---------------------------------------------------------------------------

enum class StackSourceScope : std::uint8_t {
	// Each applying source owns its own independent stack group on a given
	// target (e.g. two different casters' Poison stacks never interact).
	SOURCE_SCOPED = 0,
	// Every application against a given target shares ONE stack group
	// regardless of source.
	TARGET_SCOPED = 1,
};

enum class StackOverflowPolicy : std::uint8_t {
	// Reject the new application outright: no stack, duration, or period
	// change; nothing is created or mutated.
	REJECT = 0,
	// Keep the stack count at its maximum but still apply the duration-
	// refresh / period-reset rules below.
	REFRESH = 1,
	// Tear down the existing active instance completely (its modifiers and
	// granted-tag source are removed) and rebuild it fresh under the SAME
	// `EffectHandle`, as if this were a brand new, non-stacking application
	// (stack count resets to 1, magnitudes are re-resolved from the current
	// snapshot).
	REPLACE = 2,
	// Leave the existing stack group completely untouched and additionally
	// apply `overflow_effect` (resolved at `seal()`) as its own independent
	// effect application against the same source/target/level. Applying the
	// overflow effect is NOT itself subject to a further overflow trigger
	// (bounded to one level -- see `EffectRuntime::apply`), so this can never
	// recurse unboundedly.
	APPLY_OVERFLOW_EFFECT = 3,
};

// Governs what happens when an existing stack in the SAME stack group is
// removed one unit at a time (`EffectRuntime::remove_effect`). Expiration
// (the whole group's shared `end_tick` being reached) always removes the
// entire active instance regardless of this rule -- see ga_effect_runtime.h.
enum class StackRemovalRule : std::uint8_t {
	// One `remove_effect` call decrements the stack count by one; the
	// instance (and its granted tags) is only fully torn down once the count
	// reaches zero.
	REMOVE_SINGLE_STACK = 0,
	// One `remove_effect` call tears down the entire active instance
	// immediately, regardless of how many stacks remain.
	REMOVE_ALL_STACKS = 1,
};

struct StackingPolicyDesc {
	bool stackable = false;
	// Canonical stacking key. Left empty, this defaults to the owning
	// effect's own identifier (the common case: an effect only stacks with
	// itself). An explicit key lets two DIFFERENT effect definitions compete
	// for the same stack slots (e.g. "WeakPoison" and "StrongPoison" sharing
	// a "poison_dot" key).
	std::string stack_key;
	StackSourceScope source_scope = StackSourceScope::SOURCE_SCOPED;
	std::uint32_t max_stacks = 1;
	StackOverflowPolicy overflow_policy = StackOverflowPolicy::REJECT;
	// "duration-refresh rule": does adding a stack (below max, or via
	// REFRESH/REPLACE at max) reset the shared end tick to a fresh
	// `start_tick + duration_ticks`?
	bool refresh_duration_on_add = true;
	// "period-reset rule": does adding a stack restart the periodic
	// countdown (`next_period_tick = start_tick + period_ticks`)?
	bool reset_period_on_add = true;
	StackRemovalRule removal_rule = StackRemovalRule::REMOVE_SINGLE_STACK;
	// Only meaningful (and only permitted to be non-empty) when
	// `overflow_policy == APPLY_OVERFLOW_EFFECT`. Resolved to a `DefinitionId`
	// at `seal()` -- see file comment.
	std::string overflow_effect;
};

struct StackingPolicy {
	bool stackable = false;
	std::string stack_key;
	StackSourceScope source_scope = StackSourceScope::SOURCE_SCOPED;
	std::uint32_t max_stacks = 1;
	StackOverflowPolicy overflow_policy = StackOverflowPolicy::REJECT;
	bool refresh_duration_on_add = true;
	bool reset_period_on_add = true;
	StackRemovalRule removal_rule = StackRemovalRule::REMOVE_SINGLE_STACK;
	bool has_overflow_effect = false;
	DefinitionId overflow_effect = INVALID_DEFINITION_ID;
};

// ---------------------------------------------------------------------------
// Set-by-caller fields
// ---------------------------------------------------------------------------

// `identifier` is a lightweight named parameter (e.g. "heal_amount"), not a
// top-level namespaced content identifier: it is validated against the
// identifier grammar's single-segment charset (`[a-z][a-z0-9_]*`, <=
// MAX_IDENTIFIER_BYTES) but does NOT require `validate_identifier`'s >= 2
// dotted segments, since it is only ever matched against this SAME effect's
// own declaration (see EffectSpec/validate_effect_spec), never registered or
// looked up in a shared registry.
struct SetByCallerFieldDesc {
	std::string identifier;
	bool required = false;
};

// ---------------------------------------------------------------------------
// Effect definition
// ---------------------------------------------------------------------------

// Author-facing input to `EffectRegistry::register_effect`. Every string
// reference here (attribute/tag/cue identifiers) is resolved and validated
// immediately against the sealed registries passed to `register_effect`,
// except `stacking.overflow_effect`, which is resolved at `seal()` (see file
// comment).
struct EffectDefinitionDesc {
	std::string identifier;

	EffectDuration duration_policy = EffectDuration::INSTANT;
	std::uint64_t duration_ticks = 0; // DURATION only; validated via validate_duration_ticks
	bool has_period = false;
	std::uint64_t period_ticks = 0; // validated via validate_period_ticks when has_period

	std::vector<ModifierDeclarationDesc> modifiers; // <= MAX_EFFECT_MODIFIERS
	std::vector<std::string> granted_tags; // <= MAX_GRANTED_TAGS

	TagRequirementDesc source_requirements;
	TagRequirementDesc target_requirements;
	// Evaluated against the TARGET only. If satisfied, application is
	// rejected with `StatusCode::EFFECT_IMMUNE` before anything is created.
	TagRequirementDesc immunity;

	StackingPolicyDesc stacking;
	std::vector<SetByCallerFieldDesc> set_by_caller_fields; // <= MAX_SET_BY_CALLER
	std::vector<std::string> cue_identifiers; // must already be registered via register_cue

	// Declares this effect eligible for the v1 prediction-safe self-effect
	// set (section 8 enforces the rest of the conformance check; this is
	// only the authored declaration).
	bool prediction_safe = false;

	// Retain coordinator-validated target context on duration/infinite
	// instances for later periodic calculations/cues and snapshot restore.
	// Instant applications still expose context on their one-shot records.
	bool retain_target_context = false;
};

// Sealed (validated, resolved) counterpart of `EffectDefinitionDesc`.
// Immutable once returned by a sealed `EffectRegistry`.
struct EffectDefinition {
	DefinitionId id = INVALID_DEFINITION_ID;
	std::string identifier;

	EffectDuration duration_policy = EffectDuration::INSTANT;
	std::uint64_t duration_ticks = 0;
	bool has_period = false;
	std::uint64_t period_ticks = 0;

	std::vector<ModifierDeclaration> modifiers;
	std::vector<DefinitionId> granted_tags; // ascending, deduplicated

	TagQuery source_requirements;
	TagQuery target_requirements;
	TagQuery immunity_query;

	StackingPolicy stacking;
	std::vector<SetByCallerFieldDesc> set_by_caller_fields;
	std::vector<std::string> cue_identifiers;

	bool prediction_safe = false;
	bool retain_target_context = false;
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

class EffectRegistry {
public:
	// Registers a cue identifier so effects may legally reference it in
	// `cue_identifiers`. Fails with the identifier grammar's own `Status` if
	// malformed, `StatusCode::DUPLICATE_DEFINITION` if already registered, or
	// `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	Status register_cue(const std::string &p_identifier);

	// Validates and stores one effect definition. `p_tags` and `p_attributes`
	// must already be sealed. Fails closed (this definition is not stored)
	// with a diagnostic naming the offending reference in `Status::detail`
	// (via `hash_string`, matching `AttributeRegistry`'s own convention) on:
	//   - `validate_identifier`'s own `Status` for a malformed identifier.
	//   - `StatusCode::DUPLICATE_DEFINITION` if the identifier was already
	//     registered.
	//   - `StatusCode::INVALID_ARGUMENT` / `DiagnosticId::DURATION_INVALID` or
	//     `PERIOD_INVALID` for an inconsistent duration/period policy (see
	//     `EffectDuration` -- INSTANT must not declare a period; DURATION
	//     must declare a positive duration; any declared period must be
	//     positive).
	//   - `StatusCode::CAPACITY_EXCEEDED` past `MAX_EFFECT_MODIFIERS`,
	//     `MAX_GRANTED_TAGS`, or `MAX_SET_BY_CALLER`.
	//   - `StatusCode::UNKNOWN_ATTRIBUTE` for an unresolvable modifier target
	//     or SOURCE_ATTRIBUTE/TARGET_ATTRIBUTE magnitude reference.
	//   - `StatusCode::UNKNOWN_TAG` for an unresolvable granted tag or
	//     requirement/immunity operand.
	//   - `StatusCode::UNKNOWN_DEFINITION` for an unregistered cue reference.
	//   - `StatusCode::UNDECLARED_SET_BY_CALLER` for a SET_BY_CALLER magnitude
	//     naming a field this effect did not declare, or a duplicate declared
	//     field identifier.
	//   - `StatusCode::INVALID_ARGUMENT` / `DiagnosticId::VALUE_NOT_REPRESENTABLE`
	//     if a coefficient cannot be quantized.
	//   - `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	Status register_effect(const EffectDefinitionDesc &p_desc, const TagRegistry &p_tags,
			const AttributeRegistry &p_attributes, DefinitionId &r_id);

	// Assigns dense ids 1..N in identifier byte order (see `IdentifierTable`)
	// and resolves every deferred `stacking.overflow_effect` reference now
	// that every effect identifier is known. Fails with
	// `StatusCode::UNKNOWN_DEFINITION` / `DiagnosticId::DEFINITION_UNKNOWN_REFERENCE`,
	// `detail == hash_string(missing identifier)`, if any overflow-effect
	// reference does not resolve -- in which case the registry is left
	// unsealed and no definition becomes usable (no partial seal).
	Status seal();
	bool sealed() const { return is_sealed; }
	std::size_t size() const { return by_id.empty() ? 0 : by_id.size() - 1; }

	const EffectDefinition *find(DefinitionId p_id) const;
	const EffectDefinition *find(const std::string &p_identifier) const;
	DefinitionId id_of(const std::string &p_identifier) const;

	// Every assigned id, ascending. Empty before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	// Contributes one manifest entry per sealed effect (kind = EFFECT), in
	// canonical order, whose bytes cover every field that affects behavior.
	Status contribute_manifest(ManifestBuilder &p_builder) const;

private:
	struct PendingEffect {
		EffectDefinition definition; // overflow_effect left unresolved (id 0, has_overflow_effect false) until seal()
		std::string overflow_effect_identifier; // empty if none declared
	};

	std::map<std::string, PendingEffect> pending; // sorted by identifier; iteration order == dense id order
	std::vector<EffectDefinition> by_id; // index 0 unused; valid after seal()
	IdentifierTable identifiers;
	std::set<std::string> registered_cues; // identifiers accepted by register_cue
	bool is_sealed = false;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_EFFECTS_H
