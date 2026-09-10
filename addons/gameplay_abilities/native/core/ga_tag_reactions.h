#ifndef GAMEPLAY_ABILITIES_CORE_TAG_REACTIONS_H
#define GAMEPLAY_ABILITIES_CORE_TAG_REACTIONS_H

#include "core/ga_effects.h"
#include "core/ga_ids.h"
#include "core/ga_manifest.h"
#include "core/ga_status.h"
#include "core/ga_tags.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// Declarative "when a tag operand's effective truth value transitions,
// apply an effect to the owning component" definitions (design.md decision
// 3, "Model reactions as immutable registered definitions"). Task 1 (catalog
// model and migration boundary) established the catalog authoring surface
// and canonical-identity contribution below (`TagReactionCanonicalDesc`,
// `contribute_tag_reaction_manifest`). THIS task (3, "Native reaction
// definitions and validation") adds the sealed `TagReactionRegistry`:
// duplicate/malformed/cross-registry validation, the exact/parent-aware
// operand index a later runtime queries for bounded affected-predicate
// evaluation (task 3.2), and conservative static cycle validation (task
// 3.4). The deferred dispatch queue, edge computation from committed tag
// transactions, and WHILE_PRESENT handle binding are ALL a later change
// (design.md decision 4, tasks 4.x) -- this registry is definitions +
// validation + indexing only and holds no runtime/mutable component state.
// Kept engine-independent (no godot-cpp) so both the Godot adapter
// (native/resources/gameplay_tag_reaction_definition.h,
// native/godot/gameplay_ability_component.cpp,
// native/godot/gameplay_definition_validator.cpp) and godot-free native
// tests encode a reaction's canonical fields through exactly one function,
// so they can never silently drift apart.
namespace ga {

// Mirrors the Godot-authored `GameplayTagReactionDefinition::Mode` enum
// (native/resources/gameplay_tag_reaction_definition.h) exactly. Values are
// this type's own authoring order, NOT the canonical dispatch order a later
// change assigns reactions within one committed transaction (design.md
// decision 4: within one transaction, mode ordering is `ON_REMOVED`, then
// `ON_ADDED`, then `WHILE_PRESENT`) -- that ordering is a separate sort key
// the future runtime computes, not this enum's raw value.
enum class TagReactionMode : std::uint8_t {
	ON_ADDED = 0,
	ON_REMOVED = 1,
	WHILE_PRESENT = 2,
};

// Mirrors `ga::TagMatchMode` (native/core/ga_tag_query.h) exactly, repeated
// here as its own raw-value enum rather than an include so this header
// stays free of ga_tag_query.h's dependencies; the Godot adapter is
// responsible for keeping the two numerically in sync (see that file's own
// conversion sites).
enum class TagReactionMatchMode : std::uint8_t {
	EXACT = 0,
	PARENT_AWARE = 1,
};

// One authored reaction's canonical identity fields -- exactly the fields
// specs/gameplay-definition-authoring/spec.md's "Canonical Catalog
// Identity" requirement lists as fingerprint contributors: identifier,
// operand tag + match mode, reaction mode, and target effect identifier.
// This is ALSO the complete author-facing input to
// `TagReactionRegistry::register_reaction` below: v1 reactions carry no
// target selector, context payload, set-by-caller value, or level at all
// (design.md decision 3), so there is no separate "registration desc" with
// extra fields the way `EffectDefinitionDesc` has beyond its own canonical
// identity -- one struct serves both authoring input and manifest identity.
struct TagReactionCanonicalDesc {
	std::string identifier;
	std::string operand_tag;
	TagReactionMatchMode match_mode = TagReactionMatchMode::EXACT;
	TagReactionMode mode = TagReactionMode::ON_ADDED;
	std::string effect_identifier;
};

// Encodes `p_desc`'s canonical fields and adds them to `p_builder` under
// `ManifestEntryKind::REACTION`, keyed by `p_desc.identifier` exactly like
// every other manifest contribution. `ManifestBuilder::build` already sorts
// entries by `(kind, identifier)` (see ga_manifest.h), so two catalogs with
// the same reactions authored in a different array order still produce an
// identical fingerprint, and any one canonical field differing changes it --
// the two "Canonical Catalog Identity" scenarios this function exists to
// satisfy. Fails the same way `ManifestBuilder::add` does: a malformed
// `p_desc.identifier` (see `validate_identifier`) or a duplicate identifier
// already added under `ManifestEntryKind::REACTION`.
Status contribute_tag_reaction_manifest(ManifestBuilder &p_builder, const TagReactionCanonicalDesc &p_desc);

// ---------------------------------------------------------------------------
// Sealed registry (task 3.1-3.4)
// ---------------------------------------------------------------------------

// Sealed (validated, resolved) counterpart of `TagReactionCanonicalDesc`.
// Immutable once returned by a sealed `TagReactionRegistry`.
struct TagReactionDefinition {
	DefinitionId id = INVALID_DEFINITION_ID;
	std::string identifier;

