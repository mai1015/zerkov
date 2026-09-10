#include "core/ga_tags.h"

#include "core/ga_bytes.h"
#include "core/ga_identifier.h"
#include "core/ga_limits.h"

namespace ga {

Status TagRegistry::ensure_registered(const std::string &p_identifier, bool p_explicit, const TagDefinitionDesc *p_explicit_desc, TagRegistrationConflict *r_conflict) {
	const auto it = entries.find(p_identifier);
	if (it == entries.end()) {
		// Brand new identifier (explicit or an auto-registered ancestor) --
		// intern it once so hash-collision detection and seal-time id
		// assignment stay delegated to `IdentifierTable`.
		DefinitionId unused = INVALID_DEFINITION_ID;
		const Status interned = identifiers.intern(p_identifier, unused);
		if (!interned.ok()) {
			return interned;
		}
		Entry entry;
		entry.is_explicit = p_explicit;
		if (p_explicit && p_explicit_desc) {
			entry.description = p_explicit_desc->description;
			entry.source_label = p_explicit_desc->source_label;
		}
		entries.emplace(p_identifier, std::move(entry));
		return ok_status();
	}

	if (!p_explicit) {
		// Ensuring an ancestor exists never conflicts with whatever is
		// already registered for it (explicit or auto).
		return ok_status();
	}

	if (!it->second.is_explicit) {
		// Upgrade an auto-registered placeholder ancestor to an explicit
		// definition; this is not a conflict because nobody had claimed it.
		it->second.is_explicit = true;
		if (p_explicit_desc) {
			it->second.description = p_explicit_desc->description;
			it->second.source_label = p_explicit_desc->source_label;
		}
		return ok_status();
	}

	// Two explicit registrations of the same identifier. Keep the first
	// registration unchanged -- no definition is ever selected implicitly --
	// and surface both origins for the caller's diagnostic.
	if (r_conflict) {
		r_conflict->identifier = p_identifier;
		r_conflict->first_source_label = it->second.source_label;
		r_conflict->second_source_label = p_explicit_desc ? p_explicit_desc->source_label : std::string();
	}
	return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, hash_string(p_identifier));
}

Status TagRegistry::register_tag(const TagDefinitionDesc &p_desc, TagRegistrationConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED, DiagnosticId::NONE, 0);
	}

	const Status validity = validate_identifier(p_desc.identifier);
	if (!validity.ok()) {
		return validity;
	}
	if (p_desc.description.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_desc.description.size());
	}
	if (p_desc.source_label.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_desc.source_label.size());
	}

	// Ancestors are derived deterministically from the identifier's own
	// segments (never authored) and auto-registered so the identifier is
	// always recognizable as a descendant, even if nobody explicitly
	// declares e.g. `state.control` on its own.
	for (const std::string &ancestor : identifier_ancestors(p_desc.identifier)) {
		const Status ancestor_status = ensure_registered(ancestor, /*p_explicit=*/false, nullptr, nullptr);
		if (!ancestor_status.ok()) {
			return ancestor_status;
		}
	}

	return ensure_registered(p_desc.identifier, /*p_explicit=*/true, &p_desc, r_conflict);
}

Status TagRegistry::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED, DiagnosticId::NONE, 0);
	}
	const Status sealed_status = identifiers.seal();
	if (!sealed_status.ok()) {
		return sealed_status;
	}

	by_id.assign(entries.size() + 1, TagDefinition{}); // index 0 unused
	for (const auto &pair : entries) {
		const DefinitionId id = identifiers.lookup(pair.first);
		TagDefinition def;
		def.id = id;
		def.identifier = pair.first;
		def.parent_identifier = identifier_parent(pair.first);
		def.parent_id = def.parent_identifier.empty() ? INVALID_DEFINITION_ID : identifiers.lookup(def.parent_identifier);
		def.description = pair.second.description;
		def.is_explicit = pair.second.is_explicit;
		by_id[id] = def;
	}

	is_sealed = true;
	return ok_status();
}

DefinitionId TagRegistry::id_of(const std::string &p_identifier) const {
	return identifiers.lookup(p_identifier);
}

const TagDefinition *TagRegistry::definition(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= by_id.size()) {
		return nullptr;
	}
	return &by_id[p_id];
}

const TagDefinition *TagRegistry::definition(const std::string &p_identifier) const {
	return definition(id_of(p_identifier));
}

std::vector<DefinitionId> TagRegistry::canonical_order() const {
	return identifiers.canonical_order();
}

std::vector<DefinitionId> TagRegistry::ancestors_of(DefinitionId p_id) const {
	std::vector<DefinitionId> result;
	const TagDefinition *def = definition(p_id);
	if (def == nullptr) {
		return result;
	}
	for (const std::string &ancestor : identifier_ancestors(def->identifier)) {
		const DefinitionId ancestor_id = identifiers.lookup(ancestor);
		if (ancestor_id != INVALID_DEFINITION_ID) {
			result.push_back(ancestor_id);
		}
	}
	return result;
}

bool TagRegistry::is_descendant_of(DefinitionId p_descendant, DefinitionId p_ancestor) const {
	const TagDefinition *descendant_def = definition(p_descendant);
	const TagDefinition *ancestor_def = definition(p_ancestor);
	if (descendant_def == nullptr || ancestor_def == nullptr) {
		return false;
	}
	return identifier_is_descendant_of(descendant_def->identifier, ancestor_def->identifier);
}

Status TagRegistry::contribute_manifest(ManifestBuilder &p_builder) const {
	for (const auto &pair : entries) {
		ByteWriter writer;
		writer.write_bool(pair.second.is_explicit);
		writer.write_string(pair.second.description);
		if (!writer.ok()) {
			return writer.status();
		}
		const Status added = p_builder.add(ManifestEntryKind::TAG, pair.first, writer.bytes());
		if (!added.ok()) {
			return added;
		}
	}
	return ok_status();
}

} // namespace ga
