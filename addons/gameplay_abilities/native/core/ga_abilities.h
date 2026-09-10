#ifndef GAMEPLAY_ABILITIES_CORE_ABILITIES_H
#define GAMEPLAY_ABILITIES_CORE_ABILITIES_H

#include "core/ga_effects.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_status.h"
#include "core/ga_tag_query.h"
#include "core/ga_tags.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// Immutable gameplay-ability *definitions* (task 6.1). Runtime state --
// per-component grants and in-flight executions -- lives in
// `ga_ability_component.h`; this file only ever describes content, never
// holds per-component state, exactly the same split `ga_effects.h` /
// `ga_effect_runtime.h` already establish.
//
// Two-phase life cycle, exactly like `TagRegistry`/`AttributeRegistry`/
// `EffectRegistry`: register every `AbilityDefinitionDesc` (author-facing,
// string references into the already-sealed tag and effect registries),
// then `seal()`, which assigns dense, peer-reproducible ids. Unlike
// `EffectRegistry`, no reference here is self- or forward-referential (an
// ability never names another ability), so every reference resolves
// immediately in `register_ability` and `seal()` only needs to assign ids.
namespace ga {

// ---------------------------------------------------------------------------
// Addon-internal authoring bounds (not part of the wire contract in
// ga_limits.h, which the foundation agent owns -- these mirror the same
// "small bound owned by the file that needs it" precedent as
// ga_transaction.h's MAX_TRANSACTION_UNDO_OPS).
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_ABILITY_TRIGGERS = 8;
constexpr std::size_t MAX_ABILITY_COMMIT_EFFECTS = 8;

// ---------------------------------------------------------------------------
// Activation, grant, and revocation policy
// ---------------------------------------------------------------------------

// How an ability becomes active. See design.md "Manual, Event, and Passive
// Activation Policies".
enum class ActivationPolicy : std::uint8_t {
	MANUAL = 0, // explicit `AbilityComponent::request_activation` call
	GAMEPLAY_EVENT = 1, // triggered by a matching validated gameplay event
	PASSIVE_ON_GRANT = 2, // activates automatically once granted, if requirements pass
};

// Whether a second execution of the SAME granted spec may run while one is
// already active.
enum class AbilityConcurrencyPolicy : std::uint8_t {
	REJECT_IF_ACTIVE = 0,
	ALLOW_MULTIPLE = 1,
};

// What happens when the same ability is granted to a component that already
// holds a (possibly revoked) spec for it.
enum class AbilityDuplicateGrantPolicy : std::uint8_t {
	REJECT = 0, // the new grant fails; the existing spec/executions are untouched
	REPLACE = 1, // the existing spec is revoked (per its OWN revoke_policy) and a fresh spec is granted
	MULTI_GRANT = 2, // the new grant becomes an independent, additional spec
};

// What happens to an active execution when its granting spec is revoked.
enum class AbilityRevokePolicy : std::uint8_t {
	CANCEL_ACTIVE = 0,
	PERMIT_COMPLETION = 1,
};

// Whether an owning client may predict this ability's activation locally
// (section 8). Declaring `PREDICTABLE` subjects this definition to the
// prediction-safety validation documented on `AbilityRegistry::register_ability`.
enum class AbilityPredictionPolicy : std::uint8_t {
	NOT_PREDICTABLE = 0,
	PREDICTABLE = 1,
};

// Which typed behavior-hook interface (see ga_ability_component.h) this
// ability's runtime execution requires. This is a content-level DECLARATION
// only -- a function pointer/vtable cannot be part of a deterministic,
// hashable manifest, so the definition names a KIND, and the concrete hook
// instance is registered separately on the owning `AbilityComponent` (see
// `AbilityComponent::bind_authority_hook` / `bind_prediction_safe_hook`),
// exactly the way `ga_effect_hooks.h`'s `AuthorityCalculationHook*` is
// supplied per-call to `EffectRuntime::apply` rather than stored on
// `EffectDefinition`.
enum class AbilityHookBinding : std::uint8_t {
	NONE = 0,
	AUTHORITY_ONLY = 1,
	PREDICTION_SAFE = 2,
};

// ---------------------------------------------------------------------------
// Input / gameplay-event triggers
// ---------------------------------------------------------------------------

// Author-facing trigger declaration. `input_id` is an opaque, game-defined
// logical action name (e.g. "action.dash") -- never a Godot `InputEvent` and
// never registered, consumed, or rebound by this addon (see design.md
// "Input-Agnostic Activation API"). `gameplay_event_tag` names a tag this
// ability reacts to when delivered via `AbilityComponent::handle_gameplay_event`.
struct AbilityTriggerDesc {
	enum class Kind : std::uint8_t {
		INPUT = 0,
		GAMEPLAY_EVENT = 1,
	};