	DefinitionId operand_tag = INVALID_DEFINITION_ID;
	TagReactionMatchMode match_mode = TagReactionMatchMode::EXACT;
	TagReactionMode mode = TagReactionMode::ON_ADDED;

	DefinitionId effect_id = INVALID_DEFINITION_ID;
	std::string effect_identifier; // kept alongside effect_id purely so cycle
			// diagnostics (`TagReactionCycleConflict`) can name the effect
			// without a second registry lookup.
	// A COPY of the target effect's `EffectDefinition::granted_tags` (already
	// resolved, ascending, deduplicated `DefinitionId`s) taken at
	// `TagReactionRegistry::register_reaction` time. Reactions target
	// already-sealed effects (design.md's migration plan builds tags, then
	// attributes, then effects, then reactions), so this copy can never go
	// stale, and `TagReactionRegistry::seal`'s cycle validation (task 3.4)
	// never needs to hold onto the `EffectRegistry` itself.
	std::vector<DefinitionId> effect_granted_tags;
};

// Filled by `TagReactionRegistry::seal` when it rejects a conservative
// dependency-graph cycle (design.md decision 5, "Reject static cycles and
// bound dynamic chains"; specs/gameplay-effects/spec.md "Two reaction
// effects form a granted-tag cycle" / "Reaction effect grants its own
// trigger tag"), so the caller can build a diagnostic naming the whole
// involved reaction/effect path without this registry owning any
// logging/formatting (mirrors `TagRegistrationConflict`, ga_tags.h).
struct TagReactionCycleConflict {
	// Reaction identifiers in cycle order. `reaction_path[i]`'s target
	// effect (== `effect_path[i]`) grants a tag that satisfies
	// `reaction_path[i + 1]`'s operand (match-mode-aware: EXACT requires the
	// identical tag, PARENT_AWARE accepts the operand tag or any of its
	// descendants). The LAST entry always repeats `reaction_path[0]` to make
	// the loop closing visible, so a length-one self-loop (a reaction whose
	// own effect grants a tag matching its own operand) reads as exactly
	// `{ identifier, identifier }`.
	std::vector<std::string> reaction_path;
	// `effect_path[i]` is `reaction_path[i]`'s target effect identifier --
	// one shorter than `reaction_path` (the repeated closing entry has no
	// corresponding new effect).
	std::vector<std::string> effect_path;
};

// Validates, resolves, and seals declarative tag-reaction definitions
// against already-sealed `TagRegistry`/`EffectRegistry` instances, exactly
// like `EffectRegistry` validates against sealed `TagRegistry`/
// `AttributeRegistry` instances (see ga_effects.h's file comment) -- tags,
// then attributes, then effects, then reactions is the fixed catalog build
// order (design.md's migration plan), so every cross-registry reference a
// reaction can make is always resolvable eagerly; there is no deferred
// reference to resolve at `seal()` the way `EffectRegistry::seal` resolves
// `stacking.overflow_effect`.
//
// Not thread-safe; built single-threaded during content load, before a
// session starts -- same contract as every other registry in this addon.
class TagReactionRegistry {
public:
	// Validates one authored reaction and stores it pending id assignment at
	// `seal()`. `p_tags` and `p_effects` MUST already be sealed. Fails closed
	// (this definition is not stored) with:
	//   - `validate_identifier`'s own `Status` for a malformed or
	//     non-namespaced `p_desc.identifier`.
	//   - `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	//   - `StatusCode::UNKNOWN_TAG` / `DiagnosticId::DEFINITION_UNKNOWN_REFERENCE`,
	//     `detail == hash_string(p_desc.operand_tag)`, if the operand tag does
	//     not resolve against `p_tags`.
	//   - `StatusCode::UNKNOWN_EFFECT` / `DiagnosticId::DEFINITION_UNKNOWN_REFERENCE`,
	//     `detail == hash_string(p_desc.effect_identifier)`, if the target
	//     effect does not resolve against `p_effects`.
	//   - `StatusCode::INVALID_EFFECT_SPEC` / `DiagnosticId::DURATION_INVALID`,
	//     `detail == hash_string(p_desc.identifier)`, if `p_desc.mode ==
	//     WHILE_PRESENT` and the target effect's `duration_policy` is not
	//     `EffectDuration::INFINITE` (an instant or duration effect cannot be
	//     guaranteed for the complete predicate interval -- design.md decision
	//     3; specs/gameplay-effects/spec.md "While-present reaction targets a
	//     duration effect"). A periodic INFINITE effect is accepted --
	//     `has_period` is completely orthogonal to `duration_policy`.
	//   - `StatusCode::DUPLICATE_DEFINITION` / `DiagnosticId::DEFINITION_DUPLICATE`
	//     if `p_desc.identifier` was already registered.
	// V1 self-target note (design.md decision 3, task 3.3): there is no
	// separate "target selector" validation step here because
	// `TagReactionCanonicalDesc` has no target-like field to begin with --
	// see that struct's own comment. Nothing configurable could ever fail
	// that check.
	Status register_reaction(const TagReactionCanonicalDesc &p_desc, const TagRegistry &p_tags,
			const EffectRegistry &p_effects, DefinitionId &r_id);

