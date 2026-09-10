#ifndef GAMEPLAY_ABILITIES_CORE_TAGS_H
#define GAMEPLAY_ABILITIES_CORE_TAGS_H

#include "core/ga_ids.h"
#include "core/ga_manifest.h"
#include "core/ga_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// Gameplay tags are hierarchical, namespaced identifiers (`state.control.stunned`)
// whose parent relationships are derived deterministically from dotted segments
// (see `ga_identifier.h`) rather than authored explicitly. This file owns the
// *definition* half of the tag system: validated, immutable, peer-reproducible
// `TagDefinition`s and the `TagRegistry` that assigns them stable `DefinitionId`s.
// Ownership/ref-counting and queries live in `ga_tag_container.h` / `ga_tag_query.h`.
//
// Design decision -- ancestors auto-register: registering `state.control.stunned`
// implicitly creates a `state.control` entry too (if no one has declared it yet)
// so it always has a `DefinitionId` and can be named as a parent-aware query
// target or reported as an ancestor, even for content that only ever authors leaf
// tags. An auto-created entry has `is_explicit() == false` and no authored
// metadata; a later explicit registration of the same identifier "upgrades" it in
// place rather than colliding with the placeholder. Auto-registration only ever
// adds ancestors of an explicitly-registered identifier, so the final registered
// set depends only on which identifiers were explicitly registered, never on the
// order they were registered in -- two peers loading the same content in any
// order still assign identical `DefinitionId`s (see `IdentifierTable`'s own
// seal-time ordering guarantee, which this registry builds on).
namespace ga {

// Authored input to `TagRegistry::register_tag`. `source_label` names the
// authoring resource/origin purely for duplicate-conflict diagnostics (e.g. a
// resource path or content-table row identifier); it is never a Godot
// `RID`/`ObjectID`/`NodePath` and never affects hashing, ordering, or ids.
struct TagDefinitionDesc {
	std::string identifier;
	std::string description; // optional authored text, <= MAX_STRING_BYTES
	std::string source_label; // optional authoring-origin label, <= MAX_STRING_BYTES
};

// One registered tag's immutable, queryable state. Stable for the lifetime of
// the registry that produced it; never mutated after `TagRegistry::seal()`.
struct TagDefinition {
	DefinitionId id = INVALID_DEFINITION_ID;
	std::string identifier;
	std::string parent_identifier; // empty if `identifier` has no registrable parent
	DefinitionId parent_id = INVALID_DEFINITION_ID; // INVALID_DEFINITION_ID if none
	std::string description;
	// False for an ancestor that exists only because a descendant was
	// registered and nobody explicitly declared it (see class comment).
	bool is_explicit = false;
};

// Filled by `TagRegistry::register_tag` when it rejects a genuine duplicate
// explicit registration, so the caller can build a diagnostic naming both
// authoring origins without the registry itself owning any logging/formatting.
struct TagRegistrationConflict {
	std::string identifier;
	std::string first_source_label;
	std::string second_source_label;
};

// Validates and interns hierarchical tag definitions, then assigns dense,
// peer-reproducible `DefinitionId`s at `seal()` (see `IdentifierTable`). Not
// thread-safe; registries are built single-threaded during content load,
// before a session starts.
class TagRegistry {
public:
	// Registers one authored tag identifier. Fails closed with:
	//   - `validate_identifier`'s own `Status` if `p_desc.identifier` is malformed.
	//   - `StatusCode::INVALID_ARGUMENT` / `DiagnosticId::BYTE_LIMIT_EXCEEDED` if
	//     `description` or `source_label` exceeds `MAX_STRING_BYTES`.
	//   - `StatusCode::REGISTRY_SEALED` once `seal()` has been called.
	//   - `StatusCode::DUPLICATE_DEFINITION` / `DiagnosticId::DEFINITION_DUPLICATE`
	//     if `p_desc.identifier` was already registered *explicitly* (by this or
	//     an earlier call); `r_conflict` (if not null) is filled with the shared
	//     identifier and both source labels. The earlier registration is kept
	//     unchanged -- no definition is ever selected implicitly.
	//   - the identifier hash-collision `Status` surfaced by the underlying
	//     `IdentifierTable` if a *different* already-registered identifier
	//     happens to share `p_desc.identifier`'s content hash.
	// Registering an identifier that exists only as an auto-registered ancestor
	// (see class comment) "upgrades" it to explicit with this call's metadata
	// and never conflicts.
	Status register_tag(const TagDefinitionDesc &p_desc, TagRegistrationConflict *r_conflict = nullptr);

	// Assigns dense ids 1..N (see `IdentifierTable::seal`) to every explicit and
	// auto-registered identifier, in ascending byte order. A second call fails
	// with `StatusCode::REGISTRY_SEALED`.
	Status seal();
	bool sealed() const { return is_sealed; }
	std::size_t size() const { return entries.size(); }

	// Valid only after `seal()`; return `INVALID_DEFINITION_ID`/`nullptr` before
	// that or for an unknown id/identifier.
	DefinitionId id_of(const std::string &p_identifier) const;
	const TagDefinition *definition(DefinitionId p_id) const;
	const TagDefinition *definition(const std::string &p_identifier) const;

	// Every assigned id, ascending (== canonical identifier order). Empty
	// before `seal()`.
	std::vector<DefinitionId> canonical_order() const;

	// Ancestor ids of `p_id`, immediate parent first, root-most last. Empty if
	// `p_id` is unknown or has no registrable parent. Valid only after `seal()`.
	std::vector<DefinitionId> ancestors_of(DefinitionId p_id) const;

	// True when `p_descendant` is `p_ancestor` itself or is nested beneath it
	// (mirrors `identifier_is_descendant_of`). False if either id is unknown.
	bool is_descendant_of(DefinitionId p_descendant, DefinitionId p_ancestor) const;

	// Adds this registry's canonical (kind = TAG) contribution to a session
	// content manifest: one entry per registered identifier (explicit or
	// auto-registered ancestor), sorted by identifier, each carrying
	// `is_explicit` and `description` in its canonical field bytes so a
	// metadata difference changes the manifest fingerprint too.
	Status contribute_manifest(ManifestBuilder &p_builder) const;

private:
	struct Entry {
		std::string description;
		std::string source_label;
		bool is_explicit = false;
	};

	Status ensure_registered(const std::string &p_identifier, bool p_explicit, const TagDefinitionDesc *p_explicit_desc, TagRegistrationConflict *r_conflict);

	std::map<std::string, Entry> entries; // sorted by identifier -- never an unordered_map
	IdentifierTable identifiers;
	std::vector<TagDefinition> by_id; // index 0 unused; valid after seal()
	bool is_sealed = false;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TAGS_H