	Kind kind = Kind::INPUT;
	std::string input_id; // INPUT only; <= MAX_STRING_BYTES
	std::string gameplay_event_tag; // GAMEPLAY_EVENT only; must be a registered tag identifier
};

// Resolved counterpart: `gameplay_event_tag` is already a `DefinitionId`.
struct AbilityTrigger {
	AbilityTriggerDesc::Kind kind = AbilityTriggerDesc::Kind::INPUT;
	std::string input_id;
	DefinitionId gameplay_event_tag = INVALID_DEFINITION_ID;
};

// ---------------------------------------------------------------------------
// Ability definition
// ---------------------------------------------------------------------------

// Author-facing input to `AbilityRegistry::register_ability`. Every tag/
// effect string reference is resolved and validated immediately against the
// sealed registries passed to `register_ability` (both must already be
// sealed -- tags and effects are built before abilities, same migration
// order `ga_effects.h` documents for its own tag/attribute dependencies).
struct AbilityDefinitionDesc {
	std::string identifier;
	ActivationPolicy activation_policy = ActivationPolicy::MANUAL;

	// Evaluated against the OWNER's own tags at request time.
	TagRequirementDesc required_tags; // must be satisfied, or activation fails ABILITY_MISSING_TAG
	TagRequirementDesc blocked_tags; // if satisfied, activation fails ABILITY_BLOCKED_TAG

	// Granted to the owner (via this execution's own source token) for as
	// long as the execution stays ACTIVE; removed atomically when it ends or
	// cancels. <= MAX_GRANTED_TAGS.
	std::vector<std::string> owned_tags;

	// Evaluated against the OWNER's tags after every tag mutation while an
	// execution of this ability is ACTIVE; satisfying it cancels that
	// execution (e.g. Dash channel cancelled by a newly granted Stun tag).
	TagRequirementDesc cancel_tags;

	// Cost/cooldown are just gameplay effects (design.md "Ability Costs and
	// Cooldowns as Effects"): applied with source == target == the owner via
	// `EffectRuntime::apply`, through the exact same attribute/tag/
	// transaction/replication/prediction rules as any other effect. Empty
	// string = none declared.
	std::string cost_effect;
	std::string cooldown_effect;

	// Declared effects applied to the owner (self) atomically at commit,
	// alongside cost/cooldown/owned tags. <= MAX_ABILITY_COMMIT_EFFECTS.
	std::vector<std::string> commit_effects;

	std::vector<AbilityTriggerDesc> triggers; // <= MAX_ABILITY_TRIGGERS

	AbilityConcurrencyPolicy concurrency_policy = AbilityConcurrencyPolicy::REJECT_IF_ACTIVE;
	AbilityDuplicateGrantPolicy duplicate_grant_policy = AbilityDuplicateGrantPolicy::REJECT;
	AbilityRevokePolicy revoke_policy = AbilityRevokePolicy::CANCEL_ACTIVE;
	AbilityPredictionPolicy prediction_policy = AbilityPredictionPolicy::NOT_PREDICTABLE;
	AbilityHookBinding hook_binding = AbilityHookBinding::NONE;

	// If false, `request_activation` stops at the BEGUN phase and the caller
	// (or a bound hook, driven by game logic) must call `commit_activation`
	// explicitly -- the "optional commit" the spec names. If true (the
	// common case for an instantaneous ability like Dash or Heal),
	// `request_activation` performs begin and commit in one call.
	bool auto_commit = true;

	// If true (the common case), a successful commit immediately transitions
	// the execution to ENDED (an instantaneous ability). If false, the
	// execution remains ACTIVE after commit (e.g. a channel) until an
	// explicit end/cancel or a satisfied `cancel_tags` query.
	bool ends_on_commit = true;

	// Declares this ability's runtime execution safe for owning-client local
	// prediction (section 8's conformance test enforces the rest; this file
	// enforces every STATIC constraint it can already check -- see
	// `register_ability`).
	bool prediction_safe_declared = false;
};

// Sealed (validated, resolved) counterpart of `AbilityDefinitionDesc`.
// Immutable once returned by a sealed `AbilityRegistry`.
struct AbilityDefinition {
	DefinitionId id = INVALID_DEFINITION_ID;
	std::string identifier;
	ActivationPolicy activation_policy = ActivationPolicy::MANUAL;

	TagQuery required_tags;
	TagQuery blocked_tags;
	std::vector<DefinitionId> owned_tags; // ascending, deduplicated
	TagQuery cancel_tags;