	// Assigns dense ids 1..N in identifier byte order (mirrors
	// `TagRegistry`/`EffectRegistry`/`IdentifierTable::seal`), builds the
	// exact/parent-aware operand index (task 3.2), and runs conservative
	// dependency-graph cycle validation (task 3.4): a directed edge exists
	// from reaction A to reaction B when A's target effect grants a tag that
	// satisfies B's operand (match-mode-aware -- see `TagReactionCycleConflict`).
	// A depth-first walk in ascending reaction-id order (deterministic,
	// content-derived -- never hash-table iteration order) detects the first
	// cycle reachable, including a node with an edge to itself (the
	// length-one self-loop). `p_tags` MUST be the same sealed registry every
	// `register_reaction` call used; it is stored (not copied) for later
	// `affected_reactions` queries and MUST outlive this registry, exactly
	// like `TagContainer` requires of its `TagRegistry` (see ga_tag_container.h).
	//
	// Fails, leaving the registry unsealed (no partial seal -- mirrors
	// `EffectRegistry::seal`'s unknown-overflow-reference failure), with:
	//   - `StatusCode::REGISTRY_SEALED` if already sealed.
	//   - `StatusCode::INVALID_REFERENCE` / `DiagnosticId::REACTION_CYCLE` if a
	//     cycle is found; `r_conflict` (if not null) is filled with the
	//     readable involved reaction/effect path.
	Status seal(const TagRegistry &p_tags, TagReactionCycleConflict *r_conflict = nullptr);
	bool sealed() const { return is_sealed; }
	std::size_t size() const { return by_id.empty() ? 0 : by_id.size() - 1; }

	const TagReactionDefinition *find(DefinitionId p_id) const;
	const TagReactionDefinition *find(const std::string &p_identifier) const;
	DefinitionId id_of(const std::string &p_identifier) const;

	// Every assigned id, ascending (== canonical identifier order). Empty
	// before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	// Task 3.2: given `p_changed_tags` -- the set of EXACT tag ids a
	// committed transaction changed -- returns every reaction whose operand
	// could be affected, deduplicated, in ascending `DefinitionId` order.
	// EXACT operands are matched by an O(1) lookup keyed on the changed tag
	// itself; PARENT_AWARE operands are matched by walking the changed tag's
	// OWN ancestor chain (bounded by `MAX_IDENTIFIER_SEGMENTS`) and probing
	// the same index at each ancestor -- so this never scans every
	// registered reaction, only the (small, bounded) set of tags actually
	// implicated by this transaction. A tag with no registered reaction
	// anywhere on its exact identity or ancestor chain costs a handful of
	// map lookups, not a linear scan. Empty before `seal()`.
	//
	// This is a pure query, callable freely and repeatedly -- it never
	// mutates this registry. The future runtime dispatch queue (task 4.x)
	// is the only intended caller; this task only builds and tests the
	// index and query surface.
	std::vector<DefinitionId> affected_reactions(const std::vector<DefinitionId> &p_changed_tags) const;

private:
	std::vector<DefinitionId> affected_reactions_unsealed(const std::vector<DefinitionId> &p_changed_tags) const;
	void build_cycle_conflict(const std::vector<DefinitionId> &p_stack, DefinitionId p_closing_node, TagReactionCycleConflict &r_conflict) const;

	std::map<std::string, TagReactionDefinition> pending; // sorted by identifier; iteration order == dense id order
	std::vector<TagReactionDefinition> by_id; // index 0 unused; valid after seal()
	IdentifierTable identifiers; // duplicate-identifier detection only, mirrors EffectRegistry

	// operand tag id -> reaction ids whose EXACT/PARENT_AWARE operand names
	// that tag, ascending by construction (built while iterating by_id in
	// ascending id order). Valid only after seal().
	std::map<DefinitionId, std::vector<DefinitionId>> exact_index;
	std::map<DefinitionId, std::vector<DefinitionId>> parent_aware_index;

	const TagRegistry *tags = nullptr; // set at seal(); must outlive this registry
	bool is_sealed = false;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TAG_REACTIONS_H
