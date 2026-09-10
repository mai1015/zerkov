#include "core/ga_ids.h"

#include "core/ga_identifier.h"

namespace ga {

Status IdentifierTable::intern(const std::string &p_identifier, DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;

	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED, DiagnosticId::NONE, 0);
	}

	const Status validity = validate_identifier(p_identifier);
	if (!validity.ok()) {
		return validity;
	}

	if (entries.find(p_identifier) != entries.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, 0);
	}

	const std::uint64_t content_hash = hash_string(p_identifier);
	const auto hash_it = hash_index.find(content_hash);
	if (hash_it != hash_index.end() && hash_it->second != p_identifier) {
		// A different identifier already owns this content hash. Never
		// silently pick one -- fail closed and let the caller see the
		// colliding hash via `detail`.
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, content_hash);
	}

	entries.emplace(p_identifier, INVALID_DEFINITION_ID);
	hash_index.emplace(content_hash, p_identifier);
	return ok_status();
}

DefinitionId IdentifierTable::lookup(const std::string &p_identifier) const {
	if (!is_sealed) {
		return INVALID_DEFINITION_ID;
	}
	const auto it = entries.find(p_identifier);
	return (it == entries.end()) ? INVALID_DEFINITION_ID : it->second;
}

const std::string *IdentifierTable::name_of(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= id_to_name.size()) {
		return nullptr;
	}
	return &id_to_name[p_id];
}

std::vector<DefinitionId> IdentifierTable::canonical_order() const {
	std::vector<DefinitionId> order;
	if (!is_sealed) {
		return order;
	}
	order.reserve(entries.size());
	for (const auto &entry : entries) {
		order.push_back(entry.second);
	}
	return order;
}

Status IdentifierTable::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED, DiagnosticId::NONE, 0);
	}
	is_sealed = true;

	// `entries` is a std::map<std::string, ...>, so iterating it already
	// visits identifiers in ascending byte order regardless of insertion
	// order -- exactly the canonical order dense ids are assigned in.
	id_to_name.assign(entries.size() + 1, std::string()); // index 0 unused (INVALID_DEFINITION_ID)
	DefinitionId next_id = 1;
	for (auto &entry : entries) {
		entry.second = next_id;
		id_to_name[next_id] = entry.first;
		++next_id;
	}
	return ok_status();
}

std::uint64_t IdentifierTable::fingerprint() const {
	Hasher hasher;
	for (const auto &entry : entries) {
		hasher.write_string(entry.first);
		hasher.write_u32(entry.second);
	}
	return hasher.digest();
}

} // namespace ga