	bool has_cost_effect = false;
	DefinitionId cost_effect = INVALID_DEFINITION_ID;
	bool has_cooldown_effect = false;
	DefinitionId cooldown_effect = INVALID_DEFINITION_ID;
	std::vector<DefinitionId> commit_effects;

	std::vector<AbilityTrigger> triggers;

	AbilityConcurrencyPolicy concurrency_policy = AbilityConcurrencyPolicy::REJECT_IF_ACTIVE;
	AbilityDuplicateGrantPolicy duplicate_grant_policy = AbilityDuplicateGrantPolicy::REJECT;
	AbilityRevokePolicy revoke_policy = AbilityRevokePolicy::CANCEL_ACTIVE;
	AbilityPredictionPolicy prediction_policy = AbilityPredictionPolicy::NOT_PREDICTABLE;
	AbilityHookBinding hook_binding = AbilityHookBinding::NONE;

	bool auto_commit = true;
	bool ends_on_commit = true;
	bool prediction_safe_declared = false;
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

class AbilityRegistry {
public:
	// Validates and stores one ability definition. `p_tags` and `p_effects`
	// must already be sealed. Fails closed (this definition is not stored)
	// with a diagnostic naming the offending reference in `Status::detail`
	// (via `hash_string`, matching `EffectRegistry`'s own convention) on:
	//   - `validate_identifier`'s own `Status` for a malformed identifier.
	//   - `StatusCode::DUPLICATE_DEFINITION` if the identifier was already
	//     registered.
	//   - `StatusCode::UNKNOWN_TAG` for an unresolvable required/blocked/
	//     cancel/owned-tag reference.
	//   - `StatusCode::UNKNOWN_EFFECT` for an unresolvable cost/cooldown/
	//     commit-effect reference.
	//   - `StatusCode::CAPACITY_EXCEEDED` past `MAX_GRANTED_TAGS` (owned
	//     tags), `MAX_ABILITY_COMMIT_EFFECTS`, or `MAX_ABILITY_TRIGGERS`.
	//   - `StatusCode::INVALID_ARGUMENT` for a trigger missing its required
	//     field (INPUT without `input_id`, GAMEPLAY_EVENT without a
	//     resolvable `gameplay_event_tag`) or an `input_id` exceeding
	//     `MAX_STRING_BYTES`.
	//   - `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	//
	// Prediction-safety validation (normative "Prediction declaration is
	// unsafe" scenario), checked only when
	// `p_desc.prediction_policy == PREDICTABLE`, in this order, fails with
	// `StatusCode::PREDICTION_NOT_SAFE` / `DiagnosticId::HOOK_CAPABILITY_DENIED`,
	// `detail == hash_string(...)` naming the offending reference:
	//   - `hook_binding == AUTHORITY_ONLY` (an authority-only hook may never
	//     run during predicted execution).
	//   - the cost effect, cooldown effect, or any commit effect resolves to
	//     a definition whose own `prediction_safe` flag is false, or which
	//     declares `has_period` (a periodic outcome is never predictable --
	//     see design.md "Owning-client prediction and reconciliation").
	// This file cannot validate a scene query, random value, or the concrete
	// hook's own conformance (no hook instance exists yet at registration
	// time -- see `AbilityHookBinding`); `AbilityComponent::bind_prediction_safe_hook`
	// (ga_ability_component.h) enforces that half via `validate_prediction_safe_hook`
	// at bind time, covering the "Prediction-safe hook uses non-deterministic
	// input" scenario.
	Status register_ability(const AbilityDefinitionDesc &p_desc, const TagRegistry &p_tags,
			const EffectRegistry &p_effects, DefinitionId &r_id);

	// Assigns dense ids 1..N in identifier byte order (see `IdentifierTable`).
	// Every reference an ability can make already resolves eagerly in
	// `register_ability` (unlike `EffectRegistry`, no forward self-reference
	// exists here), so `seal()` never fails once every `register_ability`
	// call already succeeded.
	Status seal();
	bool sealed() const { return is_sealed; }
	std::size_t size() const { return by_id.empty() ? 0 : by_id.size() - 1; }

	const AbilityDefinition *find(DefinitionId p_id) const;
	const AbilityDefinition *find(const std::string &p_identifier) const;
	DefinitionId id_of(const std::string &p_identifier) const;

	// Every assigned id, ascending. Empty before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	// Contributes one manifest entry per sealed ability (kind = ABILITY), in
	// canonical order, whose bytes cover every field that affects behavior.
	Status contribute_manifest(ManifestBuilder &p_builder) const;

private:
	std::map<std::string, AbilityDefinition> pending; // sorted by identifier
	std::vector<AbilityDefinition> by_id; // index 0 unused; valid after seal()
	IdentifierTable identifiers;
	bool is_sealed = false;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_ABILITIES_H
